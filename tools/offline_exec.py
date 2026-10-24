"""Run a Linux x86-64 artifact check with IP sockets denied in this process tree.

This development gate leaves the host's networking/security configuration alone.
AF_UNIX (GTK/X11/D-Bus) and AF_NETLINK remain available. All other socket domains
return EPERM; the filter is inherited by the application and packaged helper.
Use an owned temporary project and private XDG directories for GUI checks.
"""
import ctypes
import errno
import os
import platform
import socket
import sys


class Filter(ctypes.Structure):
    _fields_ = [('code', ctypes.c_ushort), ('jt', ctypes.c_ubyte),
                ('jf', ctypes.c_ubyte), ('k', ctypes.c_uint)]


class Program(ctypes.Structure):
    _fields_ = [('length', ctypes.c_ushort), ('filters', ctypes.POINTER(Filter))]


def confine():
    if sys.platform != 'linux' or platform.machine() != 'x86_64':
        raise RuntimeError('This smoke gate requires Linux x86-64')
    # Check audit architecture before interpreting syscall/argument offsets.
    entries = [(0x20, 0, 0, 4), (0x15, 1, 0, 0xC000003E),
               (0x06, 0, 0, 0x80000000), (0x20, 0, 0, 0),
               (0x15, 0, 4, 41), (0x20, 0, 0, 16),
               (0x15, 2, 0, socket.AF_UNIX),
               (0x15, 1, 0, socket.AF_NETLINK),
               (0x06, 0, 0, 0x00050000 | errno.EPERM),
               (0x06, 0, 0, 0x7FFF0000)]
    filters = (Filter * len(entries))(*(Filter(*entry) for entry in entries))
    program = Program(len(entries), filters)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) or libc.prctl(22, 2, ctypes.byref(program)):
        raise OSError(ctypes.get_errno(), 'Cannot install child-only seccomp gate')
    for domain in (socket.AF_INET, socket.AF_INET6):
        try:
            with socket.socket(domain):
                raise RuntimeError('IP socket unexpectedly permitted')
        except PermissionError as error:
            if error.errno != errno.EPERM:
                raise
    with socket.socket(socket.AF_UNIX):
        pass


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit('Usage: python3 tools/offline_exec.py COMMAND [ARG...]')
    confine()
    os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
