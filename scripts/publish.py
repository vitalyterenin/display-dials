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

BUCKET = 'teren.in'
PREFIX = 'updates/display-dials/'
ORIGIN = 'https://storage.yandexcloud.net/' + BUCKET + '/' + PREFIX
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def publish(directory, client=None):
    directory = pathlib.Path(directory)
    state = json.loads((directory / 'publication.json').read_text())
    feed = (directory / 'appcast.xml').read_bytes()
    root = ET.fromstring(feed)
    latest = max(root.findall('./channel/item'),
                 key=lambda item: int(item.findtext('sparkle:version', namespaces=NS)))
    filename = latest.find('enclosure').get('url').removeprefix('https://teren.in/' + PREFIX)
    if '/' in filename or not filename.startswith('DisplayDials-') or not filename.endswith('.zip'):
        raise ValueError('Unexpected update archive name')
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
    try:
        client.put_object(Bucket=BUCKET, Key='updates/display-dials-access-check',
                          Body=b'', IfMatch='"00000000000000000000000000000000"')
    except ClientError as error:
        if error.response['ResponseMetadata']['HTTPStatusCode'] != 403:
            raise ValueError('Publisher is not restricted to its application prefix') from error
    else:
        raise ValueError('Publisher unexpectedly wrote outside its application prefix')
    print('Verified: publishing credential is restricted to this application prefix')

    def put(name, content, content_type, cache_control, condition):
        client.put_object(Bucket=BUCKET, Key=PREFIX + name, Body=content,
                          ContentType=content_type, CacheControl=cache_control,
                          ContentMD5=base64.b64encode(hashlib.md5(content).digest()).decode(),
                          **condition)

    try:
        put(filename, archive, 'application/zip', 'public, max-age=31536000, immutable',
            {'IfNoneMatch': '*'})
    except ClientError as error:
        if error.response['ResponseMetadata']['HTTPStatusCode'] != 412:
            raise
        existing = client.get_object(Bucket=BUCKET, Key=PREFIX + filename)['Body'].read()
        if existing != archive:
            raise ValueError('This version already exists with different bytes; publish a new version') from error
    uploaded = client.get_object(Bucket=BUCKET, Key=PREFIX + filename)['Body'].read()
    if uploaded != archive:
        raise ValueError('Uploaded archive differs from the verified artifact; feed was not changed')
    condition = {'IfMatch': state['etag']} if state['etag'] else {'IfNoneMatch': '*'}
    try:
        put('appcast.xml', feed, 'application/xml; charset=utf-8', 'no-cache, max-age=0, must-revalidate', condition)
    except ClientError as error:
        if error.response['ResponseMetadata']['HTTPStatusCode'] != 412:
            raise
        existing = client.get_object(Bucket=BUCKET, Key=PREFIX + 'appcast.xml')['Body'].read()
        if existing != feed:
            raise ValueError('The published feed changed during this release; refusing to overwrite it') from error
    published = client.get_object(Bucket=BUCKET, Key=PREFIX + 'appcast.xml')['Body'].read()
    if published != feed:
        raise ValueError('Published feed differs from the verified artifact')
    print('Published: https://teren.in/' + PREFIX + filename)
    print('Feed: https://teren.in/' + PREFIX + 'appcast.xml')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    publish(parser.parse_args().directory)
