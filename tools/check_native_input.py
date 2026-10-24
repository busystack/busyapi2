"""Replay complete native key events on an owned, focused trusted test window.

No waits are inserted between burst events. The final full-document clipboard
and explicitly saved bytes are correctness oracles, not pixel-crop heuristics.
Use system Python with GTK 3 on X11; prepare Source focus/selection first.
"""
import argparse
import ctypes
import hashlib
import json
import pathlib
import time
import gi

gi.require_version('Gdk', '3.0')
gi.require_version('GdkX11', '3.0')
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, GdkX11, Gio, GLib, Gtk
from native_focus import belongs_to_window


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('window', type=int)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--fixture', type=pathlib.Path, required=True)
    parser.add_argument('--expected', type=pathlib.Path, required=True)
    parser.add_argument('--keys', nargs='+', default=['x', 'BackSpace'])
    parser.add_argument('--repeat', type=int, default=100)
    parser.add_argument('--clipboard-format', choices=['exact', 'gtk-text'], default='exact',
                        help='GTK text transfer canonicalizes CRLF/CR; saved bytes remain exact')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    for path in [args.fixture, args.expected, args.output]:
        if not path.resolve().is_relative_to('/tmp'):
            parser.error('Use trusted temporary fixtures and outputs')
    if not 1 <= args.repeat <= 1000:
        parser.error('Repeat must be between 1 and 1000')
    screen = Gio.DBusProxy.new_for_bus_sync(
        Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
        'org.gnome.ScreenSaver', '/org/gnome/ScreenSaver',
        'org.gnome.ScreenSaver', None)
    window = GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(), args.window)
    if not window or not window.is_viewable():
        parser.error('Owned application window must be visible')
    x = ctypes.CDLL('libX11.so.6')
    xt = ctypes.CDLL('libXtst.so.6')
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XStringToKeysym.argtypes = [ctypes.c_char_p]
    x.XStringToKeysym.restype = ctypes.c_ulong
    x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x.XKeysymToKeycode.restype = ctypes.c_uint
    x.XFlush.argtypes = [ctypes.c_void_p]
    x.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
    x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XInternAtom.restype = ctypes.c_ulong
    x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                                    ctypes.c_long, ctypes.c_long, ctypes.c_int,
                                    ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                                    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                                    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
    x.XFree.argtypes = [ctypes.c_void_p]
    xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    display = x.XOpenDisplay(None)
    atom = x.XInternAtom(display, b'_NET_WM_PID', False)
    cardinal = x.XInternAtom(display, b'CARDINAL', False)
    kind, count, remaining = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_ulong()
    bits, data = ctypes.c_int(), ctypes.c_void_p()
    status = x.XGetWindowProperty(display, args.window, atom, 0, 1, False,
                                  cardinal, ctypes.byref(kind), ctypes.byref(bits),
                                  ctypes.byref(count), ctypes.byref(remaining), ctypes.byref(data))
    pid = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[0] if data.value and count.value else None
    if data.value:
        x.XFree(data)
    if status or kind.value != cardinal or bits.value != 32 or count.value != 1 or pid != args.pid:
        x.XCloseDisplay(display)
        parser.error('Window ownership does not match the explicit PID')

    def parent_of(child):
        root, parent, children, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p(), ctypes.c_uint()
        status = x.XQueryTree(display, child, ctypes.byref(root), ctypes.byref(parent),
                              ctypes.byref(children), ctypes.byref(count))
        if children.value:
            x.XFree(children)
        return parent.value if status else None

    def ready():
        if screen.call_sync('GetActive', None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]:
            raise RuntimeError('Desktop locked; no further input sent')
        focus, revert = ctypes.c_ulong(), ctypes.c_int()
        x.XGetInputFocus(display, ctypes.byref(focus), ctypes.byref(revert))
        if not belongs_to_window(focus.value, args.window, parent_of) or not window.is_viewable():
            raise RuntimeError('Owned window lost focus or visibility')

    def chord(value):
        names = value.split('+')
        codes = [x.XKeysymToKeycode(display, x.XStringToKeysym(n.encode('ascii'))) for n in names]
        if not all(codes):
            raise ValueError('Unknown native key name: ' + value)
        for code in codes:
            xt.XTestFakeKeyEvent(display, code, 1, 0)
        for code in reversed(codes):
            xt.XTestFakeKeyEvent(display, code, 0, 0)

    try:
        ready()
        original = args.fixture.read_bytes()
        expected = args.expected.read_bytes()
        start = time.monotonic_ns()
        for _ in range(args.repeat):
            for key in args.keys:
                chord(key)
        x.XFlush(display)
        dispatch_ms = (time.monotonic_ns() - start) / 1e6
        # This read command follows the entire burst in the same native queue.
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text('BUSYAPI_NATIVE_ORACLE_PENDING', -1)
        chord('Control_L+a')
        chord('Control_L+c')
        x.XFlush(display)
        end = time.monotonic() + 20
        while time.monotonic() < end:
            ready()
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            text = clipboard.wait_for_text()
            if text is not None and text != 'BUSYAPI_NATIVE_ORACLE_PENDING':
                break
            time.sleep(.01)
        else:
            raise RuntimeError('Queued full-source copy did not complete')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.with_suffix('.txt').write_text(text, newline='')
        # BOM is format metadata rather than an editable source character.
        expected_text = expected.decode('utf-8-sig')
        if args.clipboard_format == 'gtk-text':
            expected_text = expected_text.replace('\r\n', '\n').replace('\r', '\n')
        if text != expected_text:
            raise AssertionError('Accepted full source differs from expected source')
        ready()
        chord('Control_L+s')
        x.XFlush(display)
        end = time.monotonic() + 10
        while args.fixture.read_bytes() != expected:
            ready()
            if time.monotonic() > end:
                raise AssertionError('Saved bytes differ from expected bytes')
            time.sleep(.02)
        record = {'version': 1, 'keys': args.keys, 'repeat': args.repeat,
                  'clipboardFormat': args.clipboard_format,
                  'pid': args.pid, 'window': args.window, 'dispatchMs': dispatch_ms,
                  'initialSha256': hashlib.sha256(original).hexdigest(),
                  'expectedSha256': hashlib.sha256(expected).hexdigest(),
                  'bytes': len(expected), 'fullSourceAndSavedBytes': 'passed'}
        args.output.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record))
    finally:
        x.XCloseDisplay(display)


if __name__ == '__main__':
    main()
