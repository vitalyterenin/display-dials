#!/usr/bin/env python3
"""Publish a verified release to the existing Yandex bucket, feed last."""
import argparse
import base64
import hashlib
import json
import pathlib
import xml.etree.ElementTree as ET

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from release import config, object_key

BUCKET = 'teren.in'
RELEASE = config()
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
ARCHIVE_NAME = 'DisplayDials.dmg'
DOWNLOAD_URL = RELEASE['downloadURL']
DOWNLOAD_KEY = object_key(DOWNLOAD_URL)
FEED_KEY = object_key(RELEASE['feedURL'])
ALLOWED_KEYS = {DOWNLOAD_KEY, FEED_KEY}
NO_CACHE = 'no-store, max-age=0'


def publish(directory, client=None):
    directory = pathlib.Path(directory)
    state = json.loads((directory / 'publication.json').read_text())
    feed = (directory / 'appcast.xml').read_bytes()
    root = ET.fromstring(feed)
    items = root.findall('./channel/item')
    if len(items) != 1 or items[0].find('enclosure').get('url') != DOWNLOAD_URL:
        raise ValueError('The feed must contain one current release at the permanent download URL')
    latest = items[0]
    filename = ARCHIVE_NAME
    archive = (directory / filename).read_bytes()
    for name, content in [(filename, archive), ('appcast.xml', feed)]:
        if hashlib.sha256(content).hexdigest() != state['sha256'][name]:
            raise ValueError(f'{name} does not match the verified build artifact')
    client = client or boto3.client(
        's3', endpoint_url='https://storage.yandexcloud.net', region_name='ru-central1',
        config=Config(signature_version='s3v4', s3={'addressing_style': 'path'},
                      request_checksum_calculation='when_required',
                      response_checksum_validation='when_required'))

    # Check the credential boundary without creating or replacing any object.
    # An impossible ETag condition prevents mutation even if access is too broad.
    for key in ('index.html', 'apps/index.html', 'apps/OtherApp.dmg', 'apps/feeds/other-app.xml'):
        try:
            client.put_object(Bucket=BUCKET, Key=key,
                              Body=b'', IfMatch='"00000000000000000000000000000000"')
        except ClientError as error:
            if error.response['ResponseMetadata']['HTTPStatusCode'] != 403:
                raise ValueError('Publisher can access files outside its two release objects') from error
        else:
            raise ValueError('Publisher unexpectedly wrote an unrelated file')
    print('Verified: publisher cannot change site pages or another application')

    def key_for(name):
        return DOWNLOAD_KEY if name == ARCHIVE_NAME else FEED_KEY

    def get(name):
        try:
            response = client.get_object(Bucket=BUCKET, Key=key_for(name))
            return response['Body'].read(), response['ETag']
        except ClientError as error:
            if error.response['ResponseMetadata']['HTTPStatusCode'] != 404:
                raise
            return None, None

    current_feed, current_etag = get('appcast.xml')
    if current_feed != feed and current_etag != state['etag']:
        raise ValueError('The feed changed before publication; download was not replaced')
    same_build = False
    if current_feed:
        current = max(ET.fromstring(current_feed).findall('./channel/item'),
                      key=lambda item: int(item.findtext('sparkle:version', namespaces=NS)))
        current_build = int(current.findtext('sparkle:version', namespaces=NS))
        next_build = int(latest.findtext('sparkle:version', namespaces=NS))
        if next_build < current_build:
            raise ValueError('Refusing to replace a newer release')
        same_build = next_build == current_build
        if same_build:
            signature = '{' + NS['sparkle'] + '}edSignature'
            old, new = current.find('enclosure'), latest.find('enclosure')
            if (old.get(signature) != new.get(signature) or old.get('length') != new.get('length')
                    or current.findtext('sparkle:shortVersionString', namespaces=NS)
                    != latest.findtext('sparkle:shortVersionString', namespaces=NS)):
                raise ValueError('A build number cannot be reused for different app bytes')

    def put(name, content, content_type, cache_control, condition):
        client.put_object(Bucket=BUCKET, Key=key_for(name), Body=content,
                          ContentType=content_type, CacheControl=cache_control,
                          ContentMD5=base64.b64encode(hashlib.md5(content).digest()).decode(),
                          **condition)

    existing_archive, archive_etag = get(filename)
    if same_build and existing_archive is not None and existing_archive != archive:
        raise ValueError('The current build already has different download bytes')
    condition = {'IfMatch': archive_etag} if archive_etag else {'IfNoneMatch': '*'}
    put(filename, archive, 'application/x-apple-diskimage', NO_CACHE, condition)
    uploaded = client.get_object(Bucket=BUCKET, Key=DOWNLOAD_KEY)['Body'].read()
    if uploaded != archive:
        raise ValueError('Uploaded archive differs from the verified artifact; feed was not changed')
    condition = {'IfMatch': current_etag} if current_etag else {'IfNoneMatch': '*'}
    try:
        put('appcast.xml', feed, 'application/xml; charset=utf-8', NO_CACHE, condition)
    except ClientError as error:
        if error.response['ResponseMetadata']['HTTPStatusCode'] != 412:
            raise
        existing = client.get_object(Bucket=BUCKET, Key=FEED_KEY)['Body'].read()
        if existing != feed:
            raise ValueError('The published feed changed during this release; refusing to overwrite it') from error
    published = client.get_object(Bucket=BUCKET, Key=FEED_KEY)['Body'].read()
    if published != feed:
        raise ValueError('Published feed differs from the verified artifact')
    print('Published: ' + DOWNLOAD_URL)
    print('Feed: ' + RELEASE['feedURL'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    publish(parser.parse_args().directory)
