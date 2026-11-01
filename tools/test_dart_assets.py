"""Exact core notice staging and ordinary all-mode CMake installation."""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / '.dart_tool/package_config.json'


def package_roots():
    value = json.loads(CONFIG.read_text())
    return {entry['name']: pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(
        urllib.parse.urljoin(CONFIG.as_uri(), entry['rootUri'])).path)) for entry in value['packages']}


class DartAssetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CONFIG.is_file():
            raise unittest.SkipTest('Provision the locked Flutter package configuration')
        cls.packages = package_roots()
        cls.sdk = cls.packages['flutter'].parent.parent
        cls.dart = os.environ.get('BUSYAPI_DART', str(cls.sdk / 'bin/cache/dart-sdk/bin/dart'))
        cls.script = ROOT / 'packages/busyapi_core/tool/prepare_notices.dart'

    def run_tool(self, output, *, configuration=CONFIG):
        return subprocess.run([self.dart, '--packages='+str(configuration), str(self.script),
                               '--output='+str(output)], capture_output=True, text=True, timeout=60)

    def verify(self, output):
        inventory = json.loads((output / 'dependencies.json').read_text())
        self.assertEqual(inventory['scope'], 'headless-core-production-closure')
        self.assertEqual({record['name'] for record in inventory['packages']}, {
            'args', 'collection', 'crypto', 'ffi', 'markdown', 'meta', 'path',
            'source_span', 'string_scanner', 'term_glyph', 'typed_data', 'yaml'})
        self.assertEqual(hashlib.sha256((output/'DART-LICENSE').read_bytes()).hexdigest(),
                         inventory['sdkNoticeSha256'])
        for package in inventory['packages']:
            for notice in package['notices']:
                path = output / notice['file']
                self.assertFalse(path.is_symlink())
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), notice['sha256'])
        dataset = inventory['datasets'][0]
        self.assertEqual(hashlib.sha256((output/'datasets/WHATWG-HTML-ENTITIES-LICENSE').read_bytes()).hexdigest(), dataset['noticeSha256'])
        self.assertIn('Copyright © WHATWG', (output/'datasets/WHATWG-HTML-ENTITIES-LICENSE').read_text())
        self.assertIn('Kirill Simonov', (output/'yaml/LICENSE').read_text())
        runtime=inventory['runtime']
        self.assertEqual(runtime['sdkRevision'],'b530c21f7de367b94fb04787bfed9d8e989d75e8')
        self.assertEqual(len(runtime['components']),10)
        self.assertEqual(json.loads((output/'runtime/dependencies.json').read_bytes()),runtime)
        for component in runtime['components']:
            for notice in component['notices']:
                installed=output/'runtime'/notice['file']
                self.assertFalse(installed.is_symlink())
                self.assertEqual(hashlib.sha256(installed.read_bytes()).hexdigest(),notice['sha256'])
                self.assertEqual(installed.read_bytes(),(ROOT/'tools/licenses/dart-runtime'/notice['file']).read_bytes())
        self.assertIn('Boost Software License',(output/'runtime/libcxx-ryu-header').read_text())
        self.assertIn('1991-2022 Unicode',(output/'runtime/libcxx-unicode-header').read_text())
        self.assertIn('1995-2024 Jean-loup Gailly',(output/'runtime/zlib-zlib.h-header').read_text())
        self.assertIn('patent',(output/'runtime/DART-PATENT_GRANT').read_text())

    def test_repeated_preparation_is_verified_and_byte_equivalent(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-dart-assets-') as temporary:
            output = pathlib.Path(temporary) / 'notices'
            result = self.run_tool(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.verify(output)
            original = {str(file.relative_to(output)): file.read_bytes() for file in output.rglob('*') if file.is_file()}
            result = self.run_tool(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(original, {str(file.relative_to(output)): file.read_bytes() for file in output.rglob('*') if file.is_file()})

    def test_unowned_output_or_changed_notice_cannot_be_accepted_or_overwritten(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-dart-assets-denied-') as temporary:
            directory = pathlib.Path(temporary)
            output = directory/'notices'
            output.mkdir()
            (output/'keep.yaml').write_text('source must survive\n')
            result = self.run_tool(output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((output/'keep.yaml').read_text(), 'source must survive\n')
            fake = directory/'markdown'
            fake.mkdir()
            for name in ['pubspec.yaml', 'LICENSE']:
                (fake/name).write_bytes((self.packages['markdown']/name).read_bytes())
            (fake/'LICENSE').write_text('unreviewed replacement\n')
            value = json.loads(CONFIG.read_text())
            for package in value['packages']:
                package['rootUri'] = (fake if package['name'] == 'markdown' else self.packages[package['name']]).as_uri()+'/'
            configuration = directory/'packages.json'
            configuration.write_text(json.dumps(value))
            result = self.run_tool(directory/'must-not-exist', configuration=configuration)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unreviewed Dart dependency identity/notice: markdown', result.stderr)
            self.assertFalse((directory/'must-not-exist').exists())

    def test_normal_cmake_installs_ordinary_notices_in_every_build_mode(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-dart-cmake-') as temporary:
            directory = pathlib.Path(temporary)
            source = directory/'source'
            source.mkdir()
            (source/'flutter').mkdir()
            (source/'flutter/CMakeLists.txt').write_text(f'set(FLUTTER_ROOT "{self.sdk}")\n')
            (source/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.13)
project(notices NONE)
add_subdirectory(flutter)
set(FLUTTER_MANAGED_DIR "{source}/flutter")
set(BUSYAPI_SOURCE_DIR "{ROOT}")
set(BUSYAPI_DART_NOTICES "{directory}/stage" CACHE PATH "")
set(BINARY_NAME app)
add_custom_target(app)
include("{ROOT}/linux/dart_notices.cmake")
''')
            for mode in ['Debug', 'Profile', 'Release']:
                build = directory/mode
                subprocess.run(['cmake', '-G', 'Ninja', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE='+mode], check=True, capture_output=True, text=True, timeout=60)
                subprocess.run(['cmake', '--build', str(build)], check=True, capture_output=True, text=True, timeout=60)
                target = directory/('installed '+mode+' 雪')
                subprocess.run(['cmake', '--install', str(build), '--prefix', str(target)], check=True, capture_output=True, text=True, timeout=60)
                self.verify(target/'share/licenses/busyapi-dart')
                self.assertFalse(any(path.is_symlink() for path in target.rglob('*')))

    def test_changed_library_or_symlink_is_not_the_reviewed_distribution(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-dart-source-denied-') as temporary:
            directory = pathlib.Path(temporary)
            fake = directory/'markdown'
            fake.mkdir()
            for name in ['pubspec.yaml', 'LICENSE']:
                shutil.copyfile(self.packages['markdown']/name, fake/name)
            shutil.copytree(self.packages['markdown']/'lib', fake/'lib')
            value = json.loads(CONFIG.read_text())
            for package in value['packages']:
                package['rootUri'] = (fake if package['name'] == 'markdown' else self.packages[package['name']]).as_uri()+'/'
            configuration = directory/'packages.json'
            configuration.write_text(json.dumps(value))
            source = fake/'lib/markdown.dart'
            original = source.read_bytes()
            source.write_bytes(original+b'\n// Unreviewed library change.\n')
            result = self.run_tool(directory/'must-not-exist', configuration=configuration)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('markdown (sourceSha256)', result.stderr)
            self.assertFalse((directory/'must-not-exist').exists())
            source.unlink()
            source.symlink_to(self.packages['markdown']/'lib/markdown.dart')
            result = self.run_tool(directory/'must-not-exist', configuration=configuration)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Non-ordinary dependency source: markdown', result.stderr)
            self.assertFalse((directory/'must-not-exist').exists())


if __name__ == '__main__':
    unittest.main()
