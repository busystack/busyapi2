"""Real locked helper/runtime staging and all-mode CMake install regressions."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
PREPARE = ROOT / 'tools/prepare_contract_assets.py'


class ContractAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='busyapi-build-assets-')
        cls.root = Path(cls.temporary.name)
        cls.stage = cls.root / 'stage'
        cls.node = os.environ.get('BUSYAPI_NODE') or shutil.which('node')
        if not cls.node:
            raise RuntimeError('Provision the pinned build-time Node before these tests')
        subprocess.run([sys.executable, str(PREPARE), '--output', str(cls.stage),
                        '--node', cls.node], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_prepare(self, output, *extra, **kwargs):
        return subprocess.run([sys.executable, str(PREPARE), '--output', str(output),
                               *extra], capture_output=True, text=True, **kwargs)

    def test_prepared_build_has_no_global_node_requirement(self):
        environment = dict(os.environ, PATH='/nonexistent')
        environment.pop('BUSYAPI_NODE', None)
        before = (self.stage / 'engine.cjs').stat().st_mtime_ns
        result = self.run_prepare(self.stage, env=environment, cwd='/tmp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.stage / 'engine.cjs').stat().st_mtime_ns, before)
        lock = json.loads((ROOT / 'tools/contract_engine/runtime.lock.json').read_text())
        self.assertEqual(hashlib.sha256((self.stage / 'node').read_bytes()).hexdigest(),
                         lock['binarySha256'])

    def test_missing_build_runtime_fails_explicitly_without_downloading(self):
        environment = dict(os.environ, PATH='/nonexistent')
        environment.pop('BUSYAPI_NODE', None)
        result = self.run_prepare(self.root / 'missing', env=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Pinned Node build input is missing', result.stderr)
        self.assertFalse((self.root / 'missing/node').exists())

    def test_runtime_dependency_notices_match_every_production_lock_identity(self):
        index = json.loads((self.stage / 'licenses/dependencies.json').read_text())
        locked = json.loads((ROOT / 'tools/contract_engine/package-lock.json').read_text())['packages']
        expected = {(key.rsplit('node_modules/', 1)[-1], value['version'])
                    for key, value in locked.items() if key and not value.get('dev')}
        self.assertEqual(index['version'], 1)
        self.assertEqual({(p['name'], p['version']) for p in index['packages']}, expected)
        for package in index['packages']:
            notice = self.stage / 'licenses' / package['file']
            self.assertTrue(notice.is_file(), package['name'])
            self.assertEqual(hashlib.sha256(notice.read_bytes()).hexdigest(), package['sha256'])
            self.assertTrue(package['purpose'])
            self.assertTrue(package['source'].startswith('https://registry.npmjs.org/'))
            self.assertTrue(package['integrity'].startswith('sha512-'))
            self.assertTrue(package['obligations'])
            for filename in package['requiredNotices']:
                self.assertTrue((self.stage / 'licenses' / filename).is_file())
        receipt = json.loads((self.stage / 'build.json').read_text())
        distributed = {p['name'] for p in index['packages'] if p['distribution'] == 'bundled-engine-code'}
        self.assertEqual(distributed, set(receipt['bundledPackages']))
        self.assertNotIn('@apidevtools/json-schema-ref-parser', distributed)
        self.assertNotIn('playwright', distributed)
        self.assertNotIn('@scarf/scarf', distributed)
        self.assertNotIn('@asyncapi/specs', distributed)
        acorn = next(package for package in index['packages'] if package['name'] == 'acorn')
        self.assertEqual(acorn['version'], '8.19.0')
        self.assertEqual(acorn['license'], 'MIT')
        self.assertEqual(acorn['distribution'], 'bundled-engine-code')
        for name, version, license_id in [('enhanced-resolve','5.26.0','MIT'),
                                          ('tapable','2.3.3','MIT'),
                                          ('graceful-fs','4.2.11','ISC')]:
            package = next(value for value in index['packages'] if value['name'] == name)
            self.assertEqual((package['version'], package['license']), (version, license_id))
        self.assertEqual(receipt['runtimeEntrypoints'],
                         ['engine.cjs', 'policy-worker.cjs', 'mock-server.cjs'])
        self.assertEqual(hashlib.sha256((self.stage / 'policy-worker.cjs').read_bytes()).hexdigest(), receipt['policyHelperSha256'])
        policy_receipt = json.loads((self.stage / 'policy-build.json').read_text())
        for name, identity in policy_receipt['files'].items():
            self.assertFalse((self.stage / name).is_symlink())
            self.assertEqual(hashlib.sha256((self.stage / name).read_bytes()).hexdigest(), identity)
        for name in ['LIBSECCOMP-LGPL-2.1', 'LIBSECCOMP-COPYRIGHT']:
            self.assertEqual((self.stage / 'licenses' / name).read_bytes(),
                             (ROOT / 'tools/contract_engine/licenses' / name).read_bytes())
        attribution = acorn['additionalNotices'][0]
        self.assertEqual(attribution['source'], 'https://raw.githubusercontent.com/acornjs/acorn/8.19.0/AUTHORS')
        self.assertEqual((self.stage / 'licenses' / attribution['file']).read_bytes(),
                         (ROOT / 'tools/contract_engine/licenses' / attribution['file']).read_bytes())
        self.assertEqual(hashlib.sha256((self.stage / 'licenses' / attribution['file']).read_bytes()).hexdigest(),
                         attribution['sha256'])
        self.assertEqual(index['datasets'][0]['version'], '2020-12')
        for dataset in index['datasets']:
            for filename in dataset['requiredNotices']:
                self.assertEqual((self.stage / 'licenses' / filename).read_bytes(),
                                 (ROOT / 'tools/contract_engine' / dataset.get('noticeDirectory', 'schemas') / filename).read_bytes())

    def test_mismatched_runtime_is_rejected_before_publication(self):
        candidate = self.root / 'incorrect-node'
        candidate.write_text('wrong runtime')
        result = self.run_prepare(self.root / 'wrong', '--node', str(candidate))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse((self.root / 'wrong/node').exists())

    def test_corrupt_or_missing_helper_is_rebuilt_from_locked_sources(self):
        for name in ['engine.cjs','policy-worker.cjs','mock-server.cjs',
                     'policy-isolation.node','policy-launcher']:
            helper = self.stage / name
            original = helper.read_bytes()
            for corrupt in [True, False]:
                with self.subTest(name=name,corrupt=corrupt):
                    if corrupt:
                        helper.write_text('corrupt build output')
                    else:
                        helper.unlink()
                    result = self.run_prepare(self.stage)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(helper.read_bytes(), original)

    def test_every_cmake_mode_reinstalls_assets_after_bundle_cleanup(self):
        source = self.root / 'cmake-source'
        source.mkdir()
        # Exercise the exact production install rules, without requiring a
        # display or substituting a mock helper. Full Flutter builds are also
        # checked by the documented native smoke path.
        (source / 'CMakeLists.txt').write_text('''
cmake_minimum_required(VERSION 3.13)
project(asset_test NONE)
set(BINARY_NAME asset_test)
add_custom_target(asset_test)
install(CODE "file(REMOVE_RECURSE \\"${CMAKE_INSTALL_PREFIX}/\\")")
include("''' + str(ROOT / 'linux/contract_assets.cmake') + '''")
''')
        renderer_identities = {}
        for mode in ['Debug', 'Profile', 'Release']:
            with self.subTest(mode=mode):
                build = self.root / ('cmake-' + mode)
                bundle = self.root / ('relocated ' + mode)
                subprocess.run(['cmake', '-S', str(source), '-B', str(build),
                                '-DCMAKE_BUILD_TYPE=' + mode,
                                '-DCMAKE_INSTALL_PREFIX=' + str(bundle)],
                               check=True, capture_output=True)
                for iteration in range(2):
                    subprocess.run(['cmake', '--build', str(build), '--target', 'install'],
                                   check=True, capture_output=True)
                    self.assertTrue((bundle / 'libexec/busyapi/node').is_file())
                    self.assertTrue((bundle / 'libexec/busyapi/engine.cjs').is_file())
                    for name in ['policy-worker.cjs','mock-server.cjs',
                                 'policy-isolation.node','policy-launcher',
                                 'policy-build.json']:
                        self.assertEqual((bundle / 'libexec/busyapi' / name).read_bytes(), (self.stage / name).read_bytes())
                        self.assertFalse((bundle / 'libexec/busyapi' / name).is_symlink())
                    self.assertEqual(
                        hashlib.sha256((bundle / 'libexec/busyapi/oasdiff').read_bytes()).hexdigest(),
                        'fa65aae43c867e9f79da9cb121d3c1a113637883afe014c0680fd5b50696f416')
                    self.assertTrue((bundle / 'share/busyapi/schemas/oas32.json').is_file())
                    self.assertEqual((bundle / 'share/busyapi/schemas/oas30.json').read_bytes(),
                                     (ROOT / 'tools/contract_engine/schemas/oas30.json').read_bytes())
                    self.assertTrue((bundle / 'share/licenses/busyapi-engine/NODE-LICENSE').is_file())
                    for notice in ['acorn-8.19.0-AUTHORS', 'acorn-8.19.0-LICENSE']:
                        self.assertEqual((bundle / 'share/licenses/busyapi-engine' / notice).read_bytes(),
                                         (self.stage / 'licenses' / notice).read_bytes())
                    for preset, version, count, copyright in [
                            ('redoc', '3.0.1', 52, b'(c) Copyright 2025 Redocly Inc, all rights reserved.'),
                            ('swagger', '5.33.2', 118, b'Copyright 2020-2021 SmartBear Software Inc.')]:
                        documentation = bundle / ('share/busyapi/documentation/' + preset)
                        manifest = json.loads((documentation / 'assets.json').read_text())
                        renderer_identities.setdefault(preset, manifest['identity'])
                        self.assertEqual(manifest['identity'], renderer_identities[preset])
                        self.assertEqual(manifest['adapter']['packageVersion'], version)
                        for name, digest in manifest['files'].items():
                            asset = documentation / name
                            self.assertFalse(asset.is_symlink())
                            self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(), digest)
                        notices = (documentation / 'THIRD_PARTY_NOTICES.txt').read_bytes()
                        self.assertIn(copyright, notices)
                        self.assertIn(b'Permission is hereby granted, free of charge', notices)
                        self.assertIn(b'regenerator-runtime -- Copyright (c) 2014-present, Facebook, Inc. -- license (MIT)', notices)
                        for name in manifest['notices']:
                            self.assertEqual((bundle / ('share/licenses/busyapi-documentation/' + preset) / name).read_bytes(), (documentation / name).read_bytes())
                        inventory = json.loads((documentation / 'third-party.json').read_text())
                        self.assertEqual(len(inventory['packages']), count)
                        dompurify = next(record for record in inventory['packages'] if record['name'] == 'dompurify')
                        self.assertEqual(dompurify['embeddedSources'][0]['license'], 'MIT')
                        if preset == 'redoc':
                            declaration = json.loads((ROOT / 'tools/documentation_renderers/license_declarations.json').read_text())['packages']['@redocly/redoc-opentelemetry@0.5.1']
                            component = next(record for record in inventory['packages'] if record['name'] == '@redocly/redoc-opentelemetry')
                            self.assertEqual((component['version'], component['license']), ('0.5.1', 'MIT'))
                            self.assertEqual(component['declarationEvidence'], declaration)
                            self.assertIn((ROOT / 'tools/documentation_renderers' / declaration['supplement']).read_bytes(), notices)
                        self.assertNotIn('playwright', {record['name'] for record in inventory['packages']})
                        if iteration == 0:
                            (documentation / 'bootstrap.js').unlink()
                    self.assertFalse((bundle / 'stale-post-build-copy').exists())
                    if iteration == 0:
                        (bundle / 'libexec/busyapi/engine.cjs').unlink()
                        (bundle / 'stale-post-build-copy').touch()


if __name__ == '__main__':
    unittest.main()
