import unittest
import os
from pathlib import Path
import socket
import subprocess
import tempfile

from tools.native_focus import (NativeFocusPending, belongs_to_window, owned_transient_frame, private_session_command, private_session_environment,
                                restore_native_environment, validate_private_accessibility_address, wait_for_initial_focus)


class NativeFocusTests(unittest.TestCase):
    def test_initial_focus_is_observed_without_changing_or_sending_input(self):
        observations = iter([None, None, 'owned-window'])
        pauses = []
        def read():
            value = next(observations)
            if value is None:
                raise NativeFocusPending('Not owned yet')
            return value
        self.assertEqual(wait_for_initial_focus(read, clock=lambda: 0, pause=pauses.append), 'owned-window')
        self.assertEqual(pauses, [0.05, 0.05])

    def test_initial_focus_wait_never_retries_a_held_button_or_locked_desktop(self):
        for message in ['A desktop pointer button is held; no input sent', 'Desktop locked; no input sent']:
            failure = RuntimeError(message)
            pauses = []
            def read():
                raise failure
            with self.subTest(message=message), self.assertRaises(RuntimeError) as result:
                wait_for_initial_focus(read, pause=pauses.append)
            self.assertIs(result.exception, failure)
            self.assertEqual(pauses, [])

    def test_initial_foreign_focus_remains_a_failure_after_its_bounded_wait(self):
        now, pauses = [0.0], []
        failure = NativeFocusPending('Foreign focus; no input sent')
        def read():
            raise failure
        def pause(delay):
            pauses.append(delay)
            now[0] += delay
        with self.assertRaises(NativeFocusPending) as result:
            wait_for_initial_focus(read, timeout=0.12, clock=lambda: now[0], pause=pause)
        self.assertIs(result.exception, failure)
        self.assertAlmostEqual(now[0], 0.12)
        self.assertEqual(len(pauses), 3)

    def test_fixture_bus_cannot_activate_desktop_portal_or_secret_service(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-runtime-test-') as runtime:
            service = Path(runtime) / 'original.service'
            original = b'[D-BUS Service]\nName=org.a11y.Bus\nExec=/bin/false\n'
            service.write_bytes(original)
            command = private_session_command(runtime, accessibility_service=service)
            self.assertEqual((Path(runtime)/'services/org.a11y.Bus.service').read_bytes(), original)
            self.assertEqual(service.read_bytes(), original)
            result = subprocess.run([*command, 'gdbus', 'call', '--session',
                '--dest', 'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus',
                '--method', 'org.freedesktop.DBus.ListActivatableNames'],
                env=private_session_environment(os.environ, runtime), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('org.a11y.Bus', result.stdout)
            self.assertNotIn('org.freedesktop.portal', result.stdout)
            self.assertNotIn('org.freedesktop.secrets', result.stdout)
            self.assertEqual(result.stdout.count("'org."), 2, result.stdout)

    def test_private_bus_activation_cannot_inherit_desktop_display_or_socket(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-runtime-test-') as runtime:
            original = {'DISPLAY': ':42', 'WAYLAND_DISPLAY': 'wayland-fixture',
                        'XDG_RUNTIME_DIR': '/run/user/fixture',
                        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/session/fixture',
                        'AT_SPI_BUS_ADDRESS': 'unix:path=/desktop/fixture'}
            environment = private_session_environment(original, runtime)
            self.assertNotIn('DISPLAY', environment)
            self.assertNotIn('WAYLAND_DISPLAY', environment)
            self.assertNotIn('AT_SPI_BUS_ADDRESS', environment)
            self.assertEqual(environment['XDG_RUNTIME_DIR'], runtime)
            # dbus-run-session replaces only this address; never restore the
            # desktop bus when restoring the fixture's native display.
            environment['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=/private/session'
            restore_native_environment(environment)
            for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR'):
                self.assertEqual(environment[key], original[key])
            self.assertEqual(environment['DBUS_SESSION_BUS_ADDRESS'], 'unix:path=/private/session')
            self.assertEqual(original['AT_SPI_BUS_ADDRESS'], 'unix:path=/desktop/fixture')

    def test_missing_native_variables_are_restored_as_absent(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-runtime-test-') as runtime:
            environment = private_session_environment({}, runtime)
            restore_native_environment(environment)
            self.assertEqual(environment, {})

    def test_foreign_missing_and_non_socket_accessibility_addresses_fail(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-runtime-test-') as runtime:
            directory = Path(runtime) / 'at-spi'
            directory.mkdir()
            path = directory / 'bus'
            environment = {'XDG_RUNTIME_DIR': runtime}
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                validate_private_accessibility_address('unix:path=' + str(path) + ',guid=fixture', environment)
                for address in ('tcp:host=fixture', 'unix:path=/run/user/fixture/bus',
                                'unix:path=' + str(directory / 'missing'),
                                'unix:path=' + str(path) + ';unix:path=/foreign'):
                    with self.subTest(address=address), self.assertRaises((ValueError, FileNotFoundError)):
                        validate_private_accessibility_address(address, environment)
            path.unlink()
            path.write_text('not a socket')
            with self.assertRaises(ValueError):
                validate_private_accessibility_address('unix:path=' + str(path), environment)
            os.chmod(runtime, 0o755)
            with self.assertRaises(ValueError):
                private_session_environment({}, runtime)

    def test_frame_and_gtk_focus_child_are_owned(self):
        parents = {102: 101, 101: 100, 100: 50}
        self.assertTrue(belongs_to_window(100, 100, parents.get))
        self.assertTrue(belongs_to_window(102, 100, parents.get))

    def test_unrelated_frame_root_and_missing_ancestry_fail_closed(self):
        parents = {102: 100, 100: 50, 200: 50, 50: 0}
        for focus in [None, 0, 1, 200, 50, 999]:
            with self.subTest(focus=focus):
                self.assertFalse(belongs_to_window(focus, 100, parents.get))

    def test_cycles_and_excessive_depth_are_bounded(self):
        self.assertFalse(belongs_to_window(102, 100, {102: 103, 103: 102}.get))
        calls = []

        def unbounded_parent(window):
            calls.append(window)
            return window + 1

        self.assertFalse(belongs_to_window(2, 999, unbounded_parent))
        self.assertEqual(len(calls), 32)

    def test_only_a_same_process_dialog_transient_for_the_main_frame_is_selected(self):
        parents = {302: 301, 301: 300, 300: 50, 100: 50}
        owners = {100: 42, 300: 42}
        for focus in [300, 301, 302]:
            with self.subTest(focus=focus):
                self.assertEqual(owned_transient_frame(
                    focus, 100, 42, parents.get, owners.get,
                    {300: 100}.get, lambda window: window == 300), 300)
                self.assertFalse(belongs_to_window(focus, 100, parents.get))

    def test_transient_parent_type_and_both_owners_are_required(self):
        for main_owner, dialog_owner, transient, dialog in [
            (99, 42, 100, True), (42, 99, 100, True),
            (42, None, 100, True), (42, 42, 999, True),
            (42, 42, None, True), (42, 42, 100, False),
        ]:
            with self.subTest(values=(main_owner, dialog_owner, transient, dialog)):
                self.assertIsNone(owned_transient_frame(
                    300, 100, 42, {300: 50}.get,
                    {100: main_owner, 300: dialog_owner}.get,
                    {300: transient}.get, lambda _: dialog))

    def test_missing_or_malformed_expected_pid_cannot_authorize_unowned_dialogs(self):
        for pid in [None, 0, -42, True, '42']:
            with self.subTest(pid=pid):
                self.assertIsNone(owned_transient_frame(
                    300, 100, pid, {300: 50}.get,
                    {100: pid, 300: pid}.get,
                    {300: 100}.get, lambda _: True))

    def test_foreign_focus_child_cannot_borrow_an_owned_dialog(self):
        self.assertIsNone(owned_transient_frame(
            301, 100, 42, {301: 300}.get,
            {100: 42, 300: 42, 301: 99}.get,
            {300: 100}.get, lambda window: window == 300))

    def test_dialog_focus_proof_rechecks_mutated_native_properties(self):
        owners, transients, dialogs = {100: 42, 300: 42}, {300: 100}, {300}
        def proof():
            return owned_transient_frame(300, 100, 42, {300: 50}.get,
                owners.get, transients.get, dialogs.__contains__)
        self.assertEqual(proof(), 300)
        owners[300] = 99
        self.assertIsNone(proof())
        owners[300] = 42
        transients[300] = 999
        self.assertIsNone(proof())
        transients[300] = 100
        dialogs.clear()
        self.assertIsNone(proof())

    def test_missing_main_cycles_and_unbounded_dialog_ancestry_fail_closed(self):
        owners = {100: 42}.get
        for focus, main, parents in [
            (300, None, {}), (300, 999, {}), (100, 100, {}),
            (0, 100, {}), (1, 100, {}), (300, 100, {300: 301, 301: 300}),
        ]:
            with self.subTest(focus=focus, main=main):
                self.assertIsNone(owned_transient_frame(
                    focus, main, 42, parents.get, owners, lambda _: 100, lambda _: True))
        calls = []
        def parent(window):
            calls.append(window)
            return window + 1
        self.assertIsNone(owned_transient_frame(300, 100, 42, parent,
            owners, lambda _: 100, lambda _: True))
        self.assertEqual(len(calls), 32)


if __name__ == '__main__':
    unittest.main()
