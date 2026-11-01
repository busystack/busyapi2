"""Benchmark protocol controls; native contract qualification uses the real CLI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name('benchmark_engine.py')


class BenchmarkEngine(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='busyapi benchmark controls 雪 ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixtures = self.root / 'fixtures 雪'
        self.fixtures.mkdir()
        for name in ['1mb.json', '5mb.json', '1mb.yaml', '5mb.yaml',
                     '1mb-minified.json', '5mb-minified.json', 'graph/openapi.json']:
            file = self.fixtures / name
            file.parent.mkdir(exist_ok=True)
            file.write_bytes(b'{}')

    def inventory(self):
        return {str(p.relative_to(self.fixtures)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.fixtures.rglob('*') if p.is_file()}

    def invoke(self, report):
        cli = self.root / 'controlled cli'
        cli.write_text(f'#!{sys.executable}\nprint({json.dumps(report)!r})\n')
        cli.chmod(0o700)
        before = self.inventory()
        result = subprocess.run([sys.executable, str(SCRIPT), str(cli), str(self.fixtures)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(self.inventory(), before)
        return result

    def test_complete_validation_measures_every_fixture_without_source_changes(self):
        result = self.invoke({'status': 'complete', 'complete': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report['results']), 7)
        for fixture in report['results']:
            self.assertEqual(fixture['bytes'], 2)
            self.assertEqual(len(fixture['seconds']), 5)
            self.assertTrue(all(value >= 0 for value in fixture['seconds']))

    def test_zero_exit_with_incomplete_validation_cannot_emit_measurements(self):
        for report in [{'status': 'incomplete', 'complete': False},
                       {'status': 'complete', 'complete': False},
                       {'status': 'invalid', 'complete': True},
                       {'status': 'complete'},
                       []]:
            with self.subTest(report=report):
                result = self.invoke(report)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
