#!/usr/bin/env python3
"""Explicit build-input acquisition/staging; ordinary preparation is offline."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
OASDIFF_VERSION = '1.33.0'
OASDIFF_SHA256 = 'fa65aae43c867e9f79da9cb121d3c1a113637883afe014c0680fd5b50696f416'
OASDIFF_ARCHIVE_SHA256 = '43a4e328e2d13ba1552d760aa68d2485c75c5621f309f6ff64ae895188345247'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def atomic_copy(source, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        shutil.copyfile(source, temporary)
        temporary.chmod(mode)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def acquire(directory):
    """Only an explicit builder invocation downloads this exact release."""
    archive = directory / 'oasdiff.tar.gz'
    url = ('https://github.com/oasdiff/oasdiff/releases/download/v1.33.0/'
           'oasdiff_1.33.0_linux_amd64.tar.gz')
    with urllib.request.urlopen(url, timeout=60) as source, archive.open('xb') as target:
        total = 0
        while chunk := source.read(1024 * 1024):
            total += len(chunk)
            if total > 64 * 1024 * 1024:
                raise RuntimeError('oasdiff build archive exceeds its limit')
            target.write(chunk)
    if digest(archive) != OASDIFF_ARCHIVE_SHA256:
        raise RuntimeError('oasdiff release archive digest mismatch')
    binary = directory / 'oasdiff'
    with tarfile.open(archive, 'r:gz') as source:
        matches = [item for item in source.getmembers() if item.name == 'oasdiff']
        if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 64 * 1024 * 1024:
            raise RuntimeError('oasdiff archive has no unique ordinary binary')
        with source.extractfile(matches[0]) as stream, binary.open('xb') as target:
            shutil.copyfileobj(stream, target)
    if digest(binary) != OASDIFF_SHA256:
        raise RuntimeError('oasdiff extracted binary digest mismatch')
    binary.chmod(0o755)
    return binary


def prepare(output, oasdiff=None, provision=False):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('The pinned M3 tool runtime targets Linux amd64')
    explicit = oasdiff if oasdiff is not None else os.environ.get('BUSYAPI_OASDIFF')
    source = Path(explicit) if explicit is not None else output / 'oasdiff'
    if explicit is None and not source.exists():
        source = ROOT / 'build/m3-tools/oasdiff'
    if explicit is None and not source.exists() and provision:
        with tempfile.TemporaryDirectory(prefix='busyapi-m3-build-input-') as temporary:
            return prepare(output, acquire(Path(temporary)))
    if not source.is_file() or source.is_symlink() or digest(source) != OASDIFF_SHA256:
        raise RuntimeError('oasdiff 1.33.0 Linux amd64 build input is missing or has the wrong digest; supply --oasdiff FILE or explicitly --provision in the builder')
    version = subprocess.run([source, '--version'], capture_output=True, text=True,
                             timeout=10, env={'PATH': '', 'LANG': 'C.UTF-8'}, check=True)
    if version.stdout.strip() != 'oasdiff version 1.33.0':
        raise RuntimeError('oasdiff build input reports an unexpected version')
    output.mkdir(parents=True, exist_ok=True)
    atomic_copy(source, output / 'oasdiff', 0o755)
    licenses = output / 'licenses'
    licenses.mkdir(exist_ok=True)
    # Upstream v1.33.0 uses the unmodified Apache-2.0 text. BusyAPI's own copy
    # is identical and is installed under an unambiguous component filename.
    atomic_copy(ROOT / 'LICENSE', licenses / 'oasdiff-1.33.0-LICENSE')
    go = shutil.which('go')
    build_info = (subprocess.run([go, 'version', '-m', source], capture_output=True,
                                 text=True, timeout=10, check=False).stdout
                  if go else 'Go build-module inventory tool unavailable at packaging time; final assembled dependency clearance remains M4.')
    receipt = {
        'version': 1,
        'tools': [{
            'name': 'oasdiff', 'version': OASDIFF_VERSION,
            'binarySha256': OASDIFF_SHA256,
            'releaseArchiveSha256': OASDIFF_ARCHIVE_SHA256,
            'release': 'https://github.com/oasdiff/oasdiff/releases/tag/v1.33.0',
            'source': 'https://github.com/oasdiff/oasdiff/tree/v1.33.0',
            'license': 'Apache-2.0',
            'licenseFile': 'oasdiff-1.33.0-LICENSE',
            'purpose': 'Offline semantic OpenAPI comparison over BusyAPI-derived snapshots',
            'network': 'disabled by adapter; external references disabled',
        }],
        'goBuildInfo': build_info.splitlines(),
        'distributionQualification': 'M3 exact binary and direct license; final assembled redistribution clearance remains M4',
    }
    (output / 'tools.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--oasdiff')
    parser.add_argument('--provision', action='store_true', help='Explicitly acquire the locked release in this build environment')
    args = parser.parse_args()
    prepare(args.output, args.oasdiff, args.provision)
