"""Build-policy and actual installed icon glyph coverage (no SDK mutation)."""
import json
import hashlib
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class FlutterAssets(unittest.TestCase):
    def test_every_build_mode_uses_complete_icon_fonts(self):
        managed = (ROOT / 'linux/flutter/CMakeLists.txt').read_text()
        self.assertLess(managed.index('flutter_assets.cmake'),
                        managed.index('add_custom_command('))
        with tempfile.TemporaryDirectory(prefix='busyapi-icon-policy-') as temporary:
            script = pathlib.Path(temporary) / 'verify.cmake'
            for mode in ['Debug', 'Profile', 'Release']:
                script.write_text(
                    'set(CMAKE_BUILD_TYPE ' + mode + ')\n'
                    'set(FLUTTER_TOOL_ENVIRONMENT "TREE_SHAKE_ICONS=true" "KEPT=value")\n'
                    'include(' + json.dumps(str(ROOT / 'linux/flutter_assets.cmake')) + ')\n'
                    'include(' + json.dumps(str(ROOT / 'linux/flutter_assets.cmake')) + ')\n'
                    'if(NOT FLUTTER_TOOL_ENVIRONMENT STREQUAL "KEPT=value;TREE_SHAKE_ICONS=false")\n'
                    '  message(FATAL_ERROR "Incorrect Flutter asset environment")\nendif()\n')
                subprocess.run(['cmake', '-P', str(script)], check=True,
                               capture_output=True, text=True)

    def test_installed_release_contains_reachable_native_tree_glyphs(self):
        asset = (ROOT / 'build/linux/x64/release/bundle/data/flutter_assets/'
                 'packages/yaru/assets/yaru_icons.otf')
        self.assertTrue(asset.is_file(), 'Build the normal native release first')
        self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(),
                         '17ebce595bdc436d2302d7cfed53704a0b6049593b7c20870940e6c7c9554b96',
                         'Ship the unchanged pinned Yaru 10.2.0 icon font')
        charset = subprocess.check_output(
            ['fc-query', '--format=%{charset}', str(asset)], text=True).split()
        def contains(point):
            for token in charset:
                parts = token.split('-')
                if int(parts[0], 16) <= point <= int(parts[-1], 16):
                    return True
            return False
        for point in [0xe179, 0xe17a, 0xe1a3]:
            self.assertTrue(contains(point), f'Missing native icon U+{point:04X}')


if __name__ == '__main__':
    unittest.main()
