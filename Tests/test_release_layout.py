import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import release

class Response:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self): return self.body

class PreviousFeedTests(unittest.TestCase):
    def test_migration_fallback_records_exact_legacy_feed_hash(self):
        body = b'<rss><channel/></rss>'
        with tempfile.TemporaryDirectory() as d, patch.object(release.urllib.request, 'urlopen', side_effect=[HTTPError('url',404,'missing',{},None),Response(body)]) as read:
            p=Path(d)/'previous.xml';release.previous(p)
            state=json.loads(p.with_suffix('.state.json').read_text())
            self.assertEqual(state['sourceURL'],release.config()['legacyFeedURLs'][0])
            self.assertEqual(state['previousFeedSHA256'],hashlib.sha256(body).hexdigest())
            self.assertEqual(read.call_args_list[0].args[0].full_url,release.config()['feedURL'])
    def test_existing_app_cannot_silently_become_a_first_release(self):
        with tempfile.TemporaryDirectory() as d, patch.object(release.urllib.request,'urlopen',side_effect=HTTPError('url',404,'missing',{},None)):
            with self.assertRaisesRegex(ValueError,'established'):
                release.previous(Path(d)/'previous.xml')
    def test_download_must_belong_to_its_repository(self):
        data=release.config();data['downloadURL']='https://github.com/other/repo/releases/latest/download/'+release.ARCHIVE_NAME
        with patch.object(release.json,'loads',return_value=data), self.assertRaises(ValueError):release.config()
if __name__ == '__main__': unittest.main()
