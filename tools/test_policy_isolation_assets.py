"""Exact offline native policy build inputs; does not modify host packages."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.prepare_policy_isolation import ROOT, digest, prepare


class PolicyIsolationAssets(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='busyapi-policy-assets-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.inputs = self.root / 'inputs'
        shutil.copytree(ROOT / 'build/policy-isolation-inputs', self.inputs)
        self.output = self.root / 'relocated ü policy'

    def test_offline_receipt_reuse_and_replaceable_dynamic_linkage(self):
        first = prepare(self.output, inputs=self.inputs)
        for name, identity in first['files'].items():
            file = self.output / name
            self.assertEqual(digest(file), identity)
            self.assertFalse(file.is_symlink())
            dynamic = subprocess.run(['readelf', '-d', str(file)], check=True,
                                     capture_output=True, text=True).stdout
            self.assertIn('[libseccomp.so.2]', dynamic)
            self.assertNotIn('RPATH', dynamic)
            self.assertNotIn('RUNPATH', dynamic)
        before = {name: (self.output / name).stat().st_mtime_ns for name in first['files']}
        self.assertEqual(prepare(self.output, inputs=self.inputs), first)
        self.assertEqual(before, {name: (self.output / name).stat().st_mtime_ns for name in first['files']})
        self.assertEqual(json.loads((self.output / 'policy-build.json').read_text()), first)

    def test_no_fallback_for_missing_changed_or_symlinked_reviewed_headers(self):
        header = self.inputs / 'node/node_api.h'
        original = header.read_bytes()
        for state in ['missing', 'changed', 'symlink']:
            with self.subTest(state=state):
                header.unlink()
                if state == 'changed':
                    header.write_bytes(original + b'\n')
                elif state == 'symlink':
                    other = self.root / 'real-header'
                    other.write_bytes(original)
                    header.symlink_to(other)
                with self.assertRaisesRegex(RuntimeError, 'Missing or changed reviewed node header'):
                    prepare(self.output, inputs=self.inputs)
                self.assertFalse((self.output / 'policy-build.json').exists())
                header.unlink(missing_ok=True)
                header.write_bytes(original)

    def test_damaged_output_is_rebuilt_not_silently_reused(self):
        first = prepare(self.output, inputs=self.inputs)
        (self.output / 'policy-launcher').write_bytes(b'changed')
        self.assertEqual(prepare(self.output, inputs=self.inputs), first)
        self.assertEqual(digest(self.output / 'policy-launcher'), first['files']['policy-launcher'])


if __name__ == '__main__':
    unittest.main()
