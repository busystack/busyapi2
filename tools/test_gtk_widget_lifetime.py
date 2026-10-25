"""Compile and exercise native GTK teardown; requires the qualification display."""
import ast
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from tools.native_focus import (
    private_session_command, private_session_environment,
    restore_native_environment, validate_private_accessibility_address,
)


def run_private_fixture(executable):
    response = subprocess.run([
        'gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
        '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress',
    ], check=True, capture_output=True, text=True, timeout=10)
    value = ast.literal_eval(response.stdout)
    if not isinstance(value, tuple) or len(value) != 1 or not isinstance(value[0], str):
        raise RuntimeError('Invalid private accessibility identity')
    environment = dict(os.environ)
    validate_private_accessibility_address(value[0], environment)
    restore_native_environment(environment)
    environment['AT_SPI_BUS_ADDRESS'] = value[0]
    return subprocess.run([executable], env=environment, timeout=10).returncode


class GtkWidgetLifetimeTest(unittest.TestCase):
    def test_nested_presentation_survives_until_engine_disposal(self):
        root = Path(__file__).resolve().parents[1]
        runner = root / 'linux/runner'
        flags = shlex.split(subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'gtk+-3.0'], text=True))
        with tempfile.TemporaryDirectory(prefix='busyapi-gtk-lifetime-') as temporary:
            executable = Path(temporary) / 'lifetime'
            subprocess.run([
                *shlex.split(os.environ.get('CXX', 'c++')),
                '-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', str(runner),
                str(runner / 'gtk_widget_lifetime.cc'),
                str(runner / 'gtk_widget_lifetime_test.cc'),
                '-o', str(executable), *flags,
            ], check=True, capture_output=True, text=True, timeout=30)
            with tempfile.TemporaryDirectory(prefix='busyapi-gtk-lifetime-bus-') as runtime:
                result = subprocess.run([
                    *private_session_command(runtime), sys.executable,
                    '-m', 'tools.test_gtk_widget_lifetime', '--session', str(executable),
                ], cwd=root, env=private_session_environment(os.environ, runtime),
                    capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('ok 1 /busyapi/widget-lifetime/nested-destroy', result.stdout)
            self.assertIn('ok 2 /busyapi/widget-lifetime/live-parent', result.stdout)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--session':
        sys.exit(run_private_fixture(sys.argv[2]))
    unittest.main()
