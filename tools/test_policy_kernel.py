#!/usr/bin/env python3
"""Run the production isolation regressions in an explicit networkless kernel VM.

Development only. Supply an already verified Linux kernel, pinned Node and an
empty work directory. No package install, host kernel change or VM networking.
The initramfs contains only test assets and replaceable host runtime libraries.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

from prepare_policy_isolation import ROOT, digest, prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--kernel-sha256', required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    if digest(args.kernel) != args.kernel_sha256:
        parser.error('Explicit kernel identity does not match')
    import json
    if digest(args.node) != json.loads((ROOT / 'tools/contract_engine/runtime.lock.json').read_text())['binarySha256']:
        parser.error('Use the pinned Node runtime')
    args.work.mkdir(exist_ok=False)
    root = args.work / 'root'
    for directory in ['bin', 'dev', 'proc', 'sys', 'tmp', 'policy', 'runtime', 'tests']:
        (root / directory).mkdir(parents=True)
    prepare(ROOT / 'build/policy-isolation')
    binaries = [args.node, Path('/bin/busybox'),
                ROOT / 'build/policy-isolation/policy-launcher',
                ROOT / 'build/policy-isolation/policy-isolation.node']
    for source, target in zip(binaries, ['runtime/node', 'bin/busybox',
                                       'policy/policy-launcher', 'policy/policy-isolation.node']):
        shutil.copy2(source, root / target)
    # Exact ELF dependency paths, not a whole host filesystem or library tree.
    for binary in binaries:
        linkage = subprocess.run(['ldd', str(binary)], capture_output=True, text=True)
        if linkage.returncode and binary != Path('/bin/busybox'):
            raise RuntimeError('Missing test runtime dependency: ' + str(binary))
        for spelling in re.findall(r'(/[^\s()]+)', linkage.stdout):
            source = Path(spelling)
            if not source.is_file():
                raise RuntimeError('Unresolved test DSO')
            target = root / source.relative_to('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                shutil.copy2(source, target)
    compiler = ROOT / 'tools/contract_engine/node_modules/@esbuild/linux-x64/bin/esbuild'
    for source, target in [('policy_worker.ts', 'policy-worker.cjs'),
                           ('policy_process_worker.ts', 'transport.cjs'),
                           ('governance.ts', 'governance.cjs'), ('policy_code_review.ts', 'review.cjs')]:
        subprocess.run([str(compiler), str(ROOT / 'tools/contract_engine/src' / source),
                        '--bundle', '--platform=node', '--format=cjs', '--main-fields=module,main',
                        '--outfile=' + str(root / 'policy' / target)], check=True, cwd=ROOT)
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-fPIC', '-shared', '-I' + str(ROOT / 'build/policy-isolation-inputs/node'),
                    str(ROOT / 'tools/contract_engine/native/policy_isolation_test.cc'),
                    '-o', str(root / 'policy/attempts.node')], check=True)
    for test in ['isolation', 'process', 'execution']:
        shutil.copy2(ROOT / f'tools/contract_engine/test_policy_{test}.cjs', root / 'tests')
    shutil.copy2(ROOT / 'tools/policy_kernel_init.sh', root / 'init')
    (root / 'init').chmod(0o755)
    # cpio runs in this private newly-created tree, without elevated writes.
    names = subprocess.run(['find', '.', '-print0'], cwd=root, check=True, capture_output=True).stdout
    archive = args.work / 'initramfs.cpio'
    with archive.open('xb') as stream:
        subprocess.run(['cpio', '--null', '-o', '-H', 'newc', '--reproducible'],
                       cwd=root, input=names, stdout=stream, check=True)
    log = args.work / 'console.log'
    with log.open('xb') as stream:
        process = subprocess.run(['qemu-system-x86_64', '-accel', 'kvm', '-cpu', 'host',
                                  '-m', '2048', '-smp', '2', '-nic', 'none', '-nographic',
                                  '-no-reboot', '-kernel', str(args.kernel), '-initrd', str(archive),
                                  '-append', 'console=ttyS0 rdinit=/init panic=1'],
                                 stdout=stream, stderr=subprocess.STDOUT, timeout=180)
    text = log.read_text(errors='replace')
    print(text)
    if process.returncode or 'BUSYAPI_KERNEL_TEST_PASS' not in text or 'BUSYAPI_KERNEL_TEST_FAIL' in text:
        raise RuntimeError('Kernel security regressions did not complete successfully')


if __name__ == '__main__':
    main()
