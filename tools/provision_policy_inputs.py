#!/usr/bin/env python3
"""Explicit build-only acquisition of the exact reviewed header archive.

Not called by opening, runtime, CMake or offline preparation. It installs no
system package, changes no host policy and does not provision another toolchain.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit

if __package__:
    from .prepare_policy_isolation import ROOT, prepare
else:
    from prepare_policy_isolation import ROOT, prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provision', action='store_true', help='Explicitly allow this one locked public archive download')
    parser.add_argument('--node-include', type=Path, required=True)
    arguments = parser.parse_args()
    if not arguments.provision:
        parser.error('Use --provision to acquire the locked headers, or prepare_policy_isolation.py for offline cached inputs')
    lock = json.loads((ROOT / 'tools/contract_engine/native/build-inputs.lock.json').read_text())
    for name, expected in lock['node']['headers'].items():
        header = arguments.node_include / name
        if not header.is_file() or header.is_symlink() or hashlib.sha256(header.read_bytes()).hexdigest() != expected:
            parser.error('Provision the reviewed pinned Node headers before acquiring libseccomp declarations')
    record = lock['libseccomp']
    source = record['headerPackage']
    origin = urlsplit(source)
    if origin.scheme != 'https' or origin.username or origin.password or origin.fragment:
        parser.error('The reviewed build input must use a credential-free HTTPS identity')

    try:
        curl = shutil.which('curl')
        if curl is None:
            raise RuntimeError('Explicit provisioning needs the build host curl; offline preparation does not')
        with tempfile.TemporaryDirectory(prefix='busyapi-policy-declarations-') as folder:
            archive = Path(folder) / 'headers.deb'
            # The maintained transfer tool enforces a total wall limit, not
            # just per-read socket timeouts. No curlrc, redirects, proxies,
            # credentials or unrelated environment enter this public request.
            subprocess.run([curl, '--disable', '--silent', '--show-error', '--fail',
                            '--proto', '=https', '--proto-redir', '=https',
                            '--location', '--max-redirs', '0', '--noproxy', '*',
                            '--max-time', '60', '--max-filesize', str(2 * 1024 * 1024),
                            '--output', str(archive), source], check=True, timeout=65, env={})
            data = archive.read_bytes()
            if len(data) > 2 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != record['headerPackageSha256']:
                raise RuntimeError('The acquired header archive does not match the reviewed digest/byte limit')
            # Verify before the archive reader. Only its owned temporary data is
            # extracted; no system package or application asset is installed.
            extracted = Path(folder) / 'extracted'
            subprocess.run(['dpkg-deb', '--extract', str(archive), str(extracted)], check=True, timeout=30)
            prepare(ROOT / 'build/policy-isolation', node_include=arguments.node_include,
                    seccomp_include=extracted / 'usr/include')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, 'Policy build input provisioning failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
