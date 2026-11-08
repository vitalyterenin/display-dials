#!/usr/bin/env python3
"""Publish a verified DMG to GitHub Releases, then verify Pages and prune old DMGs."""
import argparse
import hashlib
import json
import os
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request
from release import ARCHIVE_NAME, NS, config, read_feed


def public_bytes(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'Cache-Control': 'no-cache'}), timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, repository):
        self.repository = repository
        self.token = os.environ['GH_TOKEN']
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, path, method='GET', data=None):
        return self.send('https://api.github.com/repos/' + self.repository + path,
                         method, json.dumps(data).encode() if data is not None else None,
                         'application/json')

    def send(self, url, method, body, content_type):
        request = urllib.request.Request(url, data=body, method=method, headers={
            'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
            'Content-Type': content_type, 'User-Agent': 'app-release-publisher'})
        try:
            with self.opener.open(request, timeout=90) as response:
                content = response.read()
                return json.loads(content) if content else None
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == 'GET':
                return None
            raise ValueError(f'GitHub {method} failed with HTTP {error.code}') from error

    def upload(self, release_id, name, body):
        url = (f'https://uploads.github.com/repos/{self.repository}/releases/{release_id}/assets?'
               + urllib.parse.urlencode({'name': name}))
        return self.send(url, 'POST', body, 'application/octet-stream')


def load(directory):
    directory = pathlib.Path(directory)
    data = config()
    state = json.loads((directory / 'publication.json').read_text())
    feed = (directory / 'appcast.xml').read_bytes()
    archive = (directory / ARCHIVE_NAME).read_bytes()
    for name, body in [(ARCHIVE_NAME, archive), ('appcast.xml', feed)]:
        if hashlib.sha256(body).hexdigest() != state['sha256'][name]:
            raise ValueError(f'{name} differs from the verified build artifact')
    root, _ = read_feed(feed)
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('The feed must contain one release')
    item = items[0]
    if (item.findtext('sparkle:version', namespaces=NS) != data['build']
            or item.findtext('sparkle:shortVersionString', namespaces=NS) != data['version']
            or item.findtext('sparkle:hardwareRequirements', namespaces=NS) != 'arm64'):
        raise ValueError('Feed version, build or architecture does not match the release')
    enclosure = item.find('enclosure')
    if (enclosure is None or enclosure.get('url') != data['downloadURL']
            or int(enclosure.get('length', '0')) != len(archive)
            or not enclosure.get('{' + NS['sparkle'] + '}edSignature')):
        raise ValueError('Unexpected download metadata')
    return data, state, feed, archive


def publish(directory, client=None, fetch=public_bytes):
    data, state, feed, archive = load(directory)
    repository = data['githubRepository']
    if os.environ.get('GITHUB_REPOSITORY', repository) != repository:
        raise ValueError('Publication is restricted to its own repository')
    tag = 'v' + data['version']
    if os.environ.get('GITHUB_REF', 'refs/tags/' + tag) != 'refs/tags/' + tag:
        raise ValueError('Publication requires the matching release tag')
    client = client or GitHub(repository)
    ref = client.request('/git/ref/tags/' + tag)
    if not ref:
        raise ValueError('The release tag does not exist')
    target = ref['object']
    while target['type'] == 'tag':
        target = client.request('/git/tags/' + target['sha'])['object']
    if target['type'] != 'commit' or target['sha'] != os.environ.get('GITHUB_SHA', target['sha']):
        raise ValueError('The tag does not identify this checked commit')
    latest = client.request('/releases/latest')
    if latest and tuple(map(int, latest['tag_name'].removeprefix('v').split('.'))) > tuple(map(int, data['version'].split('.'))):
        raise ValueError('Refusing to replace a newer release')
    previous_url = state['sourceURL']
    if previous_url not in [data['feedURL'], *data.get('legacyFeedURLs', [])]:
        raise ValueError('Unexpected previous feed source')
    current = fetch(previous_url)
    current_hash = hashlib.sha256(current).hexdigest() if current is not None else None
    if current != feed and current_hash != state['previousFeedSHA256']:
        raise ValueError('The feed changed before publication')
    if current and current != feed:
        _, builds = read_feed(current)
        if builds and int(data['build']) <= max(builds):
            raise ValueError('Build numbers must increase')
    release = client.request('/releases/tags/' + tag)
    if release and not release['draft']:
        # Retry only with the exact already-published archive; never replace its bytes.
        asset = next((a for a in release['assets'] if a['name'] == ARCHIVE_NAME), None)
        if asset is None or fetch(asset['browser_download_url']) != archive:
            raise ValueError('This release already exists with different archive bytes')
        client.request('/releases/' + str(release['id']), 'PATCH', {'make_latest': 'true'})
    else:
        if release is None:
            release = client.request('/releases', 'POST', {
                'tag_name': tag, 'target_commitish': target['sha'], 'name': data['name'] + ' ' + data['version'],
                'draft': True, 'prerelease': False,
                'body': 'Stable Apple Silicon release. Requires macOS 13 or later.'})
        for asset in release['assets']:
            if asset['name'] == ARCHIVE_NAME:
                client.request('/releases/assets/' + str(asset['id']), 'DELETE')
        client.upload(release['id'], ARCHIVE_NAME, archive)
        client.request('/releases/' + str(release['id']), 'PATCH', {'draft': False, 'make_latest': 'true'})
    if fetch(data['downloadURL']) != archive:
        raise ValueError('Public download differs from the verified archive')
    pages = pathlib.Path(directory) / 'pages'
    pages.mkdir(exist_ok=True)
    (pages / 'appcast.xml').write_bytes(feed)
    (pages / '.nojekyll').write_text('')
    (pages / 'robots.txt').write_text('User-agent: *\nDisallow: /\n')
    print('GitHub DMG verified; signed feed is ready for Pages deployment')


def verify(directory, client=None, fetch=public_bytes, attempts=24, sleep=time.sleep):
    data, _, feed, archive = load(directory)
    for attempt in range(attempts):
        if fetch(data['feedURL']) == feed and fetch(data['downloadURL']) == archive:
            break
        if attempt + 1 == attempts:
            raise ValueError('Public feed/download did not converge; older downloads were preserved')
        sleep(5)
    client = client or GitHub(data['githubRepository'])
    tag = 'v' + data['version']
    latest = client.request('/releases/latest')
    if not latest or latest['tag_name'] != tag:
        raise ValueError('Latest release changed; cleanup was not performed')
    # Collect before deleting to keep pagination stable. Preserve releases, tags and other assets.
    releases, page = [], 1
    while True:
        batch = client.request('/releases?per_page=100&page=' + str(page))
        releases.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    for release in releases:
        if release['tag_name'] == tag or release['draft'] or release.get('prerelease'):
            continue
        if tuple(map(int, release['tag_name'].removeprefix('v').split('.'))) >= tuple(map(int, data['version'].split('.'))):
            continue
        for asset in release['assets']:
            if asset['name'] == ARCHIVE_NAME:
                if release.get('immutable'):
                    raise ValueError('An older immutable release prevents removing its DMG')
                client.request('/releases/assets/' + str(asset['id']), 'DELETE')
    print('Public signed feed and DMG verified; only the current DMG is retained')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['publish', 'verify'])
    parser.add_argument('directory')
    args = parser.parse_args()
    try:
        (publish if args.command == 'publish' else verify)(args.directory)
    except (ValueError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
