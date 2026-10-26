"""Qualify explicit production migration with owned synthetic resources."""
import hashlib
import json
from pathlib import Path
import re
import shutil

from test_openapi_application import (
    activate_control, complete_problems, contains, design_values, field_matches,
    keys, mode, text_keys, wait_tree,
)

TARGETS = ('2.0', '3.0.4', '3.1.2', '3.2.1')


def verify_migration(destination, baseline, file, fragment, version, target):
    metadata = json.loads((destination / 'migration.json').read_text())
    receipt = json.loads((destination / 'busyapi-output.json').read_text())
    manifest = json.loads((destination / 'busyapi.yaml').read_text())
    assert receipt['owner'] == 'io.busystack.busyapi'
    assert receipt['metadata'] == metadata
    assert metadata['operation'] == 'migration'
    assert metadata['producer'] == 'busyapi-native-migration' and metadata['producerVersion'] == '4'
    assert metadata['target']['declaredVersion'] == target
    assert metadata['status'] == 'faithfully-convertible'
    assert metadata['input'] == 'working-copy' and metadata['unsaved'] is True
    assert metadata['decisions'] == {}
    assert metadata['invariants']['requests'] == 'effective-url-serialization-security-and-media'
    working = baseline[str(file)].replace(('edited ' + version).encode(), ('migrated ' + version).encode(), 1)
    sources = {file.as_uri(): working, fragment.as_uri(): baseline[str(fragment)]}
    assert {source['resource'] for source in metadata['sources']} == set(sources)
    for source in metadata['sources']:
        assert source['identity'] == hashlib.sha256(sources[source['resource']]).hexdigest()
    for name, digest in receipt['files'].items():
        relative = Path(name)
        assert not relative.is_absolute() and '..' not in relative.parts
        resource = destination / relative
        assert resource.is_file() and not resource.is_symlink()
        assert all(not parent.is_symlink() for parent in resource.parents if parent != destination.parent)
        assert hashlib.sha256(resource.read_bytes()).hexdigest() == digest
    assert manifest['version'] == 1 and manifest['roots'][0]['path'] == metadata['entry']
    assert set(manifest['resourceMappings'].values()) <= set(receipt['files'])
    resources = sorted(path for path in destination.rglob('*') if path.is_file() and path.suffix in ['.yaml', '.json']
                       and path.name not in ['busyapi.yaml', 'migration.json', 'busyapi-output.json'])
    root = destination / metadata['entry']
    assert len(resources) == 2 and root in resources
    shared = next(path for path in resources if path != root)
    assert shared.read_bytes() == baseline[str(fragment)]
    raw = root.read_bytes()
    assert raw.startswith(b'\xef\xbb\xbf') == baseline[str(file)].startswith(b'\xef\xbb\xbf')
    declaration = 'swagger' if target == '2.0' else 'openapi'
    if root.suffix == '.json':
        data = json.loads(raw.decode('utf-8-sig'))
        assert data[declaration] == target and data['info']['title'] == 'migrated ' + version
        assert data['info']['version'] == 'api-version2'
    else:
        assert re.search(r'(?m)^' + declaration + r': [\"\x27]?' + re.escape(target) + r'[\"\x27]?\r?$', raw.decode('utf-8-sig'))
        assert ('migrated ' + version).encode() in raw and b'api-version2' in raw
        assert b'# Retain source organization\r\n' in raw
    return {'entry': metadata['entry'], 'sourceIdentities': True, 'ownedFileHashes': True,
            'exactSharedSource': True, 'declaredTarget': target, 'files': len(receipt['files'])}


