"""Read-only identity checks for the pinned upstream SDK and its selected engine.

The SDK is provisioned separately from the official Flutter release. This tool
never builds an engine, downloads inputs, executes Flutter/Dart or changes the SDK.
Its receipt binds subsequent install checks to the captured SDK/cache bytes;
it is not a publisher signature or an independent archive attestation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'tools/flutter_sdk.lock.json').read_text())
RECEIPT = 'share/busyapi/flutter-sdk.json'


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def ordinary(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('Missing or linked upstream SDK input: ' + path.name)
    return path


def source_identity(sdk):
    # Do not inherit Git redirection, hooks, fsmonitor or external diff commands.
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C', 'GIT_OPTIONAL_LOCKS': '0'}
    command = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-C', str(sdk)]
    revision = subprocess.check_output(command + ['rev-parse', 'HEAD'], env=environment, timeout=30).decode().strip()
    if revision != LOCK['frameworkRevision']:
        raise ValueError('Use the pinned original Flutter source revision')
    result = subprocess.run(command + ['diff', '--no-ext-diff', '--no-textconv', '--quiet', 'HEAD', '--'],
                            env=environment, timeout=30, check=False)
    if result.returncode != 0:
        raise ValueError('Modified or unavailable Flutter SDK source is not a build input')


def verify(sdk, mode, library=None):
    if mode not in LOCK['modes']:
        raise ValueError('Unknown Flutter build mode')
    for name in ('BUSYAPI_FLUTTER_ENGINE_HOME', 'FLUTTER_ENGINE', 'FLUTTER_ENGINE_SRC_PATH',
                 'FLUTTER_PREBUILT_ENGINE_VERSION', 'FLUTTER_REALM'):
        if os.environ.get(name):
            raise ValueError('Remove custom engine configuration: ' + name)
    sdk = Path(sdk).resolve(strict=True)
    source_identity(sdk)
    if ordinary(sdk / 'bin/internal/engine.version').read_text().strip() != LOCK['engineRevision']:
        raise ValueError('Flutter engine declaration does not match the upstream SDK')
    if ordinary(sdk / 'bin/cache/engine.stamp').read_text().strip() != LOCK['engineRevision']:
        raise ValueError('Flutter engine cache does not match the pinned SDK')
    realm = sdk / 'bin/cache/engine.realm'
    if realm.exists() and ordinary(realm).read_text().strip():
        raise ValueError('Presubmit Flutter artifacts are not release inputs')
    dart = sdk / 'bin/cache/dart-sdk'
    if ordinary(dart / 'version').read_text().strip() != LOCK['dartVersion']:
        raise ValueError('Use Dart from the pinned upstream Flutter SDK')
    if digest(ordinary(dart / 'bin/dartaotruntime')) != LOCK['dartAotRuntimeSha256']:
        raise ValueError('Dart runtime bytes do not match their reviewed upstream identity')
    selected = ordinary(sdk / 'bin/cache/artifacts/engine' / LOCK['modes'][mode] / 'libflutter_linux_gtk.so')
    for name in ('busyapi-engine.json', 'linux-input-ordering.patch'):
        if (selected.parent / name).exists() or (selected.parent / name).is_symlink():
            raise ValueError('A custom engine stage is not an upstream SDK cache')
    identity = digest(selected)
    if library is not None and digest(Path(library)) != identity:
        raise ValueError('Selected Flutter build library differs from its SDK mode')
    return {'version': 1, 'producer': 'busyapi-upstream-flutter',
            'frameworkVersion': LOCK['frameworkVersion'], 'frameworkRevision': LOCK['frameworkRevision'],
            'engineRevision': LOCK['engineRevision'], 'dartVersion': LOCK['dartVersion'],
            'target': LOCK['target'], 'source': LOCK['source'], 'mode': mode, 'librarySha256': identity}


def capture(path, record):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('SDK capture destination is linked')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.flutter-sdk-', delete=False) as output:
            temporary = Path(output.name)
            output.write((json.dumps(record, sort_keys=True, indent=2) + '\n').encode())
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def verify_installed(bundle):
    bundle = Path(bundle)
    path = ordinary(bundle / RECEIPT)
    if path.stat().st_size > 64 * 1024:
        raise ValueError('Oversized Flutter SDK capture')
    record = json.loads(path.read_text())
    expected = {'version': 1, 'producer': 'busyapi-upstream-flutter',
                **{key: LOCK[key] for key in ('frameworkVersion', 'frameworkRevision', 'engineRevision', 'dartVersion', 'target', 'source')}}
    if not isinstance(record, dict) or any(record.get(key) != value for key, value in expected.items()):
        raise ValueError('Installed Flutter SDK identity does not match the lock')
    if record.get('mode') not in LOCK['modes']:
        raise ValueError('Invalid installed Flutter SDK mode')
    if digest(ordinary(bundle / 'lib/libflutter_linux_gtk.so')) != record.get('librarySha256'):
        raise ValueError('Installed Flutter library differs from its captured SDK input')
    if (bundle / 'share/busyapi/flutter-engine').exists() or (bundle / 'share/busyapi/flutter-engine').is_symlink():
        raise ValueError('Remove the obsolete custom engine output before packaging')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path)
    parser.add_argument('--mode', choices=tuple(LOCK['modes']))
    parser.add_argument('--library', type=Path)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--check-receipt', action='store_true')
    parser.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    if args.bundle:
        if any((args.sdk, args.mode, args.library, args.receipt, args.check_receipt)):
            parser.error('Choose an installed bundle or SDK inputs')
        verify_installed(args.bundle)
    else:
        if not args.sdk or not args.mode:
            parser.error('SDK verification requires --sdk and --mode')
        record = verify(args.sdk, args.mode, args.library)
        if args.check_receipt:
            if not args.receipt or json.loads(ordinary(args.receipt).read_text()) != record:
                raise ValueError('Flutter SDK inputs changed after build capture')
        elif args.receipt:
            capture(args.receipt, record)


if __name__ == '__main__':
    main()
