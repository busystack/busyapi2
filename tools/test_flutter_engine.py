"""Provenance checks do not substitute for native input qualification."""
import copy
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import re
import textwrap
from verify_flutter_engine import REPO, verify, cache_identity
from prepare_flutter_engine import stage


class EngineProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='busyapi-engine-provenance-')
        self.home = pathlib.Path(self.temp.name)
        self.output = self.home / 'host_release'
        self.output.mkdir()
        self.library = self.output / 'libflutter_linux_gtk.so'
        self.library.write_bytes(b'Trusted provenance unit-test fixture')
        self.record = {
            **json.loads((REPO / 'tools/flutter_engine/engine.lock.json').read_text()),
            'mode': 'release',
            'gnArgs': 'flutter_runtime_mode = "release"\nis_clang = true\nenable_lto = true\nflutter_use_fontconfig = true\n',
            'librarySha256': hashlib.sha256(self.library.read_bytes()).hexdigest(),
        }
        self.write(self.record)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, value):
        (self.output / 'busyapi-engine.json').write_text(json.dumps(value))

    def test_matching_library_and_pins(self):
        self.assertEqual(verify(self.home, 'release'), self.output)

    def test_cache_identity_changes_with_mode_target_inputs_and_build_sources(self):
        baseline = cache_identity('release', 'linux-x64', 'controlled builder inputs')
        self.assertEqual(cache_identity('release', 'linux-x64', 'controlled builder inputs'), baseline)
        for mode, target, inputs in [('debug', 'linux-x64', 'controlled builder inputs'),
                                     ('release', 'other-target', 'controlled builder inputs'),
                                     ('release', 'linux-x64', 'changed builder inputs')]:
            self.assertNotEqual(cache_identity(mode, target, inputs), baseline)
        fixture = self.home/'cache-inputs'
        for name in ['tools/flutter_engine', 'linux']:
            (fixture/name).mkdir(parents=True)
        for name in ['tools/flutter_engine/engine.lock.json', 'tools/build_flutter_engine.py',
                     'tools/prepare_flutter_engine.py', 'tools/verify_flutter_engine.py', 'linux/flutter_engine.cmake']:
            shutil.copy2(REPO/name, fixture/name)
        lock = json.loads((REPO/'tools/flutter_engine/engine.lock.json').read_text())
        patch = 'tools/flutter_engine/' + lock['patch']
        shutil.copy2(REPO/patch, fixture/patch)
        self.assertEqual(cache_identity('release', 'linux-x64', 'controlled builder inputs', fixture), baseline)
        with (fixture/'tools/build_flutter_engine.py').open('a') as target:
            target.write('\n# changed build input\n')
        self.assertNotEqual(cache_identity('release', 'linux-x64', 'controlled builder inputs', fixture), baseline)

    def test_ci_cache_dispatch_verifies_hit_builds_miss_and_refuses_invalid_restoration(self):
        workflow = (REPO/'.github/workflows/flutter-linux.yml').read_text()
        match = re.search(r'      - name: Build the isolated pinned Linux engine\n        run: \|\n(.*?)(?=      - name:)', workflow, re.S)
        self.assertIsNotNone(match)
        script = textwrap.dedent(match.group(1))
        commands = self.home/'cache-command-fixtures'
        commands.mkdir()
        python = commands/'python3'
        python.write_text('''#!/bin/sh
case "$1" in
  tools/verify_flutter_engine.py) exit "$CONTROLLED_VERIFY_EXIT";;
  tools/build_flutter_engine.py) printf '%s\\n' "$*" > "$CONTROLLED_BUILD_LOG"; exit 0;;
  *) exit 99;;
esac
''')
        python.chmod(0o755)
        # Only the workflow's dispatch is stubbed. Real library/provenance
        # admission, mode matching and tamper refusal are tested separately.
        for name, valid, restored, expected, builds in [('hit', True, True, 0, False),
                ('miss', False, False, 0, True), ('invalid', False, True, 1, False)]:
            with self.subTest(name=name):
                root = self.home/name
                root.mkdir()
                if restored:
                    (root/'busyapi-engine/flutter/engine/src/out/host_release').mkdir(parents=True)
                log = root/'build-command'
                result = subprocess.run(['/bin/bash', '-eu', '-c', script], cwd=REPO,
                    env=dict(os.environ, PATH=str(commands)+':/usr/bin:/bin', RUNNER_TEMP=str(root),
                        FLUTTER_ROOT='/controlled/pinned-sdk', CONTROLLED_VERIFY_EXIT='0' if valid else '1',
                        CONTROLLED_BUILD_LOG=str(log)), capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(log.exists(), builds)
                if builds:
                    self.assertIn('--provision --mode release', log.read_text())
                if name == 'invalid':
                    self.assertIn('refusing cached bytes', result.stderr)

    def test_clean_or_partial_stage_cannot_silently_use_stock_engine(self):
        script = self.home / 'missing-stage.cmake'
        environment = dict(os.environ)
        environment.pop('BUSYAPI_FLUTTER_ENGINE_HOME', None)
        for mode in ['Debug', 'Profile', 'Release']:
            for partial in [False, True]:
                with self.subTest(mode=mode, partial=partial):
                    source = self.home / ('source-' + mode + str(partial))
                    source.mkdir()
                    if partial:
                        (source / 'build/flutter-engine').mkdir(parents=True)
                    script.write_text('set(BUSYAPI_SOURCE_DIR "' + str(source) + '")\n'
                                      'set(CMAKE_BUILD_TYPE "' + mode + '")\n'
                                      'include("' + str(REPO / 'linux/flutter_engine.cmake') + '")\n')
                    result = subprocess.run(['cmake', '-P', str(script)], env=environment,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Prepare BusyAPI's pinned", result.stderr)

    def test_cached_configuration_cannot_acknowledge_a_replaced_library(self):
        self.library.write_bytes(b'Replaced after CMake configuration')
        with self.assertRaisesRegex(ValueError, 'library'):
            verify(self.home, 'release')

    def test_each_locked_identity_and_build_mode_is_checked(self):
        for key, value in [('frameworkRevision', 'wrong'), ('engineRevision', 'wrong'),
                           ('patchSha256', 'wrong'), ('mode', 'profile')]:
            with self.subTest(key=key):
                changed = copy.deepcopy(self.record)
                changed[key] = value
                self.write(changed)
                with self.assertRaises(ValueError):
                    verify(self.home, 'release')

    def test_runtime_and_lto_settings_cannot_be_swapped(self):
        for gn in ['flutter_runtime_mode = "debug"\nis_clang = true\nenable_lto = true',
                   'flutter_runtime_mode = "release"\nis_clang = true\nenable_lto = false']:
            changed = {**self.record, 'gnArgs': gn}
            self.write(changed)
            with self.assertRaises(ValueError):
                verify(self.home, 'release')

    def test_desktop_font_fallback_cannot_be_omitted(self):
        for setting in ['', 'flutter_use_fontconfig = false']:
            with self.subTest(setting=setting):
                changed = {**self.record, 'gnArgs': self.record['gnArgs'].replace(
                    'flutter_use_fontconfig = true', setting)}
                self.write(changed)
                with self.assertRaisesRegex(ValueError, 'fontconfig'):
                    verify(self.home, 'release')

    def test_staging_is_relocatable_and_preserves_verified_pins_and_notices(self):
        output = self.home / 'application-stage'
        selected = stage(self.home, output, 'release')
        self.assertTrue(selected.is_symlink())
        self.assertEqual(verify(output, 'release'), selected)
        for name in ['FLUTTER-LICENSE', 'ENGINE-LICENSE',
                     'linux-input-ordering.patch', 'busyapi-engine.json']:
            self.assertTrue((selected / name).is_file(), name)
        self.assertEqual((selected / self.library.name).read_bytes(),
                         self.library.read_bytes())

    def test_cmake_installs_provenance_without_exporting_the_stage_symlink(self):
        for mode in ['debug', 'profile', 'release']:
            with self.subTest(mode=mode):
                if mode != 'release':
                    output = self.home / ('host_' + mode)
                    output.mkdir()
                    (output / self.library.name).write_bytes(self.library.read_bytes())
                    record = {**self.record, 'mode': mode,
                              'gnArgs': self.record['gnArgs'].replace('"release"', '"' + mode + '"')}
                    (output / 'busyapi-engine.json').write_text(json.dumps(record))
                stage_home = self.home / 'stage'
                selected = stage(self.home, stage_home, mode)
                flutter = os.environ.get('BUSYAPI_FLUTTER') or shutil.which('flutter')
                self.assertTrue(flutter, 'This CMake regression requires the pinned Flutter SDK')
                sdk = pathlib.Path(flutter).resolve().parents[1]
                source = self.home / ('cmake-source-' + mode)
                managed = source / 'flutter'
                managed.mkdir(parents=True)
                (managed / 'CMakeLists.txt').write_text(f'set(FLUTTER_ROOT "{sdk}")\n')
                destination = self.home / ('bundle-' + mode)
                installed = destination / 'share/busyapi/flutter-engine'
                installed.parent.mkdir(parents=True)
                # Also repair a bundle left by an earlier installation, without
                # following its link and modifying the immutable input stage.
                installed.symlink_to(selected.resolve(), target_is_directory=True)
                (source / 'CMakeLists.txt').write_text(
                    'cmake_minimum_required(VERSION 3.16)\nproject(engine_install NONE)\n'
                    f'set(BUSYAPI_SOURCE_DIR "{REPO}")\n'
                    f'set(FLUTTER_MANAGED_DIR "{managed}")\n'
                    'add_subdirectory(flutter)\nset(BINARY_NAME app)\nadd_custom_target(app)\n'
                    f'set(Python3_EXECUTABLE "{sys.executable}")\n'
                    f'set(INSTALL_BUNDLE_LIB_DIR "{destination}/lib")\n'
                    f'include("{REPO}/linux/flutter_engine.cmake")\n')
                environment = dict(os.environ, BUSYAPI_FLUTTER_ENGINE_HOME=str(stage_home))
                build = self.home / ('cmake-build-' + mode)
                for command in [
                    ['cmake', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=' + mode.title(),
                     '-DCMAKE_INSTALL_PREFIX=' + str(destination)],
                    ['cmake', '--install', str(build), '--component', 'Runtime'],
                ]:
                    result = subprocess.run(command, env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(installed.is_symlink())
                for name in ['busyapi-engine.json', 'linux-input-ordering.patch',
                             'FLUTTER-LICENSE', 'ENGINE-LICENSE']:
                    self.assertEqual((installed / name).read_bytes(), (selected / name).read_bytes())
                self.assertFalse((installed / self.library.name).exists())
                self.assertEqual((destination / 'lib' / self.library.name).read_bytes(),
                                 self.library.read_bytes())
                verify(stage_home, mode)

    def test_rejected_build_cannot_replace_a_selected_staged_engine(self):
        output = self.home / 'application-stage'
        selected = stage(self.home, output, 'release')
        before = selected.resolve()
        self.library.write_bytes(b'Changed without a matching build receipt')
        with self.assertRaises(ValueError):
            stage(self.home, output, 'release')
        self.assertEqual(selected.resolve(), before)
        verify(output, 'release')

    def test_tampered_cached_stage_is_not_reused(self):
        output = self.home / 'application-stage'
        selected = stage(self.home, output, 'release')
        (selected / self.library.name).write_bytes(b'Tampered cached artifact')
        with self.assertRaises(ValueError):
            stage(self.home, output, 'release')


if __name__ == '__main__':
    unittest.main()