def prepare(native, process, destination, target):
    mode(native, process.pid, 'Migrate specification')
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Target specification') and contains(nodes, 'Review migration'),
        'Native migration dialog did not appear')
    if target != '3.2.1':
        activate_control(native, process.pid, 'Target specification')
        wait_tree(native, process.pid, lambda nodes: all(contains(nodes, value) for value in TARGETS),
                  'Native migration target choices did not appear')
        keys(native, ['Home'] + ['Down'] * TARGETS.index(target) + ['Return'])
    activate_control(native, process.pid, 'Review migration')
    wait_tree(native, process.pid,
        lambda nodes: field_matches(nodes, 'Output folder', editable=True, focused=True),
        'Migration destination did not own input')
    keys(native, ['Control_L+a'] + text_keys(str(destination)) + ['Return'])
    nodes = wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Convertible with the reviewed mappings') or contains(nodes, 'Migration is blocked'),
        'Native migration preparation did not finish')
    assert contains(nodes, 'Convertible with the reviewed mappings'), nodes
    assert not destination.exists(), 'Migration review published before acceptance'


def migrate(native, process, file, fragment, baseline, version, target, evidence, case):
    destination = file.parent.parent / 'migrated'
    native.perform({'kind': 'click', 'scale': 1, 'point': [700, 250], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: field_matches(nodes, 'Title', focused=True),
              'Title did not own migration input')
    keys(native, ['Control_L+a'] + text_keys('migrated ' + version) + ['Tab'])
    wait_tree(native, process.pid, lambda nodes: field_matches(nodes, 'Title', value='migrated ' + version),
              'Unsaved migration title was not retained')
    for attempt in ['cancel', 'race', 'publish']:
        prepare(native, process, destination, target)
        assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
        if attempt == 'race':
            destination.mkdir()
            sentinel = destination / 'other-writer.txt'
            sentinel.write_bytes(b'Preserve migration destination race\r\n')
        if attempt != 'cancel':
            activate_control(native, process.pid, 'Create migrated copy')
            if attempt == 'race':
                wait_tree(native, process.pid,
                    lambda nodes: contains(nodes, 'output.ownership: The directory is not an unchanged BusyAPI-owned output'),
                    'Foreign migration destination did not retain its ownership refusal')
                assert sorted(path.name for path in destination.iterdir()) == [sentinel.name]
                assert sentinel.read_bytes() == b'Preserve migration destination race\r\n'
                sentinel.unlink()
                destination.rmdir()
            else:
                wait_tree(native, process.pid,
                    lambda nodes: contains(nodes, 'The migrated copy was created. Original documents are preserved.'),
                    'Native migration publication did not complete')
        activate_control(native, process.pid, 'Close')
        wait_tree(native, process.pid, lambda nodes: not contains(nodes, 'Review migration'),
                  'Native migration review did not close')
        assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
        if attempt != 'publish':
            assert not destination.exists()
    verification = verify_migration(destination, baseline, file, fragment, version, target)
    preserved = evidence / (case + '-migration')
    shutil.copytree(destination, preserved, symlinks=True)
    mode(native, process.pid, 'source')
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and 'migrated ' + version in (node['text'] or '') for node in nodes),
        'Original working source did not remain available after migration')
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: any(node['focused'] and node['editable'] for node in nodes),
              'Original source did not own history input')
    keys(native, ['Control_L+z'])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and 'edited ' + version in (node['text'] or '') for node in nodes),
        'Migration altered the original one-operation history')
    keys(native, ['Control_L+s'])
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    mode(native, process.pid, 'design')
    wait_tree(native, process.pid,
        lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes),
        'Original native contract was not retained after migration')
    return {**verification, 'reviewCancelled': True, 'destinationRaceRefused': True,
            'originalHistoryRetained': True, 'artifact': str(preserved), 'outputDirectory': str(destination)}


def inspect_copy(native, process, version, target):
    wait_tree(native, process.pid,
        lambda nodes: design_values(nodes, 'migrated ' + version, 'api-version2') and complete_problems(nodes),
        'Published target did not reopen in native Design')
    mode(native, process.pid, 'reference')
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'migrated ' + version) and contains(nodes, 'api-version2') and complete_problems(nodes),
        'Published target did not retain its native Reference projection')
    mode(native, process.pid, 'source')
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and target in (node['text'] or '') and 'migrated ' + version in (node['text'] or '') for node in nodes),
        'Published target did not retain its declared version in Source')
