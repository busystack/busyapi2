"""Verify actual Flutter/plugin notices, covered source and matching app output."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IDENTITIES = ('name', 'version', 'source', 'archiveSha256', 'pubspecSha256',
              'notices', 'sourceSha256', 'sourceFiles', 'linuxNativePlugin',
              'license', 'purpose', 'distribution', 'obligations')


def ordinary(root, relative, limit=4 * 1024 * 1024):
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or any(p in ('.', '..') for p in parts):
        raise RuntimeError('Invalid application notice/source path')
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise RuntimeError('Application notices/source must not use build-stage symlinks')
    if not path.is_file() or path.stat().st_size > limit:
        raise RuntimeError('Missing/non-ordinary or oversized application notice/source: ' + relative)
    return path


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def verify(bundle, *, require_production=True):
    bundle = Path(bundle).resolve()
    root = bundle / 'share/licenses/busyapi-application'
    inventory = json.loads(ordinary(root, 'dependencies.json').read_bytes())
    review = json.loads((ROOT / 'tools/flutter_dependencies.review.json').read_bytes())
    if (inventory.get('version') != 1 or inventory.get('scope') != 'flutter-linux-application-inputs'
            or inventory.get('sdk') != review['sdk']):
        raise RuntimeError('Unreviewed application/framework distribution identity')
    application = inventory['application']
    if application['mode'] not in ('Debug', 'Profile', 'Release'):
        raise RuntimeError('Unknown application distribution mode')
    if application['productionEntry'] is not (application['entry'] == 'lib/main.dart'):
        raise RuntimeError('Inconsistent application entry identity')
    if require_production and not application['productionEntry']:
        raise RuntimeError('A development/test entry is not a production application')
    artifact = 'data/flutter_assets/kernel_blob.bin' if application['mode'] == 'Debug' else 'lib/libapp.so'
    if digest(ordinary(bundle, artifact, 256 * 1024 * 1024)) != application['sha256']:
        raise RuntimeError('Application output does not match its notice/source receipt')
    sdk = review['sdk']
    if digest(ordinary(root, sdk['engineNotice'])) != sdk['engineNoticeSha256']:
        raise RuntimeError('Changed original engine third-party aggregate')
    approved = {entry['name']: entry for entry in review['packages']}
    records = inventory['packages']
    names = {entry['name'] for entry in records}
    if len(names) != len(records) or not names <= approved.keys():
        raise RuntimeError('Unreviewed/duplicate application dependency')
    expected_native = {name for name, record in approved.items() if record['linuxNativePlugin']}
    if {entry['name'] for entry in records if entry['linuxNativePlugin']} != expected_native:
        raise RuntimeError('Missing linked Linux plugin notice/source')
    text = ordinary(root, 'THIRD_PARTY_NOTICES.txt').read_text()
    for record in records:
        source = approved[record['name']]
        if any(record.get(key) != source.get(key) for key in IDENTITIES):
            raise RuntimeError('Changed application dependency review: ' + record['name'])
        for notice in record['notices']:
            if digest(ordinary(root, notice['file'])) != notice['sha256']:
                raise RuntimeError('Changed original application notice: ' + notice['file'])
        if any(record[key] not in text for key in ('source', 'license', 'purpose', 'obligations')):
            raise RuntimeError('Missing application redistribution attribution/terms')
        if record['license'] != 'MPL-2.0':
            continue
        available = record.get('sourceAvailability', {})
        archive = 'https://pub.dev/api/archives/' + record['name'] + '-' + record['version'] + '.tar.gz'
        if (available.get('license') != 'MPL-2.0' or available.get('originalArchive') != archive
                or available.get('archiveSha256') != record['archiveSha256']):
            raise RuntimeError('Missing MPL source availability identity')
        access = ordinary(root, 'SOURCE-AVAILABILITY.txt').read_text()
        if archive not in access or record['archiveSha256'] not in access:
            raise RuntimeError('Missing MPL source access information')
        prefix = 'sources/' + record['name'] + '-' + record['version'] + '/'
        sources = {}
        for file in available['files']:
            if not file['file'].startswith(prefix):
                raise RuntimeError('Mismatched MPL source owner')
            relative = file['file'][len(prefix):]
            if relative in sources or digest(ordinary(root, file['file'], 16 * 1024 * 1024)) != file['sha256']:
                raise RuntimeError('Missing/changed covered source or original notice')
            sources[relative] = file['sha256']
        if sources.pop('pubspec.yaml', None) != record['pubspecSha256']:
            raise RuntimeError('Missing original source declaration')
        for notice in record['notices']:
            relative = notice['file'][len(record['name']) + 1:]
            if sources.pop(relative, None) != notice['sha256']:
                raise RuntimeError('Missing source-copy original notice')
        identity = ''.join(file + '\0' + sources[file] + '\n' for file in sorted(sources))
        if len(sources) != record['sourceFiles'] or hashlib.sha256(identity.encode()).hexdigest() != record['sourceSha256']:
            raise RuntimeError('Incomplete/changed reviewed MPL source set')
    supplements = [item for item in review['supplements'] if names.intersection(item['packages'])]
    expected = [dict(item, installedNotice='supplements/' + item['name']) for item in supplements]
    if inventory.get('supplements') != expected:
        raise RuntimeError('Missing/changed application dataset/codec notice decision')
    for item in expected:
        if digest(ordinary(root, item['installedNotice'])) != item['noticeSha256']:
            raise RuntimeError('Changed dataset/codec notice')
    if inventory.get('datasets') != [item for item in review['datasets'] if item['package'] in names]:
        raise RuntimeError('Missing application dataset provenance')
    for name in ('LICENSE', 'NOTICE'):
        if digest(ordinary(root, 'BusyAPI-' + name)) != digest(ROOT / name):
            raise RuntimeError('Missing application/adaptation original notice')
    return inventory


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    value = verify(args.bundle)
    print('Verified application inputs, notices and covered-source availability: ' + str(len(value['packages'])))
