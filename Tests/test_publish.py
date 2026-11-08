import copy
from contextlib import closing
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import ssl
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import publish


class Client:
    def __init__(self):
        self.calls = []
        self.latest = None
        self.existing = None
        self.releases = []

    def request(self, path, method='GET', data=None):
        self.calls.append((path, method, data))
        if path.startswith('/git/ref/'):
            return {'object': {'type': 'commit', 'sha': 'checked'}}
        if path == '/releases/latest': return self.latest
        if path.startswith('/releases/tags/'): return self.existing
        if path.startswith('/releases?'): return self.releases
        if method == 'POST': return {'id': 42, 'assets': [], 'draft': True}
        return None

    def upload(self, release_id, name, body):
        self.calls.append(('upload', release_id, name))

    @property
    def mutations(self):
        return [c for c in self.calls if c[0] == 'upload' or c[1] != 'GET']


class Clock:
    def __init__(self):
        self.now = 0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class PublicReadTests(unittest.TestCase):
    def test_selected_transient_errors_retry_then_accept_exact_bytes(self):
        errors = [urllib.error.HTTPError('https://example.test', code, 'transient', {}, None)
                  for code in (404, 408, 429, 500, 502, 503, 504)]
        errors += [urllib.error.URLError('temporary connection failure'), TimeoutError(),
                   ConnectionResetError(), http.client.IncompleteRead(b'partial')]
        for error in errors:
            with self.subTest(error=repr(error)):
                clock = Clock()
                with patch.object(publish, 'public_bytes', side_effect=[error, b'exact']) as fetch:
                    self.assertTrue(publish.wait_for_public_bytes([('https://example.test', b'exact')],
                        attempts=2, sleep=clock.sleep, clock=clock))
                self.assertEqual(fetch.call_count, 2)
                self.assertEqual(clock.sleeps, [5])

    def test_permanent_errors_fail_without_retry(self):
        errors = [urllib.error.HTTPError('https://example.test', code, 'permanent', {}, None)
                  for code in (400, 401, 403, 410, 501, 505)]
        errors += [urllib.error.URLError(ssl.SSLCertVerificationError('untrusted certificate')),
                   ValueError('invalid response')]
        for error in errors:
            with self.subTest(error=repr(error)):
                clock = Clock()
                with patch.object(publish, 'public_bytes', side_effect=error) as fetch:
                    with self.assertRaises(type(error)):
                        publish.wait_for_public_bytes([('https://example.test', b'exact')],
                            sleep=clock.sleep, clock=clock)
                fetch.assert_called_once()
                self.assertFalse(clock.sleeps)

    def test_missing_and_cached_bytes_retry_within_attempt_limit(self):
        clock = Clock()
        with patch.object(publish, 'public_bytes', side_effect=[None, b'cached', b'exact']) as fetch:
            self.assertTrue(publish.wait_for_public_bytes([('https://example.test', b'exact')],
                attempts=3, sleep=clock.sleep, clock=clock))
        self.assertEqual(fetch.call_count, 3)
        self.assertEqual(clock.sleeps, [5, 5])

    def test_matching_bytes_after_deadline_are_rejected(self):
        clock = Clock()
        def fetch(url):
            clock.now += 3
            return b'exact'
        self.assertFalse(publish.wait_for_public_bytes([('https://example.test', b'exact')],
            fetch=fetch, timeout=2, sleep=clock.sleep, clock=clock))
        self.assertFalse(clock.sleeps)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = publish.config()
        self.archive = b'verified signed disk image'
        self.old = b'<rss><channel><item xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><s:version>1</s:version></item></channel></rss>'
        self.feed = f'''<rss xmlns:sparkle="{publish.NS['sparkle']}"><channel><item>
<sparkle:version>{self.data['build']}</sparkle:version>
<sparkle:shortVersionString>{self.data['version']}</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="{self.data['downloadURL']}" length="{len(self.archive)}" sparkle:edSignature="verified-by-build"/>
</item></channel></rss>'''.encode()
        self.state = {'previousFeedSHA256': hashlib.sha256(self.old).hexdigest(),
                      'sourceURL': self.data['feedURL'], 'sha256': {
                          publish.ARCHIVE_NAME: hashlib.sha256(self.archive).hexdigest(),
                          'appcast.xml': hashlib.sha256(self.feed).hexdigest()}}
        (self.root / publish.ARCHIVE_NAME).write_bytes(self.archive)
        (self.root / 'appcast.xml').write_bytes(self.feed)
        self.save_state()
        self.client = Client()
        self.environ = patch.dict(os.environ, {'GITHUB_SHA': 'checked',
            'GITHUB_REF': 'refs/tags/v' + self.data['version'],
            'GITHUB_REPOSITORY': self.data['githubRepository']})
        self.environ.start(); self.addCleanup(self.environ.stop)

    def save_state(self):
        (self.root / 'publication.json').write_text(json.dumps(self.state))

    def fetch(self, url):
        return self.old if url == self.data['feedURL'] else self.archive

    def test_publish_verifies_download_before_staging_pages(self):
        publish.publish(self.root, self.client, self.fetch)
        self.assertEqual((self.root / 'pages/appcast.xml').read_bytes(), self.feed)
        self.assertIn(('upload', 42, publish.ARCHIVE_NAME), self.client.calls)
        self.assertEqual(self.client.mutations[-1][2], {'draft': False, 'make_latest': 'true'})

    def test_publish_retries_public_download_without_repeating_mutations(self):
        clock = Clock()
        downloads = []
        def fetch(url):
            if url == self.data['feedURL']:
                return self.old
            downloads.append(url)
            if len(downloads) == 1:
                raise urllib.error.URLError('temporary connection failure')
            return self.archive
        publish.publish(self.root, self.client, fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(downloads, [self.data['downloadURL']] * 2)
        self.assertEqual(clock.sleeps, [5])
        self.assertEqual(len(self.client.mutations), 3)
        self.assertEqual((self.root / 'pages/appcast.xml').read_bytes(), self.feed)

    def test_failed_download_verification_does_not_stage_pages(self):
        for response in [b'cached', urllib.error.URLError('temporary connection failure')]:
            with self.subTest(response=repr(response)):
                clock = Clock()
                self.client = Client()
                reads = []
                def fetch(url):
                    if url == self.data['feedURL']:
                        return self.old
                    reads.append(url)
                    if isinstance(response, Exception):
                        raise response
                    return response
                with self.assertRaisesRegex(ValueError, 'Pages was not staged'):
                    publish.publish(self.root, self.client, fetch, attempts=2,
                                    sleep=clock.sleep, clock=clock)
                self.assertEqual(len(reads), 2)
                self.assertEqual(len(self.client.mutations), 3)
                self.assertFalse((self.root / 'pages').exists())
                self.assertFalse(any(c[1] == 'DELETE' for c in self.client.calls))

    def test_failed_github_mutation_is_not_retried(self):
        clock = Clock()
        with patch.object(self.client, 'upload', side_effect=urllib.error.URLError('upload failed')) as upload:
            with self.assertRaises(urllib.error.URLError):
                publish.publish(self.root, self.client, self.fetch, sleep=clock.sleep, clock=clock)
            upload.assert_called_once()
        self.assertFalse(clock.sleeps)
        self.assertFalse((self.root / 'pages').exists())

    def test_corrupt_artifact_cannot_mutate_github(self):
        (self.root / publish.ARCHIVE_NAME).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'differs'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.calls)

    def test_non_github_previous_feed_cannot_be_fetched_or_published(self):
        self.state['sourceURL'] = 'https://example.invalid/appcast.xml'
        self.save_state()
        with patch.object(publish, 'public_bytes') as fetch:
            with self.assertRaisesRegex(ValueError, 'previous feed source'):
                publish.publish(self.root, self.client, fetch)
            fetch.assert_not_called()
        self.assertFalse(self.client.mutations)

    def test_stale_feed_cannot_mutate_release(self):
        with self.assertRaisesRegex(ValueError, 'feed changed'):
            publish.publish(self.root, self.client, lambda url: b'changed')
        self.assertFalse(self.client.mutations)

    def test_wrong_tag_commit_is_rejected(self):
        with patch.dict(os.environ, {'GITHUB_SHA': 'another'}):
            with self.assertRaisesRegex(ValueError, 'checked commit'):
                publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)

    def test_wrong_repository_and_branch_are_rejected(self):
        for env in [{'GITHUB_REPOSITORY': 'other/repo'}, {'GITHUB_REF': 'refs/heads/main'}]:
            with patch.dict(os.environ, env), self.assertRaises(ValueError):
                publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.calls)

    def test_newer_release_is_preserved(self):
        self.client.latest = {'tag_name': 'v999.0.0'}
        with self.assertRaisesRegex(ValueError, 'newer'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)

    def test_cached_pages_cannot_allow_reusing_latest_github_build(self):
        self.client.latest = {'tag_name': 'v0.0.1', 'body': f"Build {self.data['build']}."}
        with self.assertRaisesRegex(ValueError, 'latest GitHub release'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)

    def test_existing_release_can_only_reuse_exact_bytes(self):
        self.client.existing = {'id': 42, 'draft': False, 'assets': [
            {'name': publish.ARCHIVE_NAME, 'browser_download_url': 'https://example.test/dmg'}]}
        publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(any(c[0] == 'upload' for c in self.client.calls))
        with self.assertRaisesRegex(ValueError, 'different archive'):
            publish.publish(self.root, self.client, lambda u: self.old if u == self.data['feedURL'] else b'other')

    def test_failed_pages_verification_never_deletes_assets(self):
        with self.assertRaisesRegex(ValueError, 'did not converge'):
            publish.verify(self.root, self.client, self.fetch, attempts=1)
        self.assertFalse(self.client.mutations)

    def test_transient_verification_exhaustion_never_calls_github(self):
        clock = Clock()
        with patch.object(publish, 'public_bytes', side_effect=urllib.error.URLError('offline')) as fetch:
            with self.assertRaisesRegex(ValueError, 'older downloads were preserved'):
                publish.verify(self.root, self.client, attempts=2, sleep=clock.sleep, clock=clock)
        self.assertEqual(fetch.call_count, 2)
        self.assertFalse(self.client.calls)

    def test_verification_deadline_caps_sleep_and_prevents_cleanup(self):
        clock = Clock()
        with patch.object(publish, 'public_bytes', return_value=b'cached') as fetch:
            with self.assertRaisesRegex(ValueError, 'did not converge'):
                publish.verify(self.root, self.client, timeout=6, sleep=clock.sleep, clock=clock)
        self.assertEqual(clock.sleeps, [5, 1])
        self.assertEqual(clock.now, 6)
        self.assertEqual(fetch.call_count, 2)
        self.assertFalse(self.client.calls)

    def test_permanent_http_error_prevents_cleanup_without_retry(self):
        clock = Clock()
        error = urllib.error.HTTPError(self.data['feedURL'], 403, 'forbidden', {}, None)
        with patch.object(publish, 'public_bytes', side_effect=error) as fetch:
            with self.assertRaises(urllib.error.HTTPError):
                publish.verify(self.root, self.client, sleep=clock.sleep, clock=clock)
        fetch.assert_called_once()
        self.assertFalse(clock.sleeps)
        self.assertFalse(self.client.calls)

    def test_zero_attempts_cannot_skip_verification(self):
        with self.assertRaisesRegex(ValueError, 'positive attempt'):
            publish.verify(self.root, self.client, self.fetch, attempts=0)
        self.assertFalse(self.client.calls)

    def test_default_fetch_receives_remaining_timeout_for_each_url(self):
        clock = Clock()
        self.client.latest = {'tag_name': 'v' + self.data['version']}
        requests = []
        def open_url(request, timeout):
            requests.append((request.full_url, timeout))
            clock.now += 2
            body = self.feed if request.full_url == self.data['feedURL'] else self.archive
            return closing(io.BytesIO(body))
        with patch.object(publish.urllib.request, 'urlopen', side_effect=open_url):
            publish.verify(self.root, self.client, timeout=10, sleep=clock.sleep, clock=clock)
        self.assertEqual(requests, [(self.data['feedURL'], 10), (self.data['downloadURL'], 8)])
        self.assertFalse(clock.sleeps)

    def test_cached_archive_requires_both_public_files_to_match_before_cleanup(self):
        clock = Clock()
        self.client.latest = {'tag_name': 'v' + self.data['version']}
        self.client.releases = [{'tag_name': 'v0.0.1', 'draft': False,
                                 'assets': [{'id': 1, 'name': publish.ARCHIVE_NAME}]}]
        requests = []
        def fetch(url):
            self.assertFalse(self.client.calls, 'Cleanup must wait for all public bytes to match.')
            requests.append(url)
            if url == self.data['feedURL']:
                return self.feed
            return b'cached' if len(requests) == 2 else self.archive
        publish.verify(self.root, self.client, fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(requests, [self.data['feedURL'], self.data['downloadURL']] * 2)
        self.assertEqual(clock.sleeps, [5])
        self.assertEqual(self.client.mutations, [('/releases/assets/1', 'DELETE', None)])

    def test_cleanup_preserves_current_drafts_tags_and_unrelated_assets(self):
        self.client.latest = {'tag_name': 'v' + self.data['version']}
        self.client.releases = [
            {'tag_name': 'v0.0.1', 'draft': False, 'assets': [
                {'id': 1, 'name': publish.ARCHIVE_NAME}, {'id': 2, 'name': 'notes.txt'}]},
            {'tag_name': 'v' + self.data['version'], 'draft': False, 'assets': [{'id': 3, 'name': publish.ARCHIVE_NAME}]},
            {'tag_name': 'v0.0.2', 'draft': True, 'assets': [{'id': 4, 'name': publish.ARCHIVE_NAME}]}]
        publish.verify(self.root, self.client, lambda u: self.feed if u == self.data['feedURL'] else self.archive, attempts=1)
        self.assertEqual(self.client.mutations, [('/releases/assets/1', 'DELETE', None)])

    def test_publication_does_not_reuse_a_build(self):
        self.old = self.feed.replace(b'arm64', b'arm64 ')
        self.state['previousFeedSHA256'] = hashlib.sha256(self.old).hexdigest(); self.save_state()
        with self.assertRaisesRegex(ValueError, 'Build numbers'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)


if __name__ == '__main__': unittest.main()
