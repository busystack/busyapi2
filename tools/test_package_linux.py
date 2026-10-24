"""Packaging must reject an incomplete Flutter-only bundle before copying libs."""
import pathlib
import os
import subprocess
import sys
import tempfile
import unittest

REQUIRED = ['busyapi-desktop','busyapi','libexec/busyapi/node','libexec/busyapi/engine.cjs',
            'libexec/busyapi/policy-worker.cjs','lib/libbusyapi_documentation.so',
            'share/busyapi/documentation-runtime.json','libexec/busyapi/policy-isolation.node',
            'libexec/busyapi/policy-launcher','libexec/busyapi/policy-build.json',
            'libexec/busyapi/mock-server.cjs','libexec/busyapi/oasdiff','libexec/busyapi/build.json',
            'libexec/busyapi/generator/assets.json','libexec/busyapi/generator/openapi-generator.jar',
            'libexec/busyapi/generator/jre/bin/java','libexec/busyapi/generator/generator-launcher']


def prerequisite_files(bundle, extra=()):
    # These tests reach a later boundary deliberately; incomplete unrelated
    # fixtures must not fail at a newly installed earlier production component.
    for name in [*REQUIRED,*extra]:
        file=bundle/name
        file.parent.mkdir(parents=True,exist_ok=True)
        file.touch()


class StandaloneAssets(unittest.TestCase):
    def test_distribution_choices_fail_before_toolchain_or_source_collection(self):
        for extra, expected in [
            ({'BUSYAPI_DISTRIBUTION': 'unsupported'}, 'Choose BUSYAPI_DISTRIBUTION'),
            ({'BUSYAPI_DISTRIBUTION': 'snap', 'BUSYAPI_NATIVE_SOURCE_INDEX': 'not-a-platform-inventory'},
             'standalone copied-library source companion is not a Snap platform inventory'),
        ]:
            with self.subTest(extra=extra):
                environment = {key: value for key, value in os.environ.items() if not key.startswith('BUSYAPI_')}
                environment.update(BUSYAPI_NODE='/deliberately/unavailable', **extra)
                result = subprocess.run(['bash', str(pathlib.Path(__file__).with_name('build_linux.sh'))],
                                        env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_platform_runtime_refuses_a_previously_assembled_standalone_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            marker = bundle / 'share/licenses/busyapi-native/dependencies.json'
            marker.parent.mkdir(parents=True)
            marker.write_text('{}')
            result = subprocess.run([sys.executable,
                str(pathlib.Path(__file__).with_name('package_linux.py')),
                directory, '--platform-runtime'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires a fresh CMake install', result.stderr)
            self.assertEqual(marker.read_text(), '{}')

    def test_platform_runtime_keeps_missing_asset_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable,
                str(pathlib.Path(__file__).with_name('package_linux.py')),
                directory, '--platform-runtime'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing standalone asset: busyapi-desktop', result.stderr)

    def test_missing_cli_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            (bundle / 'busyapi-desktop').touch()
            result = subprocess.run(
                [sys.executable, str(pathlib.Path(__file__).with_name('package_linux.py')),
                 directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing standalone asset: busyapi', result.stderr)

    def test_missing_schemas_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            prerequisite_files(bundle)
            result = subprocess.run(
                [sys.executable, str(pathlib.Path(__file__).with_name('package_linux.py')),
                 directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing standalone schema asset: oas31.json', result.stderr)

    def test_missing_oas32_is_an_error_with_oas31_present(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            prerequisite_files(bundle,['share/busyapi/schemas/oas31.json'])
            result = subprocess.run(
                [sys.executable, str(pathlib.Path(__file__).with_name('package_linux.py')),
                 directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing standalone schema asset: oas32.json', result.stderr)

    def test_provenance_cannot_link_to_the_build_stage(self):
        for absolute in [True, False]:
            with self.subTest(absolute=absolute), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                bundle = root / 'bundle'
                prerequisite_files(bundle,['share/busyapi/schemas/oas31.json','share/busyapi/schemas/oas32.json','share/busyapi/schemas/oas30.json'])
                outside = root / 'build-stage'
                outside.mkdir()
                link = bundle / 'share/busyapi/flutter-engine'
                link.symlink_to(outside if absolute else '../../../build-stage',
                                target_is_directory=True)
                result = subprocess.run(
                    [sys.executable, str(pathlib.Path(__file__).with_name('package_linux.py')),
                     str(bundle)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Non-relocatable bundle symlink', result.stderr)

    def test_missing_oas30_is_an_error_with_modern_schemas_present(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory)
            prerequisite_files(bundle, ['share/busyapi/schemas/oas31.json', 'share/busyapi/schemas/oas32.json'])
            result = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('package_linux.py')), directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing standalone schema asset: oas30.json', result.stderr)


if __name__ == '__main__':
    unittest.main()
