#!/usr/bin/env python3
"""Offline build-time staging for the existing core's read-only package loader."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import re
import subprocess
import tempfile

from prepare_contract_assets import copy_atomic, digest

ROOT = Path(__file__).resolve().parent.parent


def prepare(output, dart, contract, notices):
    if platform.system()!='Linux' or platform.machine()!='x86_64':
        raise RuntimeError('The pinned resource-package runtime targets Linux amd64')
    if 'Dart SDK version: 3.13.4 ' not in subprocess.check_output([str(dart), '--version'], text=True):
        raise RuntimeError('Use the locked Dart 3.13.4 build SDK; no runtime compiler is downloaded')
    output.mkdir(parents=True, exist_ok=True)
    inputs = [Path(__file__).resolve(), ROOT/'pubspec.lock', ROOT/'tools/dart_dependencies.review.json',
              ROOT/'packages/busyapi_core/pubspec.lock', ROOT/'packages/busyapi_core/pubspec.yaml',
              ROOT/'packages/busyapi_core/bin/resource_package.dart']
    inputs += sorted((ROOT/'packages/busyapi_core/lib').rglob('*.dart'))
    identity = hashlib.sha256()
    for file in inputs:
        identity.update(str(file.relative_to(ROOT)).encode()+b'\0'+file.read_bytes())
    sdk_revision=(dart.parent.parent/'revision').read_text().strip()
    compiler_digest=digest(dart)
    runtime_digest=digest(dart.parent/'dartaotruntime')
    core_notices=json.loads((notices/'dependencies.json').read_bytes())
    runtime_notices=core_notices.get('runtime',{})
    if (runtime_notices.get('sdkRevision')!=sdk_revision
            or runtime_notices.get('aotRuntimeSha256')!=runtime_digest
            or not runtime_notices.get('components')
            or json.loads((notices/'runtime/dependencies.json').read_bytes())!=runtime_notices):
        raise RuntimeError('Prepare reviewed original embedded Dart runtime notices before package assets')
    for component in runtime_notices['components']:
        for notice in component['notices']:
            name=notice['file']
            if not re.fullmatch(r'[A-Za-z0-9_.-]+',name) or name in ('.','..'):
                raise RuntimeError('Invalid reviewed Dart runtime notice path')
            original=notices/'runtime'/name
            if not original.is_file() or original.is_symlink() or digest(original)!=notice['sha256']:
                raise RuntimeError('Missing or changed original embedded Dart runtime notice: '+name)
    identity.update((sdk_revision+'\0'+compiler_digest+'\0'+runtime_digest).encode())
    signature = identity.hexdigest()
    node_lock=json.loads((ROOT/'tools/contract_engine/runtime.lock.json').read_bytes())
    engine_receipt=json.loads((contract/'build.json').read_bytes())
    if (digest(contract/'node')!=node_lock['binarySha256']
            or digest(contract/'engine.cjs')!=engine_receipt['helperSha256']):
        raise RuntimeError('Package exports require the exact locked Node and matching prepared contract helper')
    loader = output/'resource-package-loader'
    receipt = output/'build.json'
    try:
        previous = json.loads(receipt.read_text())
    except (ValueError, OSError):
        previous = {}
    if (previous.get('inputs') != signature or not loader.is_file() or loader.is_symlink()
            or digest(loader) != previous.get('loaderSha256')):
        with tempfile.TemporaryDirectory(prefix='busyapi-package-compiler-', dir=output) as stage:
            target = Path(stage)/'loader'
            subprocess.run([str(dart), 'compile', 'exe',
                            '--packages='+str(ROOT/'.dart_tool/package_config.json'),
                            str(ROOT/'packages/busyapi_core/bin/resource_package.dart'),
                            '-o', str(target)], cwd=ROOT, check=True)
            copy_atomic(target, loader, 0o755)
            record = Path(stage)/'build.json'
            record.write_text(json.dumps({'version':1,'inputs':signature,'sdk':'3.13.4',
                                          'loaderSha256':digest(loader)})+'\n')
            copy_atomic(record, receipt)
    files = {'libexec/busyapi/resource-package-loader':digest(loader)}
    for name in ('node','engine.cjs'):
        source = contract/name
        if not source.is_file() or source.is_symlink():
            raise RuntimeError('Prepare the matching locked contract runtime before package assets')
        files['libexec/busyapi/'+name] = digest(source)
    for directory, prefix in [(contract/'licenses','share/licenses/busyapi-engine/'),
                              (notices,'share/licenses/busyapi-dart/')]:
        if not (directory/'dependencies.json').is_file():
            raise RuntimeError('Prepare the reviewed original core/runtime notices before package assets')
        for file in sorted(directory.rglob('*')):
            if file.is_symlink():
                raise RuntimeError('Package notices cannot refer to a build-stage symlink')
            if file.is_file() and file.name != 'busyapi-output.json':
                files[prefix+file.relative_to(directory).as_posix()] = digest(file)
    libraries = set()
    versions = set()
    for binary in (loader, contract/'node'):
        dynamic = subprocess.check_output(['readelf','-d',str(binary)], text=True)
        libraries.update(re.findall(r'\(NEEDED\).*\[(.*?)\]',dynamic))
        symbols = subprocess.check_output(['readelf','--version-info',str(binary)], text=True)
        versions.update(re.findall(r'Name: ((?:GLIBC|GLIBCXX|CXXABI)_[\d.]+)',symbols))
    descriptor = {'version':1,'producer':'busyapi-resource-package-runtime','producerVersion':'1',
                  'sourceInputIdentity':signature,'sdk':'3.13.4','node':'24.15.0',
                  'sdkRevision':sdk_revision,
                  'compilerSha256':compiler_digest,
                  'aotRuntimeSha256':runtime_digest,
                  'platform':{'system':'Linux','architecture':'x86_64',
                              'requiredSystemLibraries':sorted(libraries),
                              'requiredElfSymbolVersions':sorted(versions)},
                  'files':files}
    # Match Dart's canonical compact, Unicode-preserving manifest spelling.
    raw = json.dumps(descriptor, separators=(',',':'), ensure_ascii=False)
    descriptor['identity'] = hashlib.sha256(raw.encode()).hexdigest()
    with tempfile.TemporaryDirectory(dir=output) as stage:
        record=Path(stage)/'runtime.json'
        record.write_text(json.dumps(descriptor,separators=(',',':'),ensure_ascii=False)+'\n')
        copy_atomic(record,output/'runtime.json')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--dart',required=True,type=Path)
    parser.add_argument('--contract-runtime',required=True,type=Path)
    parser.add_argument('--dart-notices',required=True,type=Path)
    args=parser.parse_args()
    prepare(args.output,args.dart,args.contract_runtime,args.dart_notices)
