"""Build an isolated diagnostic IBus module, never a production installation.

Provisioning is explicit and build-time only. This candidate is not approved as
a BusyAPI runtime dependency. See tools/flutter_engine/ibus.lock.json.
"""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[1]
LOCK = REPO / 'tools/flutter_engine/ibus.lock.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(home):
    lock = json.loads(LOCK.read_text())
    if digest(LOCK.parent / lock['patch']) != lock['patchSha256']:
        raise ValueError('Private IBus patch differs from its lock')
    record = json.loads((home / 'busyapi-ibus.json').read_text())
    for key, value in lock.items():
        if record.get(key) != value:
            raise ValueError('Private IBus provenance differs: ' + key)
    for name, expected in record['artifacts'].items():
        if digest(home / name) != expected:
            raise ValueError('Private IBus artifact differs: ' + name)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=pathlib.Path, required=True)
    parser.add_argument('--provision', action='store_true')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    home = args.workspace.expanduser().resolve()
    if args.verify:
        verify(home / 'bundle')
        return
    if home == REPO or home.is_relative_to(REPO) or not 1 <= args.jobs <= 16:
        parser.error('Use an external owned workspace and 1–16 jobs')
    lock = json.loads(LOCK.read_text())
    patch = LOCK.parent / lock['patch']
    if digest(patch) != lock['patchSha256']:
        raise ValueError('Private IBus patch differs from its lock')
    home.mkdir(parents=True, exist_ok=True)
    owner = home / '.busyapi-ibus-workspace.json'
    identity = {'application': 'io.busystack.busyapi', 'version': lock['version']}
    if not owner.exists():
        if any(home.iterdir()):
            raise ValueError('Choose an empty private IBus workspace')
        owner.write_text(json.dumps(identity) + '\n')
    if json.loads(owner.read_text()) != identity:
        raise ValueError('Private IBus workspace ownership differs')
    with (home / '.build.lock').open('a') as guard:
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        archive = home / 'ibus-1.5.29.tar.gz'
        if not archive.exists() and args.provision:
            temporary = archive.with_suffix('.download')
            with urllib.request.urlopen(lock['sourceUrl'], timeout=120) as response, temporary.open('wb') as out:
                shutil.copyfileobj(response, out)
            if digest(temporary) != lock['sourceSha256']:
                raise ValueError('Downloaded IBus release has an unexpected checksum')
            temporary.replace(archive)
        if not archive.exists() or digest(archive) != lock['sourceSha256']:
            raise ValueError('Missing verified IBus release; provision explicitly')
        source = home / 'ibus-1.5.29'
        def run(argv, cwd):
            subprocess.run(argv, cwd=cwd, check=True)
        if not source.exists():
            with tarfile.open(archive) as tar:
                tar.extractall(home, filter='data')
            run(['patch', '--batch', '--fuzz=0', '-p1', '-i', str(patch)], source)
        # Only the module source is modified; the client library is upstream.
        if digest(source / 'client/gtk2/ibusimcontext.c') != lock['patchedSourceSha256']:
            raise ValueError('Private IBus source differs from its locked patch')
        build = home / 'build'
        build.mkdir(exist_ok=True)
        configure = [str(source / 'configure'), *lock['configure'],
                     'CC=/usr/bin/gcc', 'CFLAGS=-O2 -fPIC',
                     # Upstream configure checks these unused panel-only packages
                     # even with --disable-ui. No panel target is built or linked.
                     'DBUSMENU_GLIB_CFLAGS= ', 'DBUSMENU_GLIB_LIBS= ',
                     'DBUSMENU_GTK3_CFLAGS= ', 'DBUSMENU_GTK3_LIBS= ']
        run(configure, build)
        run(['make', '-C', 'src', '-j', str(args.jobs)], build)
        bundle = home / 'bundle'
        bundle.mkdir(exist_ok=True)
        client = bundle / 'libibus-1.0.so.5'
        shutil.copy2(build / 'src/.libs/libibus-1.0.so.5', client)
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk+-3.0', 'gmodule-2.0'], text=True).split()
        run(['/usr/bin/gcc', '-shared', '-fPIC', '-O2', '-DHAVE_CONFIG_H',
             '-I' + str(build), '-I' + str(build / 'src'), '-I' + str(source / 'src'),
             '-I' + str(source / 'client/gtk2'),
             str(source / 'client/gtk2/ibusimcontext.c'), str(source / 'client/gtk2/ibusim.c'),
             str(client), *flags, '-Wl,-rpath,$ORIGIN', '-Wl,--enable-new-dtags',
             '-o', str(bundle / 'im-ibus-busyapi.so')], build)
        test = home / 'test-private-ibus'
        run(['/usr/bin/gcc', '-O2', '-DHAVE_CONFIG_H',
             '-DBUSYAPI_IBUS_SOURCE="' + str(source / 'client/gtk2/ibusimcontext.c') + '"',
             '-I' + str(build), '-I' + str(build / 'src'), '-I' + str(source / 'src'),
             '-I' + str(source / 'client/gtk2'), str(REPO / 'tools/test_private_ibus.c'),
             str(client), *flags, '-Wl,-rpath,' + str(bundle), '-o', str(test)], build)
        run([str(test)], home)
        shutil.copy2(source / 'COPYING', bundle / 'COPYING.IBus')
        shutil.copy2(patch, bundle / patch.name)
        record = {**lock, 'configureCommand': configure,
                  'compiler': subprocess.check_output(['/usr/bin/gcc', '--version'], text=True).splitlines()[0],
                  'gtkVersion': subprocess.check_output(['pkg-config', '--modversion', 'gtk+-3.0'], text=True).strip(),
                  'artifacts': {p.name: digest(p) for p in bundle.iterdir() if p.is_file() and p.name != 'busyapi-ibus.json'}}
        temporary = bundle / 'busyapi-ibus.json.tmp'
        temporary.write_text(json.dumps(record, indent=2) + '\n')
        temporary.replace(bundle / 'busyapi-ibus.json')
        verify(bundle)
        print('Built diagnostic-only private IBus:', bundle)


if __name__ == '__main__':
    main()
