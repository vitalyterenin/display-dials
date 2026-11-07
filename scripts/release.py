#!/usr/bin/env python3
"""Build metadata and package signed updates for the one stable feed."""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACCOUNT = 'com.vitalyterenin.displaydials'
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
ARCHIVE_NAME = 'DisplayDials.dmg'


def config():
    data = json.loads((ROOT / 'release.json').read_text())
    if not re.fullmatch(r'\d+\.\d+\.\d+', data['version']):
        raise ValueError('version must be three numeric components')
    if not re.fullmatch(r'[1-9]\d*', data['build']):
        raise ValueError('build must be a positive, increasing integer')
    if len(base64.b64decode(data['publicEDKey'], validate=True)) != 32:
        raise ValueError('publicEDKey must contain the Sparkle public key')
    if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', data['id']):
        raise ValueError('id must be a stable lowercase application slug')
    if object_key(data['downloadURL']) != 'apps/' + ARCHIVE_NAME:
        raise ValueError('The download must be a single app-named DMG directly inside /apps/')
    if object_key(data['feedURL']) != 'apps/feeds/' + data['id'] + '.xml':
        raise ValueError('The feed must be /apps/feeds/<app-id>.xml')
    for url in data.get('legacyFeedURLs', []):
        object_key(url)
    uuid.UUID(data['telemetryDeckAppID'])
    return data


def object_key(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.netloc != 'teren.in' or parsed.query or parsed.fragment
            or not re.fullmatch(r'/[A-Za-z0-9._/-]+', parsed.path)
            or any(part in ('', '.', '..') for part in parsed.path.split('/')[1:])):
        raise ValueError('Expected a plain HTTPS file URL on teren.in')
    return parsed.path.lstrip('/')


def origin_url(url):
    return 'https://storage.yandexcloud.net/teren.in/' + object_key(url)


def write_plist(path):
    data = config()
    values = dict(
        CFBundleName='Display Dials', CFBundleDisplayName='Display Dials',
        CFBundleIdentifier=ACCOUNT, CFBundleExecutable='DisplayDials',
        CFBundlePackageType='APPL', CFBundleIconFile='AppIcon.icns',
        CFBundleShortVersionString=data['version'],
        CFBundleVersion=data['build'], LSMinimumSystemVersion='13.0',
        LSUIElement=True, NSHighResolutionCapable=True,
        TelemetryDeckAppID=data['telemetryDeckAppID'],
        SUFeedURL=data['feedURL'], SUPublicEDKey=data['publicEDKey'],
        SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True,
        SUScheduledCheckInterval=14400, SUEnableSystemProfiling=False,
        SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
        SUSignedFeedFailureExpirationInterval=0,
    )
    pathlib.Path(path).write_bytes(plistlib.dumps(values))


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def signing_args():
    # CI supplies its secret over stdin, never in command-line arguments or files.
    secret = os.environ.get('SPARKLE_PRIVATE_KEY')
    if secret:
        return ['--ed-key-file', '-'], {'input': secret.encode()}
    return ['--account', ACCOUNT], {}


def read_feed(content):
    root = ET.fromstring(content)
    if root.tag != 'rss' or root.find('channel') is None:
        raise ValueError('Expected a Sparkle RSS appcast')
    return root, [int(item.findtext('sparkle:version', namespaces=NS))
                  for item in root.findall('./channel/item')]


def create_disk_image(app, archive):
    # One image serves both Finder installation and Sparkle updates.
    with tempfile.TemporaryDirectory(prefix='display-dials-dmg-') as staging:
        staging = pathlib.Path(staging)
        run('ditto', app, staging / app.name)
        (staging / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', 'Display Dials',
            '-srcfolder', staging, '-fs', 'APFS', '-format', 'ULFO',
            '-nospotlight', archive)
    run('hdiutil', 'verify', archive)


def package(app, output, tools, previous):
    data = config()
    output = pathlib.Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Use an empty package output directory')
    app = pathlib.Path(app).resolve()
    plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key, expected in [('CFBundleVersion', data['build']),
                          ('CFBundleShortVersionString', data['version']),
                          ('SUPublicEDKey', data['publicEDKey']),
                          ('TelemetryDeckAppID', data['telemetryDeckAppID']),
                          ('SUFeedURL', data['feedURL'])]:
        if plist.get(key) != expected:
            raise ValueError(f'Built app has unexpected {key}; rebuild it')
    run('codesign', '--verify', '--deep', '--strict', app)
    architectures = subprocess.check_output(
        ['lipo', '-archs', str(app / 'Contents/MacOS/DisplayDials')], text=True).strip()
    if architectures != 'arm64':
        raise ValueError('Releases must contain only the arm64 app binary')
    archive = output / ARCHIVE_NAME
    if previous:
        previous = pathlib.Path(previous)
        content = previous.read_bytes()
        _, versions = read_feed(content)
        if versions and int(data['build']) <= max(versions):
            raise ValueError('New build must be greater than every published build')
    state_file = pathlib.Path(previous).with_suffix('.state.json') if previous else None
    state = json.loads(state_file.read_text()) if state_file and state_file.exists() else {'etag': None}
    create_disk_image(app, archive)
    prepare_feed(output, tools, data, state)


