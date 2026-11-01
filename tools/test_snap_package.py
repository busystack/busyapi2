"""Missing terminal hooks must fail before a candidate is offered for install."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.check_snap_package import CONFIGURE, DESKTOP, ICON, PACKAGED_ICON, WRAPPER, verify

ROOT = Path(__file__).resolve().parent.parent


class SnapHooks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='busyapi-snap-hooks-')
        self.addCleanup(self.temp.cleanup)
        self.prime = Path(self.temp.name)
        self.write('snap/hooks/configure', CONFIGURE)
        self.write('meta/hooks/configure', WRAPPER)
        # Controlled stand-in for the font-cache stage, not a replacement for
        # the actual GNOME runtime test. It preserves the terminal exec contract.
        self.write('snap/command-chain/hooks-configure-fonts',
                   b'#!/bin/sh\nprintf "cache-complete\\n"\nexec "$@"\n')
        self.write('snap/command-chain/run', b'#!/bin/sh\nexec "$@"\n')
        self.write(DESKTOP, (ROOT/'linux/io.busystack.busyapi.desktop').read_bytes())
        self.write(ICON, (ROOT/'assets/branding/busyapi_logo.svg').read_bytes())
        self.write(PACKAGED_ICON, (ROOT/'assets/branding/busyapi_logo.svg').read_bytes())
        self.desktop = b'[Desktop Entry]\nType=Application\nTerminal=false\nExec=busyapi.busyapi-desktop %F\nIcon=${SNAP}/' + PACKAGED_ICON.encode() + b'\n'
        self.write('meta/gui/busyapi-desktop.desktop', self.desktop)

    def write(self, name, data):
        path = self.prime / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755)
        return path

    def run_chain(self):
        return subprocess.run([str(self.prime/'snap/command-chain/hooks-configure-fonts'),
                               str(self.prime/'meta/hooks/configure')],
                              env={**os.environ, 'SNAP': str(self.prime)},
                              capture_output=True, timeout=5)

    def test_source_and_both_supported_snapcraft_handoffs(self):
        self.assertEqual((ROOT/'snap/hooks/configure').read_bytes(), CONFIGURE)
        self.assertEqual((ROOT/'snap/hooks/configure').stat().st_mode & 0o111, 0o111)
        for data in (CONFIGURE, WRAPPER):
            with self.subTest(handoff=data):
                self.write('meta/hooks/configure', data)
                verify(self.prime, packaged=True)
                result = self.run_chain()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b'cache-complete\n')

    def test_missing_terminal_reproduces_post_cache_failure_and_is_rejected(self):
        (self.prime/'meta/hooks/configure').unlink()
        result = self.run_chain()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'cache-complete\n')
        with self.assertRaisesRegex(RuntimeError, 'Missing'):
            verify(self.prime, packaged=True)

    def test_every_stage_must_be_ordinary_and_executable(self):
        for name in ['snap/hooks/configure', 'meta/hooks/configure',
                     'snap/command-chain/hooks-configure-fonts', 'snap/command-chain/run']:
            path = self.prime/name
            original = path.read_bytes()
            with self.subTest(name=name):
                path.chmod(0o644)
                with self.assertRaisesRegex(RuntimeError, 'Non-executable'):
                    verify(self.prime, packaged=True)
                path.unlink()
                path.symlink_to('/bin/true')
                with self.assertRaisesRegex(RuntimeError, 'Linked'):
                    verify(self.prime, packaged=True)
                path.unlink()
                self.write(name, original)

    def test_unreviewed_hook_or_wrapper_is_rejected_without_repair(self):
        for name in ['snap/hooks/configure', 'meta/hooks/configure']:
            with self.subTest(name=name):
                original = (self.prime/name).read_bytes()
                path = self.write(name, original+b'exit 0\n')
                with self.assertRaisesRegex(RuntimeError, 'Unexpected'):
                    verify(self.prime, packaged=True)
                self.assertEqual(path.read_bytes(), original+b'exit 0\n')
                self.write(name, original)

    def test_unmediated_or_absent_exec_cannot_pass_packaged_checks(self):
        for command in [b'busyapi-desktop %F', b'', b'busyapi %F', b'busyapi.busyapi-desktop --unsafe %F']:
            with self.subTest(command=command):
                self.write('meta/gui/busyapi-desktop.desktop',
                           self.desktop.replace(b'busyapi.busyapi-desktop %F', command))
                with self.assertRaisesRegex(RuntimeError, 'desktop command'):
                    verify(self.prime, packaged=True)
        self.write('meta/gui/busyapi-desktop.desktop', self.desktop.replace(b'Exec=busyapi.busyapi-desktop %F\n', b''))
        with self.assertRaisesRegex(RuntimeError, 'desktop command'):
            verify(self.prime, packaged=True)

    def test_missing_or_linked_desktop_and_icon_are_refused(self):
        for name in [DESKTOP, ICON, PACKAGED_ICON, 'meta/gui/busyapi-desktop.desktop']:
            path = self.prime/name
            original = path.read_bytes()
            with self.subTest(name=name):
                path.unlink()
                with self.assertRaisesRegex(RuntimeError, 'Missing'):
                    verify(self.prime, packaged=True)
                path.symlink_to(ROOT/'linux/io.busystack.busyapi.desktop')
                with self.assertRaisesRegex(RuntimeError, 'Linked'):
                    verify(self.prime, packaged=True)
                path.unlink()
                self.write(name, original)

    def test_unresolved_theme_icon_is_not_a_packaged_icon(self):
        self.write('meta/gui/busyapi-desktop.desktop', self.desktop.replace(
            b'${SNAP}/' + PACKAGED_ICON.encode(), b'io.busystack.busyapi'))
        with self.assertRaisesRegex(RuntimeError, 'icon identity'):
            verify(self.prime, packaged=True)

    def test_changed_packaged_icon_is_rejected(self):
        self.write(PACKAGED_ICON, b'other icon')
        with self.assertRaisesRegex(RuntimeError, 'Changed packaged'):
            verify(self.prime, packaged=True)


if __name__ == '__main__':
    unittest.main()
