#!/usr/bin/python3
"""Producer mismatches must stop before a native fixture can take input."""
import json
import os
from pathlib import Path
import re
import tempfile
import unittest

from tools.native_migration_preflight import (
    MIGRATION_PRODUCER, preflight_migration, verify_migration_producer,
)


class PreflightTests(unittest.TestCase):
    def test_revision_matches_production_engine_and_core(self):
        repository = Path(__file__).resolve().parent.parent
        engine = (repository / 'tools/contract_engine/src/migration.ts').read_text()
        core = (repository / 'packages/busyapi_core/lib/src/migration.dart').read_text()
        engine_revision = re.search(r"const migrationProducerVersion\s*=\s*'([^']+)'", engine)
        core_revision = re.search(r"result\['producerVersion'\]\s*!=\s*'([^']+)'", core)
        self.assertIsNotNone(engine_revision, 'Locate the production migration producer')
        self.assertIsNotNone(core_revision, 'Locate Core migration admission')
        self.assertEqual(engine_revision.group(1), core_revision.group(1))
        self.assertEqual(MIGRATION_PRODUCER, engine_revision.group(1))

    def test_current_revision_is_accepted_and_previous_package_is_rejected(self):
        verify_migration_producer({'producer': 'busyapi-native-migration', 'producerVersion': '34'})
        with self.assertRaisesRegex(RuntimeError, 'producer differ'):
            verify_migration_producer({'producer': 'busyapi-native-migration', 'producerVersion': '25'})

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='busyapi-native-preflight-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'api.json'
        self.raw = b'{"openapi":"3.0.4","info":{"title":"Original","version":"1"},"paths":{}}\n'
        self.source.write_bytes(self.raw)
        self.originals = {self.source: self.raw}
        self.destination = self.root / 'preview'

    def fake(self, report, code=0, malformed=None):
        binary = self.root / 'busyapi-fake'
        payload = json.dumps(report) if malformed is None else malformed
        binary.write_text('#!/usr/bin/python3\nimport sys\nprint(' + repr(payload) + ')\nsys.exit(' + str(code) + ')\n')
        binary.chmod(0o700)
        return binary

    def review(self, **updates):
        return {'producer': 'busyapi-native-migration', 'producerVersion': MIGRATION_PRODUCER,
                'status': 'faithfully-convertible', 'complete': True, 'published': False,
                'target': {'declaredVersion': '2.0'}, 'reviewIdentity': 'a' * 64, **updates}

    def test_obsolete_producer_is_rejected_without_publication(self):
        for version in ['6', '23', '25', '31', '32', '33']:
            with self.subTest(producerVersion=version):
                binary = self.fake(self.review(producerVersion=version))
                with self.assertRaisesRegex(RuntimeError, 'producer differ'):
                    preflight_migration(binary, self.source, '2.0', self.destination, self.originals)
                self.assertFalse(self.destination.exists())
                self.assertEqual(self.source.read_bytes(), self.raw)

    def test_malformed_failed_and_nonreview_outputs_are_not_readiness(self):
        cases = [(self.review(), 0, '{broken'), ([], 0, None),
                 (self.review(), 2, None), (self.review(complete=False), 0, None),
                 (self.review(published=True), 0, None),
                 (self.review(target=[]), 0, None),
                 (self.review(target={'declaredVersion': '3.1.2'}), 0, None),
                 (self.review(reviewIdentity=''), 0, None)]
        for report, code, malformed in cases:
            with self.subTest(report=report, code=code, malformed=malformed):
                with self.assertRaises(RuntimeError):
                    preflight_migration(self.fake(report, code, malformed), self.source,
                                        '2.0', self.destination, self.originals)
                self.assertFalse(self.destination.exists())
                self.assertEqual(self.source.read_bytes(), self.raw)

    def test_stale_source_and_occupied_destination_refuse_before_launch(self):
        self.source.write_bytes(b'Changed fixture')
        with self.assertRaisesRegex(RuntimeError, 'changed before preflight'):
            preflight_migration(self.root / 'missing-binary', self.source, '2.0',
                                self.destination, self.originals)
        self.source.write_bytes(self.raw)
        self.destination.mkdir()
        sentinel = self.destination / 'foreign'
        sentinel.write_bytes(b'Keep foreign destination')
        with self.assertRaisesRegex(RuntimeError, 'absent private preflight'):
            preflight_migration(self.root / 'missing-binary', self.source, '2.0',
                                self.destination, self.originals)
        self.assertEqual(sentinel.read_bytes(), b'Keep foreign destination')

    def test_actual_packaged_cli_previews_all_families_without_publication(self):
        bundle = Path(os.environ.get('BUSYAPI_TEST_BUNDLE') or
                      Path(__file__).resolve().parent.parent / 'build/linux/x64/release/bundle')
        binary = bundle / 'busyapi'
        self.assertTrue(binary.is_file(), 'Build the assembled CLI or set BUSYAPI_TEST_BUNDLE')
        for version in ['2.0', '3.0.4', '3.1.2', '3.2.1']:
            for format in ['yaml', 'json']:
                with self.subTest(version=version, format=format):
                    source = self.root / ('api-' + version + '.' + format)
                    fragment = self.root / ('model-' + version + '.json')
                    schema = {'$ref': fragment.name + '#/Item'}
                    response = {'description': 'Value', **({'schema': schema}
                                if version == '2.0' else {'content': {'application/json': {'schema': schema}}})}
                    value = {'swagger' if version == '2.0' else 'openapi': version,
                             'info': {'title': 'Owned 雪', 'version': 'api-version'},
                             **({'host': '127.0.0.1:1', 'basePath': '/v1', 'schemes': ['http'],
                                 'produces': ['application/json']} if version == '2.0'
                                else {'servers': [{'url': 'http://127.0.0.1:1/v1'}]}),
                             'paths': {'/value': {'get': {'responses': {'200': response}}}},
                             'x-kept': {'exact': 'EXACT', 'flag': False, 'empty': ''}}
                    raw = (('# Keep source 雪\r\n' if format == 'yaml' else '')
                           + json.dumps(value, ensure_ascii=False).replace('"EXACT"', '9007199254740993.000') + '\r\n').encode()
                    extra = b'{"Item":{"type":"integer"}}\r\n'
                    source.write_bytes(raw)
                    fragment.write_bytes(extra)
                    destination = self.root / ('preview-' + version + '-' + format)
                    report = preflight_migration(binary, source, '2.0', destination,
                                                 {source: raw, fragment: extra})
                    self.assertFalse(report['published'])
                    self.assertFalse(report['nativeAcceptance'])
                    self.assertEqual(report['producerVersion'], MIGRATION_PRODUCER)
                    self.assertFalse(destination.exists())
                    self.assertEqual(source.read_bytes(), raw)
                    self.assertEqual(fragment.read_bytes(), extra)


if __name__ == '__main__':
    unittest.main()
