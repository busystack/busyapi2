"""Provision and build BusyAPI's pinned, isolated Linux engine.

Development/build-time provisioning only. Never modifies a shared Flutter SDK.
"""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[1]
LOCK = REPO / 'tools/flutter_engine/engine.lock.json'
BUILD_LOCK_FD = None


def run(args, cwd, env=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True,
                   pass_fds=() if BUILD_LOCK_FD is None else (BUILD_LOCK_FD,))


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=pathlib.Path, required=True)
    parser.add_argument('--mode', choices=['all', 'debug', 'profile', 'release'], default='all')
    parser.add_argument('--provision', action='store_true', help='Explicitly fetch pinned sources and dependencies')
    parser.add_argument('--source-repository', default='https://github.com/flutter/flutter.git')
    parser.add_argument('--jobs', type=int, default=6)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error('Jobs must be between 1 and 64')
    lock = json.loads(LOCK.read_text())
    patch = LOCK.parent / lock['patch']
    if digest(patch) != lock['patchSha256']:
        raise RuntimeError('Engine patch differs from its lock')
    workspace = args.workspace.expanduser().resolve()
    if workspace == REPO or workspace.is_relative_to(REPO):
        raise RuntimeError('Engine sources and outputs must be outside the repository')
    workspace.mkdir(parents=True, exist_ok=True)
    marker = workspace / '.busyapi-engine-workspace.json'
    if not marker.exists():
        if any(workspace.iterdir()):
            raise RuntimeError('Choose an empty BusyAPI-owned engine workspace')
        marker.write_text(json.dumps({'application': 'io.busystack.busyapi', 'engineRevision': lock['engineRevision']}) + '\n')
    if json.loads(marker.read_text()) != {'application': 'io.busystack.busyapi', 'engineRevision': lock['engineRevision']}:
        raise RuntimeError('Engine workspace ownership does not match this build')
    # Keep the lock in build children too. Terminating this parent must not let
    # a second invocation mutate an output while its Ninja child is still busy.
    global BUILD_LOCK_FD
    BUILD_LOCK_FD = os.open(workspace / '.build.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(BUILD_LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('This isolated engine workspace is already building') from None
    source, depot = workspace / 'flutter', workspace / 'depot_tools'
    if args.provision:
        if not source.exists():
            run(['git', 'clone', '--no-hardlinks', '--no-checkout', args.source_repository, source], workspace)
            run(['git', 'checkout', '--detach', lock['engineRevision']], source)
        if not depot.exists():
            run(['git', 'clone', 'https://chromium.googlesource.com/chromium/tools/depot_tools.git', depot], workspace)
            run(['git', 'checkout', '--detach', lock['depotToolsRevision']], depot)
    def verify_revisions():
        for path, revision in [(source, lock['engineRevision']), (depot, lock['depotToolsRevision'])]:
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=path, text=True).strip()
            if actual != revision:
                raise RuntimeError(f'{path} must be pinned to {revision}; found {actual}')

    verify_revisions()
    # Reject unrelated source mutations; keep an existing correctly applied patch.
    expected = workspace / 'applied-patch.sha256'
    reverse = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=source, capture_output=True)
    if reverse.returncode != 0:
        run(['git', 'apply', '--check', patch], source)
        run(['git', 'apply', patch], source)
    modified = subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=source, text=True).splitlines()
    if set(modified) - set(lock['files']):
        raise RuntimeError('Unrelated tracked engine source changes would enter this build')
    run(['git', 'diff', '--check', 'HEAD'], source)
    for name, expected_hash in lock['files'].items():
        if digest(source / name) != expected_hash:
            raise RuntimeError('Patched source identity differs: ' + name)
    expected.write_text(lock['patchSha256'] + '\n')
    config = {'solutions': [{
        'custom_deps': {}, 'custom_vars': lock['dependencyConfig'], 'deps_file': 'DEPS',
        'managed': False, 'name': '.', 'safesync_url': '', 'url': 'https://github.com/flutter/flutter.git',
    }]}
    config_path = source / '.gclient'
    config_path.write_text('solutions = ' + repr(config['solutions']) + '\n')
    env = dict(os.environ, DEPOT_TOOLS_UPDATE='0', PATH='/usr/bin:/bin:' + str(depot))
    if args.provision:
        run([depot / 'gclient', 'sync', '--no-history', '--nohooks', '--revision',
             '.@' + lock['engineRevision'], '--jobs', str(args.jobs)], source, env)
        run([depot / 'gclient', 'runhooks'], source, env)
    for mode in lock['modes'] if args.mode == 'all' else [args.mode]:
        verify_revisions()
        # Match the pinned linux_host_desktop_engine configuration: native
        # system font discovery/fallback is required in every desktop mode.
        run(['/usr/bin/python3', 'engine/src/flutter/tools/gn', '--runtime-mode', mode,
             '--enable-fontconfig', '--enable-unittests'], source, env)
        output = source / 'engine/src/out' / ('host_' + mode)
        run(['/usr/bin/ninja', '-C', output, '-j', str(args.jobs), *lock['build']['targets']], source, env)
        verify_revisions()
        for name, expected_hash in lock['files'].items():
            if digest(source / name) != expected_hash:
                raise RuntimeError('Engine source changed during build: ' + name)
        library = output / 'libflutter_linux_gtk.so'
        record = {
            **lock, 'mode': mode, 'librarySha256': digest(library),
            'buildJobs': args.jobs,
            'gnArgs': (output / 'args.gn').read_text(),
            'clangVersion': subprocess.check_output([source / 'engine/src/flutter/buildtools/linux-x64/clang/bin/clang', '--version'], text=True),
        }
        receipt = output / 'busyapi-engine.json'
        staged = output / 'busyapi-engine.json.tmp'
        with staged.open('w') as stream:
            stream.write(json.dumps(record, indent=2) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        staged.replace(receipt)
        print('Built pinned BusyAPI engine:', mode, record['librarySha256'], flush=True)


if __name__ == '__main__':
    main()
