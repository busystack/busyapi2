"""Actual selected compiler/plugin notice publication and Ninja installation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urljoin, urlparse

from tools.verify_application_assets import verify

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / '.dart_tool/package_config.json'


class ApplicationAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        configuration = json.loads(CONFIG.read_text())
        cls.packages = {item['name']: Path(unquote(urlparse(urljoin(CONFIG.as_uri(), item['rootUri'])).path)) for item in configuration['packages']}
        cls.sdk = cls.packages['flutter'].parent.parent
        cls.dart = os.environ.get('BUSYAPI_DART', str(cls.sdk/'bin/cache/dart-sdk/bin/dart'))
        cls.script = ROOT/'packages/busyapi_core/tool/prepare_notices.dart'
        cls.kernel = ROOT/'build/flutter_assets/kernel_blob.bin'
        if not cls.kernel.is_file():
            raise unittest.SkipTest('Build the ordinary pinned Linux debug application first')

    def run_tool(self, output, *extra):
        return subprocess.run([self.dart, '--packages='+str(CONFIG), str(self.script),
                               '--application='+str(self.kernel), '--mode=Debug', '--entry=lib/main.dart',
                               '--output='+str(output), *extra], capture_output=True, text=True, timeout=120)

    def test_actual_notices_and_covered_sources_survive_relocation_and_fail_closed_on_tampering(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-application-assets-') as temporary:
            bundle = Path(temporary)/'relocated 雪 with spaces'
            artifact = bundle/'data/flutter_assets/kernel_blob.bin'
            artifact.parent.mkdir(parents=True)
            shutil.copyfile(self.kernel, artifact)
            output = bundle/'share/licenses/busyapi-application'
            result = self.run_tool(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            inventory = verify(bundle)
            self.assertEqual(len(inventory['packages']), 82)
            self.assertEqual(sum(item['license'] == 'MPL-2.0' for item in inventory['packages']), 9)
            self.assertEqual(len(inventory['datasets']), 5)
            self.assertEqual(len(inventory['supplements']), 4)
            owner_notice = (output/'BusyAPI-NOTICE').read_text()
            self.assertIn('native Linux rendering stack uses the FreeType Project', owner_notice)
            self.assertIn('FreeType License (FTL) alternative', owner_notice)
            self.assertIn('This software is based in part on the work of the Independent JPEG Group.', owner_notice)
            self.assertEqual((output/'BusyAPI-NOTICE').read_bytes(), (ROOT/'NOTICE').read_bytes())
            for name, expected in [('UNICODE-16-LICENSE', '1991-2024 Unicode'), ('CLDR-48-LICENSE', '2004-2025 Unicode'), ('Apache-2.0', 'Patent'), ('WHATWG-HTML-ENTITIES-LICENSE', 'WHATWG')]:
                self.assertIn(expected, (output/'supplements'/name).read_text())
            before = {str(path.relative_to(output)): path.read_bytes() for path in output.rglob('*') if path.is_file()}
            result = self.run_tool(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(before, {str(path.relative_to(output)): path.read_bytes() for path in output.rglob('*') if path.is_file()})
            covered = output/'sources/gtk-2.2.0/lib/gtk.dart'
            original = covered.read_bytes()
            covered.write_bytes(original + b'changed')
            with self.assertRaisesRegex(RuntimeError, 'covered source'):
                verify(bundle)
            covered.write_bytes(original)
            notice = output/'supplements/UNICODE-16-LICENSE'
            original = notice.read_bytes()
            notice.write_bytes(original + b'changed')
            with self.assertRaisesRegex(RuntimeError, 'dataset/codec notice'):
                verify(bundle)
            notice.write_bytes(original)
            notice.unlink()
            notice.symlink_to(self.packages['characters']/'third_party/Unicode_Consortium/UNICODE_LICENSE.txt')
            with self.assertRaisesRegex(RuntimeError, 'symlinks'):
                verify(bundle)
            notice.unlink()
            notice.write_bytes(original)
            path = output/'dependencies.json'
            original_inventory = path.read_bytes()
            inventory['application']['entry'] = 'test/benchmark_desktop.dart'
            inventory['application']['productionEntry'] = False
            path.write_text(json.dumps(inventory))
            with self.assertRaisesRegex(RuntimeError, 'development/test entry'):
                verify(bundle)
            path.write_bytes(original_inventory)
            with artifact.open('r+b') as stream:
                first = stream.read(1)
                stream.seek(0)
                stream.write(bytes([first[0] ^ 1]))
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                verify(bundle)

    def test_unowned_output_is_not_overwritten_and_option_errors_cannot_publish(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-application-denied-') as temporary:
            output = Path(temporary)/'source'
            output.mkdir()
            authored = output/'contract.yaml'
            authored.write_bytes(b'# unchanged\r\nopenapi: 3.2.0\r\n')
            result = self.run_tool(output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(authored.read_bytes(), b'# unchanged\r\nopenapi: 3.2.0\r\n')
            result = self.run_tool(Path(temporary)/'not-created', '--font-assets=invalid')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('are separate', result.stderr)
            self.assertFalse((Path(temporary)/'not-created').exists())

    def test_ninja_all_mode_command_wiring_and_actual_debug_notice_installation(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-application-cmake-') as temporary:
            root = Path(temporary)
            source = root/'source'
            source.mkdir()
            managed = source/'flutter'
            managed.mkdir()
            (managed/'CMakeLists.txt').write_text('set(FLUTTER_TOOL_ENVIRONMENT "FLUTTER_TARGET=lib/main.dart")\n')
            (source/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.16)
project(application_notice_test LANGUAGES NONE)
set(BINARY_NAME busyapi-desktop)
add_custom_target(${{BINARY_NAME}} ALL)
set(BUSYAPI_SOURCE_DIR "{ROOT}")
set(BUSYAPI_NOTICE_DART "{self.dart}")
set(FLUTTER_MANAGED_DIR "{managed}")
add_subdirectory(flutter)
set(PROJECT_BUILD_DIR "{ROOT}/build/")
set(FLUTTER_ASSET_DIR_NAME flutter_assets)
set(AOT_LIBRARY "{ROOT}/build/lib/libapp.so")
add_custom_target(flutter_assemble)
include("{ROOT}/linux/application_notices.cmake")
''')
            for mode in ('Debug', 'Profile', 'Release'):
                build = root/mode
                output = root/('notices-'+mode)
                install = root/('installed-'+mode)
                result = subprocess.run(['cmake', '-G', 'Ninja', '-S', str(source), '-B', str(build),
                                         '-DCMAKE_BUILD_TYPE='+mode, '-DCMAKE_INSTALL_PREFIX='+str(install),
                                         '-DBUSYAPI_APPLICATION_NOTICES='+str(output)], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                ninja = (build/'build.ninja').read_text()
                self.assertIn('--mode='+mode, ninja)
                self.assertIn('--entry=lib/main.dart', ninja)
                self.assertIn(str(self.kernel) if mode == 'Debug' else str(ROOT/'build/lib/libapp.so'), ninja)
                # Actual Profile/Release compiler receipts are tested by the
                # core collector and normal release build, not forged here.
                if mode != 'Debug':
                    continue
                result = subprocess.run(['cmake', '--build', str(build)], capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                result = subprocess.run(['cmake', '--install', str(build)], capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                artifact = install/'data/flutter_assets/kernel_blob.bin'
                artifact.parent.mkdir(parents=True)
                shutil.copyfile(self.kernel, artifact)
                self.assertEqual(len(verify(install)['packages']), 82)
                self.assertFalse(any(path.is_symlink() for path in install.rglob('*')))
            (managed/'CMakeLists.txt').write_text(f'set(FLUTTER_TOOL_ENVIRONMENT "FLUTTER_TARGET={ROOT}/test/benchmark_desktop.dart")\n')
            result = subprocess.run(['cmake', '-S', str(source), '-B', str(root/'Debug')], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--entry='+str(ROOT/'test/benchmark_desktop.dart'), (root/'Debug/build.ninja').read_text())


if __name__ == '__main__':
    unittest.main()
