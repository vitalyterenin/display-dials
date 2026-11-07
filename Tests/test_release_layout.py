"""Check public URL conventions and migration bootstrap conditions."""
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import release


class Response(io.BytesIO):
    headers = {'ETag': '"current-etag"'}


class ReleaseLayoutTests(unittest.TestCase):
    def test_download_and_feed_have_distinct_app_owned_keys(self):
        data = release.config()
        self.assertEqual(release.object_key(data['downloadURL']), 'apps/DisplayDials.dmg')
        self.assertEqual(release.object_key(data['feedURL']), 'apps/feeds/display-dials.xml')

    def test_rejects_foreign_or_ambiguous_origin_paths(self):
        for url in ['https://example.com/apps/DisplayDials.dmg', 'http://teren.in/apps/a.dmg',
                    'https://teren.in/apps/../index.html', 'https://teren.in/apps/%2e%2e/index.html',
                    'https://teren.in/apps/a.dmg?version=1', 'https://teren.in/apps//a.dmg']:
            with self.assertRaises(ValueError):
                release.origin_url(url)

    def test_legacy_feed_does_not_supply_etag_for_a_new_object(self):
        content = b'<rss><channel/></rss>'
        data = release.config()
        def read(request, timeout):
            if request.full_url == release.origin_url(data['feedURL']):
                raise urllib.error.HTTPError(request.full_url, 404, 'Not Found', {}, None)
            self.assertEqual(request.full_url, release.origin_url(data['legacyFeedURLs'][0]))
            return Response(content)
        with tempfile.TemporaryDirectory() as directory, patch.object(release.urllib.request, 'urlopen', side_effect=read):
            path = Path(directory) / 'previous.xml'
            release.previous(path)
            state = json.loads(path.with_suffix('.state.json').read_text())
            self.assertIsNone(state['etag'])
            self.assertEqual(state['sourceURL'], data['legacyFeedURLs'][0])
            self.assertEqual(path.read_bytes(), content)

    def test_existing_canonical_feed_supplies_its_own_etag(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release.urllib.request, 'urlopen', return_value=Response(b'<rss><channel/></rss>')) as read:
            path = Path(directory) / 'previous.xml'
            release.previous(path)
            state = json.loads(path.with_suffix('.state.json').read_text())
            self.assertEqual(state['etag'], '"current-etag"')
            self.assertEqual(read.call_count, 1)


if __name__ == '__main__':
    unittest.main()
