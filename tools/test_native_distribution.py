"""Native identity/notice capture, including actual assembled input evidence."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tools.native_distribution import (assemble, cached_libraries, collect, common_licences, licence_fields,
                                       original_library, package_owners, resolved_libraries)

ROOT = Path(__file__).resolve().parent.parent


class NativeDistribution(unittest.TestCase):
    def test_original_system_library_attribution_requires_unique_bytes_not_only_a_soname(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-original-') as temporary:
            root = Path(temporary)
            original, installed, other = [root / name for name in ('original.so', 'installed.so', 'other.so')]
            original.write_bytes(b'Original shared library bytes')
            installed.write_bytes(original.read_bytes())
            other.write_bytes(b'Conflicting shared library bytes')
            cache = cached_libraries(
                f'libfixture.so.1 (libc6,x86-64) => {original}\n'
                f'libfixture.so.1 (libc6) => {other}\n'
                f'libstale.so.0 (libc6) => {root / "missing"}\n')
            self.assertEqual(original_library('libfixture.so.1', installed, cache), original)
            self.assertIsNone(original_library('libbusyapi_owned.so', installed, cache))
            installed.write_bytes(b'Modified private system library')
            with self.assertRaisesRegex(RuntimeError, 'no unique original byte identity'):
                original_library('libfixture.so.1', installed, cache)
            installed.write_bytes(original.read_bytes())
            other.write_bytes(original.read_bytes())
            with self.assertRaisesRegex(RuntimeError, 'no unique original byte identity'):
                original_library('libfixture.so.1', installed, cache)

    def test_assembled_notices_and_copied_libraries_are_verified_and_repeatable(self):
        # Real ELF/loader/package boundaries, with small trusted local inputs.
        # This does not claim a final BusyAPI artifact or native-license review.
        with tempfile.TemporaryDirectory(prefix='busyapi-native-assembly-') as temporary:
            bundle, real = Path(temporary), ROOT / 'build/linux/x64/debug/bundle'
            for name in ['busyapi-desktop', 'busyapi', 'libexec/busyapi/node',
                         'libexec/busyapi/resource-package-loader',
                         'libexec/busyapi/policy-isolation.node', 'libexec/busyapi/policy-launcher']:
                target = bundle / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile('/usr/bin/true', target)
            for name in ['lib/libbusyapi_documentation.so', 'share/busyapi/documentation-runtime.json']:
                target = bundle / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(real / name, target)
            # Already copied distribution bytes must not become "owned" code.
            seccomp = Path('/lib/x86_64-linux-gnu/libseccomp.so.2').resolve(strict=True)
            shutil.copyfile(seccomp, bundle / 'lib/libseccomp.so.2')
            first = assemble(bundle)
            self.assertEqual(first['inventoryStage'], 'assembled')
            instructions = (bundle / 'share/licenses/busyapi-native/README.txt').read_text()
            self.assertIn('same SONAME and architecture', instructions)
            self.assertIn('does not hash-gate', instructions)
            self.assertIn('reverse engineering needed to debug', instructions)
            self.assertIn('repacking/sideloading', instructions)
            self.assertFalse(first['licenceReviewComplete'])
            entry = next(item for item in first['libraries'] if item['file'] == 'lib/libseccomp.so.2')
            self.assertEqual(entry['sha256'], hashlib.sha256(seccomp.read_bytes()).hexdigest())
            self.assertIn('busyapi', first['applicationLinkage'])
            self.assertIn('libexec/busyapi/resource-package-loader', first['applicationLinkage'])
            directory = bundle / 'share/licenses/busyapi-native'
            record = (directory / 'dependencies.json').read_bytes()
            for package in first['packages']:
                for material in package['notices']:
                    file = directory / 'packages' / package['name'] / material['file']
                    self.assertFalse(file.is_symlink())
                    self.assertEqual(hashlib.sha256(file.read_bytes()).hexdigest(), material['sha256'])
            self.assertTrue(list(directory.glob('packages/*/common/LGPL-2.1')))
            self.assertEqual(assemble(bundle), first)
            self.assertEqual((directory / 'dependencies.json').read_bytes(), record)
            common = next(directory.glob('packages/*/common/LGPL-2.1'))
            common.unlink()
            common.symlink_to(directory / 'README.txt')
            with self.assertRaisesRegex(RuntimeError, 'destination is a symlink'):
                assemble(bundle)

    def test_loader_paths_with_spaces_are_exact_and_missing_or_ambiguous_results_are_not_empty_success(self):
        self.assertEqual(resolved_libraries(' libexample.so.1 => /tmp/space 雪/libexample.so.1 (0x000012ab)\n linux-vdso.so.1 (0x12ab)\n'),
                         {'libexample.so.1': Path('/tmp/space 雪/libexample.so.1')})
        for output in ('libexample.so => not found\n', 'libexample.so => unknown\n',
                       'libexample.so => /first/libexample.so (0x123)\nlibexample.so => /second/libexample.so (0x456)\n'):
            with self.assertRaises(RuntimeError):
                resolved_libraries(output)

    def test_original_notice_labels_are_evidence_not_invented_spdx_or_a_license_verdict(self):
        self.assertEqual(licence_fields('License: LGPL-2.1+ or Expat\r\nLicense: GPL-3+ with Bison exception\n'),
                         ['GPL-3+ with Bison exception', 'LGPL-2.1+ or Expat'])
        self.assertEqual(licence_fields('The complete original grant is in this human-readable copyright file.'), [])

    def test_referenced_common_licence_text_is_retained_and_escape_is_not_followed(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-licences-') as temporary:
            root = Path(temporary)
            directory = root / 'common'
            directory.mkdir()
            original = b'Original permission and disclaimer\n'
            (directory / 'LGPL-2.1').write_bytes(original)
            self.assertEqual(common_licences('See /usr/share/common-licenses/LGPL-2.1.', directory), {'LGPL-2.1': original})
            (root / 'outside').write_bytes(b'not a common licence')
            (directory / 'GPL-3').symlink_to(root / 'outside')
            with self.assertRaisesRegex(RuntimeError, 'escapes'):
                common_licences('See /usr/share/common-licenses/GPL-3.', directory)

    def test_package_ownership_is_batched_exact_multiarch_and_conflicts_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-native-owner-') as temporary:
            source = Path(temporary) / 'libfixture.so.1'
            source.write_bytes(b'Owned fixture')
            class Result:
                stdout = 'libfixture1:amd64: ' + str(source) + '\n'
            with patch('tools.native_distribution.subprocess.run', return_value=Result()) as query:
                self.assertEqual(package_owners([source]), {source: 'libfixture1:amd64'})
                query.assert_called_once()
            Result.stdout += 'libother1:amd64: ' + str(source) + '\n'
            with patch('tools.native_distribution.subprocess.run', return_value=Result()):
                with self.assertRaisesRegex(RuntimeError, 'unique installed package owner'):
                    package_owners([source])
            Result.stdout = 'libfixture1:amd64, libother1:amd64: ' + str(source) + '\n'
            with patch('tools.native_distribution.subprocess.run', return_value=Result()):
                with self.assertRaisesRegex(RuntimeError, 'unique installed package owner'):
                    package_owners([source])
            Result.stdout = '../not-a-package: ' + str(source) + '\n'
            with patch('tools.native_distribution.subprocess.run', return_value=Result()):
                with self.assertRaisesRegex(RuntimeError, 'Invalid installed native package owner'):
                    package_owners([source])

    def test_actual_ordinary_bundle_inventory_keeps_copied_and_system_only_libraries_distinct(self):
        bundle = ROOT / 'build/linux/x64/debug/bundle'
        data, notices, libraries = collect(bundle)
        self.assertFalse(data['licenceReviewComplete'], 'Identity/notice capture must not masquerade as completed source/linkage review')
        self.assertNotIn('libwebkit2gtk-4.1.so.0', libraries)
        self.assertNotIn('libjavascriptcoregtk-4.1.so.0', libraries)
        self.assertIn('libgtk-3.so.0', libraries)
        self.assertEqual(data['documentationRuntime']['systemRuntime'], 'webkit2gtk-4.1')
        self.assertEqual('busyapi' in data['applicationLinkage'], (bundle/'busyapi').is_file())
        self.assertIn('libexec/busyapi/resource-package-loader',data['applicationLinkage'])
        self.assertEqual(data['documentationRuntime']['moduleSha256'], hashlib.sha256((bundle / 'lib/libbusyapi_documentation.so').read_bytes()).hexdigest())
        packages = {item['name']: item for item in data['packages']}
        self.assertTrue(any(item['sourcePackage'] == 'gtk+3.0' for item in packages.values()))
        for item in data['libraries']:
            self.assertEqual(item['linkage'], 'dynamic')
            self.assertEqual(item['sha256'], hashlib.sha256(libraries[Path(item['file']).name].read_bytes()).hexdigest())
            self.assertIn(item['package'], packages)
        for package in packages.values():
            self.assertTrue(package['version'])
            self.assertTrue(package['sourceVersion'])
            for notice in package['notices']:
                key = 'packages/' + package['name'] + '/' + notice['file']
                self.assertEqual(hashlib.sha256(notices[key]).hexdigest(), notice['sha256'])
        self.assertNotIn(str(ROOT), json.dumps(data), 'Portable evidence must not expose a checkout or private build path')


if __name__ == '__main__':
    unittest.main()
