"""Build-time identity/notice capture for the actual Linux ELF closure.

This is distribution evidence, not a licence scanner or a permission grant.
It neither installs packages nor acquires sources, and never runs at runtime.
The final source/linkage review remains explicit in the release materials.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

try:
    from tools.verify_documentation_runtime import verify as verify_documentation_runtime
except ModuleNotFoundError:
    from verify_documentation_runtime import verify as verify_documentation_runtime


PLATFORM = frozenset(('libc.so.6', 'libm.so.6', 'libdl.so.2',
                      'libpthread.so.0', 'librt.so.1', 'ld-linux-x86-64.so.2'))
COMMAND_ENV = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C'}


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def command(*args: str) -> str:
    result = subprocess.run(args, capture_output=True, text=True,
                            env=COMMAND_ENV, timeout=30, check=False)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout


def dynamic(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f'Expected ordinary ELF file: {path}')
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            raise RuntimeError(f'Expected ELF input: {path}')
    output = command('/usr/bin/readelf', '-d', str(path))
    fields = {}
    for tag, value in re.findall(r'\((NEEDED|SONAME|RPATH|RUNPATH)\).*?\[([^\]\r\n]+)\]', output):
        fields.setdefault(tag.lower(), []).append(value)
    return fields


def resolved_libraries(output: str) -> dict[str, Path]:
    result = {}
    for line in output.splitlines():
        if '=> not found' in line:
            raise RuntimeError('Missing native dependency: ' + line.strip())
        match = re.fullmatch(r'\s*(\S+) => (/.*?) \(0x[0-9a-f]+\)\s*', line)
        if not match:
            # The vDSO and loader have no =>; they are platform inputs.
            if '=>' in line:
                raise RuntimeError('Unrecognised native-loader result: ' + line.strip())
            continue
        name, filename = match.groups()
        if Path(name).name != name or name in ('.', '..'):
            raise RuntimeError('Invalid native dependency name')
        path = Path(filename)
        previous = result.get(name)
        if previous is not None and previous != path:
            raise RuntimeError('Ambiguous native dependency: ' + name)
        result[name] = path
    return result


def cached_libraries(output: str) -> dict[str, set[Path]]:
    """Trusted host loader cache, used only to attribute already copied bytes.

    Matching a SONAME is not evidence of package ownership. Collection below
    requires exact file identity and a unique installed distribution owner too.
    """
    result: dict[str, set[Path]] = {}
    for line in output.splitlines():
        match = re.fullmatch(r'\s*(\S+) \([^)]*\) => (/.*?)\s*', line)
        if match:
            name, filename = match.groups()
            if Path(name).name != name:
                raise RuntimeError('Invalid cached native dependency name')
            result.setdefault(name, set()).add(Path(filename))
    return result


def original_library(name: str, installed: Path, cache: dict[str, set[Path]]) -> Path | None:
    candidates = cache.get(name, set())
    if not candidates:
        return None  # Application/engine/plugin input, not a cached system DSO.
    identity = digest(installed)
    matches = {path.resolve(strict=True) for path in candidates if path.is_file() and digest(path) == identity}
    if len(matches) != 1:
        raise RuntimeError('A bundled system-library name has no unique original byte identity: ' + name)
    return next(iter(matches))


def package_owners(paths: list[Path]) -> dict[Path, str]:
    # usrmerge may expose one installed file through either spelling. Do not
    # select the first of several package owners or discard the architecture.
    spellings = {}
    for path in paths:
        real = path.resolve(strict=True)
        candidates = {str(path), str(real)}
        for item in tuple(candidates):
            if item.startswith('/usr/'):
                candidates.add(item[4:])
            elif item.startswith(('/lib/', '/lib64/', '/bin/', '/sbin/')):
                candidates.add('/usr' + item)
        spellings[path] = candidates
    all_paths = set().union(*spellings.values()) if spellings else set()
    if not all_paths:
        return {}
    result = subprocess.run(['/usr/bin/dpkg-query', '-S', *sorted(all_paths)],
                            capture_output=True, text=True, env=COMMAND_ENV,
                            timeout=30, check=False)
    found = {}
    for line in result.stdout.splitlines():
        if ': ' not in line:
            continue
        owner, filename = line.rsplit(': ', 1)
        if filename in all_paths and not owner.startswith(('diversion ', 'local diversion')):
            names = owner.split(', ')
            if not all(re.fullmatch(r'[a-z0-9][a-z0-9+.-]*(?::[a-z0-9][a-z0-9-]*)?', name) for name in names):
                raise RuntimeError('Invalid installed native package owner')
            found.setdefault(filename, set()).update(names)
    owners = {}
    for path, candidates in spellings.items():
        matches = set().union(*(found.get(candidate, set()) for candidate in candidates))
        if len(matches) != 1:
            raise RuntimeError(f'Native library has no unique installed package owner: {path}')
        owners[path] = matches.pop()
    return owners


def licence_fields(text: str) -> list[str]:
    # These are original Debian copyright labels, not inferred SPDX choices.
    # Retain the complete notice even when a human-readable file has no labels.
    return sorted(set(re.findall(r'^License: ([^\r\n]+)', text, re.MULTILINE)))


def common_licences(text: str, directory: Path = Path('/usr/share/common-licenses')) -> dict[str, bytes]:
    names = set(name.rstrip('.') for name in re.findall(r'/usr/share/common-licenses/([A-Za-z0-9.+-]+)', text))
    result = {}
    for name in sorted(names):
        source = directory / name
        # The distribution's common-licence aliases can be symlinks within
        # that directory. Output always contains an independent ordinary copy.
        if not source.resolve(strict=True).is_relative_to(directory.resolve()):
            raise RuntimeError('Common licence escapes its source directory: ' + name)
        data = source.read_bytes()
        if not data or len(data) > 2 * 1024 * 1024:
            raise RuntimeError('Invalid common licence text: ' + name)
        result[name] = data
    return result


def package_evidence(package: str) -> tuple[dict, dict[str, bytes]]:
    fields = command('/usr/bin/dpkg-query', '-W',
                     '-f=${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\t${Architecture}\t${db:Status-Status}\n', package).strip().split('\t')
    if len(fields) != 6 or fields[0] != package or fields[5] != 'installed':
        raise RuntimeError('Unexpected installed native package metadata: ' + package)
    name, version, source, source_version, architecture, _ = fields
    plain = name.split(':', 1)[0]
    notice = Path('/usr/share/doc') / plain / 'copyright'
    data = notice.read_bytes()
    if not data or len(data) > 8 * 1024 * 1024:
        raise RuntimeError('Missing or oversized native package copyright: ' + name)
    text = data.decode('utf-8')
    materials = {'copyright': data, **{'common/' + key: value for key, value in common_licences(text).items()}}
    return {
        'name': name, 'version': version, 'sourcePackage': source,
        'sourceVersion': source_version, 'architecture': architecture,
        'purpose': 'Dynamically linked native Linux runtime dependency.',
        'distribution': 'Unmodified shared-library copy; not the package tools, documentation or source tree.',
        'sourceNoticeUrls': sorted(set(re.findall(r'^Source: (https?://\S+)', text, re.MULTILINE))),
        'licenceLabels': licence_fields(text),
        'licenceLabelScope': 'Original distribution copyright declarations; not a determination that every source-file licence applies to this binary.',
        'notices': [{'file': key, 'sha256': hashlib.sha256(value).hexdigest()} for key, value in sorted(materials.items())],
        'review': 'Corresponding-source and actual linkage/redistribution review required; notices alone are not clearance.',
    }, materials


def installed_engine(bundle: Path, installed: Path) -> bool:
    if installed.name != 'libflutter_linux_gtk.so' or installed.is_symlink():
        return False
    try:
        from tools.verify_flutter_sdk import verify_installed
    except ModuleNotFoundError:
        from verify_flutter_sdk import verify_installed
    verify_installed(bundle)
    return True


def collect(bundle: Path) -> tuple[dict, dict[str, bytes], dict[str, Path]]:
    bundle = bundle.resolve(strict=True)
    runtime = verify_documentation_runtime(bundle)
    for name in PLATFORM:
        if (bundle / 'lib' / name).exists():
            raise RuntimeError('Host C runtime/loader is not a private distribution input: ' + name)
    required = ('busyapi-desktop', 'libexec/busyapi/node',
                'libexec/busyapi/resource-package-loader',
                'libexec/busyapi/policy-isolation.node', 'libexec/busyapi/policy-launcher')
    entries = [bundle / name for name in required]
    generator_launcher = bundle / 'libexec/busyapi/generator/generator-launcher'
    if generator_launcher.exists():
        entries.append(generator_launcher)
    # The standalone packager requires the compiled CLI. A normal GUI-only
    # IDE/debug install can be inventoried too, without inventing an entry.
    if (bundle / 'busyapi').exists():
        entries.append(bundle / 'busyapi')
    entries.extend(sorted(path for path in (bundle / 'lib').glob('*.so*') if path.name != 'libbusyapi_documentation.so'))
    queue = list(entries)
    seen = set()
    linked, external, packages, materials = {}, {}, {}, {}
    cache = cached_libraries(command('/usr/sbin/ldconfig', '-p'))
    while queue:
        binary = queue.pop()
        if binary in seen:
            continue
        seen.add(binary)
        fields = dynamic(binary)
        if binary.parent == bundle / 'lib':
            sonames = fields.get('soname', [])
            if len(sonames) > 1:
                raise RuntimeError('Ambiguous installed native SONAME')
            original = original_library(sonames[0] if sonames else binary.name, binary, cache)
            if original is not None:
                external[binary.name] = original
        for name, path in resolved_libraries(command('/usr/bin/ldd', str(binary))).items():
            real = path.resolve(strict=True)
            if name in PLATFORM:
                continue
            installed = bundle / 'lib' / name
            if installed.is_file() and installed.resolve(strict=True) != real:
                if installed.is_symlink() or digest(installed) != digest(real) and not installed_engine(bundle, installed):
                    raise RuntimeError('Installed/native loader identity mismatch: ' + name)
                # A plugin's direct-loader inspection can name the SDK's
                # other-mode SDK engine. Use the captured installed mode,
                # independently checked against its locked SDK identity.
                real = installed
            previous = external.get(name)
            if real.is_relative_to(bundle):
                queue.append(real)
                # Repeated packaging must still inventory libraries copied by
                # an earlier run, not relabel them as BusyAPI-owned code.
                original = original_library(name, real, cache)
                if original is not None:
                    if previous is not None and digest(previous) != digest(original):
                        raise RuntimeError('Conflicting native library identities: ' + name)
                    external[name] = original
            else:
                if previous is not None and digest(previous) != digest(real):
                    raise RuntimeError('Conflicting native library identities: ' + name)
                external[name] = real
        linked[str(binary.relative_to(bundle)) if binary.is_relative_to(bundle) else str(binary)] = {
            'sha256': digest(binary), 'bytes': binary.stat().st_size, **fields}
    owners = package_owners(list(set(external.values())))
    for name, source in sorted(external.items()):
        package = owners[source]
        if package not in packages:
            record, notices = package_evidence(package)
            packages[package] = record
            for filename, data in notices.items():
                materials['packages/' + package + '/' + filename] = data
    libraries = []
    for name, source in sorted(external.items()):
        package = owners[source]
        # ldd's transitive closure is inspected without loading an arbitrary
        # project executable. These are verified application/runtime inputs.
        fields = dynamic(source)
        libraries.append({'file': 'lib/' + name, 'sha256': digest(source),
                          'bytes': source.stat().st_size, 'package': package,
                          'sourceFile': str(source),
                          'linkage': 'dynamic', **fields})
    return {'version': 1, 'scope': 'busyapi-linux-native-distribution',
            'libraries': libraries, 'packages': [packages[name] for name in sorted(packages)],
            'platformLibraries': sorted(PLATFORM),
            'platformScope': 'Required host C runtime/loader, not copied by the standalone collector.',
            'documentationRuntime': {**runtime, 'distribution': 'Full host/platform runtime; not privately copied by this standalone collector.',
                                     'moduleSha256': digest(bundle / runtime['module']),
                                     'moduleLinkage': dynamic(bundle / runtime['module'])},
            'applicationLinkage': {name: fields for name, fields in sorted(linked.items())},
            'licenceReviewComplete': False}, materials, external


def _write_material(bundle: Path, relative: str, data: bytes) -> None:
    """Ordinary build-owned output only; never follow a notice-directory link."""
    path = bundle / relative
    if Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise RuntimeError('Invalid native material destination')
    for parent in [path, *path.parents]:
        if parent == bundle:
            break
        if parent.is_symlink():
            raise RuntimeError('Native material destination is a symlink: ' + relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def assemble(bundle: Path) -> dict:
    """Copy the proved unmodified closure and verify actual assembled notices.

    This fulfills identity/inventory/material collection, not the separate
    source/linkage review. It cannot mark an application legally cleared.
    """
    bundle = bundle.resolve(strict=True)
    before, before_materials, sources = collect(bundle)
    for name, source in sorted(sources.items()):
        target = bundle / 'lib' / name
        if target.is_symlink():
            raise RuntimeError('Native library output is not ordinary: ' + name)
        if target.exists():
            if digest(target) != digest(source):
                raise RuntimeError('Native library collision: ' + name)
        else:
            shutil.copy2(source, target)
    # Re-read the relocated layout after copying. Attribution of a bundled
    # library still requires the unique original installed bytes/package.
    after, materials, _ = collect(bundle)
    if {item['file']: item['sha256'] for item in before['libraries']} != {
            item['file']: item['sha256'] for item in after['libraries']}:
        raise RuntimeError('The assembled native dependency closure changed during packaging')
    if before['packages'] != after['packages'] or before_materials != materials:
        raise RuntimeError('Native package/notice inputs changed during packaging')
    if any(after['applicationLinkage'].get(name) != fields
           for name, fields in before['applicationLinkage'].items()):
        raise RuntimeError('Application/native binary inputs changed during packaging')
    if len(materials) > 4096 or sum(map(len, materials.values())) > 64 * 1024 * 1024:
        raise RuntimeError('Native distribution notice materials exceed their bound')
    prefix = 'share/licenses/busyapi-native/'
    for relative, data in sorted(materials.items()):
        _write_material(bundle, prefix + relative, data)
    after['inventoryStage'] = 'assembled'
    _write_material(bundle, prefix + 'dependencies.json',
                    (json.dumps(after, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode())
    _write_material(bundle, prefix + 'README.txt', (
        'BusyAPI native runtime distribution materials\n\n'
        'dependencies.json identifies actual dynamically linked copied bytes, their exact installed binary/source packages, and retained original copyright/common-license files. '
        'It excludes the separately identified full system WebKit runtime and host C runtime/loader. '
        'Package-wide license labels are evidence, not a claim that every package source-file license applies to a shipped library.\n\n'
        'The inventory intentionally does not assert completed license clearance. Corresponding-source, selected binary/source scope, native-library replacement/relinking and engine redistribution obligations require the separate distribution review and accompanying materials. '
        'Do not treat these notices alone as a source offer or permission grant. No proprietary BusyAPI source-disclosure conclusion is inferred.\n'
        '\nReplacing dynamically linked libraries\n'
        'Keep an unchanged backup. In a private copy of the standalone layout, rebuild the selected library from the matching source companion (original upstream archives plus distribution patches/build instructions), '
        'or supply another interface-compatible build under its applicable licence. Replace its ordinary lib/ file using the same SONAME and architecture; preserve the other layout files. '
        'The normal ELF loader resolves these shared libraries at runtime. BusyAPI does not hash-gate the replaceable system-library bytes; its build-time inventory records the original distribution, not a veto on user replacements. '
        'Required security interfaces/minimum versions and actual restriction installation still apply. Native modules/engine and Node have separate application-owned provenance boundaries.\n'
        'The applicable LGPL permits library modification/replacement and reverse engineering needed to debug those modifications; BusyAPI imposes no additional restriction on exercising those rights. '
        'Retain all applicable library terms/notices and supply the matching source materials when redistributing. This is not permission to disregard other components\' terms. '
        'A read-only Snap image needs repacking/sideloading rather than in-place replacement; that distribution\'s corresponding-source, installation/replacement and confinement qualification must be reviewed separately.\n'
    ).encode())
    # Verify the bytes inside the assembled layout, not just a generated report.
    for library in after['libraries']:
        path = bundle / library['file']
        if path.is_symlink() or path.stat().st_size != library['bytes'] or digest(path) != library['sha256']:
            raise RuntimeError('Assembled native library identity mismatch: ' + library['file'])
    for package in after['packages']:
        for notice in package['notices']:
            relative = 'packages/' + package['name'] + '/' + notice['file']
            path = bundle / prefix / relative
            if path.is_symlink() or digest(path) != notice['sha256'] or path.read_bytes() != materials[relative]:
                raise RuntimeError('Assembled native notice mismatch: ' + relative)
    return after


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--assemble', action='store_true', help='Copy/verify build-owned native libraries and original notice materials')
    args = parser.parse_args()
    if args.assemble:
        inventory = assemble(args.bundle)
    else:
        inventory, _, _ = collect(args.bundle)
    print(json.dumps(inventory, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
