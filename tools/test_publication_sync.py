"""Observe durable staged-file flush through the actual export APIs."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def publication_offsets(calls, target):
    synced = re.search(
        r'(?:f|fdata)sync\([^\n]*busyapi-export-[^\n]*/document\.bin[^\n]*\)\s*= 0', calls)
    # The Flutter Dart wrapper can rename engine.stamp before executing Dart.
    # Attribute publication to this export's exact destination, not the first
    # rename anywhere in the traced process tree.
    published = re.search(
        r'renameat2\([^\n]*"/proc/self/fd/\d+/document\.bin",[^\n]*"' +
        re.escape(str(target)) + r'", RENAME_NOREPLACE\)\s*= 0', calls)
    if synced is None or published is None:
        raise AssertionError('Missing successful staged-data sync or export publication:\n' + calls)
    return synced.start(), published.start()


class PublicationSync(unittest.TestCase):
    def test_trace_attributes_publication_to_the_export(self):
        startup = '1 renameat2(AT_FDCWD, "engine.stamp.tmp", AT_FDCWD, "engine.stamp", RENAME_NOREPLACE) = -1 EEXIST\n'
        sync = '2 fsync(10</tmp/busyapi-export-test/document.bin>) = 0\n'
        publish = '3 renameat2(AT_FDCWD, "/proc/self/fd/9/document.bin", AT_FDCWD, "/tmp/export.bin", RENAME_NOREPLACE) = 0\n'
        synced, published = publication_offsets(startup + sync + publish, '/tmp/export.bin')
        self.assertLess(synced, published)
        synced, published = publication_offsets(startup + publish + sync, '/tmp/export.bin')
        self.assertGreater(synced, published)
        with self.assertRaises(AssertionError):
            publication_offsets(startup + sync + publish, '/tmp/another.bin')

    def test_staged_data_is_synced_before_no_clobber_publication(self):
        dart = os.environ.get('BUSYAPI_DART') or shutil.which('dart')
        trace_tool = shutil.which('strace')
        if not dart or not trace_tool:
            raise RuntimeError('The publication syscall regression needs build-time Dart and strace')
        with tempfile.TemporaryDirectory(prefix='busyapi-publication-sync-') as temporary:
            root = Path(temporary)
            for kind in ['bytes', 'response']:
                with self.subTest(kind=kind):
                    trace = root/(kind + '.trace')
                    target = root/(kind + '.bin')
                    result = subprocess.run([trace_tool, '-f', '-yy', '-e', 'trace=fsync,fdatasync,renameat2',
                        '-o', str(trace), dart, 'packages/busyapi_core/test/publication_stream_child.dart', kind, str(target)],
                        cwd=ROOT, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(target.read_bytes(), bytes([0,255,128,17,0,7]))
                    calls = trace.read_text()
                    synced, published = publication_offsets(calls, target)
                    self.assertLess(synced, published)


if __name__ == '__main__':
    unittest.main()
