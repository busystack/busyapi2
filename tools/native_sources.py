"""Assemble an offline corresponding-source companion for copied native libraries.

Consumes an assembled native inventory and explicitly supplied original Debian
source declarations/archives. No downloads, package installation, extraction,
licence inference, project reads or upstream signature-verification claim.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile
from email.parser import Parser
from urllib.parse import unquote, urlsplit


MAX_INDEX = 4 * 1024 * 1024
MAX_DECLARATION = 256 * 1024
MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9.+_~:-]{0,255}')
SHA = re.compile(r'[a-f0-9]{64}')


def ordinary(root: Path, name: str, limit: int) -> Path:
    if not NAME.fullmatch(name):
        raise RuntimeError('Invalid source material name')
    path = root / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise RuntimeError('Missing, linked or oversized source material: ' + name)
    return path


def read_json(path: Path, limit: int) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise RuntimeError('Expected bounded ordinary source inventory')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise RuntimeError('Duplicate source inventory key')
            result[key] = value
        return result
    value = json.loads(path.read_bytes(), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise RuntimeError('Expected source inventory object')
    return value


def declaration(data: bytes) -> tuple[str, str, dict[str, tuple[int, str]]]:
    """Read the original Deb822 source identity/checksums, not its trust status."""
    if len(data) > MAX_DECLARATION:
        raise RuntimeError('Oversized source declaration')
    text = data.decode('utf-8').replace('\r\n', '\n')
    if text.startswith('-----BEGIN PGP SIGNED MESSAGE-----\n'):
        _, separator, text = text.partition('\n\n')
        text, signature, _ = text.partition('\n-----BEGIN PGP SIGNATURE-----')
        if not separator or not signature:
            raise RuntimeError('Malformed signed source declaration')
        # Cleartext dash escaping belongs to the signature envelope, not Deb822.
        text = '\n'.join(line[2:] if line.startswith('- ') else line for line in text.split('\n'))
    headers = Parser().parsestr(text, headersonly=True)
    if headers.defects or any(len(headers.get_all(key, [])) != 1 for key in ('Source', 'Version', 'Checksums-Sha256')):
        raise RuntimeError('Missing or repeated source declaration identity/checksums')
    package, version = headers['Source'].strip(), headers['Version'].strip()
    if not NAME.fullmatch(package) or not NAME.fullmatch(version):
        raise RuntimeError('Invalid source declaration identity')
    files = {}
    for line in headers['Checksums-Sha256'].splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 3:
            raise RuntimeError('Malformed source checksum record')
        sha, size, name = parts
        if not SHA.fullmatch(sha) or not size.isascii() or not size.isdigit() or not NAME.fullmatch(name):
            raise RuntimeError('Invalid source checksum record')
        count = int(size)
        if count <= 0 or count > MAX_FILE or name in files:
            raise RuntimeError('Repeated or oversized source checksum record')
        files[name] = (count, sha)
    if not files:
        raise RuntimeError('Empty source declaration')
    return package, version, files


def url_name(url: str) -> str:
    parts = urlsplit(url)
    name = unquote(parts.path.rsplit('/', 1)[-1])
    if parts.scheme != 'https' or not parts.netloc or parts.username or parts.password or parts.fragment or parts.query or not NAME.fullmatch(name):
        raise RuntimeError('Invalid original source URL')
    return name


class CheckedReader:
    def __init__(self, stream):
        self.stream, self.digest = stream, hashlib.sha256()

    def read(self, count):
        data = self.stream.read(count)
        self.digest.update(data)
        return data


def assemble(bundle: Path, cache: Path, index_path: Path, output: Path) -> dict:
    bundle, cache = bundle.resolve(strict=True), cache.resolve(strict=True)
    # Inputs are immutable build evidence; an existing output is never replaced.
    output = output.absolute()
    for part in [output, *output.parents]:
        if part.is_symlink():
            raise RuntimeError('Source companion destination uses a symlink')
    if output.exists() or not output.parent.is_dir():
        raise RuntimeError('Source companion destination exists or has no parent')
    inventory_path = bundle / 'share/licenses/busyapi-native/dependencies.json'
    if any(parent.is_symlink() for parent in inventory_path.parents if parent != bundle and parent.is_relative_to(bundle)):
        raise RuntimeError('Assembled native inventory uses a symlink')
    inventory = read_json(inventory_path, MAX_INDEX)
    inventory_bytes = inventory_path.read_bytes()
    if json.loads(inventory_bytes) != inventory:
        raise RuntimeError('Assembled native inventory changed during capture')
    if inventory.get('version') != 1 or inventory.get('scope') != 'busyapi-linux-native-distribution' or inventory.get('inventoryStage') != 'assembled':
        raise RuntimeError('A verified assembled native inventory is required')
    packages = inventory.get('packages', [])
    needed = {(item['sourcePackage'], item['sourceVersion']) for item in packages}
    if not needed or len(packages) > 2048 or len(needed) > 512:
        raise RuntimeError('Invalid native source scope')
    package_names = {item['name'] for item in packages}
    if len(package_names) != len(packages):
        raise RuntimeError('Repeated assembled native package identity')
    libraries = inventory.get('libraries', [])
    if not libraries or len(libraries) > 2048:
        raise RuntimeError('Invalid assembled native library scope')
    if len({item['file'] for item in libraries}) != len(libraries) or (bundle / 'lib').is_symlink():
        raise RuntimeError('Repeated or linked assembled native library identity')
    def verify_libraries():
        for item in libraries:
            name = item['file']
            if not isinstance(name, str) or not name.startswith('lib/') or not NAME.fullmatch(name[4:]) or item['package'] not in package_names:
                raise RuntimeError('Invalid assembled native library identity')
            file = ordinary(bundle / 'lib', name[4:], MAX_FILE)
            with file.open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
                    raise RuntimeError('Assembled native library changed: ' + name)
    verify_libraries()
    index = read_json(index_path, MAX_INDEX)
    records = index.get('sources')
    if not isinstance(records, list) or len(records) != len(needed):
        raise RuntimeError('Source index does not match the assembled native scope')
    sources, files, total = [], {}, 0
    seen = set()
    for item in records:
        identity = (item['package'], item['version'])
        if identity not in needed or identity in seen:
            raise RuntimeError('Missing, repeated or unrelated source package identity')
        seen.add(identity)
        original = item['declaration']
        name = url_name(original['url'])
        if not name.endswith('.dsc'):
            raise RuntimeError('Expected original source declaration')
        file = ordinary(cache, name, MAX_DECLARATION)
        data = file.read_bytes()
        if len(data) != original['bytes'] or hashlib.sha256(data).hexdigest() != original['sha256']:
            raise RuntimeError('Original source declaration changed: ' + name)
        package, version, declared = declaration(data)
        if (package, version) != identity:
            raise RuntimeError('Source declaration does not match the binary source version')
        selected = {}
        entries = [{'file': name, 'bytes': len(data), 'sha256': original['sha256'], 'url': original['url']}]
        for archive in item['files']:
            archive_name = archive['file']
            if url_name(archive['url']) != archive_name or archive_name in selected:
                raise RuntimeError('Invalid or repeated original source archive')
            selected[archive_name] = (archive['bytes'], archive['sha256'])
            entries.append({key: archive[key] for key in ('file', 'bytes', 'sha256', 'url')})
        if selected != declared:
            raise RuntimeError('Source archives differ from the original declaration')
        for entry in entries:
            name = entry['file']
            if name in files and files[name] != entry:
                raise RuntimeError('Conflicting source material identities')
            ordinary(cache, name, MAX_FILE)
            if name not in files:
                total += entry['bytes']
                files[name] = entry
        sources.append({'package': package, 'version': version, 'declaration': entries[0], 'archives': sorted(entries[1:], key=lambda value: value['file'])})
    if total > MAX_TOTAL:
        raise RuntimeError('Source companion exceeds its byte limit')
    manifest = {'version': 1, 'scope': 'busyapi-copied-native-sources',
                'nativeInventorySha256': hashlib.sha256(inventory_bytes).hexdigest(),
                'libraries': [{key: item[key] for key in ('file', 'sha256', 'package')} for item in sorted(libraries, key=lambda value: value['file'])],
                'packages': [{key: item[key] for key in ('name', 'version', 'sourcePackage', 'sourceVersion')} for item in sorted(packages, key=lambda value: value['name'])],
                'sources': sorted(sources, key=lambda value: (value['package'], value['version'])),
                'upstreamSignatureVerification': 'not-performed', 'licenceReviewComplete': False}
    instructions = (
        'BusyAPI copied native-library source companion\n\n'
        'sources.json binds these original source declarations and archives to the assembled native inventory and exact copied library bytes. '
        'Only those native packages are covered, not the BusyAPI application, Flutter engine, Node, WebKit platform runtime or other separately noticed inputs. '
        'Original Debian source packaging/build instructions and patches are retained in full. For each source, use dpkg-source -x archives/NAME.dsc in a separate build directory; '
        'follow its original debian/control and debian/rules with the declared build dependencies. No build scripts are executed by this companion. '
        'The exact original archive URLs and SHA-256 identities are in sources.json. Declarations retain their original signatures; this facility verifies bytes/checksums, not those signatures.\n\n'
        'Copied libraries are unmodified shared libraries. Their corresponding installed notices and full referenced licence texts accompany the application under share/licenses/busyapi-native. '
        'This companion is source material, not a written future source offer or a legal-clearance statement. '
        'Review the applicable licence, actual selected binary/source scope and replacement/relinking conditions before distribution. '
        'Interface-compatible modified shared libraries must remain replaceable; no BusyAPI hash gate is applied to these native libraries at application runtime. '
        'Build-time identity checks distinguish the reviewed distribution from replacement versions and do not prohibit such replacement. '
        'No BusyAPI-supplied condition restricts modification or reverse engineering for debugging modifications to an applicable LGPL library.\n'
    ).encode()
    with tempfile.NamedTemporaryFile(prefix='.busyapi-native-sources-', dir=output.parent) as temporary:
        with tarfile.open(fileobj=temporary, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            def add(name, count, stream):
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = count, 0o644, 0
                archive.addfile(info, stream)
            for name, data in [('sources.json', (json.dumps(manifest, indent=2, ensure_ascii=True) + '\n').encode()), ('README.txt', instructions)]:
                add(name, len(data), io.BytesIO(data))
            for name, entry in sorted(files.items()):
                file = ordinary(cache, name, MAX_FILE)
                if file.stat().st_size != entry['bytes']:
                    raise RuntimeError('Source material size changed: ' + name)
                with file.open('rb') as stream:
                    checked = CheckedReader(stream)
                    add('archives/' + name, entry['bytes'], checked)
                    if stream.read(1) or checked.digest.hexdigest() != entry['sha256']:
                        raise RuntimeError('Source material bytes changed: ' + name)
        temporary.flush()
        os.fsync(temporary.fileno())
        if inventory_path.read_bytes() != inventory_bytes:
            raise RuntimeError('Assembled native inventory changed before publication')
        verify_libraries()
        # Atomic, no-overwrite publication of a regular file. Never replace or
        # recursively remove a caller-selected destination directory.
        os.link(temporary.name, output)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--index', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    record = assemble(args.bundle, args.cache, args.index, args.output)
    print('Verified original native source companion: ' + str(len(record['sources'])) + ' source packages; licence/linkage review remains separate.')
