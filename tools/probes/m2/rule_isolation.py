"""Focused development probe, not a production custom-rule trust/launch path.

Use an explicitly built upstream Bubblewrap 0.13.1 and the pinned Node runtime.
Only the named fixture, runtime and its shared-library files enter the sandbox.
No host setting, installed package, project file or input-method service changes.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile


def network_filter():
    """Use the installed upstream library, not a hand-written BPF assembler."""
    if not hasattr(os, 'memfd_create'):
        raise RuntimeError('Use Linux system Python with memfd_create for this probe')
    library = ctypes.CDLL('libseccomp.so.2', use_errno=True)
    library.seccomp_init.argtypes = [ctypes.c_uint32]
    library.seccomp_init.restype = ctypes.c_void_p
    library.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
    library.seccomp_syscall_resolve_name.restype = ctypes.c_int
    library.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                       ctypes.c_int, ctypes.c_uint]
    library.seccomp_rule_add.restype = ctypes.c_int
    library.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.seccomp_export_bpf.restype = ctypes.c_int
    library.seccomp_release.argtypes = [ctypes.c_void_p]
    context = library.seccomp_init(0x7fff0000)  # SCMP_ACT_ALLOW
    assert context
    descriptor = os.memfd_create('busyapi-probe-network-filter', os.MFD_CLOEXEC)
    try:
        # Socket denial alone is insufficient: io_uring can create/connect
        # sockets without issuing the ordinary socket/connect syscalls.
        for name in ['socket', 'socketpair', 'connect', 'bind', 'listen',
                     'accept', 'accept4', 'io_uring_setup', 'io_uring_enter',
                     'io_uring_register', 'bpf', 'ptrace', 'process_vm_writev',
                     'pidfd_getfd', 'mount', 'umount2', 'pivot_root', 'chroot',
                     'unshare', 'setns']:
            number = library.seccomp_syscall_resolve_name(name.encode())
            assert number >= 0, 'Unknown native syscall: ' + name
            assert library.seccomp_rule_add(context, 0x50001, number, 0) == 0  # ERRNO(EPERM)
        assert library.seccomp_export_bpf(context, descriptor) == 0
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise
    finally:
        library.seccomp_release(context)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('bubblewrap', type=Path)
    parser.add_argument('node', type=Path)
    parser.add_argument('--network', choices=['namespace', 'seccomp'], default='namespace')
    args = parser.parse_args()
    bubblewrap, node = args.bubblewrap.resolve(strict=True), args.node.resolve(strict=True)
    assert subprocess.check_output([bubblewrap, '--version'], text=True).strip() == 'bubblewrap 0.13.1'
    assert hashlib.sha256(node.read_bytes()).hexdigest() == 'd1de76d8edf2fededf6f8b30d244e2c0529ac607923a018283b77e9c74bd932c'
    assert subprocess.check_output([node, '--version'], text=True).strip() == 'v24.15.0'
    # Only inspect the already verified executable, never an arbitrary project
    # binary. Production library capabilities still need packaged-layout and
    # strict-Snap qualification; this developer probe does not establish them.
    linked = subprocess.check_output(['ldd', node], text=True)
    libraries = sorted(set(re.findall(r'(/[^\s()]+)', linked)))
    assert libraries and all(Path(path).is_file() for path in libraries), linked
    fixture = Path(__file__).with_name('isolation_fixture.cjs').resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='busyapi-rule-boundary-') as temporary:
        canary = Path(temporary) / 'outside-canary'
        canary.write_text('Synthetic private host marker', encoding='utf8')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            listener.setblocking(False)
            frame = {'version': 1, 'canary': str(canary),
                     'port': listener.getsockname()[1], 'example': {},
                     'namespaces': {name: os.readlink('/proc/self/ns/' + name)
                                    for name in ['user', 'pid', 'net', 'mnt']}}
            command = [str(bubblewrap), '--unshare-all', '--die-with-parent',
                       '--new-session', '--cap-drop', 'ALL', '--clearenv',
                       '--dir', '/busyapi', '--chmod', '0555', '/busyapi',
                       '--ro-bind', str(node), '/busyapi/node',
                       '--ro-bind', str(fixture), '/busyapi/fixture.cjs']
            descriptors = ()
            if args.network == 'seccomp':
                descriptor = network_filter()
                descriptors = (descriptor,)
                command += ['--share-net', '--seccomp', str(descriptor)]
                frame['networkBoundary'] = 'seccomp'
            for library in libraries:
                command += ['--ro-bind', library, library]
            command += ['--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp',
                        '--chdir', '/tmp', '/busyapi/node', '--no-addons',
                        '--disable-proto=throw', '--max-old-space-size=128',
                        '/busyapi/fixture.cjs']
            try:
                result = subprocess.run(command, input=json.dumps(frame), text=True,
                                        capture_output=True, timeout=8,
                                        pass_fds=descriptors,
                                        env={**os.environ, 'BUSYAPI_PROBE_PRIVATE': 'Synthetic private environment marker'})
            finally:
                for descriptor in descriptors:
                    os.close(descriptor)
            assert result.returncode == 0, result.stderr
            record = json.loads(result.stdout)
            assert record['complete'] and record['hostFilesystem'] == 'denied'
            try:
                escaped, _ = listener.accept()
            except BlockingIOError:
                pass
            else:
                escaped.close()
                raise AssertionError('The isolated process contacted the host listener')
            assert canary.read_text(encoding='utf8') == 'Synthetic private host marker'
            print(json.dumps({'candidate': 'bubblewrap', 'version': '0.13.1',
                              'node': '24.15.0', 'networkBoundary': args.network, 'result': record,
                              'productionAccepted': False,
                              'remaining': ['exact-code trust and loading',
                                            'cancellation/descendant exit',
                                            'packaging and notices', 'strict-Snap integration']}))


if __name__ == '__main__':
    main()
