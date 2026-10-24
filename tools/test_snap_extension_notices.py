"""Bounded original-source/runtime correspondence and assembled notice checks."""
import hashlib
from pathlib import Path
import tempfile
import unittest

from tools.snap_extension_notices import assemble, collect_review
import json


class SnapExtensionNotices(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='busyapi-snap-notices-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.extensions, self.prime = self.root/'extensions', self.root/'prime'
        self.extensions.mkdir()
        self.prime.mkdir()
        self.licence = self.root/'original-license'
        self.licence.write_bytes(b'controlled original licence fixture\n')
        data = b'controlled template %GPU_INTERFACE%\n'
        source = self.extensions/'gpu/command-chain/gpu-wrapper'
        source.parent.mkdir(parents=True)
        source.write_bytes(data)
        target = self.prime/'snap/command-chain/gpu-2404-wrapper'
        target.parent.mkdir(parents=True)
        target.write_bytes(data.replace(b'%GPU_INTERFACE%', b'gpu-2404'))
        self.review = dict(version=1, component='Controlled build-input fixture',
            componentVersion='test', license='controlled', source='controlled',
            licenseSha256=hashlib.sha256(self.licence.read_bytes()).hexdigest(), files=[
                dict(file='gpu/command-chain/gpu-wrapper', sha256=hashlib.sha256(data).hexdigest(),
                     runtime='snap/command-chain/gpu-2404-wrapper', substituteGpu=True)])

    def run_build(self):
        return assemble(self.extensions, self.prime, review=self.review, license_file=self.licence)

    def test_exact_sources_actual_generated_script_and_repeatable_materials(self):
        first = self.run_build()
        notices = self.prime/'share/licenses/busyapi-snap-extension'
        self.assertEqual((notices/'LICENSE').read_bytes(), self.licence.read_bytes())
        self.assertEqual((notices/'sources/gpu/gpu-wrapper').read_bytes(),
                         (self.extensions/'gpu/command-chain/gpu-wrapper').read_bytes())
        self.assertIn('GPU_INTERFACE=gpu-2404', (notices/'MODIFICATIONS.txt').read_text())
        self.assertEqual(self.run_build(), first)

    def test_changed_source_licence_and_generated_runtime_are_not_accepted(self):
        for path in [self.licence, self.extensions/'gpu/command-chain/gpu-wrapper',
                     self.prime/'snap/command-chain/gpu-2404-wrapper']:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(original+b'changed')
                with self.assertRaises(RuntimeError): self.run_build()
                self.assertFalse((self.prime/'share').exists())
                path.write_bytes(original)

    def test_notice_collision_preserves_existing_bytes_and_publishes_nothing_else(self):
        path = self.prime/'share/licenses/busyapi-snap-extension/LICENSE'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'existing')
        with self.assertRaisesRegex(RuntimeError, 'collision'): self.run_build()
        self.assertEqual(path.read_bytes(), b'existing')
        self.assertFalse((path.parent/'sources').exists())

    def test_linked_source_runtime_and_destination_are_refused(self):
        for path in [self.extensions/'gpu/command-chain/gpu-wrapper',
                     self.prime/'snap/command-chain/gpu-2404-wrapper']:
            original = path.read_bytes()
            other = self.root/'other'
            other.write_bytes(original)
            path.unlink()
            path.symlink_to(other)
            with self.assertRaisesRegex(RuntimeError, 'Linked'): self.run_build()
            path.unlink()
            path.write_bytes(original)
        (self.prime/'share').symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'Linked'): self.run_build()

    def test_deliberate_material_refresh_requires_a_reviewed_proposal(self):
        source = self.extensions/'gpu/command-chain/gpu-wrapper'
        runtime = self.prime/'snap/command-chain/gpu-2404-wrapper'
        source.write_bytes(source.read_bytes() + b'controlled upstream update\n')
        runtime.write_bytes(source.read_bytes().replace(b'%GPU_INTERFACE%', b'gpu-2404'))
        with self.assertRaisesRegex(RuntimeError, 'Unreviewed'): self.run_build()
        proposal = self.root/'proposal.json'
        diff = collect_review(self.extensions, self.prime, proposal,
            builder_version='selected-supported-builder', source='https://example.invalid/original-source',
            license_file=self.licence, review=self.review)
        self.assertIn('selected-supported-builder', diff)
        self.assertFalse((self.prime/'share').exists())
        refreshed = json.loads(proposal.read_text())
        assemble(self.extensions, self.prime, review=refreshed, license_file=self.licence)
        runtime.write_bytes(b'changed generated output')
        with self.assertRaisesRegex(RuntimeError, 'generated'):
            collect_review(self.extensions, self.prime, self.root/'bad-proposal.json',
                builder_version='selected-supported-builder', source='https://example.invalid/original-source',
                license_file=self.licence, review=refreshed)
        self.assertFalse((self.root/'bad-proposal.json').exists())


if __name__ == '__main__':
    unittest.main()
