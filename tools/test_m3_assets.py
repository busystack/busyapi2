"""Production preparation reuse and final installed M3 asset checks."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_m3_tools as preparation
from verify_m3_assets import verify


class M3Assets(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='busyapi-m3-assets-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input = Path(os.environ.get('BUSYAPI_OASDIFF') or preparation.ROOT / 'build/m3-tools/oasdiff')
        if not self.input.is_file():
            raise RuntimeError('Prepare the locked oasdiff build input before asset regressions')

    def test_clean_prepare_then_verified_offline_reuse_survives_input_removal(self):
        supplied = self.root / 'supplied'
        shutil.copy2(self.input, supplied)
        stage = self.root / 'stage'
        preparation.prepare(stage, supplied)
        supplied.unlink()
        preparation.prepare(stage)
        self.assertEqual(preparation.digest(stage / 'oasdiff'), preparation.OASDIFF_SHA256)
        with self.assertRaisesRegex(RuntimeError, 'missing or has the wrong digest'):
            preparation.prepare(stage, '')
        for explicit in [supplied, self.root / 'tampered']:
            if explicit.name == 'tampered': explicit.write_bytes(b'not the locked tool')
            with self.assertRaisesRegex(RuntimeError, 'missing or has the wrong digest'):
                preparation.prepare(stage, explicit)
        self.assertEqual(preparation.digest(stage / 'oasdiff'), preparation.OASDIFF_SHA256)

    def test_missing_and_tampered_stage_never_silently_provision(self):
        missing = self.root / 'missing'
        with self.assertRaises(RuntimeError): preparation.prepare(self.root / 'output', missing)
        stage = self.root / 'stage'
        preparation.prepare(stage, self.input)
        (stage / 'oasdiff').write_bytes(b'tampered')
        with self.assertRaises(RuntimeError): preparation.prepare(stage)

    def test_final_package_requires_each_ordinary_matching_asset(self):
        bundle = self.root / 'relocated BusyAPI 雪'
        runtime = bundle / 'libexec/busyapi'
        preparation.prepare(runtime, self.input)
        metadata = bundle / 'share/busyapi'
        metadata.mkdir(parents=True)
        shutil.copy2(runtime / 'tools.json', metadata / 'tools.json')
        mock = runtime / 'mock-server.cjs'
        mock.write_text('controlled packaged mock fixture')
        (runtime / 'build.json').write_text(json.dumps({'version': 1, 'mockHelperSha256': preparation.digest(mock)}))
        verify(bundle)
        for asset in [mock, runtime / 'oasdiff']:
            saved = asset.read_bytes()
            asset.unlink()
            with self.assertRaises(RuntimeError): verify(bundle)
            asset.write_bytes(saved + b'tampered')
            with self.assertRaises(RuntimeError): verify(bundle)
            asset.write_bytes(saved)
            asset.chmod(0o755)
        (runtime / 'oasdiff').chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, 'mode'): verify(bundle)
        (runtime / 'oasdiff').chmod(0o755)
        verify(bundle)


if __name__ == '__main__':
    unittest.main()
