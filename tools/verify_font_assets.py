"""Read-only verification of the fonts/notices actually assembled for Linux."""
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def ordinary(root, relative):
    name = Path(relative)
    if name.is_absolute() or not name.parts or any(part in ('.', '..') for part in name.parts):
        raise RuntimeError('Invalid font distribution path')
    path = root
    for part in name.parts:
        path = path / part
        if path.is_symlink():
            raise RuntimeError('Font assets/notices must not use build-stage symlinks')
    if not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise RuntimeError('Missing/non-ordinary or oversized font asset/notice: ' + relative)
    return path.read_bytes()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify(bundle):
    bundle = Path(bundle).resolve()
    notices = bundle / 'share/licenses/busyapi-fonts'
    assets = bundle / 'data/flutter_assets'
    review = json.loads((ROOT / 'tools/flutter_fonts.review.json').read_text())
    inventory = json.loads(ordinary(notices, 'dependencies.json'))
    if inventory.get('version') != 1 or inventory.get('scope') != 'application-font-assets' or inventory.get('frameworkRevision') != review['frameworkRevision']:
        raise RuntimeError('Missing/mismatched font distribution inventory')
    approved = {group['name']: group for group in review['groups']}
    groups = inventory['groups']
    if len(groups) != len(approved) or {group['name'] for group in groups} != set(approved):
        raise RuntimeError('Unreviewed font distribution closure')
    emitted = {}
    for family in json.loads(ordinary(assets, 'FontManifest.json')):
        for font in family['fonts']:
            if font['asset'] in emitted:
                raise RuntimeError('Duplicate font distribution identity')
            emitted[font['asset']] = family['family']
    expected = set()
    attribution = ordinary(notices, 'THIRD_PARTY_NOTICES.txt').decode('utf-8')
    for group in groups:
        original = approved[group['name']]
        for key in original.keys() - {'fonts', 'notices'}:
            if group.get(key) != original[key]:
                raise RuntimeError('Unreviewed font distribution record: ' + group['name'])
        for required in ('copyright', 'license', 'source', 'obligations'):
            if original[required] not in attribution:
                raise RuntimeError('Missing font attribution or redistribution terms')
        actual_notices = group['notices']
        expected_notices = [dict(file=group['package']+'/'+notice['file'], sha256=notice['sha256']) for notice in original['notices']]
        if actual_notices != expected_notices:
            raise RuntimeError('Unreviewed/missing original font notice')
        for notice in actual_notices:
            if digest(ordinary(notices, notice['file'])) != notice['sha256']:
                raise RuntimeError('Changed original font notice: ' + notice['file'])
        fonts = group['fonts']
        if len(fonts) != len(original['fonts']):
            raise RuntimeError('Missing font distribution record')
        for font, source in zip(fonts, original['fonts']):
            asset = source['asset']
            family = ('packages/yaru/' if group['package'] == 'yaru' else '') + group['name']
            if asset in expected or emitted.get(asset) != family or font['asset'] != asset or font.get('sourceFile') != source['file'] or font['sourceSha256'] != source['sha256']:
                raise RuntimeError('Unreviewed font identity or source')
            expected.add(asset)
            data = ordinary(assets, asset)
            if len(data) < 12:
                raise RuntimeError('Empty or truncated installed font: ' + asset)
            actual = digest(data)
            modified = actual != source['sha256']
            if font['sha256'] != actual or font['modified'] is not modified or modified or original['allowBuildModification'] is not False:
                raise RuntimeError('Changed/unreviewed installed font: ' + asset)
            description = 'Original font bytes unchanged.'
            if font.get('modifications') != description or description not in attribution:
                raise RuntimeError('Missing font modification notice')
    if set(emitted) != expected:
        raise RuntimeError('An unreviewed font entered the distribution')
    return inventory


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    value = verify(args.bundle)
    print('Verified application font assets and original notices: '+str(sum(len(group['fonts']) for group in value['groups'])))
