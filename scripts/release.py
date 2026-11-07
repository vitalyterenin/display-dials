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
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACCOUNT = 'com.vitalyterenin.displaydials'
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def config():
    data = json.loads((ROOT / 'release.json').read_text())
    if not re.fullmatch(r'\d+\.\d+\.\d+', data['version']):
        raise ValueError('version must be three numeric components')
    if not re.fullmatch(r'[1-9]\d*', data['build']):
        raise ValueError('build must be a positive, increasing integer')
    if len(base64.b64decode(data['publicEDKey'], validate=True)) != 32:
        raise ValueError('publicEDKey must contain the Sparkle public key')
    for key in ('feedURL', 'downloadURLPrefix'):
        url = urllib.parse.urlparse(data[key])
        if url.scheme != 'https' or not url.netloc or url.query or url.fragment:
            raise ValueError(f'{key} must be an HTTPS URL without a query or fragment')
    if data['feedURL'] != data['downloadURLPrefix'] + 'appcast.xml':
        raise ValueError('feedURL must be downloadURLPrefix + appcast.xml')
    return data


def write_plist(path):
    data = config()
    values = dict(
        CFBundleName='Display Dials', CFBundleDisplayName='Display Dials',
        CFBundleIdentifier=ACCOUNT, CFBundleExecutable='DisplayDials',
        CFBundlePackageType='APPL', CFBundleShortVersionString=data['version'],
        CFBundleVersion=data['build'], LSMinimumSystemVersion='13.0',
        LSUIElement=True, NSHighResolutionCapable=True,
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
                          ('SUFeedURL', data['feedURL'])]:
        if plist.get(key) != expected:
            raise ValueError(f'Built app has unexpected {key}; rebuild it')
    run('codesign', '--verify', '--deep', '--strict', app)
    architectures = subprocess.check_output(
        ['lipo', '-archs', str(app / 'Contents/MacOS/DisplayDials')], text=True).strip()
    if architectures != 'arm64':
        raise ValueError('Releases must contain only the arm64 app binary')
    archive = output / f'DisplayDials-{data["version"]}.zip'
    if previous:
        previous = pathlib.Path(previous)
        content = previous.read_bytes()
        _, versions = read_feed(content)
        if versions and int(data['build']) <= max(versions):
            raise ValueError('New build must be greater than every published build')
        (output / 'appcast.xml').write_bytes(content)
    state_file = pathlib.Path(previous).with_suffix('.state.json') if previous else None
    state = json.loads(state_file.read_text()) if state_file and state_file.exists() else {'etag': None}
    (output / 'publication.json').write_text(json.dumps(state))
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    args, kwargs = signing_args()
    run(pathlib.Path(tools) / 'bin/generate_appcast', *args,
        '--download-url-prefix', data['downloadURLPrefix'],
        '--maximum-deltas', '0', '--maximum-versions', '0',
        '--link', 'https://teren.in/', output, **kwargs)
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify',
        output / 'appcast.xml', **kwargs)
    root, _ = read_feed((output / 'appcast.xml').read_bytes())
    item = next((i for i in root.findall('./channel/item')
                 if i.findtext('sparkle:version', namespaces=NS) == data['build']), None)
    if item is None:
        raise ValueError('Generated appcast does not contain this build')
    if item.findtext('sparkle:hardwareRequirements', namespaces=NS) != 'arm64':
        raise ValueError('Generated appcast must require Apple Silicon')
    enclosure = item.find('enclosure')
    if enclosure.get('url') != data['downloadURLPrefix'] + archive.name:
        raise ValueError('Unexpected archive URL')
    signature = enclosure.get('{' + NS['sparkle'] + '}edSignature')
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify', archive, signature, **kwargs)
    # Keep the artifact manifest separate from the signed Sparkle feed.
    state['sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (archive, output / 'appcast.xml')}
    (output / 'publication.json').write_text(json.dumps(state, indent=2) + '\n')
    print(f'Ready: {archive}\nFeed: {output / "appcast.xml"}')


def previous(path):
    # Read the origin directly so a stale CDN response cannot lose feed history.
    origin = 'https://storage.yandexcloud.net/teren.in/updates/display-dials/appcast.xml'
    request = urllib.request.Request(origin, headers={'Cache-Control': 'no-cache'})
    path = pathlib.Path(path)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content = response.read()
            etag = response.headers['ETag']
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print('No previous release; preparing the first appcast.')
            path.unlink(missing_ok=True)
            path.with_suffix('.state.json').write_text(json.dumps({'etag': None}))
            return
        raise
    read_feed(content)
    pathlib.Path(path).write_bytes(content)
    path.with_suffix('.state.json').write_text(json.dumps({'etag': etag}))


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
    commands.add_parser('validate')
    args = parser.parse_args()
    if args.command == 'plist': write_plist(args.path)
    elif args.command == 'previous': previous(args.path)
    elif args.command == 'package': package(args.app, args.output, args.tools, args.previous)
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
