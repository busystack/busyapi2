"""Validate BusyAPI's isolated engine before a native build or publication."""
import argparse
import hashlib
import json
import pathlib
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cache_identity(mode, target, build_inputs, repo=REPO):
    """CI cache lookup only; verify() remains mandatory after restoration."""
    paths = ['tools/flutter_engine/engine.lock.json', 'tools/build_flutter_engine.py',
             'tools/prepare_flutter_engine.py', 'tools/verify_flutter_engine.py',
             'linux/flutter_engine.cmake']
    lock = json.loads((repo / paths[0]).read_text())
    paths.append('tools/flutter_engine/' + lock['patch'])
    identity = hashlib.sha256(json.dumps([mode, target, build_inputs], sort_keys=True).encode())
    for name in paths:
        identity.update(name.encode())
        identity.update((repo / name).read_bytes())
    return identity.hexdigest()


def verify(home, mode, sdk=None):
    lock = json.loads((REPO / 'tools/flutter_engine/engine.lock.json').read_text())
    patch = REPO / 'tools/flutter_engine' / lock['patch']
    if sha256(patch) != lock['patchSha256']:
        raise ValueError('Engine patch does not match its lock')
    output = home.resolve() / ('host_' + mode)
    record = json.loads((output / 'busyapi-engine.json').read_text())
    for key, value in lock.items():
        if record.get(key) != value:
            raise ValueError('Engine provenance does not match: ' + key)
    library = output / 'libflutter_linux_gtk.so'
    if record['mode'] != mode or sha256(library) != record['librarySha256']:
        raise ValueError('Engine library or build mode does not match provenance')
    gn = record['gnArgs']
    if f'flutter_runtime_mode = "{mode}"' not in gn:
        raise ValueError('Engine runtime mode does not match the application')
    if 'is_clang = true' not in gn or 'enable_lto = true' not in gn:
        raise ValueError('Engine compiler/LTO settings do not match the lock')
    if 'flutter_use_fontconfig = true' not in gn:
        raise ValueError('Engine desktop fontconfig setting does not match the lock')
    if sdk:
        sdk = sdk.resolve()
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=sdk, text=True).strip()
        engine = (sdk / 'bin/internal/engine.version').read_text().strip()
        if revision != lock['frameworkRevision'] or engine != lock['engineRevision']:
            raise ValueError('Framework or engine revision does not match the pinned SDK')
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=pathlib.Path)
    parser.add_argument('--mode', choices=['debug', 'profile', 'release'], required=True)
    parser.add_argument('--sdk', type=pathlib.Path)
    parser.add_argument('--cache-key', action='store_true')
    parser.add_argument('--target', default='linux-x64')
    parser.add_argument('--build-inputs', type=pathlib.Path)
    args = parser.parse_args()
    if args.cache_key:
        if args.build_inputs is None:
            parser.error('Cache identity requires the actual builder input identities')
        print(cache_identity(args.mode, args.target, args.build_inputs.read_text()))
    else:
        if args.home is None:
            parser.error('Verification requires --home')
        print(verify(args.home, args.mode, args.sdk))
