"""Stage a verified BusyAPI-only Flutter engine for ordinary Linux/IDE builds.

This never changes the Flutter SDK or GTK input modules. Sources and build
provenance come from tools/build_flutter_engine.py; preparation is offline.
"""
import argparse
import json
import os
import pathlib
import shutil
import tempfile
from verify_flutter_engine import verify, REPO


def stage(home, output, mode, sdk=None):
    source = verify(home, mode, sdk)
    output.mkdir(parents=True, exist_ok=True)
    # One per-mode directory is immutable once published. An atomic symlink
    # switch keeps concurrent CMake readers from mixing a library and receipt.
    versions = output / '.versions'
    versions.mkdir(exist_ok=True)
    record = json.loads((source / 'busyapi-engine.json').read_text())
    version = versions / (mode + '-' + record['librarySha256'])
    if not version.exists():
        with tempfile.TemporaryDirectory(prefix=mode + '-', dir=versions) as temp:
            temp = pathlib.Path(temp)
            shutil.copy2(source / 'libflutter_linux_gtk.so', temp)
            shutil.copy2(source / 'busyapi-engine.json', temp)
            # Include the exact public patch and notices with the qualified
            # library. Runtime use does not depend on its external source tree.
            lock_dir = REPO / 'tools/flutter_engine'
            shutil.copy2(lock_dir / record['patch'], temp)
            shutil.copy2(lock_dir / 'FLUTTER-LICENSE', temp)
            shutil.copy2(lock_dir / 'ENGINE-LICENSE', temp)
            temp.rename(version)
    # Revalidate staged bytes, including existing versions, before selection.
    parent = output / ('.verify-' + mode)
    parent.mkdir(exist_ok=True)
    link = parent / ('host_' + mode)
    link.unlink(missing_ok=True)
    link.symlink_to(version)
    try:
        verify(parent, mode, sdk)
    finally:
        link.unlink()
        parent.rmdir()
    selected = output / ('host_' + mode)
    temporary = output / ('.host_' + mode + '.' + str(os.getpid()))
    temporary.symlink_to(version)
    temporary.replace(selected)
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, default=REPO / 'build/flutter-engine')
    parser.add_argument('--mode', choices=['all','debug','profile','release'], default='all')
    parser.add_argument('--sdk', type=pathlib.Path)
    args = parser.parse_args()
    for mode in ['debug','profile','release'] if args.mode == 'all' else [args.mode]:
        print(stage(args.home, args.output.resolve(), mode, args.sdk))


if __name__ == '__main__':
    main()
