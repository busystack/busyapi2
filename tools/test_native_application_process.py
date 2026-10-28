"""Host GDB qualification over owned CPU fixtures; no display or input."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.native_application_process import DebuggedApplication, launch_application


class NativeApplicationProcess(unittest.TestCase):
    def setUp(self):
        if not Path('/usr/bin/gdb').is_file():
            raise RuntimeError('The optional Quit-backtrace check requires an installed host GDB')
        self.temp = tempfile.TemporaryDirectory(prefix='busyapi-owned-debugger-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.binary = self.directory / 'owned fixture'
        source = self.directory / 'fixture.c'
        source.write_text('''#include <string.h>
#include <unistd.h>
static void fault_marker(void) { volatile int *p = 0; *p = 1; }
int main(int argc, char **argv) {
  usleep(250000);
  if (argc > 1 && strcmp(argv[1], "fault") == 0) fault_marker();
  if (argc > 1 && strcmp(argv[1], "hold") == 0) sleep(30);
  return 0;
}
''')
        subprocess.run(['/usr/bin/cc', '-g', '-O0', str(source), '-o', str(self.binary)],
                       check=True, capture_output=True, timeout=10)
        self.stream = (self.directory / 'debugger.log').open('w')
        self.addCleanup(self.stream.close)
        self.environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
                            'XDG_CACHE_HOME': str(self.directory / 'cache')}

    def launch(self, mode):
        process = launch_application(self.binary, mode, self.stream,
                                     self.environment, backtrace=self.directory)
        self.addCleanup(self.reap, process)
        return process

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)

    def test_default_launch_retains_the_ordinary_process_owner(self):
        process = launch_application(self.binary, 'normal', self.stream, self.environment)
        self.addCleanup(self.reap, process)
        self.assertIsInstance(process, subprocess.Popen)
        self.assertNotEqual(process.pid, os.getpid())
        self.assertEqual(process.wait(timeout=5), 0)

    def test_debugger_exposes_the_actual_owned_inferior_and_normal_exit(self):
        process = self.launch('normal')
        self.assertIsInstance(process, DebuggedApplication)
        receipt = json.loads(process.receipt.read_text())
        self.assertEqual(receipt['inferiorPid'], process.pid)
        self.assertNotEqual(receipt['debuggerPid'], process.pid)
        self.assertEqual(Path(f'/proc/{process.pid}/exe').resolve(), self.binary)
        self.assertEqual(process.wait(timeout=5), 0)
        self.assertTrue(json.loads(process.receipt.read_text())['complete'])

    def test_fault_captures_a_stack_and_never_reports_a_successful_quit(self):
        process = self.launch('fault')
        self.assertNotEqual(process.wait(timeout=5), 0)
        self.stream.flush()
        log = (self.directory / 'debugger.log').read_text()
        self.assertIn('SIGSEGV', log)
        self.assertIn('fault_marker', log)
        self.assertFalse(Path(f'/proc/{process.pid}').exists())
        receipt = json.loads(process.receipt.read_text())
        self.assertTrue(receipt['complete'])
        self.assertNotEqual(receipt['debuggerExitCode'], 0)

    def test_cancellation_reaps_inferior_and_debugger(self):
        process = self.launch('hold')
        process.terminate()
        self.assertNotEqual(process.wait(timeout=5), 0)
        process.terminate()
        self.assertFalse(Path(f'/proc/{process.pid}').exists())
        self.assertIsNotNone(process.poll())
        self.assertTrue(json.loads(process.receipt.read_text())['complete'])

    def test_invalid_executable_fails_without_an_unowned_pid_fallback(self):
        invalid = self.directory / 'invalid'
        invalid.write_bytes(b'Not an executable format\n')
        invalid.chmod(0o700)
        with self.assertRaisesRegex(RuntimeError, 'owned application PID'):
            launch_application(invalid, 'normal', self.stream, self.environment,
                               backtrace=self.directory)
        receipts = [json.loads(p.read_text()) for p in self.directory.glob('quit-backtrace-*/process.json')]
        self.assertEqual(len(receipts), 1)
        self.assertTrue(receipts[0]['startupFailed'])
        self.assertTrue(receipts[0]['complete'])
        self.assertNotIn('inferiorPid', receipts[0])


if __name__ == '__main__':
    unittest.main()
