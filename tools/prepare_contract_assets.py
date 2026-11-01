#!/usr/bin/env python3
"""Build-time preparation only: no downloads, npm invocation or runtime fallback."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from prepare_policy_isolation import prepare as prepare_policy_isolation


ROOT = Path(__file__).resolve().parent.parent
RUNTIME_PURPOSES = {
    'enhanced-resolve': 'Maintained Node package/import/exports resolution over approved immutable code snapshots only',
    'graceful-fs': 'Upstream resolver default filesystem path; BusyAPI always supplies its snapshot filesystem instead',
    'tapable': 'Trusted maintained resolver hook pipeline, with no project-supplied plugins',
    'acorn': 'Source-only JavaScript syntax and literal import discovery for explicit governance code review',
    'yaml': 'Canonical YAML Document/CST parsing and source-aware edits',
    'jsonc-parser': 'Canonical located strict JSON parsing and edits',
    'ajv': 'OpenAPI structural schema checks',
    'fast-deep-equal': 'Ajv structural equality support',
    'fast-uri': 'Ajv URI handling',
    'json-schema-traverse': 'Ajv schema traversal',
    'require-from-string': 'Ajv transitive module support; project code is not loaded',
    '@hyperjump/browser': 'Schema evaluation over supplied canonical resource snapshots',
    '@hyperjump/json-schema': 'Restricted OAS 3.0 and Draft 2020-12/modern OAS dialect evaluation',
    '@hyperjump/json-pointer': 'Evaluator JSON Pointer access',
    '@hyperjump/json-schema-formats': 'Evaluator format vocabulary; assertion disabled',
    '@hyperjump/pact': 'Evaluator bounded iterator utilities',
    '@hyperjump/uri': 'Canonical graph and evaluator URI/IRI reference resolution',
    'content-type': 'Evaluator supplied-resource media-type parsing',
    'idn-hostname': 'Evaluator format vocabulary dependency',
    'just-curry-it': 'Evaluator function utility',
    'punycode': 'Evaluator format vocabulary hostname dependency',
    'uuid': 'Upstream evaluator compound-bundle dependency; not adopted as an OAS bundler',
}
LICENSE_OBLIGATIONS = {
    'Apache-2.0': 'Retain the Apache 2.0 license, original attribution and applicable NOTICE material; mark modifications if any. Patent terms apply; no trademark or endorsement grant.',
    '0BSD': 'Retain the original notice and disclaimer as supplied; permission includes use, modification and distribution for any purpose without fee.',
    'BSD-2-Clause': 'Retain copyright, conditions and disclaimer in source and binary redistribution materials.',
    'MIT': 'Retain the original copyright and permission notice with copies or substantial portions.',
    'ISC': 'Retain the original copyright and permission notice in copies.',
    'BSD-3-Clause': 'Retain copyright, license conditions and disclaimer; do not use contributor names for endorsement without permission.',
}
SUPPLEMENTAL_LICENSES = {
    ('@stoplight/spectral-runtime', '1.1.6'): ('spectral-runtime-1.1.6-LICENSE',
        'https://github.com/stoplightio/spectral/blob/a06d7b8f878d578bb37189ba76b1d1e136608e4d/LICENSE'),
    ('@stoplight/json-schema-merge-allof', '0.7.8'): ('json-schema-merge-allof-0.7.8-LICENSE',
        'https://github.com/stoplightio/json-schema-merge-allof/tree/v0.7.8#license'),
    ('abstract-logging', '2.0.1'): ('abstract-logging-2.0.1-LICENSE',
        'https://github.com/jsumners/abstract-logging/blob/v2.0.1/Readme.md#license'),
    ('esprima', '4.0.1'): ('esprima-4.0.1-LICENSE',
        'https://github.com/jquery/esprima/blob/4.0.1/LICENSE.BSD'),
    ('fnv-plus', '1.3.1'): ('fnv-plus-1.3.1-LICENSE',
        'https://github.com/tjwebb/fnv-plus/tree/v1.3.1#license'),
    ('ms', '2.1.3'): ('ms-2.1.3-LICENSE',
        'https://github.com/vercel/ms/blob/2.1.3/license.md'),
    ('parse-multipart-data', '1.5.0'): ('parse-multipart-data-1.5.0-LICENSE',
        'https://github.com/nachomazzara/parse-multipart-data/tree/v1.5.0#license'),
    ('@faker-js/faker', '5.5.3'): ('faker-5.5.3-LICENSE',
        'https://github.com/Marak/Faker.js/tree/v5.5.3#license'),
    ('pretty-data', '0.40.0'): ('pretty-data-0.40.0-LICENSE',
        'https://github.com/vkiryukhin/pretty-data/blob/0.40.0/README.md#license'),
    ('proxy-agent-negotiate', '1.1.0'): ('proxy-agent-negotiate-1.1.0-LICENSE',
        'https://github.com/TooTallNate/proxy-agents/tree/proxy-agent-negotiate%401.1.0/packages/negotiate'),
    ('seedrandom', '3.0.5'): ('seedrandom-3.0.5-LICENSE',
        'https://github.com/davidbau/seedrandom/blob/3.0.5/README.md#license-mit'),
    ('tr46', '0.0.3'): ('tr46-0.0.3-LICENSE',
        'https://github.com/jsdom/tr46/commit/3a6f29721e7063b9ffd421e461a54beae6170001'),
    ('uri-template-lite', '22.9.0'): ('uri-template-lite-22.9.0-LICENSE',
        'https://github.com/litejs/uri-template-lite/tree/v22.9.0#license'),
}
SUPPLEMENTAL_LICENSE_IDS = {
    ('compute-gcd', '1.2.1'): 'MIT',
    ('compute-lcm', '1.1.2'): 'MIT',
    ('validate.io-function', '1.0.2'): 'MIT',
    ('validate.io-integer', '1.0.5'): 'MIT',
    ('validate.io-integer-array', '1.0.0'): 'MIT',
    ('validate.io-number', '1.0.3'): 'MIT',
}


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def copy_atomic(source, target, mode=0o644):
    if target.is_file() and digest(source) == digest(target):
        target.chmod(mode)
        return
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as file:
        temporary = Path(file.name)
    try:
        shutil.copyfile(source, temporary)
        temporary.chmod(mode)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def prepare(output, node=None):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('The pinned contract runtime targets Linux amd64')
    engine = ROOT / 'tools/contract_engine'
    lock = json.loads((engine / 'runtime.lock.json').read_text())
    output.mkdir(parents=True, exist_ok=True)
    runtime = output / 'node'
    # PATH discovery is exclusively a build input. Desktop/CLI execution always
    # uses the installed bundle, including when the developer has no Node PATH.
    candidate = node or os.environ.get('BUSYAPI_NODE')
    if not candidate and runtime.is_file():
        candidate = runtime
    if not candidate:
        candidate = shutil.which('node')
    if not candidate:
        raise RuntimeError('Pinned Node build input is missing. Run '
                           'BUSYAPI_NODE=/path/to/node python3 tools/prepare_contract_assets.py '
                           'after tools/build_engine.sh; no runtime is downloaded.')
    candidate = Path(candidate).resolve()
    if not candidate.is_file() or digest(candidate) != lock['binarySha256']:
        raise RuntimeError(f'Node {lock["node"]} Linux amd64 build input '
                           f'checksum mismatch: {candidate}')
    copy_atomic(candidate, runtime, 0o755)

    inputs = [Path(__file__).resolve(), engine / 'package.json',
              engine / 'package-lock.json', engine / 'runtime.lock.json',
              engine / 'dependencies.review.json']
    # Additional attribution files are production notice inputs too. A changed
    # AUTHORS/COPYRIGHT supplement must invalidate an otherwise valid stage.
    inputs += sorted(path for path in (engine / 'licenses').iterdir()
                     if path.is_file())
    inputs += sorted((engine / 'src').rglob('*.ts'))
    inputs += [ROOT / 'tools/prepare_policy_isolation.py']
    inputs += sorted((engine / 'native').glob('*'))
    inputs += sorted((engine / 'schemas').glob('*.json'))
    identity = hashlib.sha256()
    for path in inputs:
        identity.update(str(path.relative_to(ROOT)).encode())
        identity.update(path.read_bytes())
    signature = identity.hexdigest()
    review = json.loads((engine / 'dependencies.review.json').read_text())
    if review.get('version') != 1:
        raise RuntimeError('Unsupported production dependency review version')
    reviewed = review['packages']
    helper = output / 'engine.cjs'
    policy_helper = output / 'policy-worker.cjs'
    mock_helper = output / 'mock-server.cjs'
    receipt = output / 'build.json'
    try:
        previous = json.loads(receipt.read_text())
    except (OSError, ValueError):
        previous = {}
    if (previous.get('inputs') != signature or not isinstance(previous.get('bundledPackageLocations'), list) or not helper.is_file()
            or previous.get('helperSha256') != digest(helper)
            or not policy_helper.is_file() or policy_helper.is_symlink()
            or previous.get('policyHelperSha256') != digest(policy_helper)
            or not mock_helper.is_file() or mock_helper.is_symlink()
            or previous.get('mockHelperSha256') != digest(mock_helper)):
        packages = json.loads((engine / 'package.json').read_text())
        package_lock = json.loads((engine / 'package-lock.json').read_text())['packages']
        for name, version in {**packages['dependencies'],
                              'esbuild': packages['devDependencies']['esbuild'],
                              '@esbuild/linux-x64': packages['devDependencies']['esbuild']}.items():
            installed = engine / 'node_modules' / name / 'package.json'
            if (not installed.is_file()
                    or json.loads(installed.read_text())['version'] != version
                    or package_lock['node_modules/' + name]['version'] != version):
                raise RuntimeError('Locked contract build dependencies are missing '
                                   'or mismatched. Run tools/build_engine.sh explicitly.')
        compiler = engine / 'node_modules/@esbuild/linux-x64/bin/esbuild'
        with tempfile.TemporaryDirectory(dir=output) as staging:
            compiled = Path(staging) / 'engine.cjs'
            metafile = Path(staging) / 'engine-inputs.json'
            bundled = set()
            bundled_locations = set()
            for source, target in [('server.ts', 'engine.cjs'),
                                   ('policy_worker.ts', 'policy-worker.cjs'),
                                   ('mock_server.ts', 'mock-server.cjs')]:
                compiled = Path(staging) / target
                extra = (['--alias:@jsdevtools/ono=' + str(engine / 'node_modules/@jsdevtools/ono/cjs/index.js')]
                         if source == 'mock_server.ts' else [])
                subprocess.run([str(compiler), str(engine / 'src' / source),
                                '--bundle', '--platform=node', '--format=cjs', '--main-fields=module,main',
                                '--outfile=' + str(compiled), '--metafile=' + str(metafile), *extra], check=True, cwd=ROOT)
                for filename in json.loads(metafile.read_text())['inputs']:
                    if 'node_modules/' not in filename:
                        continue
                    package = filename.rsplit('node_modules/', 1)[-1].split('/')
                    name = '/'.join(package[:2]) if package[0].startswith('@') else package[0]
                    bundled.add(name)
                    location = filename.split('tools/contract_engine/', 1)[-1].rsplit('node_modules/', 1)[0] + 'node_modules/' + name
                    bundled_locations.add(location)
            for location in bundled_locations:
                if location not in reviewed or package_lock[location].get('dev'):
                    raise RuntimeError('Unreviewed or development package entered the production helper: ' + location)
            if '@scarf/scarf' in bundled:
                raise RuntimeError('Installation analytics must not enter the production helper')
            copy_atomic(Path(staging) / 'engine.cjs', helper)
            copy_atomic(Path(staging) / 'policy-worker.cjs', policy_helper)
            copy_atomic(Path(staging) / 'mock-server.cjs', mock_helper)
            record = Path(staging) / 'build.json'
            record.write_text(json.dumps({'version': 1, 'inputs': signature,
                                          'node': lock['node'],
                                          'bundledPackages': sorted(bundled),
                                          'bundledPackageLocations': sorted(bundled_locations),
                                          'runtimeEntrypoints': ['engine.cjs', 'policy-worker.cjs', 'mock-server.cjs'],
                                          'policyHelperSha256': digest(policy_helper),
                                          'mockHelperSha256': digest(mock_helper),
                                          'helperSha256': digest(helper)}) + '\n')
            copy_atomic(record, receipt)
    prepare_policy_isolation(output)
    schemas = output / 'schemas'
    schemas.mkdir(exist_ok=True)
    for source in (engine / 'schemas').glob('*.json'):
        copy_atomic(source, schemas / source.name)
    licenses = output / 'licenses'
    licenses.mkdir(exist_ok=True)
    if digest(engine / 'node_modules/tr46/lib/mappingTable.json') != 'b6b39724dca9011113a08d9d6910204062b58169e98952acdfbd19bf2c31bbff':
        raise RuntimeError('The reviewed Unicode 8.0.0 transitive mapping data changed')
    copy_atomic(engine / 'licenses/UNICODE-IDNA-LICENSE', licenses / 'UNICODE-IDNA-LICENSE')
    for source in [ROOT / 'LICENSE', ROOT / 'NOTICE', engine / 'NODE-LICENSE',
                   engine / 'schemas/JSON-SCHEMA-LICENSE',
                   engine / 'licenses/LIBSECCOMP-LGPL-2.1',
                   engine / 'licenses/LIBSECCOMP-COPYRIGHT']:
        copy_atomic(source, licenses / source.name)
    # Bundle every production dependency's original notice, including the
    # evaluator's transitive packages. Never copy a dev tree into the runtime,
    # guess a license from npm metadata, or omit a missing notice silently.
    records = []
    bundled = set(json.loads(receipt.read_text())['bundledPackageLocations'])
    lock_packages = json.loads((engine / 'package-lock.json').read_text())['packages']
    for location, metadata in sorted(lock_packages.items()):
        if not location or metadata.get('dev'):
            continue
        package = location.rsplit('node_modules/', 1)[-1]
        installed = engine / location
        declaration = json.loads((installed / 'package.json').read_text())
        if declaration['name'] != package or declaration['version'] != metadata['version']:
            raise RuntimeError('Installed runtime dependency differs from the lock: ' + package)
        names = ['LICENSE', 'LICENCE', 'LICENSE.md', 'LICENSE.txt', 'LICENSE-MIT.txt', 'license', 'license.txt']
        source = next((installed / name for name in names if (installed / name).is_file()), None)
        supplemental = SUPPLEMENTAL_LICENSES.get((package, metadata['version']))
        if source is None and supplemental is not None:
            source = engine / 'licenses' / supplemental[0]
        if source is None:
            raise RuntimeError('Runtime dependency license is missing: ' + package)
        declared_license = declaration.get('license')
        license_id = SUPPLEMENTAL_LICENSE_IDS.get(
            (package, metadata['version']), declared_license)
        record = reviewed.get(location, {})
        if (declared_license != metadata.get('license') or license_id not in LICENSE_OBLIGATIONS
                or record.get('license') != license_id or record.get('version') != metadata['version']
                or record.get('source') != metadata['resolved'] or record.get('integrity') != metadata['integrity']
                or record.get('licenseSha256') != digest(source) or not record.get('purpose')):
            raise RuntimeError('Runtime dependency needs an explicit license/purpose review: ' + package)
        filename = ((package if package in ['yaml', 'ajv', 'jsonc-parser'] and location == 'node_modules/' + package
                     else package.replace('/', '-') + '-' + metadata['version']) + '-LICENSE')
        copy_atomic(source, licenses / filename)
        notices = [filename]
        for name in ['NOTICE', 'NOTICE.txt', 'NOTICE.md', 'COPYRIGHT']:
            extra = installed / name
            if extra.is_file():
                target = filename.removesuffix('-LICENSE') + '-' + name
                copy_atomic(extra, licenses / target)
                notices.append(target)
        additional_notices = record.get('additionalNotices', [])
        for extra in additional_notices:
            name = extra['file']
            if (Path(name).name != name or not extra.get('source', '').startswith('https://') or
                    digest(engine / 'licenses' / name) != extra['sha256']):
                raise RuntimeError('Changed reviewed additional attribution: ' + package)
            copy_atomic(engine / 'licenses' / name, licenses / name)
            notices.append(name)
        records.append({'name': package, 'version': metadata['version'],
                        'location': location,
                        'license': license_id, 'file': filename,
                        'source': metadata['resolved'], 'integrity': metadata['integrity'],
                        'upstream': declaration.get('repository'),
                        'purpose': RUNTIME_PURPOSES.get(package, record['purpose']) if location == 'node_modules/' + package else record['purpose'],
                        **({'noticeSource': supplemental[1]} if supplemental else {}),
                        'distribution': 'bundled-engine-code' if location in bundled else 'license-only; upstream dependency omitted by bundling',
                        'requiredNotices': notices,
                        **({'additionalNotices': additional_notices} if additional_notices else {}),
                        'obligations': LICENSE_OBLIGATIONS[license_id],
                        'sha256': digest(source)})
    with tempfile.TemporaryDirectory(prefix='busyapi-license-index-') as staging:
        index = Path(staging) / 'dependencies.json'
        native_lock = json.loads((engine / 'native/build-inputs.lock.json').read_text())
        index.write_text(json.dumps({'version': 1, 'packages': records,
            'nativeDependencies': [{
                'name': 'libseccomp', **native_lock['libseccomp'],
                'purpose': 'Restricted governance startup gate and all-thread syscall profile',
                'distribution': 'dynamic dependency; library is not copied by contract preparation',
                'noticeDirectory': 'licenses',
                'requiredNotices': ['LIBSECCOMP-LGPL-2.1', 'LIBSECCOMP-COPYRIGHT'],
                'obligations': 'Retain copyright/license. If redistributed, provide the actual corresponding source and satisfy applicable replacement/relinking conditions and terms permitting required modification/debugging. The full assembled native artifact needs a separate actual-component audit.',
            }], 'datasets': [{
            'name': 'JSON Schema meta-schemas', 'version': '2020-12',
            'source': 'https://github.com/json-schema-org/json-schema-spec/tree/add836e705c9a07434c467b6b90946ba45258a73',
            'license': 'BSD-3-Clause (upstream BSD alternative)',
            'purpose': 'Bundled dialect and vocabulary meta-schema data',
            'distribution': 'embedded through pinned validator packages',
            'requiredNotices': ['JSON-SCHEMA-LICENSE'],
            'obligations': LICENSE_OBLIGATIONS['BSD-3-Clause'],
        }, {
            'name': 'Unicode IDNA mapping data', 'version': '8.0.0',
            'source': 'https://www.unicode.org/Public/idna/8.0.0/IdnaMappingTable.txt',
            'sourceSha256': '5e9f5929130b713e698162ac5b60a99ccfb831606686b1c50777cd920b55dee2',
            'derivedSha256': 'b6b39724dca9011113a08d9d6910204062b58169e98952acdfbd19bf2c31bbff',
            'license': 'Unicode-DFS-2015',
            'licenseSource': 'https://github.com/unicode-org/icu/blob/release-56-1/icu4c/license.html',
            'purpose': 'Upstream URL-library IDNA mapping table; not a resource-acquisition capability',
            'distribution': 'embedded through tr46 0.0.3' if 'node_modules/tr46' in bundled else 'license-only; data omitted by bundling',
            'noticeDirectory': 'licenses',
            'requiredNotices': ['UNICODE-IDNA-LICENSE'],
            'obligations': 'Retain copyright and permission notice with data/software and associated documentation, and identify the upstream text-to-JSON modification. No endorsement grant.',
        }]},
                                    ensure_ascii=False, sort_keys=True, indent=2) + '\n')
        copy_atomic(index, licenses / index.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/contract-runtime')
    parser.add_argument('--node', help='Explicit, checksum-verified build input')
    args = parser.parse_args()
    try:
        prepare(args.output.resolve(), args.node)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'BusyAPI contract assets: {error}\n')


if __name__ == '__main__':
    main()
