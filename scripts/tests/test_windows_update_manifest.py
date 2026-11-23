import base64
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('windows_update_manifest', Path(__file__).parents[1] / 'windows-update-manifest.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WindowsUpdateManifestTests(unittest.TestCase):
    signature = base64.b64encode(b'untrusted comment: fixture\nsignature\ntrusted comment: fixture\nglobal-signature').decode()
    url = 'https://github.com/ibreez3/orbit/releases/download/v0.1.2/Orbit-v0.1.2-Windows-x64-setup.exe'

    def test_manifest_embeds_signature_and_release_notes(self):
        result = module.manifest('0.1.2', self.url, self.signature, 'Release notes')
        self.assertEqual(result['platforms']['windows-x86_64']['signature'], self.signature)
        self.assertEqual(result['version'], '0.1.2')
        self.assertEqual(result['notes'], 'Release notes')

    def test_rejects_unsafe_asset_locations_and_missing_metadata(self):
        for url in [self.url.replace('https:', 'http:'), self.url.replace('ibreez3', 'someone'), self.url.replace('.exe', '.zip')]:
            with self.assertRaises(ValueError):
                module.manifest('0.1.2', url, self.signature, 'Notes')
        for version, signature, notes in [('latest', self.signature, 'Notes'), ('0.1.2', 'broken', 'Notes'), ('0.1.2', self.signature, '')]:
            with self.assertRaises(ValueError):
                module.manifest(version, self.url, signature, notes)


if __name__ == '__main__':
    unittest.main()
