"""Exercise replacement and race protection without cloud credentials."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
import unittest
import xml.etree.ElementTree as ET

from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))

spec = importlib.util.spec_from_file_location('publish', Path(__file__).parents[1] / 'scripts/publish.py')
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


def feed(build, signature='signed', name='DisplayDials.dmg'):
    download = publication.DOWNLOAD_URL.rsplit('/', 1)[0] + '/' + name
    return f'''<rss xmlns:sparkle="{publication.NS['sparkle']}"><channel><item>
    <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>0.6.{build}</sparkle:shortVersionString>
    <enclosure url="{download}" length="3" sparkle:edSignature="{signature}"/>
    </item></channel></rss>'''.encode()


class Storage:
    def __init__(self, objects=None):
        self.objects = dict(objects or {})
        self.puts = []

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise ClientError({'ResponseMetadata': {'HTTPStatusCode': 404}}, 'GetObject')
        content = self.objects[Key]
        return {'Body': io.BytesIO(content), 'ETag': self.etag(content)}

    @staticmethod
    def etag(content):
        return '"' + hashlib.md5(content).hexdigest() + '"'

    def put_object(self, **arguments):
        key = arguments['Key']
        if key not in publication.ALLOWED_KEYS:
            raise ClientError({'ResponseMetadata': {'HTTPStatusCode': 403}}, 'PutObject')
        previous = self.objects.get(key)
        if (arguments.get('IfNoneMatch') == '*' and previous is not None
                or 'IfMatch' in arguments and (previous is None or arguments['IfMatch'] != self.etag(previous))):
            raise ClientError({'ResponseMetadata': {'HTTPStatusCode': 412}}, 'PutObject')
        self.objects[key] = arguments['Body']
        self.puts.append(arguments)


class PublicationTests(unittest.TestCase):
    def artifact(self, content, etag=None, archive=b'new'):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name)
        (path / 'DisplayDials.dmg').write_bytes(archive)
        (path / 'appcast.xml').write_bytes(content)
        state = {'etag': etag, 'sha256': {
            'DisplayDials.dmg': hashlib.sha256(archive).hexdigest(),
            'appcast.xml': hashlib.sha256(content).hexdigest()}}
        (path / 'publication.json').write_text(json.dumps(state))
        return path

    def test_first_publication_has_only_two_permanent_objects(self):
        storage = Storage()
        publication.publish(self.artifact(feed(1)), storage)
        self.assertEqual(set(storage.objects), publication.ALLOWED_KEYS)
        self.assertEqual([x['Key'] for x in storage.puts], [publication.DOWNLOAD_KEY, publication.FEED_KEY])
        self.assertTrue(all('no-store' in x['CacheControl'] for x in storage.puts))

    def test_next_release_replaces_the_same_object(self):
        current = feed(1, 'old')
        storage = Storage({publication.DOWNLOAD_KEY: b'old', publication.FEED_KEY: current})
        publication.publish(self.artifact(feed(2), Storage.etag(current)), storage)
        self.assertEqual(len(storage.objects), 2)
        self.assertEqual(storage.objects[publication.DOWNLOAD_KEY], b'new')

    def test_releases_do_not_modify_the_catalog_or_another_app(self):
        unrelated = {'apps/index.html': b'catalog', 'apps/OtherApp.dmg': b'other-app', 'index.html': b'personal-site'}
        storage = Storage(unrelated)
        publication.publish(self.artifact(feed(1)), storage)
        for key, content in unrelated.items():
            self.assertEqual(storage.objects[key], content)
        self.assertEqual({item['Key'] for item in storage.puts}, publication.ALLOWED_KEYS)

    def test_overbroad_credentials_abort_before_publication(self):
        class OverbroadStorage(Storage):
            def put_object(self, **arguments):
                if arguments['Key'] not in publication.ALLOWED_KEYS:
                    raise ClientError({'ResponseMetadata': {'HTTPStatusCode': 412}}, 'PutObject')
                return super().put_object(**arguments)
        storage = OverbroadStorage()
        with self.assertRaisesRegex(ValueError, 'outside its two release objects'):
            publication.publish(self.artifact(feed(1)), storage)
        self.assertEqual(storage.objects, {})

    def test_stale_feed_aborts_before_replacing_download(self):
        storage = Storage({publication.DOWNLOAD_KEY: b'old', publication.FEED_KEY: feed(5)})
        with self.assertRaisesRegex(ValueError, 'changed before publication'):
            publication.publish(self.artifact(feed(2), '"stale"'), storage)
        self.assertEqual(storage.puts, [])

    def test_cannot_reuse_build_number_with_a_new_signature(self):
        current = feed(1, 'old')
        storage = Storage({publication.DOWNLOAD_KEY: b'old', publication.FEED_KEY: current})
        with self.assertRaisesRegex(ValueError, 'cannot be reused'):
            publication.publish(self.artifact(feed(1, 'different'), Storage.etag(current)), storage)
        self.assertEqual(storage.puts, [])

    def test_migration_reuses_current_signed_archive(self):
        current = feed(1, name='DisplayDials-0.6.1.dmg')
        storage = Storage({publication.FEED_KEY: current})
        publication.publish(self.artifact(feed(1), Storage.etag(current)), storage)
        self.assertEqual(storage.objects[publication.DOWNLOAD_KEY], b'new')

    def test_retry_after_publication_is_idempotent(self):
        content = feed(1)
        storage = Storage({publication.DOWNLOAD_KEY: b'new', publication.FEED_KEY: content})
        publication.publish(self.artifact(content, '"earlier-etag"'), storage)
        self.assertEqual(len(storage.objects), 2)

    def test_rejects_versioned_or_historical_downloads(self):
        history = ET.fromstring(feed(1))
        history.find('channel').append(ET.fromstring(feed(2)).find('./channel/item'))
        for content in [feed(1, name='DisplayDials-0.6.1.dmg'), ET.tostring(history)]:
            with self.assertRaisesRegex(ValueError, 'one current release'):
                publication.publish(self.artifact(content), Storage())

    def test_archive_race_does_not_publish_feed(self):
        class RacingStorage(Storage):
            def put_object(self, **arguments):
                if arguments['Key'] == publication.DOWNLOAD_KEY:
                    self.objects[arguments['Key']] = b'concurrent-release'
                return super().put_object(**arguments)
        current = feed(1, 'old')
        storage = RacingStorage({publication.DOWNLOAD_KEY: b'old', publication.FEED_KEY: current})
        with self.assertRaises(ClientError):
            publication.publish(self.artifact(feed(2), Storage.etag(current)), storage)
        self.assertEqual(storage.objects[publication.FEED_KEY], current)

    def test_changed_artifact_is_never_uploaded(self):
        path = self.artifact(feed(1))
        (path / 'DisplayDials.dmg').write_bytes(b'bad')
        storage = Storage()
        with self.assertRaisesRegex(ValueError, 'verified build artifact'):
            publication.publish(path, storage)
        self.assertEqual(storage.puts, [])


if __name__ == '__main__':
    unittest.main()
