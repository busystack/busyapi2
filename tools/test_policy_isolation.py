#!/usr/bin/env python3
"""Build the reviewed target and run controlled real-kernel tests, no host setup."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from prepare_policy_isolation import ROOT, digest, prepare, publish


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', type=Path)
    parser.add_argument('--capability-aware', action='store_true', help=
        'Report unsupported-kernel refusal as incomplete required positive coverage (exit 2)')
    arguments = parser.parse_args()
    candidate = arguments.node or os.environ.get('BUSYAPI_NODE') or shutil.which('node')
    if candidate is None:
        parser.exit(1, 'Provision the pinned Node build input explicitly\n')
    node = Path(candidate).resolve()
    runtime = json.loads((ROOT / 'tools/contract_engine/runtime.lock.json').read_text())
    if not node.is_file() or digest(node) != runtime['binarySha256']:
        parser.exit(1, 'Policy isolation tests require the exact pinned Node binary\n')
    output = ROOT / 'build/policy-isolation'
    prepare(output)
    # The direct syscall helper is test-only. It is never an installed asset or
    # a project-code capability; compile it from the same reviewed N-API inputs.
    with tempfile.TemporaryDirectory(prefix='busyapi-policy-attempts-') as folder:
        stage = Path(folder)
        gate = stage / 'capability-test'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra',
                        '-Werror', '-I' + str(ROOT / 'build/policy-isolation-inputs/libseccomp'),
                        str(ROOT / 'tools/contract_engine/native/policy_capability_test.cc'),
                        '-Wl,-l:libseccomp.so.2', '-o', str(gate)], check=True)
        marker = stage / 'project-code-must-not-run'
        entry = stage / 'unsupported.cjs'
        entry.write_text('require("node:fs").writeFileSync(' + json.dumps(str(marker)) + ',"escaped")')
        command = [str(output / 'policy-launcher'), str(node), str(entry)]
        denied = subprocess.run([str(gate), '--deny-landlock', *command],
                                env={}, capture_output=True, timeout=10)
        if denied.returncode != 2 or marker.exists() or denied.stdout or (
                denied.stderr != b'Required governance startup restriction is unavailable\n'):
            raise RuntimeError('Unsupported-kernel fault test failed: project code must not execute')
        print('PASS: unavailable Landlock fails closed before Node/project code', flush=True)
        probe = subprocess.run([str(node), '-e', 'console.log(JSON.stringify(require(' +
            json.dumps(str(output / 'policy-isolation.node')) + ').capabilities()))'],
            env={}, check=True, capture_output=True, text=True)
        capabilities = json.loads(probe.stdout)
        version = tuple(map(int, capabilities['libseccomp'].split('.')))
        supported = capabilities['landlockAbi'] >= 3 and version >= (2, 5, 5)
        print('Kernel isolation capabilities: ' + json.dumps(capabilities, sort_keys=True), flush=True)
        if not supported:
            refused = subprocess.run(command, env={}, capture_output=True, timeout=10)
            if refused.returncode != 2 or marker.exists() or refused.stdout:
                raise RuntimeError('The actual unsupported host did not fail closed')
            parser.exit(2, 'FAIL-CLOSED verified; required positive isolation coverage remains unavailable. '
                        'Run this suite on an enabled Landlock ABI >=3 / libseccomp >=2.5.5 host.\n')
        # The actual launcher/TSYNC/governance tests must succeed after probing;
        # an OS image label is not a capability assertion or permission to skip.
        attempts = Path(folder) / 'attempts.node'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra',
                        '-Werror', '-fPIC', '-shared',
                        '-I' + str(ROOT / 'build/policy-isolation-inputs/node'),
                        str(ROOT / 'tools/contract_engine/native/policy_isolation_test.cc'),
                        '-o', str(attempts)], check=True)
        subprocess.run([str(node), str(ROOT / 'tools/contract_engine/test_policy_isolation.cjs')],
                       cwd=folder, env={
                           'BUSYAPI_TEST_POLICY_ISOLATION': str(output / 'policy-isolation.node'),
                           'BUSYAPI_TEST_POLICY_LAUNCHER': str(output / 'policy-launcher'),
                           'BUSYAPI_TEST_POLICY_ATTEMPTS': str(attempts),
                       }, check=True)
        compiler = ROOT / 'tools/contract_engine/node_modules/@esbuild/linux-x64/bin/esbuild'
        if not compiler.is_file():
            parser.exit(1, 'Provision the locked engine dependencies with tools/build_engine.sh first\n')
        stage = Path(folder)
        for source, name in [('policy_worker.ts', 'policy-worker.cjs'),
                             ('policy_process_worker.ts', 'transport.cjs'),
                             ('governance.ts', 'governance.cjs'),
                             ('policy_code_review.ts', 'review.cjs')]:
            subprocess.run([str(compiler), str(ROOT / 'tools/contract_engine/src' / source),
                            '--bundle', '--platform=node', '--format=cjs', '--main-fields=module,main',
                            '--outfile=' + str(stage / name)], check=True, cwd=ROOT)
        publish(output / 'policy-isolation.node', stage / 'policy-isolation.node')
        subprocess.run([str(node), str(ROOT / 'tools/contract_engine/test_policy_process.cjs')],
                       cwd=folder, env={
                           'BUSYAPI_TEST_POLICY_LAUNCHER': str(output / 'policy-launcher'),
                           'BUSYAPI_TEST_POLICY_ENTRY': str(stage / 'policy-worker.cjs'),
                           'BUSYAPI_TEST_POLICY_TRANSPORT': str(stage / 'transport.cjs'),
                           'BUSYAPI_TEST_POLICY_GOVERNANCE': str(stage / 'governance.cjs'),
                       }, check=True)
        subprocess.run([str(node), str(ROOT / 'tools/contract_engine/test_policy_execution.cjs')],
                       cwd=folder, env={
                           'BUSYAPI_TEST_POLICY_LAUNCHER': str(output / 'policy-launcher'),
                           'BUSYAPI_TEST_POLICY_ENTRY': str(stage / 'policy-worker.cjs'),
                           'BUSYAPI_TEST_POLICY_TRANSPORT': str(stage / 'transport.cjs'),
                           'BUSYAPI_TEST_POLICY_REVIEW': str(stage / 'review.cjs'),
                       }, check=True)


if __name__ == '__main__':
    main()
