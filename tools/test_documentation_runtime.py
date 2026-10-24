"""Actual ELF/module failure and relocation tests; never requests a display."""
import os
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

from tools.verify_documentation_runtime import verify

ROOT = Path(__file__).resolve().parent.parent


class DocumentationRuntime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.installed = Path(os.environ.get('BUSYAPI_DOCUMENTATION_MODULE',
            ROOT / 'build/linux/x64/debug/bundle/lib/libbusyapi_documentation.so')).absolute()
        if not cls.installed.is_file() or cls.installed.is_symlink():
            raise RuntimeError('Build the ordinary BusyAPI Linux application first')
        cls.staging = tempfile.TemporaryDirectory(prefix='busyapi-doc-runtime-')
        cls.root = Path(cls.staging.name)
        cls.executable = cls.root / 'runtime-test'
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'gtk+-3.0'], text=True))
        libraries = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gmodule-2.0'], text=True))
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Werror',
                        str(ROOT / 'linux/runner/documentation_runtime.cc'),
                        str(ROOT / 'linux/runner/documentation_runtime_test.cc'),
                        '-o', str(cls.executable), *flags, *libraries], check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.staging.cleanup()

    def run_case(self, mode, prepare=None, *args):
        directory = self.root / ('relocated 雪 with spaces ' + self._testMethodName)
        directory.mkdir()
        (directory / 'lib').mkdir()
        executable = directory / 'runtime-test'
        shutil.copyfile(self.executable, executable)
        executable.chmod(0o755)
        if prepare:
            prepare(directory)
        environment = dict(os.environ)
        for name in ('LD_LIBRARY_PATH', 'LD_PRELOAD', 'WEBKIT_EXEC_PATH', 'WEBKIT_INJECTED_BUNDLE_PATH'):
            environment.pop(name, None)
        result = subprocess.run([str(executable), mode, *map(str, args)], cwd=directory,
                                capture_output=True, text=True, env=environment, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return directory

    def test_module_is_optional_at_startup_and_failure_does_not_cache(self):
        dynamic = subprocess.check_output(['readelf', '-d', str(self.executable)], text=True)
        self.assertNotIn('libwebkit', dynamic)
        self.assertNotIn('libjavascriptcore', dynamic)
        self.run_case('retry', None, self.installed)

    def test_installed_module_relocates_and_has_the_versioned_actual_abi(self):
        self.run_case('valid', lambda directory: shutil.copyfile(self.installed, directory / 'lib/libbusyapi_documentation.so'))

    def test_missing_module_and_source_like_symlink_are_rejected(self):
        self.run_case('module', lambda directory: (directory / 'lib/libbusyapi_documentation.so').symlink_to(self.installed))

    def test_non_module_bytes_are_a_static_load_failure(self):
        self.run_case('load', lambda directory: (directory / 'lib/libbusyapi_documentation.so').write_bytes(b'not an ELF module: private source must not be returned'))

    def test_wrong_application_module_abi_is_refused(self):
        def prepare(directory):
            source = directory / 'wrong.cc'
            source.write_text('extern "C" const void* busyapi_documentation_runtime_v1() { return nullptr; }\n')
            subprocess.run(['c++', '-shared', '-fPIC', str(source), '-o', str(directory / 'lib/libbusyapi_documentation.so')], check=True, timeout=30)
        self.run_case('abi', prepare)

    def test_missing_native_dependency_does_not_become_missing_project_data(self):
        def prepare(directory):
            source = directory / 'dependency.cc'
            source.write_text('extern "C" int busyapi_fixture_runtime() { return 1; }\n')
            dependency = directory / 'libbusyapi_fixture_missing.so'
            subprocess.run(['c++', '-shared', '-fPIC', str(source), '-Wl,-soname,libbusyapi_fixture_missing.so', '-o', str(dependency)], check=True, timeout=30)
            source.write_text('extern "C" int busyapi_fixture_runtime(); extern "C" const void* busyapi_documentation_runtime_v1() { busyapi_fixture_runtime(); return nullptr; }\n')
            subprocess.run(['c++', '-shared', '-fPIC', str(source), str(dependency), '-o', str(directory / 'lib/libbusyapi_documentation.so')], check=True, timeout=30)
            dependency.unlink()
        self.run_case('load', prepare)

    def test_unavailable_runtime_symbol_is_a_load_error_before_any_api_call(self):
        def prepare(directory):
            source = directory / 'unavailable.cc'
            source.write_text('extern "C" void busyapi_fixture_unavailable(); extern "C" const void* busyapi_documentation_runtime_v1() { busyapi_fixture_unavailable(); return nullptr; }\n')
            subprocess.run(['c++', '-shared', '-fPIC', str(source), '-o', str(directory / 'lib/libbusyapi_documentation.so')], check=True, timeout=30)
        self.run_case('load', prepare)

    def test_ninja_build_and_ordinary_install_include_module_and_descriptor_in_every_mode(self):
        source = self.root / 'cmake-source'
        source.mkdir()
        common = re.search(r'function\(APPLY_STANDARD_SETTINGS TARGET\).*?endfunction\(\)',
                           (ROOT / 'linux/CMakeLists.txt').read_text(), re.DOTALL)
        self.assertIsNotNone(common)
        (source / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.13)
project(documentation_module_test LANGUAGES CXX)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(WEBKIT REQUIRED IMPORTED_TARGET webkit2gtk-4.1)
{common.group()}
include("{ROOT}/linux/documentation_runtime.cmake")
busyapi_install_documentation_runtime()
''')
        for mode in ('Debug', 'Profile', 'Release'):
            with self.subTest(mode=mode):
                build = self.root / ('cmake-' + mode)
                installed = self.root / ('installed 雪 ' + mode)
                for command in (
                    ['cmake', '-G', 'Ninja', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=' + mode, '-DCMAKE_INSTALL_PREFIX=' + str(installed)],
                    ['cmake', '--build', str(build)],
                    ['cmake', '--install', str(build)],
                ):
                    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                data = verify(installed)
                self.assertEqual(data['buildVersion'], subprocess.check_output(['pkg-config', '--modversion', 'webkit2gtk-4.1'], text=True).strip())
                self.assertFalse(any(path.is_symlink() for path in installed.rglob('*')))
                executable = installed / 'runtime-test'
                shutil.copyfile(self.executable, executable)
                executable.chmod(0o755)
                result = subprocess.run([str(executable), 'valid'], cwd=installed, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                descriptor = installed / 'share/busyapi/documentation-runtime.json'
                original = descriptor.read_bytes()
                data['moduleAbi'] = 2
                descriptor.write_text(json.dumps(data))
                with self.assertRaisesRegex(RuntimeError, 'descriptor'):
                    verify(installed)
                descriptor.write_bytes(original)
                wrong = installed / 'lib/libwebkit2gtk-4.1.so.0'
                wrong.write_bytes(b'Not an approved private runtime')
                with self.assertRaisesRegex(RuntimeError, 'partial private WebKit'):
                    verify(installed)

    def test_actual_ordinary_bundle_has_no_webkit_startup_dependency(self):
        self.assertEqual(verify(self.installed.parent.parent)['moduleAbi'], 1)


if __name__ == '__main__':
    unittest.main()
