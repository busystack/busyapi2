#!/usr/bin/env python3
"""Offline native governance build; no installs/downloads/host policy changes.

Explicit provisioning caches exact reviewed declaration headers in build/. They
are build inputs, not vendored runtime code or a replacement Node toolchain.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/contract_engine/native'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def publish(source, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and not target.is_symlink() and digest(source) == digest(target):
        target.chmod(mode)
        return
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
        name = Path(temporary.name)
    try:
        shutil.copyfile(source, name)
        name.chmod(mode)
        name.replace(target)
    finally:
        name.unlink(missing_ok=True)


def prepare(output, *, node_include=None, seccomp_include=None, inputs=None):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('The reviewed policy profile targets Linux amd64')
    lock = json.loads((SOURCE / 'build-inputs.lock.json').read_text())
    inputs = inputs or ROOT / 'build/policy-isolation-inputs'
    headers = []
    for owner, supplied in [('node', node_include), ('libseccomp', seccomp_include)]:
        for name, expected in lock[owner]['headers'].items():
            staged = inputs / owner / name
            candidate = supplied / name if supplied else staged
            if (not candidate.is_file() or candidate.is_symlink() or digest(candidate) != expected):
                raise RuntimeError('Missing or changed reviewed ' + owner + ' header: ' + name + '. '
                    'Provision explicit locked headers with tools/prepare_policy_isolation.py '
                    '--node-include /path/to/node24/include/node '
                    '--seccomp-include /path/to/extracted-libseccomp-dev/usr/include. '
                    'No system package or runtime is installed automatically.')
            publish(candidate, staged)
            headers.append(staged)
    output.mkdir(parents=True, exist_ok=True)
    receipt = output / 'policy-build.json'
    try:
        previous = json.loads(receipt.read_text())
    except (OSError, ValueError):
        previous = {}
    compiler = shutil.which(os.environ.get('CXX', 'c++'))
    compiler_identity = (subprocess.run([compiler, '--version'], check=True, text=True,
                                      capture_output=True).stdout if compiler else
                         previous.get('compilerIdentity'))
    if not isinstance(compiler_identity, str) or not 0 < len(compiler_identity) < 32768:
        raise RuntimeError('The native C++ build compiler is missing')
    sources = [SOURCE / 'policy_isolation.cc', SOURCE / 'policy_launcher.cc',
               SOURCE / 'build-inputs.lock.json', Path(__file__).resolve()]
    signature = hashlib.sha256(compiler_identity.encode())
    for item in [*sources, *headers]:
        signature.update(item.name.encode())
        signature.update(item.read_bytes())
    identity = signature.hexdigest()
    names = ['policy-isolation.node', 'policy-launcher']
    if (previous.get('inputs') != identity or any(
            not (output / name).is_file() or (output / name).is_symlink() or
            previous.get('files', {}).get(name) != digest(output / name) for name in names)):
        if not compiler:
            raise RuntimeError('Changed native policy assets require the C++ build compiler; no fallback is installed')
        with tempfile.TemporaryDirectory(prefix='policy-stage-', dir=output) as folder:
            stage = Path(folder)
            for source, name in zip(sources, names):
                arguments = [compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', '-O2',
                             '-Wl,-z,relro,-z,now', '-Wl,--as-needed',
                             '-I' + str(inputs / 'node'), '-I' + str(inputs / 'libseccomp')]
                if name.endswith('.node'):
                    arguments += ['-fPIC', '-shared']
                else:
                    arguments += ['-fPIE', '-pie']
                arguments += [str(source), '-Wl,-l:' + lock['libseccomp']['soname'], '-o', str(stage / name)]
                subprocess.run(arguments, check=True, cwd=ROOT)
                dynamic = subprocess.run(['readelf', '-d', str(stage / name)], check=True,
                                         capture_output=True, text=True).stdout
                if 'RPATH' in dynamic or 'RUNPATH' in dynamic or '[libseccomp.so.2]' not in dynamic:
                    raise RuntimeError('Policy assets must use the replaceable system libseccomp shared library')
            record = {'version': 1, 'profile': lock['profile'], 'inputs': identity,
                      'compiler': compiler_identity.splitlines()[0],
                      'compilerIdentity': compiler_identity,
                      'files': {name: digest(stage / name) for name in names},
                      'nativeDependency': lock['libseccomp'],
                      'minimumLandlockAbi': lock['minimumLandlockAbi']}
            (stage / 'policy-build.json').write_text(json.dumps(record, sort_keys=True) + '\n')
            for name in names:
                publish(stage / name, output / name, 0o755)
            publish(stage / 'policy-build.json', receipt)
    return json.loads(receipt.read_text())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/policy-isolation')
    parser.add_argument('--inputs', type=Path)
    parser.add_argument('--node-include', type=Path)
    parser.add_argument('--seccomp-include', type=Path)
    arguments = parser.parse_args()
    try:
        prepare(arguments.output, node_include=arguments.node_include,
                seccomp_include=arguments.seccomp_include, inputs=arguments.inputs)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')
