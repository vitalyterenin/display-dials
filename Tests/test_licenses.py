import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import licenses


class LicenseDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in (*licenses.FILES, 'release.json', 'Package.resolved'):
            shutil.copyfile(licenses.ROOT / name, self.root / name)
        self.patch = patch.object(licenses, 'ROOT', self.root)
        self.patch.start(); self.addCleanup(self.patch.stop)
        self.image = self.root / 'image'; self.image.mkdir()
        self.app = self.image / 'Example.app'
        info = self.app / 'Contents/Frameworks/Sparkle.framework/Resources/Info.plist'
        info.parent.mkdir(parents=True)
        version = licenses.source_files()[1]
        info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
        notice = (self.root / 'THIRD_PARTY_NOTICES.md').read_text()
        self.upstream = self.root / 'Sparkle-LICENSE'
        self.upstream.write_text(notice.split('```text\n', 1)[1].rsplit('```', 1)[0])

    def install(self):
        licenses.install(self.app, self.upstream)

    def test_license_survives_copying_only_the_app_from_the_disk_image(self):
        self.install(); licenses.stage_distribution(self.app, self.image)
        licenses.verify_distribution(self.image, self.app.name)
        installed = self.root / 'Applications/Example.app'
        shutil.copytree(self.app, installed)
        shutil.rmtree(self.image)
        licenses.verify_bundle(installed)
        self.assertEqual((installed / 'Contents/Resources/Licenses/LICENSE').read_bytes(), (self.root / 'LICENSE').read_bytes())

    def test_missing_or_modified_bundle_notices_block_distribution(self):
        self.install()
        path = self.app / 'Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md'
        path.write_text('truncated')
        with self.assertRaisesRegex(ValueError, 'THIRD_PARTY_NOTICES'):
            licenses.verify_bundle(self.app)
        path.unlink()
        with self.assertRaises(FileNotFoundError): licenses.verify_bundle(self.app)

    def test_missing_bundle_mit_blocks_packaging_even_if_image_has_a_license(self):
        self.install(); licenses.stage_distribution(self.app, self.image)
        (self.app / 'Contents/Resources/Licenses/LICENSE').unlink()
        with self.assertRaises(FileNotFoundError): licenses.verify_distribution(self.image, self.app.name)

    def test_missing_image_license_is_rejected(self):
        self.install(); licenses.stage_distribution(self.app, self.image)
        (self.image / 'LICENSE').unlink()
        with self.assertRaises(FileNotFoundError): licenses.verify_distribution(self.image, self.app.name)

    def test_changed_dependency_license_must_be_reviewed_before_install(self):
        self.upstream.write_text('Upstream changed its license or external notices')
        with self.assertRaisesRegex(ValueError, 'Complete upstream'):
            self.install()
        self.assertFalse((self.app / 'Contents/Resources/Licenses').exists())

    def test_truncated_mit_or_missing_copyright_is_rejected(self):
        path = self.root / 'LICENSE'; original = path.read_text()
        for changed in [original.replace('SOFTWARE.', ''), '\n'.join(line for line in original.splitlines() if not line.startswith('Copyright'))]:
            path.write_text(changed)
            with self.assertRaises(ValueError): licenses.source_files()

    def test_dependency_upgrade_cannot_reuse_stale_notices(self):
        path = self.root / 'Package.resolved'; data = json.loads(path.read_text())
        next(p for p in data['pins'] if p['identity'] == 'sparkle')['state']['version'] = '999.0.0'
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'pinned Sparkle'): licenses.source_files()

    def test_unapproved_license_cannot_silently_replace_mit(self):
        path = self.root / 'release.json'; data = json.loads(path.read_text()); data['license'] = 'unapproved'
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'owner-approved'): licenses.source_files()


if __name__ == '__main__': unittest.main()
