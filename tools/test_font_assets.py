"""Original font notices, real glyph subsets and all-mode installation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urljoin, urlparse

from tools.verify_font_assets import verify


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / '.dart_tool/package_config.json'


class FontAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.configuration = json.loads(CONFIG.read_text())
        cls.packages = {entry['name']: Path(unquote(urlparse(urljoin(CONFIG.as_uri(), entry['rootUri'])).path)) for entry in cls.configuration['packages']}
        cls.sdk = cls.packages['flutter'].parent.parent
        cls.dart = os.environ.get('BUSYAPI_DART', str(cls.sdk/'bin/cache/dart-sdk/bin/dart'))
        cls.review = json.loads((ROOT/'tools/flutter_fonts.review.json').read_text())
        cls.script = ROOT/'packages/busyapi_core/tool/prepare_notices.dart'

    def assets(self, root):
        root.mkdir(parents=True)
        manifest = []
        for group in self.review['groups']:
            owner = self.packages['yaru'] if group['package'] == 'yaru' else self.sdk
            family = ('packages/yaru/' if group['package'] == 'yaru' else '') + group['name']
            fonts = []
            for font in group['fonts']:
                output = root/font['asset']
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(owner/font['file'], output)
                fonts.append({'asset': font['asset']})
            manifest.append(dict(family=family, fonts=fonts))
        (root/'FontManifest.json').write_text(json.dumps(manifest))
        return root

    def run_tool(self, assets, output, *, configuration=CONFIG):
        return subprocess.run([self.dart, '--packages='+str(configuration), str(self.script),
                               '--font-assets='+str(assets), '--output='+str(output)], capture_output=True, text=True, timeout=60)

    def test_original_fonts_and_notices_survive_repeated_preparation_and_artifact_verification(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-font-assets-') as temporary:
            bundle = Path(temporary)/'relocated 雪 with spaces'
            assets = self.assets(bundle/'data/flutter_assets')
            output = bundle/'share/licenses/busyapi-fonts'
            for _ in range(2):
                result = self.run_tool(assets, output)
                self.assertEqual(result.returncode, 0, result.stderr)
                inventory = verify(bundle)
                self.assertEqual(sum(len(group['fonts']) for group in inventory['groups']), 11)
                self.assertTrue(all(not font['modified'] for group in inventory['groups'] for font in group['fonts']))
            text = (output/'THIRD_PARTY_NOTICES.txt').read_text()
            for content in ['Copyright 2019 Google LLC.', 'Copyright 2010,2011 Canonical Ltd.', 'Copyright icon_font_generator 2025', 'CC-BY-SA-4.0', 'CC-BY-4.0', 'Ubuntu-font-1.0']:
                self.assertIn(content, text)
            notice = output/'yaru/assets/fonts/LICENCE.txt'
            before = notice.read_bytes()
            notice.write_bytes(before+b'\nchanged\n')
            with self.assertRaisesRegex(RuntimeError, 'Changed original font notice'):
                verify(bundle)
            notice.write_bytes(before)
            asset = assets/'packages/yaru/assets/fonts/Ubuntu-R.ttf'
            asset.write_bytes(asset.read_bytes()+b'changed')
            with self.assertRaisesRegex(RuntimeError, 'Changed/unreviewed installed font'):
                verify(bundle)

    def test_real_icon_subsets_are_rejected_under_the_retained_normal_linux_policy(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-font-subsets-') as temporary:
            bundle = Path(temporary)/'bundle'
            assets = self.assets(bundle/'data/flutter_assets')
            executable = self.sdk/'bin/cache/artifacts/engine/linux-x64/font-subset'
            for group in self.review['groups']:
                if group['name'] not in ('YaruIcons', 'MaterialIcons'):
                    continue
                source = (self.packages['yaru'] if group['package'] == 'yaru' else self.sdk)/group['fonts'][0]['file']
                # The pinned Flutter build sends optional/required code points
                # on stdin to this supported executable; no font is hand-edited.
                result = subprocess.run([str(executable), str(assets/group['fonts'][0]['asset']), str(source)], input='optional:32\n', capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
            output = bundle/'share/licenses/busyapi-fonts'
            result = self.run_tool(assets, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('normal Linux builds require original font bytes', result.stderr)
            self.assertFalse(output.exists())

    def test_unowned_outputs_changed_ubuntu_fonts_and_unreviewed_families_fail_before_publication(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-font-denied-') as temporary:
            root = Path(temporary)
            assets = self.assets(root/'assets')
            output = root/'source'
            output.mkdir()
            (output/'contract.yaml').write_text('authored source\n')
            result = self.run_tool(assets, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((output/'contract.yaml').read_text(), 'authored source\n')
            font = assets/'packages/yaru/assets/fonts/Ubuntu-R.ttf'
            before = font.read_bytes()
            font.write_bytes(before+b'changed')
            result = self.run_tool(assets, root/'not-published')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('normal Linux builds require original font bytes', result.stderr)
            self.assertFalse((root/'not-published').exists())
            font.write_bytes(before)
            icon = assets/'packages/yaru/assets/yaru_icons.otf'
            icon_before = icon.read_bytes()
            icon.write_bytes(b'')
            result = self.run_tool(assets, root/'not-published')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('empty or truncated', result.stderr)
            self.assertFalse((root/'not-published').exists())
            icon.write_bytes(icon_before)
            manifest = json.loads((assets/'FontManifest.json').read_text())
            manifest[0]['family'] = 'Unreviewed'
            (assets/'FontManifest.json').write_text(json.dumps(manifest))
            result = self.run_tool(assets, root/'not-published')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unreviewed or missing font family/asset', result.stderr)
            self.assertFalse((root/'not-published').exists())

    def test_changed_original_notice_is_not_accepted_from_a_relocated_package_configuration(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-font-source-denied-') as temporary:
            root = Path(temporary)
            assets = self.assets(root/'assets')
            fake = root/'yaru'
            for group in self.review['groups']:
                if group['package'] != 'yaru':
                    continue
                for entry in group['fonts']+group['notices']:
                    target = fake/entry['file']
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(self.packages['yaru']/entry['file'], target)
            shutil.copyfile(self.packages['yaru']/'pubspec.yaml', fake/'pubspec.yaml')
            (fake/'assets/LICENSE.CCBYSA').write_text('a conflicting or changed declaration\n')
            configuration = json.loads(json.dumps(self.configuration))
            for package in configuration['packages']:
                package['rootUri'] = (fake if package['name'] == 'yaru' else self.packages[package['name']]).as_uri()+'/'
            config = root/'packages.json'
            config.write_text(json.dumps(configuration))
            result = self.run_tool(assets, root/'not-published', configuration=config)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unreviewed font notice', result.stderr)
            self.assertFalse((root/'not-published').exists())

    def test_cmake_orders_current_flutter_assets_and_installs_ordinary_notices_in_every_mode(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-font-cmake-') as temporary:
            root = Path(temporary)
            inputs = self.assets(root/'inputs')
            source = root/'source'
            source.mkdir()
            (source/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.16)
project(font_notice_test LANGUAGES NONE)
set(BINARY_NAME busyapi-desktop)
add_custom_target(${{BINARY_NAME}} ALL)
set(BUSYAPI_SOURCE_DIR "{ROOT}")
set(BUSYAPI_NOTICE_DART "{self.dart}")
set(PROJECT_BUILD_DIR "${{CMAKE_BINARY_DIR}}/stage")
set(FLUTTER_ASSET_DIR_NAME flutter_assets)
add_custom_target(flutter_assemble COMMAND "${{CMAKE_COMMAND}}" -E copy_directory "{inputs}" "${{PROJECT_BUILD_DIR}}/${{FLUTTER_ASSET_DIR_NAME}}")
include("{ROOT}/linux/font_notices.cmake")
''')
            for mode in ('Debug', 'Profile', 'Release'):
                build = root/mode
                install = root/(mode+' install 雪')
                commands = [
                    ['cmake', '-G', 'Ninja', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE='+mode, '-DCMAKE_INSTALL_PREFIX='+str(install), '-DBUSYAPI_FONT_NOTICES='+str(build/'notices')],
                    ['cmake', '--build', str(build)],
                    ['cmake', '--install', str(build)],
                ]
                for command in commands:
                    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stdout+'\n'+result.stderr)
                shutil.copytree(build/'stage/flutter_assets', install/'data/flutter_assets')
                verify(install)
                self.assertTrue(all(not file.is_symlink() for file in (install/'share/licenses/busyapi-fonts').rglob('*')))
            self.assertIn('verify_font_assets(bundle)', (ROOT/'tools/package_linux.py').read_text())


if __name__ == '__main__':
    unittest.main()
