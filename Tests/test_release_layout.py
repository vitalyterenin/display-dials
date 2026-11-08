import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import release


class Response:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self): return self.body


class PreviousFeedTests(unittest.TestCase):
    def test_previous_feed_uses_only_github_and_records_exact_hash(self):
        body = b'<rss><channel/></rss>'
        with tempfile.TemporaryDirectory() as directory, patch.object(
                release.urllib.request, 'urlopen', return_value=Response(body)) as read:
            path = Path(directory) / 'previous.xml'
            release.previous(path)
            state = json.loads(path.with_suffix('.state.json').read_text())
            self.assertEqual(path.read_bytes(), body)
            self.assertEqual(state['sourceURL'], release.config()['feedURL'])
            self.assertEqual(state['previousFeedSHA256'], hashlib.sha256(body).hexdigest())
            read.assert_called_once()
            self.assertEqual(read.call_args.args[0].full_url, release.config()['feedURL'])

    def test_missing_or_unavailable_feed_never_falls_back_or_resets_history(self):
        errors = [HTTPError('url', 404, 'missing', {}, None),
                  HTTPError('url', 503, 'unavailable', {}, None),
                  URLError('offline')]
        for error in errors:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory, patch.object(
                    release.urllib.request, 'urlopen', side_effect=error) as read:
                path = Path(directory) / 'previous.xml'
                expected = ValueError if isinstance(error, HTTPError) and error.code == 404 else type(error)
                with self.assertRaises(expected):
                    release.previous(path)
                read.assert_called_once()
                self.assertEqual(read.call_args.args[0].full_url, release.config()['feedURL'])
                self.assertFalse(path.exists())
                self.assertFalse(path.with_suffix('.state.json').exists())

    def test_download_must_belong_to_its_repository(self):
        data = release.config()
        data['downloadURL'] = 'https://github.com/other/repo/releases/latest/download/' + release.ARCHIVE_NAME
        with patch.object(release.json, 'loads', return_value=data), self.assertRaises(ValueError):
            release.config()

    def test_feed_must_belong_to_its_github_pages_repository(self):
        data = release.config()
        data['feedURL'] = 'https://example.invalid/appcast.xml'
        with patch.object(release.json, 'loads', return_value=data), self.assertRaises(ValueError):
            release.config()


if __name__ == '__main__': unittest.main()
