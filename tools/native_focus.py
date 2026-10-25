"""Owned-window and isolated native-test session preconditions."""

import json
import os
from pathlib import Path
import stat
import time
from urllib.parse import quote, unquote
from xml.sax.saxutils import escape


_NATIVE_KEYS = ('DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR')
_NATIVE_CAPTURE = 'BUSYAPI_NATIVE_SESSION_ENVIRONMENT'


class NativeFocusPending(RuntimeError):
    """The fixture has not acquired its own native window focus."""


def wait_for_initial_focus(check, timeout=5, *, clock=time.monotonic, pause=time.sleep):
    """Observe startup readiness; other guards and later focus loss fail at once.

    The callback only reads the native state. This never activates a window or
    sends input, and the caller still rechecks all guards for the actual action.
    """
    deadline = clock() + timeout
    while True:
        try:
            return check()
        except NativeFocusPending:
            remaining = deadline - clock()
            if remaining <= 0:
                raise
            pause(min(0.05, remaining))


def private_session_command(runtime_directory, *, accessibility_service=None):
    """Activate only AT-SPI on the fixture bus, never desktop/secret portals.

    Keep the installed upstream service descriptor unchanged. The real desktop
    bus and its normal activation policy are not modified.
    """
    runtime = Path(runtime_directory)
    private_session_environment({}, runtime)  # Validate ownership/mode first.
    service = Path(accessibility_service or '/usr/share/dbus-1/services/org.a11y.Bus.service')
    if not service.is_file() or service.is_symlink():
        raise ValueError('Missing ordinary AT-SPI service descriptor')
    services = runtime / 'services'
    services.mkdir(mode=0o700)
    (services / 'org.a11y.Bus.service').write_bytes(service.read_bytes())
    config = runtime / 'session.conf'
    config.write_text(
        '<busconfig><type>session</type><auth>EXTERNAL</auth>'
        f'<listen>unix:dir={escape(quote(str(runtime), safe="/-_."))}</listen>'
        f'<servicedir>{escape(str(services))}</servicedir>'
        '<policy context="default"><allow send_destination="*" eavesdrop="true"/>'
        '<allow eavesdrop="true"/><allow own="*"/></policy></busconfig>\n')
    return ['dbus-run-session', '--config-file=' + str(config), '--']


def private_session_environment(environment, runtime_directory):
    """Keep test bus activation away from desktop sockets/X11 properties.

    The unmodified AT-SPI 2.52 launcher uses XDG_RUNTIME_DIR plus DISPLAY for
    its socket and publishes AT_SPI_BUS when DISPLAY is set. Restore display
    variables only in the fixture, after private bus activation has completed.
    The session bus itself must retain this isolated activation environment.
    """
    runtime = Path(runtime_directory)
    info = runtime.lstat()
    if not runtime.is_absolute() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError('Native test runtime must be an owned private directory')
    child = dict(environment)
    child[_NATIVE_CAPTURE] = json.dumps({key: child.get(key) for key in _NATIVE_KEYS})
    child['XDG_RUNTIME_DIR'] = str(runtime)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'AT_SPI_BUS_ADDRESS'):
        child.pop(key, None)
    return child


def restore_native_environment(environment):
    saved = json.loads(environment[_NATIVE_CAPTURE])
    if set(saved) != set(_NATIVE_KEYS) or any(value is not None and not isinstance(value, str) for value in saved.values()):
        raise ValueError('Invalid native test environment capture')
    for key, value in saved.items():
        if value is None:
            environment.pop(key, None)
        else:
            environment[key] = value
    environment.pop(_NATIVE_CAPTURE)


def validate_private_accessibility_address(address, environment):
    if not address.startswith('unix:') or ';' in address:
        raise ValueError('Expected one local native test accessibility bus')
    fields = dict(item.split('=', 1) for item in address[5:].split(','))
    socket = Path(unquote(fields.get('path', '')))
    expected = Path(environment['XDG_RUNTIME_DIR']) / 'at-spi'
    if socket.parent != expected or not stat.S_ISSOCK(socket.lstat().st_mode):
        raise ValueError('Accessibility bus is not in the private test runtime')


def belongs_to_window(focused, owned, parent_of, maximum_depth=32):
    """Accept the owned frame or its GTK focus child; never an unrelated frame.

    parent_of is an injected read-only XQueryTree boundary. A missing parent,
    root/PointerRoot focus, a cycle or excessive depth fails closed.
    """
    seen = set()
    for _ in range(maximum_depth):
        if focused in (None, 0, 1) or focused in seen:
            return False
        if focused == owned:
            return True
        seen.add(focused)
        focused = parent_of(focused)
    return False


def owned_transient_frame(focused, main, pid, parent_of, owner_of,
                          transient_of, is_dialog, maximum_depth=32):
    """Find only this process's dialog directly transient for its owned frame.

    This grants no input authority by itself. The caller also checks visibility,
    desktop lock and pointer state, and repeats this proof for every action.
    Ordinary focus checks still exclude all separate frames.
    """
    if type(pid) is not int or pid <= 0 or main in (None, 0, 1) or owner_of(main) != pid:
        return None
    seen = set()
    for _ in range(maximum_depth):
        if focused in (None, 0, 1, main) or focused in seen:
            return None
        seen.add(focused)
        owner = owner_of(focused)
        if owner is not None and owner != pid:
            return None
        if owner == pid and transient_of(focused) == main and is_dialog(focused):
            return focused
        focused = parent_of(focused)
    return None