def prepare_feed(output, tools, data, state):
    archive = output / ARCHIVE_NAME
    args, kwargs = signing_args()
    run(pathlib.Path(tools) / 'bin/generate_appcast', *args,
        '--download-url-prefix', data['downloadURL'].removesuffix(ARCHIVE_NAME),
        '--maximum-deltas', '0', '--maximum-versions', '1',
        '--link', 'https://teren.in/apps/', '-o', output / 'appcast.xml', output, **kwargs)
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify',
        output / 'appcast.xml', **kwargs)
    root, _ = read_feed((output / 'appcast.xml').read_bytes())
    items = root.findall('./channel/item')
    if len(items) != 1 or items[0].findtext('sparkle:version', namespaces=NS) != data['build']:
        raise ValueError('Generated appcast must contain only the current build')
    item = items[0]
    if item.findtext('sparkle:hardwareRequirements', namespaces=NS) != 'arm64':
        raise ValueError('Generated appcast must require Apple Silicon')
    enclosure = item.find('enclosure')
    if enclosure.get('url') != data['downloadURL']:
        raise ValueError('Unexpected archive URL')
    signature = enclosure.get('{' + NS['sparkle'] + '}edSignature')
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify', archive, signature, **kwargs)
    # Keep the artifact manifest separate from the signed Sparkle feed.
    state['sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (archive, output / 'appcast.xml')}
    (output / 'publication.json').write_text(json.dumps(state, indent=2) + '\n')
    print(f'Ready: {archive}\nFeed: {output / "appcast.xml"}')


def republish(output, tools, previous):
    """Reuse the signed, published DMG without rebuilding or changing its version."""
    data = config()
    output = pathlib.Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Use an empty package output directory')
    previous = pathlib.Path(previous)
    args, kwargs = signing_args()
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify', previous, **kwargs)
    root, _ = read_feed(previous.read_bytes())
    item = max(root.findall('./channel/item'), key=lambda i: int(i.findtext('sparkle:version', namespaces=NS)))
    if (item.findtext('sparkle:version', namespaces=NS) != data['build']
            or item.findtext('sparkle:shortVersionString', namespaces=NS) != data['version']):
        raise ValueError('The configured version must equal the currently published release')
    enclosure = item.find('enclosure')
    source = enclosure.get('url', '')
    allowed = {data['downloadURL']} | {
        url.rsplit('/', 1)[0] + '/' + ARCHIVE_NAME for url in data.get('legacyFeedURLs', [])}
    if source not in allowed:
        raise ValueError('The published download must belong to this application')
    with urllib.request.urlopen(origin_url(source), timeout=60) as response:
        content = response.read()
    if len(content) != int(enclosure.get('length')):
        raise ValueError('Published download length does not match the signed feed')
    archive = output / ARCHIVE_NAME
    archive.write_bytes(content)
    signature = enclosure.get('{' + NS['sparkle'] + '}edSignature')
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify', archive, signature, **kwargs)
    state = json.loads(previous.with_suffix('.state.json').read_text())
    prepare_feed(output, tools, data, state)


def previous(path):
    # Read the origin directly for the current build number and publication ETag.
    data = config()
    path = pathlib.Path(path)
    for url in [data['feedURL'], *data.get('legacyFeedURLs', [])]:
        request = urllib.request.Request(origin_url(url), headers={'Cache-Control': 'no-cache'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                content = response.read()
                etag = response.headers['ETag'] if url == data['feedURL'] else None
        except urllib.error.HTTPError as error:
            if error.code == 404:
                continue
            raise
        read_feed(content)
        path.write_bytes(content)
        path.with_suffix('.state.json').write_text(json.dumps({'etag': etag, 'sourceURL': url}))
        return
    print('No previous release; preparing the first appcast.')
    path.unlink(missing_ok=True)
    path.with_suffix('.state.json').write_text(json.dumps({'etag': None}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('plist')
    p.add_argument('path')
    p = commands.add_parser('previous')
    p.add_argument('path')
    p = commands.add_parser('package')
    p.add_argument('--app', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--tools', required=True)
    p.add_argument('--previous')
    p = commands.add_parser('republish')
    p.add_argument('--output', required=True)
    p.add_argument('--tools', required=True)
    p.add_argument('--previous', required=True)
    commands.add_parser('validate')
    args = parser.parse_args()
    if args.command == 'plist': write_plist(args.path)
    elif args.command == 'previous': previous(args.path)
    elif args.command == 'package': package(args.app, args.output, args.tools, args.previous)
    elif args.command == 'republish': republish(args.output, args.tools, args.previous)
    else:
        data = config()
        tag = os.environ.get('RELEASE_TAG')
        if tag and tag != 'v' + data['version']:
            raise ValueError('Git tag must match release.json version')
        print(f'Validated Display Dials {data["version"]} (build {data["build"]})')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
