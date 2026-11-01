#!/usr/bin/env python3
"""Explicit locked generator build inputs. Never called by the application."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'tools/generator/tools.lock.json').read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(root):
    files = {}
    for file in sorted(root.rglob('*')):
        if file.is_symlink():
            raise RuntimeError('Linked generator asset: ' + str(file))
        if file.is_file() and file.relative_to(root).as_posix() != 'assets.json':
            files[file.relative_to(root).as_posix()] = digest(file)
    return files


def verify(root, *, current_source=True):
    if (root / 'assets.json').is_symlink():
        raise RuntimeError('Linked generator receipt')
    receipt = json.loads((root / 'assets.json').read_text())
    runtime_files = {k: v for k, v in receipt['files'].items() if k.startswith('jre/')}
    runtime_identity = hashlib.sha256(json.dumps(runtime_files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if (receipt['version'] != 1 or receipt['lock'] != LOCK or
            current_source and receipt['launcherSource'] != digest(ROOT / 'tools/generator/launcher.cc') or
            current_source and receipt.get('preparation') != digest(Path(__file__)) or
            runtime_identity != LOCK['runtimeFilesSha256'] or
            inventory(root) != receipt['files'] or
            receipt['files'].get('openapi-generator.jar') != LOCK['jarSha256'] or
            not os.access(root / 'jre/bin/java', os.X_OK) or
            not os.access(root / 'generator-launcher', os.X_OK)):
        raise RuntimeError('Missing or altered packaged generator inputs')
    return receipt


def build_launcher(stage):
    compiler = shutil.which(os.environ.get('CXX', 'c++'))
    if not compiler:
        raise RuntimeError('C++ compiler is required for the generator startup policy')
    subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', '-O2',
                    '-I' + str(ROOT / 'build/policy-isolation-inputs/libseccomp'),
                    '-fPIE', '-pie', '-Wl,-z,relro,-z,now',
                    str(ROOT / 'tools/generator/launcher.cc'), '-Wl,-l:libseccomp.so.2',
                    '-ldl', '-o', str(stage / 'generator-launcher')], check=True)
    return subprocess.check_output([compiler, '--version'], text=True).splitlines()[0]


def refresh_notice_index(stage):
    notices = stage / 'notices'
    notices.mkdir(exist_ok=True)
    with zipfile.ZipFile(stage / 'openapi-generator.jar') as archive:
        names = [name for name in archive.namelist() if not name.endswith('/') and
                 ('license' in name.lower() or 'notice' in name.lower()) and name.startswith('META-INF/')]
        index = {f'{i:03d}-{Path(name).name}': {'jarPath': name, 'sha256': hashlib.sha256(archive.read(name)).hexdigest()}
                 for i, name in enumerate(sorted(names))}
    (notices / 'jar-notices.json').write_text(json.dumps(index, sort_keys=True, indent=2) + '\n')


def acquire(url, target, expected):
    with urllib.request.urlopen(url, timeout=60) as source, target.open('xb') as output:
        total = 0
        while chunk := source.read(1024 * 1024):
            total += len(chunk)
            if total > 128 * 1024 * 1024:
                raise RuntimeError('Generator build input exceeds its limit')
            output.write(chunk)
    if digest(target) != expected:
        raise RuntimeError('Generator build input digest mismatch')
    return target


def prepare(output, jar=None, runtime=None, provision=False):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('The locked generator runtime targets Linux x86_64')
    jar = jar or os.environ.get('BUSYAPI_GENERATOR_JAR')
    runtime = runtime or os.environ.get('BUSYAPI_GENERATOR_JRE_ARCHIVE')
    for supplied, expected in [(jar, LOCK['jarSha256']), (runtime, LOCK['runtimeArchiveSha256'])]:
        if supplied and (not Path(supplied).is_file() or Path(supplied).is_symlink() or digest(supplied) != expected):
            raise RuntimeError('Explicit generator build input is missing or has the wrong digest')
    cached = output if (output / 'assets.json').exists() else ROOT / 'build/generator'
    source_identity = digest(ROOT / 'tools/generator/launcher.cc')
    if jar is None and runtime is None and (cached / 'assets.json').exists():
        receipt = verify(cached, current_source=False)
        if receipt['launcherSource'] != source_identity:
            with tempfile.TemporaryDirectory(prefix='generator-launcher-', dir=cached.parent) as folder:
                stage = Path(folder)
                receipt['compiler'] = build_launcher(stage)
                (stage / 'generator-launcher').replace(cached / 'generator-launcher')
                receipt['launcherSource'] = source_identity
                receipt['files'] = inventory(cached)
                (stage / 'assets.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
                (stage / 'assets.json').replace(cached / 'assets.json')
        if receipt.get('preparation') != digest(Path(__file__)):
            refresh_notice_index(cached)
            receipt['preparation'] = digest(Path(__file__))
            receipt['files'] = inventory(cached)
            (cached / 'assets.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
        if output.resolve() != cached.resolve():
            shutil.copytree(cached, output, dirs_exist_ok=True)
        return verify(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='generator-build-', dir=output.parent) as folder:
        work = Path(folder)
        if jar is None and provision:
            jar = acquire(LOCK['jarUrl'], work / 'generator.jar', LOCK['jarSha256'])
        if runtime is None and provision:
            runtime = acquire(LOCK['runtimeUrl'], work / 'runtime.tar.gz', LOCK['runtimeArchiveSha256'])
        if jar is None or runtime is None:
            raise RuntimeError('Prepare generation explicitly with --jar FILE --jre-archive FILE or --provision; no runtime downloads occur')
        unpacked = work / 'unpacked'
        with tarfile.open(runtime) as archive:
            archive.extractall(unpacked, filter='data')
        roots = list(unpacked.iterdir())
        if len(roots) != 1 or not (roots[0] / 'bin/java').is_file():
            raise RuntimeError('Invalid locked Java archive layout')
        stage = work / 'stage'
        stage.mkdir()
        shutil.copytree(roots[0], stage / 'jre', symlinks=False)
        shutil.copyfile(jar, stage / 'openapi-generator.jar')
        compiler_identity = build_launcher(stage)
        notices = stage / 'notices'
        notices.mkdir()
        with zipfile.ZipFile(jar) as archive:
            names = [name for name in archive.namelist() if not name.endswith('/') and
                     ('license' in name.lower() or 'notice' in name.lower()) and name.startswith('META-INF/')]
            notice_index = {}
            for index, name in enumerate(sorted(names)):
                filename = f'{index:03d}-{Path(name).name}'
                (notices / filename).write_bytes(archive.read(name))
                notice_index[filename] = {'jarPath': name, 'sha256': digest(notices / filename)}
            dependencies = {name: archive.read(name).decode(errors='replace')
                            for name in archive.namelist() if name.endswith('/pom.properties')}
        (notices / 'jar-components.json').write_text(json.dumps(dependencies, sort_keys=True, indent=2) + '\n')
        (notices / 'jar-notices.json').write_text(json.dumps(notice_index, sort_keys=True, indent=2) + '\n')
        shutil.copyfile(ROOT / 'LICENSE', notices / 'OpenAPI-Generator-Apache-2.0.txt')
        (notices / 'SOURCES.txt').write_text(
            'OpenAPI Generator 7.26.0: https://github.com/OpenAPITools/openapi-generator/tree/v7.26.0\n'
            'Temurin 17.0.20+8: https://github.com/adoptium/jdk17u/tree/jdk-17.0.20%2B8\n'
            'JRE original per-module grants/notices are retained in jre/legal.\n'
            'JAR embedded grants/notices and exact Maven component metadata are retained here.\n'
            'Final public-distribution review remains outstanding.\n')
        receipt = {'version': 1, 'lock': LOCK, 'launcherSource': source_identity,
                   'preparation': digest(Path(__file__)),
                   'compiler': compiler_identity,
                   'files': inventory(stage)}
        (stage / 'assets.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
        verify(stage)
        shutil.copytree(stage, output, dirs_exist_ok=True)
        return verify(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/generator')
    parser.add_argument('--jar')
    parser.add_argument('--jre-archive')
    parser.add_argument('--provision', action='store_true')
    args = parser.parse_args()
    prepare(args.output, args.jar, args.jre_archive, args.provision)
