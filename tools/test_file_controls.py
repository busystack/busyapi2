#!/usr/bin/env python3
"""Functional X11 input test for the explicit test_file_controls.dart entry.

Run the separately built test entry, not a user's BusyAPI instance. Uses real
pointer/key events on a visible, focused, PID-verified window. Stops on desktop
locking or foreign focus; never disables locking or changes desktop settings.
This is not performance, renderer, release or strict-Snap qualification.
"""
import argparse
import ast
import ctypes
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

import gi

gi.require_version('Gdk', '3.0')
gi.require_version('GdkX11', '3.0')
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, Gdk, GdkX11, Gio

from native_focus import (NativeFocusPending, belongs_to_window, private_session_command, private_session_environment,
                          restore_native_environment, validate_private_accessibility_address, wait_for_initial_focus)


class NativeInput:
    def __init__(self, pid):
        self.pid = pid
        self.x = ctypes.CDLL('libX11.so.6')
        self.xt = ctypes.CDLL('libXtst.so.6')
        x = self.x
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XQueryPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint)]
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XStringToKeysym.argtypes = [ctypes.c_char_p]
        x.XStringToKeysym.restype = ctypes.c_ulong
        x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XKeysymToKeycode.restype = ctypes.c_uint
        x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x.XInternAtom.restype = ctypes.c_ulong
        x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)]
        x.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
        x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                                        ctypes.c_long, ctypes.c_long, ctypes.c_int, ctypes.c_ulong,
                                        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
                                        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                        ctypes.POINTER(ctypes.c_void_p)]
        x.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        x.XFree.argtypes = [ctypes.c_void_p]
        self.xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.xt.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        self.xt.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.display = x.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError('X11 display unavailable')
        self.pid_atom = x.XInternAtom(self.display, b'_NET_WM_PID', False)
        self.cardinal = x.XInternAtom(self.display, b'CARDINAL', False)
        self.window = None
        desktop_bus = Gio.DBusConnection.new_for_address_sync(
            os.environ['BUSYAPI_NATIVE_DESKTOP_BUS'],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        self.screen = Gio.DBusProxy.new_sync(
            desktop_bus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
            'org.gnome.ScreenSaver', '/org/gnome/ScreenSaver',
            'org.gnome.ScreenSaver', None)

    def tree(self, window):
        root, parent, children, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p(), ctypes.c_uint()
        status = self.x.XQueryTree(self.display, window, ctypes.byref(root), ctypes.byref(parent),
                                  ctypes.byref(children), ctypes.byref(count))
        values = list(ctypes.cast(children, ctypes.POINTER(ctypes.c_ulong))[:count.value]) if children.value else []
        if children.value:
            self.x.XFree(children)
        return (parent.value, values) if status else (None, [])

    def owner(self, window):
        kind, count, remaining, bits, data = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_int(), ctypes.c_void_p()
        status = self.x.XGetWindowProperty(
            self.display, window, self.pid_atom, 0, 1, False, self.cardinal,
            ctypes.byref(kind), ctypes.byref(bits), ctypes.byref(count), ctypes.byref(remaining), ctypes.byref(data))
        value = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[0] if data.value and count.value else None
        if data.value:
            self.x.XFree(data)
        return value if not status and kind.value == self.cardinal and bits.value == 32 and count.value == 1 else None

    def ready(self):
        if self.screen.call_sync('GetActive', None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]:
            raise RuntimeError('Desktop locked; no input sent')
        focus, revert = ctypes.c_ulong(), ctypes.c_int()
        self.x.XGetInputFocus(self.display, ctypes.byref(focus), ctypes.byref(revert))
        if self.window is None:
            current = focus.value
            seen = set()
            for _ in range(32):
                if current in (None, 0, 1) or current in seen:
                    break
                seen.add(current)
                if self.owner(current) == self.pid:
                    self.window = current
                    break
                current = self.tree(current)[0]
        if self.window is None or not belongs_to_window(
                focus.value, self.window, lambda child: self.tree(child)[0]):
            raise NativeFocusPending('Test window does not own focus; no input sent')
        window = GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(), self.window)
        if not window or not window.is_viewable() or self.owner(self.window) != self.pid:
            raise RuntimeError('Test window is not visible or no longer owned')
        pointer_root, pointer_child = ctypes.c_ulong(), ctypes.c_ulong()
        root_x, root_y, local_x, local_y, mask = (ctypes.c_int(), ctypes.c_int(),
                                                ctypes.c_int(), ctypes.c_int(), ctypes.c_uint())
        if not self.x.XQueryPointer(
                self.display, self.x.XDefaultRootWindow(self.display),
                ctypes.byref(pointer_root), ctypes.byref(pointer_child),
                ctypes.byref(root_x), ctypes.byref(root_y), ctypes.byref(local_x),
                ctypes.byref(local_y), ctypes.byref(mask)):
            raise RuntimeError('Pointer state is unavailable; no input sent')
        if mask.value & 0x1f00:
            raise RuntimeError('A desktop pointer button is held; no input sent')
        return window

    def surface(self, viewport):
        if (not isinstance(viewport, list) or len(viewport) != 2 or
                not all(isinstance(v, (float, int)) and math.isfinite(v) and 1 <= v <= 16384 for v in viewport)):
            raise ValueError('Invalid fixture viewport')
        window = self.ready()
        # A Flutter viewport that exactly fills GTK's client rectangle has a
        # native geometry proof independent of accessibility component RPCs.
        # Both dimensions and GTK's CSD insets belong to this PID-verified
        # mapped window; a partial match grants no coordinate authority.
        atom = self.x.XInternAtom(self.display, b'_GTK_FRAME_EXTENTS', False)
        kind, count, remaining, bits, data = (ctypes.c_ulong(), ctypes.c_ulong(),
                                             ctypes.c_ulong(), ctypes.c_int(), ctypes.c_void_p())
        status = self.x.XGetWindowProperty(
            self.display, self.window, atom, 0, 4, False, self.cardinal,
            ctypes.byref(kind), ctypes.byref(bits), ctypes.byref(count),
            ctypes.byref(remaining), ctypes.byref(data))
        try:
            if (not status and kind.value == self.cardinal and bits.value == 32 and
                    count.value == 4 and remaining.value == 0 and data.value):
                left, right, top, bottom = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[:4]
                width, height = self.dimensions(window)
                if (left + right < width and top + bottom < height and
                        (width - left - right, height - top - bottom) == tuple(viewport)):
                    valid, x, y = window.get_origin()
                    if not valid:
                        raise RuntimeError('Owned client origin is unavailable')
                    return x + left, y + top, viewport[0], viewport[1]
        finally:
            if data.value:
                self.x.XFree(data)
        desktop = Atspi.get_desktop(0)
        roots = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
        queue = [(app, 0) for app in roots if app.get_process_id() == self.pid]
        matches = set()
        visited = 0
        while queue:
            node, depth = queue.pop(0)
            visited += 1
            if visited > 256 or depth > 12:
                raise RuntimeError('Owned native geometry exceeded its bound')
            component = node.get_component_iface()
            rect = component.get_extents(Atspi.CoordType.SCREEN) if component else None
            if (node.get_role() == Atspi.Role.PANEL and rect and
                    rect.width == viewport[0] and rect.height == viewport[1]):
                matches.add((rect.x, rect.y, rect.width, rect.height))
                # The highest matching panel is the native Flutter surface;
                # do not enumerate the entire descendant semantic document.
                continue
            count = node.get_child_count()
            if count > 256:
                raise RuntimeError('Owned native geometry exceeded its bound')
            queue.extend((node.get_child_at_index(i), depth + 1) for i in range(count))
        if len(matches) != 1:
            raise RuntimeError('Could not prove one owned content-surface geometry')
        return next(iter(matches))

    def dimensions(self, window):
        root, x, y = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_int()
        width, height, border, depth = (ctypes.c_uint() for _ in range(4))
        if not self.x.XGetGeometry(self.display, window.get_xid(), ctypes.byref(root), ctypes.byref(x), ctypes.byref(y), ctypes.byref(width), ctypes.byref(height), ctypes.byref(border), ctypes.byref(depth)):
            raise RuntimeError('Owned window geometry is unavailable')
        return width.value, height.value

    def perform(self, action):
        if action['kind'] == 'snapshot':
            if self.screen.call_sync('GetActive', None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]:
                raise RuntimeError('Desktop locked; no capture')
            windows = []
            for candidate in self.tree(self.x.XDefaultRootWindow(self.display))[1]:
                if self.owner(candidate) != self.pid: continue
                owned = GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(), candidate)
                if owned and owned.is_viewable() and all(v >= 240 for v in self.dimensions(owned)):
                    windows.append(owned)
            if len(windows) != 1: raise RuntimeError('Cannot prove one owned snapshot surface')
            window = windows[0]
        else:
            window = self.ready()
        if action['kind'] == 'click':
            scale, point = action['scale'], action['point']
            if not isinstance(scale, (float, int)) or not 0.5 <= scale <= 4 or len(point) != 2:
                raise ValueError('Invalid fixture geometry')
            if not all(isinstance(value, (float, int)) and math.isfinite(value) for value in point):
                raise ValueError('Invalid fixture point')
            px, py = (round(value * scale) for value in point)
            if window.get_scale_factor() != 1:
                raise RuntimeError('This native-input driver requires separately qualified GTK scale 1')
            ox, oy, width, height = self.surface(action['viewport'])
            _, frame_x, frame_y = window.get_origin()
            frame_width, frame_height = self.dimensions(window)
            if not (frame_x <= ox and frame_y <= oy and
                    ox + width <= frame_x + frame_width and
                    oy + height <= frame_y + frame_height):
                raise RuntimeError(f'Reported content surface {(ox, oy, width, height)} leaves owned frame {(frame_x, frame_y, frame_width, frame_height)}')
            if not 0 <= px < width or not 0 <= py < height:
                raise ValueError('Fixture point outside owned surface')
            self.xt.XTestFakeMotionEvent(self.display, -1, ox + px, oy + py, 0)
            self.x.XFlush(self.display)
            pointer_root, pointer_child = ctypes.c_ulong(), ctypes.c_ulong()
            root_x, root_y, local_x, local_y, mask = ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_uint()
            self.x.XQueryPointer(self.display, self.x.XDefaultRootWindow(self.display), ctypes.byref(pointer_root), ctypes.byref(pointer_child), ctypes.byref(root_x), ctypes.byref(root_y), ctypes.byref(local_x), ctypes.byref(local_y), ctypes.byref(mask))
            if ((root_x.value, root_y.value) != (ox + px, oy + py) or not (
                    belongs_to_window(pointer_child.value, self.window, lambda child: self.tree(child)[0]) or
                    belongs_to_window(self.window, pointer_child.value, lambda child: self.tree(child)[0]))):
                raise RuntimeError(f'Pointer does not reach visible owned surface: expected={(ox+px,oy+py)}, actual={(root_x.value,root_y.value)}, child={pointer_child.value}, owner={self.owner(pointer_child.value)}')
            self.xt.XTestFakeButtonEvent(self.display, 1, 1, 0)
            self.xt.XTestFakeButtonEvent(self.display, 1, 0, 0)
        elif action['kind'] == 'snapshot':
            name = action.get('name', '')
            if not isinstance(name, str) or len(name) > 96 or not name.startswith(('http-', 'create-')) or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in name):
                raise ValueError('Invalid native snapshot name')
            http = name.startswith('http-')
            evidence = Path('/tmp/busyapi-http-native-evidence' if http else '/tmp/busyapi-creation-native-evidence')
            evidence.mkdir(mode=0o700, exist_ok=True)
            if evidence.is_symlink() or evidence.stat().st_uid != os.getuid():
                raise ValueError('Unowned snapshot directory')
            width, height = self.dimensions(window)
            image = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
            if image is None:
                raise RuntimeError('Owned native screenshot was unavailable')
            image.savev(str(evidence / (name + '.png')), 'png', [], [])
            desktop = Atspi.get_desktop(0)
            apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
            queue = [app for app in apps if app.get_process_id() == self.pid]
            names, texts, visited = set(), set(), 0
            while queue:
                node = queue.pop(0); visited += 1
                if visited > 4096:
                    raise RuntimeError('Native accessibility inspection exceeded its bound')
                names.add(node.get_name())
                if action.get('texts') and node.get_role() != Atspi.Role.PASSWORD_TEXT:
                    text = node.get_text_iface()
                    if text:
                        texts.add(Atspi.Text.get_text(text, 0, min(4096, text.get_character_count())))
                queue.extend(node.get_child_at_index(i) for i in range(node.get_child_count()))
            for label in action.get('labels', []):
                if not any(label in (name or '') for name in names):
                    raise RuntimeError('Native accessibility label was not exposed: ' + label)
            for wanted in action.get('texts', []):
                if not any(wanted in (value or '') for value in texts):
                    raise RuntimeError('Native accessible text was not exposed: ' + wanted)
            prefix = 'BUSYAPI_HTTP_NATIVE_EVIDENCE ' if http else 'BUSYAPI_CREATION_NATIVE_EVIDENCE '
            print(prefix + name + ' accessible-labels=' + str(len(action.get('labels', []))) + ' accessible-text=' + str(len(action.get('texts', []))), flush=True)
        elif action['kind'] == 'menu-ready':
            # A native channel request is asynchronous. A fixed post-click
            # delay does not prove GTK has mapped its popup under build load.
            # Observe only this fixture PID's actual X11 popup; never alter
            # focus, retry a selection or call the application callback.
            atom = self.x.XInternAtom(self.display, b'ATOM', False)
            property_atom = self.x.XInternAtom(self.display, b'_NET_WM_WINDOW_TYPE', False)
            popup_atoms = {
                self.x.XInternAtom(self.display, name, False)
                for name in (b'_NET_WM_WINDOW_TYPE_POPUP_MENU', b'_NET_WM_WINDOW_TYPE_DROPDOWN_MENU')
            }
            deadline = time.monotonic() + 8
            mapped = False
            while time.monotonic() < deadline and not mapped:
                self.ready()
                children = self.tree(self.x.XDefaultRootWindow(self.display))[1]
                if len(children) > 4096:
                    raise RuntimeError('Owned native popup lookup exceeded its bound')
                for child in children:
                    if self.owner(child) != self.pid:
                        continue
                    candidate = GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(), child)
                    if not candidate or not candidate.is_viewable():
                        continue
                    kind, count, remaining, bits, data = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_int(), ctypes.c_void_p()
                    status = self.x.XGetWindowProperty(
                        self.display, child, property_atom, 0, 16, False, atom,
                        ctypes.byref(kind), ctypes.byref(bits), ctypes.byref(count),
                        ctypes.byref(remaining), ctypes.byref(data))
                    if not status and kind.value == atom and bits.value == 32 and data.value and count.value <= 16:
                        mapped = bool(popup_atoms.intersection(ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[:count.value]))
                    if data.value:
                        self.x.XFree(data)
                    if mapped:
                        break
                if not mapped:
                    time.sleep(0.01)
            if not mapped:
                raise RuntimeError('The fixture has no mapped owned GTK popup menu')
        elif action['kind'] == 'keys':
            chords = action['chords']
            if not isinstance(chords, list) or not 1 <= len(chords) <= 128:
                raise ValueError('Invalid fixture key count')
            for chord in chords:
                self.ready()
                if not isinstance(chord, str) or len(chord) > 80:
                    raise ValueError('Invalid fixture chord')
                codes = [self.x.XKeysymToKeycode(self.display, self.x.XStringToKeysym(name.encode('ascii')))
                         for name in chord.split('+')]
                if not all(codes):
                    raise ValueError('Unknown fixture key')
                for code in codes:
                    self.xt.XTestFakeKeyEvent(self.display, code, 1, 0)
                for code in reversed(codes):
                    self.xt.XTestFakeKeyEvent(self.display, code, 0, 0)
        else:
            raise ValueError('Unknown fixture input kind')
        self.x.XFlush(self.display)
        # Allow the actual GTK event/dialog/menu to become visible. No latency
        # measurement is made or inferred from this functional settling time.
        time.sleep(0.25)

    def close(self):
        self.x.XCloseDisplay(self.display)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('test_executable', type=Path)
    parser.add_argument('--openapi', choices=['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1'], default='3.2.1')
    parser.add_argument('--format', choices=['yaml', 'json'], default='yaml')
    parser.add_argument('--authoring', action='store_true', help='Also exercise native metadata, schemas, recursion/composition, OAuth/security requirements, parameters, headers/media/examples/links and webhook/callback controls')
    parser.add_argument('--session', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    executable = args.test_executable.resolve(strict=True)
    if not args.session:
        environment = dict(os.environ, BUSYAPI_NATIVE_DESKTOP_BUS=os.environ['DBUS_SESSION_BUS_ADDRESS'])
        with tempfile.TemporaryDirectory(prefix='busyapi-native-runtime-') as runtime:
            return subprocess.run([
                *private_session_command(runtime), sys.executable, str(Path(__file__).resolve()),
                str(executable), '--session', '--openapi', args.openapi, '--format', args.format,
                *(['--authoring'] if args.authoring else []),
            ], env=private_session_environment(environment, runtime), timeout=900 if args.authoring else 210).returncode
    # Give GTK a valid private accessibility bus without modifying the desktop
    # root property. Screen-lock checks still use the original desktop bus.
    response = subprocess.run([
        'gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
        '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress',
    ], check=True, capture_output=True, text=True, timeout=10)
    value = ast.literal_eval(response.stdout)
    if not isinstance(value, tuple) or len(value) != 1 or not isinstance(value[0], str) or not value[0].startswith('unix:'):
        raise RuntimeError('Invalid private accessibility-bus identity')
    validate_private_accessibility_address(value[0], os.environ)
    restore_native_environment(os.environ)
    os.environ['AT_SPI_BUS_ADDRESS'] = value[0]
    # PyGObject's Gdk override probes display availability on import. The
    # activation-only process intentionally had none; initialize the fixture's
    # real display now, without changing the private bus activation environment.
    if not Gdk.init_check([])[0]:
        raise RuntimeError('The restored native test display is unavailable')
    with tempfile.TemporaryDirectory(prefix='busyapi-file-controls-') as directory:
        environment = dict(os.environ, BUSYAPI_FILE_CONTROLS_DIRECTORY=directory,
                           BUSYAPI_FILE_CONTROLS_VERSION=args.openapi, BUSYAPI_FILE_CONTROLS_FORMAT=args.format,
                           BUSYAPI_FILE_CONTROLS_AUTHORING='1' if args.authoring else '0',
                           XDG_CONFIG_HOME=f'{directory}/config', XDG_STATE_HOME=f'{directory}/state',
                           XDG_CACHE_HOME=f'{directory}/cache', LC_ALL='C.UTF-8')
        process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=environment, bufsize=0)
        native = None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b''
        step = 0
        passed = False
        deadline = time.monotonic() + (870 if args.authoring else 180)
        try:
            native = NativeInput(process.pid)
            while time.monotonic() < deadline:
                if not selector.select(1):
                    if process.poll() is not None:
                        break
                    continue
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 65536:
                    raise RuntimeError('Fixture output exceeded its bound')
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    value = line.decode('utf-8', errors='replace')
                    prefix = 'BUSYAPI_FILE_CONTROLS_INPUT '
                    if value.startswith(prefix):
                        action = json.loads(value[len(prefix):])
                        step += 1
                        if action.get('version') != 1 or action.get('step') != step:
                            raise RuntimeError('Fixture protocol mismatch')
                        print(f'BUSYAPI_FILE_CONTROLS_STEP {step} {action["kind"]}', flush=True)
                        if step == 1:
                            wait_for_initial_focus(native.ready)
                        native.perform(action)
                        process.stdin.write(f'ack:{step}\n'.encode('ascii'))
                    else:
                        print(value, flush=True)
                        passed |= value.startswith('BUSYAPI_FILE_CONTROLS_PASS ')
            result = process.wait(timeout=10)
            if not passed or result != 0:
                raise RuntimeError(f'Native file-control fixture did not pass (exit {result})')
        finally:
            selector.close()
            if native is not None:
                native.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            if not passed or process.returncode != 0:
                evidence = Path(tempfile.mkdtemp(prefix='busyapi-file-controls-failure-'))
                shutil.copytree(directory, evidence / 'fixture', symlinks=True)
                print('BUSYAPI_FILE_CONTROLS_FAILURE_FIXTURE ' + str(evidence), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
