"""Upstream SDK selection and captured install ownership, using owned fixtures."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

from tools import verify_flutter_sdk as sdk_check

ROOT = Path(__file__).resolve().parents[1]


class SdkInputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='busyapi-sdk-inputs-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sdk = self.root / 'sdk'
        self.sdk.mkdir()
        self.cache = self.sdk / 'bin/cache'
        self.cache.mkdir(parents=True)
        (self.sdk / 'bin/internal').mkdir()
        (self.sdk / 'bin/internal/engine.version').write_text(sdk_check.LOCK['engineRevision'] + '\n')
        (self.sdk / 'README').write_text('Controlled original source fixture\n')
        env = {'PATH': '/usr/bin:/bin', 'LANG': 'C',
               'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'}
        git = ['git', '-c', 'core.hooksPath=/dev/null', '-C', str(self.sdk)]
        subprocess.run(git + ['init', '--quiet'], env=env, check=True)
        subprocess.run(git + ['add', 'README', 'bin/internal/engine.version'], env=env, check=True)
        subprocess.run(git + ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-m', 'Controlled original inputs'], env=env, check=True)
        revision = subprocess.check_output(git + ['rev-parse', 'HEAD'], env=env).decode().strip()
        runtime = self.cache / 'dart-sdk/bin/dartaotruntime'
        runtime.parent.mkdir(parents=True)
        runtime.write_bytes(b'Controlled runtime fixture; never executed')
        (runtime.parent.parent / 'version').write_text(sdk_check.LOCK['dartVersion'] + '\n')
        (self.cache / 'engine.stamp').write_text(sdk_check.LOCK['engineRevision'] + '\n')
        (self.cache / 'engine.realm').write_text('\n')
        for mode, directory in sdk_check.LOCK['modes'].items():
            library = self.cache / 'artifacts/engine' / directory / 'libflutter_linux_gtk.so'
            library.parent.mkdir(parents=True)
            library.write_bytes(('Controlled ' + mode + ' library fixture').encode())
        self.archives = self.root / 'upstream-archives'
        self.archives.mkdir()
        upstream = copy.deepcopy(sdk_check.LOCK['upstream'])
        def archived(record, relative, content):
            path = self.archives / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr(record['member'], content)
            record['size'] = path.stat().st_size
            record['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            record.pop('memberSha256', None)
        for mode in ('debug', 'profile', 'release'):
            archived(upstream['engine'][mode], 'linux-x64-' + mode + '/linux-x64-flutter-gtk.zip',
                     ('Controlled ' + mode + ' library fixture').encode())
        archived(upstream['dart'], 'dart-sdk-linux-x64.zip', b'Controlled runtime fixture; never executed')
        # Tests bind real read-only Git/cache boundaries to a small synthetic SDK.
        # These fixture identities are not qualification of a distributed SDK.
        lock = mock.patch.dict(sdk_check.LOCK, {
            'frameworkRevision': revision,
            'dartAotRuntimeSha256': hashlib.sha256(runtime.read_bytes()).hexdigest(),
            'upstream': upstream,
        })
        lock.start()
        self.addCleanup(lock.stop)
        variables = ('BUSYAPI_FLUTTER_ENGINE_HOME', 'FLUTTER_ENGINE', 'FLUTTER_ENGINE_SRC_PATH',
                     'FLUTTER_PREBUILT_ENGINE_VERSION', 'FLUTTER_REALM')
        environment = mock.patch.dict(os.environ, {
            **{name: '' for name in variables},
            'BUSYAPI_FLUTTER_UPSTREAM_ARTIFACTS': str(self.archives),
        })
        environment.start()
        self.addCleanup(environment.stop)

    def library(self, mode):
        return self.cache / 'artifacts/engine' / sdk_check.LOCK['modes'][mode] / 'libflutter_linux_gtk.so'

    def test_each_sdk_mode_supplies_its_original_library_without_staging(self):
        for mode in ('debug', 'profile', 'release'):
            with self.subTest(mode=mode):
                before = self.library(mode).read_bytes()
                record = sdk_check.verify(self.sdk, mode, self.library(mode))
                self.assertEqual(record['mode'], mode)
                self.assertEqual(record['librarySha256'], hashlib.sha256(before).hexdigest())
                self.assertEqual(self.library(mode).read_bytes(), before)
        with self.assertRaisesRegex(ValueError, 'differs from its SDK mode'):
            sdk_check.verify(self.sdk, 'release', self.library('debug'))

    def test_modified_source_wrong_revision_and_runtime_are_refused(self):
        (self.sdk / 'README').write_text('Modified tracked SDK source')
        with self.assertRaisesRegex(ValueError, 'Modified or unavailable'):
            sdk_check.verify(self.sdk, 'release')
        (self.sdk / 'README').write_text('Controlled original source fixture\n')
        with mock.patch.dict(sdk_check.LOCK, {'frameworkRevision': '0' * 40}):
            with self.assertRaisesRegex(ValueError, 'source revision'):
                sdk_check.verify(self.sdk, 'release')
        runtime = self.cache / 'dart-sdk/bin/dartaotruntime'
        runtime.write_bytes(b'Changed runtime')
        with self.assertRaisesRegex(ValueError, 'runtime bytes'):
            sdk_check.verify(self.sdk, 'release')

    def test_custom_engine_settings_and_stages_cannot_be_selected(self):
        for name in ('BUSYAPI_FLUTTER_ENGINE_HOME', 'FLUTTER_ENGINE', 'FLUTTER_ENGINE_SRC_PATH',
                     'FLUTTER_PREBUILT_ENGINE_VERSION', 'FLUTTER_REALM'):
            with self.subTest(setting=name), mock.patch.dict(os.environ, {name: '/controlled/custom'}):
                with self.assertRaisesRegex(ValueError, 'custom engine configuration'):
                    sdk_check.verify(self.sdk, 'release')
        marker = self.library('release').parent / 'busyapi-engine.json'
        marker.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'custom engine stage'):
            sdk_check.verify(self.sdk, 'release')

    def test_sdk_git_filters_are_not_executed_during_source_verification(self):
        marker = self.root / 'filter-must-not-run'
        (self.sdk / '.gitattributes').write_text('* filter=probe\n')
        git = ['git', '-c', 'core.hooksPath=/dev/null', '-C', str(self.sdk)]
        subprocess.run(git + ['add', '.gitattributes'], check=True)
        subprocess.run(git + ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-m', 'Controlled attribute input'], check=True)
        revision = subprocess.check_output(git + ['rev-parse', 'HEAD']).decode().strip()
        subprocess.run(git + ['config', 'filter.probe.clean',
                             'printf forbidden > ' + shlex.quote(str(marker)) + '; cat'], check=True)
        with mock.patch.dict(sdk_check.LOCK, {'frameworkRevision': revision}):
            sdk_check.verify(self.sdk, 'release')
        self.assertFalse(marker.exists())

    def test_invalid_cache_identity_and_linked_input_fail_without_repair(self):
        stamp = self.cache / 'engine.stamp'
        stamp.write_text('another engine')
        with self.assertRaisesRegex(ValueError, 'engine cache'):
            sdk_check.verify(self.sdk, 'release')
        self.assertEqual(stamp.read_text(), 'another engine')
        stamp.write_text(sdk_check.LOCK['engineRevision'])
        realm = self.cache / 'engine.realm'
        realm.write_text('presubmit')
        with self.assertRaisesRegex(ValueError, 'Presubmit'):
            sdk_check.verify(self.sdk, 'release')
        realm.write_text('')
        library = self.library('release')
        library.unlink()
        library.symlink_to(self.library('debug'))
        with self.assertRaisesRegex(ValueError, 'linked upstream SDK input'):
            sdk_check.verify(self.sdk, 'release')

    def test_install_rechecks_captured_bytes_instead_of_recapturing(self):
        receipt = self.root / 'receipt.json'
        args = ['verify_flutter_sdk.py', '--sdk', str(self.sdk), '--mode', 'release',
                '--library', str(self.library('release')), '--receipt', str(receipt)]
        with mock.patch.object(sys, 'argv', args):
            sdk_check.main()
        before = receipt.read_bytes()
        with mock.patch.object(sys, 'argv', args + ['--check-receipt']):
            sdk_check.main()
        self.library('release').write_bytes(b'Replaced after build capture')
        with mock.patch.object(sys, 'argv', args + ['--check-receipt']):
            with self.assertRaisesRegex(ValueError, 'independently authenticated upstream archive member'):
                sdk_check.main()
        self.assertEqual(receipt.read_bytes(), before)

    def test_installed_capture_and_library_are_required_and_mode_bound(self):
        bundle = self.root / 'bundle'
        library = bundle / 'lib/libflutter_linux_gtk.so'
        library.parent.mkdir(parents=True)
        library.write_bytes(self.library('release').read_bytes())
        record = sdk_check.verify(self.sdk, 'release')
        receipt = bundle / sdk_check.RECEIPT
        sdk_check.capture(receipt, record)
        self.assertEqual(sdk_check.verify_installed(bundle), record)
        for key, value in [('frameworkRevision', 'wrong'), ('engineRevision', 'wrong'),
                           ('mode', 'unknown'), ('librarySha256', '0' * 64)]:
            with self.subTest(key=key):
                changed = copy.deepcopy(record)
                changed[key] = value
                sdk_check.capture(receipt, changed)
                with self.assertRaises(ValueError):
                    sdk_check.verify_installed(bundle)
        sdk_check.capture(receipt, record)
        library.write_bytes(self.library('debug').read_bytes())
        with self.assertRaisesRegex(ValueError, 'differs from its captured'):
            sdk_check.verify_installed(bundle)

    def test_missing_capture_and_obsolete_distribution_are_not_success(self):
        bundle = self.root / 'bundle'
        with self.assertRaisesRegex(ValueError, 'Missing or linked'):
            sdk_check.verify_installed(bundle)
        library = bundle / 'lib/libflutter_linux_gtk.so'
        library.parent.mkdir(parents=True)
        library.write_bytes(self.library('release').read_bytes())
        sdk_check.capture(bundle / sdk_check.RECEIPT, sdk_check.verify(self.sdk, 'release'))
        obsolete = bundle / 'share/busyapi/flutter-engine'
        obsolete.mkdir()
        with self.assertRaisesRegex(ValueError, 'obsolete custom engine output'):
            sdk_check.verify_installed(bundle)

    def test_matching_local_library_hash_and_forged_receipt_are_not_provenance(self):
        bundle = self.root / 'bundle'
        library = bundle / 'lib/libflutter_linux_gtk.so'
        library.parent.mkdir(parents=True)
        record = sdk_check.verify(self.sdk, 'release')
        library.write_bytes(b'Untrusted replacement with a matching self-authored receipt')
        record['librarySha256'] = hashlib.sha256(library.read_bytes()).hexdigest()
        sdk_check.capture(bundle / sdk_check.RECEIPT, record)
        with self.assertRaisesRegex(ValueError, 'independent upstream provenance'):
            sdk_check.verify_installed(bundle)
        self.library('release').write_bytes(library.read_bytes())
        with self.assertRaisesRegex(ValueError, 'independently authenticated upstream archive member'):
            sdk_check.verify(self.sdk, 'release')

    def test_missing_or_modified_original_archive_cannot_authenticate_sdk_bytes(self):
        with mock.patch.dict(os.environ, {'BUSYAPI_FLUTTER_UPSTREAM_ARTIFACTS': ''}):
            with self.assertRaisesRegex(ValueError, 'Original upstream archives'):
                sdk_check.verify(self.sdk, 'release')
        archive = self.archives / 'linux-x64-release/linux-x64-flutter-gtk.zip'
        archive.write_bytes(b'Untrusted archive')
        before = self.library('release').read_bytes()
        with self.assertRaisesRegex(ValueError, 'upstream archive size'):
            sdk_check.verify(self.sdk, 'release')
        self.assertEqual(self.library('release').read_bytes(), before)

    def test_old_self_hash_receipt_is_rejected(self):
        bundle = self.root / 'bundle'
        record = sdk_check.verify(self.sdk, 'release')
        record['version'] = 1
        sdk_check.capture(bundle / sdk_check.RECEIPT, record)
        with self.assertRaisesRegex(ValueError, 'SDK identity'):
            sdk_check.verify_installed(bundle)

    def test_independent_member_pins_can_qualify_an_existing_sdk_without_archives(self):
        upstream = copy.deepcopy(sdk_check.LOCK['upstream'])
        upstream['engine']['release']['memberSha256'] = hashlib.sha256(b'Controlled release library fixture').hexdigest()
        upstream['dart']['memberSha256'] = hashlib.sha256(b'Controlled runtime fixture; never executed').hexdigest()
        with mock.patch.dict(sdk_check.LOCK, {'upstream': upstream}), \
                mock.patch.dict(os.environ, {'BUSYAPI_FLUTTER_UPSTREAM_ARTIFACTS': ''}):
            self.assertEqual(sdk_check.verify(self.sdk, 'release')['version'], 2)


class BuildOwnership(unittest.TestCase):
    def test_cmake_and_ci_use_upstream_inputs_without_an_engine_builder(self):
        cmake = (ROOT / 'linux/flutter_sdk.cmake').read_text()
        self.assertIn('add_dependencies(busyapi_verify_flutter_sdk flutter_assemble)', cmake)
        self.assertIn('--library "${FLUTTER_LIBRARY}"', cmake)
        self.assertIn('--check-receipt', cmake)
        self.assertNotIn('install(FILES "${BUSYAPI_FLUTTER', cmake)
        self.assertIn('include(flutter_sdk.cmake)', (ROOT / 'linux/CMakeLists.txt').read_text())
        build = (ROOT / 'tools/build_linux.sh').read_text()
        self.assertLess(build.index('tools/verify_flutter_sdk.py'), build.index('busyapi_sdk_metadata'))
        workflow = (ROOT / '.github/workflows/flutter-linux.yml').read_text()
        self.assertIn('tools/verify_flutter_sdk.py', workflow)
        self.assertIn('tools.test_flutter_sdk', workflow)
        for name in ('build_flutter_engine.py', 'prepare_flutter_engine.py', 'verify_flutter_engine.py'):
            self.assertNotIn(name, workflow)
            self.assertFalse((ROOT / 'tools' / name).exists())
        self.assertFalse((ROOT / 'tools/flutter_engine').exists())

    def test_installed_sdk_check_is_shared_by_both_distribution_routes(self):
        for name in ('package_linux.py', 'check_snap_package.py'):
            self.assertIn('verify_flutter_sdk', (ROOT / 'tools' / name).read_text())
        bundle = Path(os.environ.get('BUSYAPI_TEST_BUNDLE') or ROOT / 'build/linux/x64/release/bundle')
        record = sdk_check.verify_installed(bundle)
        self.assertEqual(record['mode'], 'release')


if __name__ == '__main__':
    unittest.main()
