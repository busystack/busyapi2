"""Check a packaged migration fixture before requesting desktop input."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import re


MIGRATION_PRODUCER = '21'


def verify_migration_producer(metadata):
    if (not isinstance(metadata, dict)
            or metadata.get('producer') != 'busyapi-native-migration'
            or metadata.get('producerVersion') != MIGRATION_PRODUCER):
        raise RuntimeError('Native migration fixture and packaged migration producer differ')


def preflight_migration(binary, source, target, destination, originals):
    """Preview the exact saved fixture; never apply or publish its conversion."""
    binary, source, destination = Path(binary), Path(source), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise RuntimeError('Choose an absent private preflight destination')
    before = {str(path): hashlib.sha256(raw).hexdigest() for path, raw in originals.items()}
    if any(Path(path).read_bytes() != raw for path, raw in originals.items()):
        raise RuntimeError('Native migration fixture changed before preflight')
    result = subprocess.run(
        [str(binary), 'migrate', str(source), '--target', target,
         '--output', str(destination), '--json'],
        env={'PATH': '', 'LANG': 'C.UTF-8'},
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError('Packaged migration preflight failed: ' + result.stdout + result.stderr)
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError('Packaged migration returned malformed preflight JSON') from error
    verify_migration_producer(report)
    selected = report.get('target')
    identity = report.get('reviewIdentity')
    if (report.get('status') != 'faithfully-convertible'
            or report.get('complete') is not True
            or report.get('published') is not False
            or not isinstance(selected, dict) or selected.get('declaredVersion') != target
            or not isinstance(identity, str) or not re.fullmatch('[0-9a-f]{64}', identity)):
        raise RuntimeError('Packaged migration did not return a complete unpublished fixture review')
    if destination.exists() or destination.is_symlink():
        raise RuntimeError('Migration preflight unexpectedly published a destination')
    if any(Path(path).read_bytes() != raw for path, raw in originals.items()):
        raise RuntimeError('Migration preflight changed its original fixture')
    return {'producerVersion': report['producerVersion'], 'target': target,
            'reviewIdentity': report['reviewIdentity'], 'sourceIdentities': before,
            'published': False, 'nativeAcceptance': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--version', choices=['2.0', '3.0.4', '3.1.2', '3.2.1'], default='3.0.4')
    parser.add_argument('--target', choices=['2.0', '3.0.4', '3.1.2', '3.2.1'], default='2.0')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='busyapi-migration-preflight-') as directory:
        path = Path(directory)
        source = path / 'api.json'
        value = {'swagger' if args.version == '2.0' else 'openapi': args.version,
                 'info': {'title': 'Owned preflight 雪', 'version': 'api-version'}, 'paths': {}}
        raw = (json.dumps(value, ensure_ascii=False) + '\n').encode()
        source.write_bytes(raw)
        report = preflight_migration(args.bundle.resolve() / 'busyapi', source,
                                     args.target, path / 'preview', {source: raw})
        print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
