"""Path-selection unit tests; these do not execute or qualify widget tests."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WidgetRunnerPathTests(unittest.TestCase):
    def test_sdk_resolution_through_path_explicit_path_and_symlink(self):
        script = Path(__file__).with_name('test_widgets_local.sh')
        for selection in ('default', 'command', 'absolute', 'symlink'):
            with self.subTest(selection=selection), tempfile.TemporaryDirectory(prefix='busyapi-widget-path-') as folder:
                root = Path(folder)
                project, sdk = root / 'project', root / 'Flutter SDK 雪'
                (project / 'tools').mkdir(parents=True)
                (project / 'test').mkdir()
                (project / 'test/path_test.dart').write_text('void main() {}\n')
                shutil.copy2(script, project / 'tools/test_widgets_local.sh')
                (sdk / 'bin/cache/dart-sdk/bin').mkdir(parents=True)
                (sdk / 'bin/cache/artifacts/engine/linux-x64').mkdir(parents=True)
                flutter = sdk / 'bin/flutter'
                flutter.write_text('#!/bin/sh\nexit 0\n')
                flutter.chmod(0o755)
                # Deliberate unit-test stubs: only verify which SDK executable
                # the shell selects, never report them as real widget results.
                stub = '#!/usr/bin/python3\nimport os,sys\nfrom pathlib import Path\nwith Path(os.environ["BUSYAPI_PATH_SELECTION_LOG"]).open("a") as f: f.write(str(Path(sys.argv[0]).resolve())+"\\n")\n'
                executables = [sdk / 'bin/cache/dart-sdk/bin/dartaotruntime', sdk / 'bin/cache/artifacts/engine/linux-x64/flutter_tester']
                for executable in executables:
                    executable.write_text(stub)
                    executable.chmod(0o755)
                links = root / 'links'
                links.mkdir()
                (links / 'flutter').symlink_to(flutter)
                log = root / 'selected.txt'
                env = dict(os.environ, PATH=str(links if selection == 'symlink' else sdk / 'bin') + os.pathsep + os.environ['PATH'], BUSYAPI_PATH_SELECTION_LOG=str(log))
                env.pop('BUSYAPI_TEST_NAME', None)
                env.pop('BUSYAPI_FLUTTER', None)
                if selection == 'command':
                    env['BUSYAPI_FLUTTER'] = 'flutter'
                elif selection == 'absolute':
                    env['BUSYAPI_FLUTTER'] = str(flutter)
                subprocess.run(['bash', str(project / 'tools/test_widgets_local.sh')], cwd=root, env=env, check=True, capture_output=True, text=True, timeout=20)
                self.assertEqual(log.read_text().splitlines(), [str(path) for path in executables])


if __name__ == '__main__':
    unittest.main()
