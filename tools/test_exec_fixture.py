"""Deterministic Linux fork/write/exec fixture regression; no sleep or retry.

A writable CLOEXEC descriptor retained by a different pre-exec child causes
ETXTBSY after the writer has closed in the parent. An awaited separate copier
does not put its new writer in the test VM's fork-inherited descriptor table.
No product executable, input service, SDK or host configuration is modified.
"""
import errno
import hashlib
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import unittest


class ExecutableFixtureBoundary(unittest.TestCase):
    def test_inherited_writer_reproduces_busy_exec_and_separate_copy_remains_executable(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-exec-descriptor-') as temporary:
            root = Path(temporary)
            original = Path('/usr/bin/true')
            old = root / 'parent-written'
            with original.open('rb') as source, old.open('wb') as stream:
                shutil.copyfileobj(source, stream)
            old.chmod(original.stat().st_mode & 0o777)
            descriptor = os.open(old, os.O_WRONLY | os.O_CLOEXEC)
            inherited_descriptor = descriptor
            ready_read, ready_write = os.pipe()
            release_read, release_write = os.pipe()
            child = os.fork()
            if child == 0:
                os.close(ready_read)
                os.close(release_write)
                os.write(ready_write, b'1')
                os.close(ready_write)
                os.read(release_read, 1)
                os.close(descriptor)
                os._exit(0)
            os.close(ready_write)
            os.close(release_read)
            try:
                self.assertTrue(select.select([ready_read], [], [], 5)[0], 'Owned child did not acknowledge its held descriptor')
                self.assertEqual(os.read(ready_read, 1), b'1')
                os.close(descriptor)
                descriptor = -1
                with self.assertRaises(OSError) as blocked:
                    subprocess.run([str(old)], check=True)
                self.assertEqual(blocked.exception.errno, errno.ETXTBSY)
                self.assertEqual(os.readlink(f'/proc/{child}/fd/{inherited_descriptor}'), str(old))
                target = root / 'separate copy 雪'
                subprocess.run(['/usr/bin/cp', '--update=none', '--preserve=mode', '--', str(original), str(target)],
                               env={'PATH': '', 'LANG': 'C.UTF-8'}, check=True)
                self.assertEqual(hashlib.sha256(target.read_bytes()).digest(), hashlib.sha256(original.read_bytes()).digest())
                self.assertEqual(target.stat().st_mode & 0o777, original.stat().st_mode & 0o777)
                for _ in range(20):
                    self.assertEqual(subprocess.run([str(target)], env={'PATH': ''}).returncode, 0)
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
                os.write(release_write, b'1')
                os.close(release_write)
                os.close(ready_read)
                self.assertEqual(os.waitpid(child, 0)[1], 0)
            self.assertEqual(subprocess.run([str(old)]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
