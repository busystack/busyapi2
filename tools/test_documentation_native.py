#!/usr/bin/env python3
"""Compile/run the real GTK3/WebKit window tests, with sandbox and AT-SPI on.

Uses a normal private D-Bus test session; does not change the desktop, input
methods, WebKit sandbox, GTK backend, global configuration or native libraries.
Windows do not request focus. This is not performance/strict-Snap acceptance.
"""
import argparse
import ast
from contextlib import nullcontext
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

from native_focus import (private_session_command, private_session_environment, restore_native_environment,
                          validate_private_accessibility_address)

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--trace', action='store_true', help='Fixture-only load/resource diagnostics')
    parser.add_argument('--renderers', action='store_true', help='Also qualify the exact development renderer candidates in WebKit')
    parser.add_argument('--production', action='store_true', help='Qualify both actual installed renderer assets and core-captured native pages')
    parser.add_argument('--cli', type=Path, default=ROOT / 'build/test-runtime/busyapi', help='Exact bundled CLI whose installed assets are tested')
    parser.add_argument('--runtime-module', type=Path, help='Exercise the ordinary installed documentation module through its real on-demand loader')
    parser.add_argument('--prepare', type=Path, help='Prepare a new owned fixture directory without launching it (for actual confined runtime testing; never shipped)')
    parser.add_argument('--case', choices=['ordinary', 'adversarial', 'crash-reopen', 'cancel-loading', 'invalid-resources', 'ephemeral-storage', 'outdated-snapshot', 'swagger-31', 'swagger-32', 'redoc-31', 'redoc-32', 'redoc-production-31', 'redoc-production-32', 'swagger-production-31', 'swagger-production-32'], help='Run one native host/renderer case')
    args = parser.parse_args()
    if args.prepare and args.session:
        parser.error('Fixture preparation and execution are separate operations')
    if args.prepare and (args.prepare.parent != Path('/tmp') or not args.prepare.name.startswith('busyapi-documentation-native-')):
        parser.error('Prepare fixtures only in a new /tmp/busyapi-documentation-native-* directory')
    renderer_case = bool(args.case and args.case.startswith(('swagger-', 'redoc-')))
    production_case = bool(args.case and '-production-' in args.case)
    if production_case and not args.production:
        parser.error('Production renderer cases require --production')
    if renderer_case and not production_case and not args.renderers:
        parser.error('Renderer cases require --renderers')
    if args.session:
        # GTK's early modules must see the private accessibility bus before
        # exec. Do not disable the bridge or alter the desktop X11 property.
        response = subprocess.run([
            'gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
            '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress',
        ], check=True, capture_output=True, text=True, timeout=10)
        value = ast.literal_eval(response.stdout)
        if not isinstance(value, tuple) or len(value) != 1 or not isinstance(value[0], str) or not value[0].startswith('unix:'):
            raise RuntimeError('Invalid private accessibility-bus identity')
        validate_private_accessibility_address(value[0], os.environ)
        restore_native_environment(os.environ)
        os.environ['AT_SPI_BUS_ADDRESS'] = value[0]
        if args.trace:
            os.environ['BUSYAPI_DOCUMENTATION_TEST_TRACE'] = '1'
        if args.renderers:
            os.environ['BUSYAPI_DOCUMENTATION_RENDERER_FIXTURES'] = str(args.session.parent / 'renderer-assets')
        if args.production:
            os.environ['BUSYAPI_DOCUMENTATION_PRODUCTION_FIXTURES'] = str(args.session.parent / 'renderer-assets')
        os.execv(args.session, [str(args.session), *(['-p', ('/renderers/' if renderer_case else '/documentation/') + args.case] if args.case else [])])
    flags = shlex.split(subprocess.check_output([
        'pkg-config', '--cflags', '--libs', 'webkit2gtk-4.1',
    ], text=True))
    if args.prepare:
        # A fixture can be transferred into the Snap's own executable data
        # directory without changing its installed application or profile.
        # Copy the module verbatim; the installed-loader/byte identity check
        # remains separate from actual process-confinement observation.
        args.prepare = args.prepare.absolute()
        args.prepare.mkdir(mode=0o700)
    directory = nullcontext(str(args.prepare)) if args.prepare else tempfile.TemporaryDirectory(prefix='busyapi-documentation-native-')
    with directory as staging:
        executable = Path(staging) / 'window-tests'
        module_flags = []
        implementation = ROOT / 'linux/runner/documentation_window.cc'
        if args.runtime_module:
            module = args.runtime_module.absolute()
            if module.is_symlink() or not module.is_file():
                raise RuntimeError('Choose an ordinary installed documentation module')
            (Path(staging) / 'lib').mkdir()
            shutil.copyfile(module, Path(staging) / 'lib/libbusyapi_documentation.so')
            implementation = ROOT / 'linux/runner/documentation_runtime.cc'
            module_flags = ['-DBUSYAPI_DOCUMENTATION_TEST_MODULE', *shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gmodule-2.0'], text=True))]
        subprocess.run([
            'c++', '-std=c++17', '-Wall', '-Werror',
            str(implementation),
            str(ROOT / 'linux/runner/documentation_window_test.cc'),
            '-o', str(executable), *flags, *module_flags,
        ], check=True, cwd=ROOT)
        if args.renderers:
            build_environment = dict(os.environ)
            build_environment['BUSYAPI_DOCUMENTATION_TEST_TRACE'] = '1' if args.trace else '0'
            subprocess.run(['node', str(ROOT / 'tools/documentation_renderers/test_native_fixtures.mjs'), str(Path(staging) / 'renderer-assets')], check=True, cwd=ROOT, timeout=30, env=build_environment)
        if args.production:
            dart = os.environ.get('BUSYAPI_DART') or shutil.which('dart')
            if not dart or '3.13.4' not in subprocess.check_output([dart, '--version'], text=True):
                raise RuntimeError('Set BUSYAPI_DART to the pinned Dart 3.13.4 SDK for production fixture capture')
            for family in ['31', '32']:
                source = Path(staging) / ('source-' + family)
                source.mkdir()
                shutil.copyfile(ROOT / ('fixtures/compatibility/oas' + family + '.json'), source / 'root.json')
                shutil.copyfile(ROOT / 'fixtures/compatibility/schema.json', source / 'schema.json')
                for preset in ['redoc', 'swagger']:
                    subprocess.run([dart, 'run', 'tool/native_documentation_fixture.dart', str(args.cli), str(source / 'root.json'), str(Path(staging) / 'renderer-assets' / (preset + '-production-' + family))], check=True, cwd=ROOT / 'packages/busyapi_core', timeout=45)
        if args.prepare:
            print('Prepared test-only fixture: ' + str(executable))
            print('Run with BUSYAPI_DOCUMENTATION_PRODUCTION_FIXTURES=' + str(Path(staging) / 'renderer-assets') if args.production else 'No production renderer fixtures requested')
            return 0
        command = [sys.executable, str(Path(__file__).resolve()), '--session', str(executable)]
        if args.trace:
            command.append('--trace')
        if args.renderers:
            command.append('--renderers')
        if args.production:
            command.append('--production')
        if args.case:
            command.extend(['--case', args.case])
        runtime = Path(staging) / 'runtime'
        runtime.mkdir(mode=0o700)
        return subprocess.run([*private_session_command(runtime), *command], cwd=ROOT, env=private_session_environment(os.environ, runtime), timeout=180).returncode


if __name__ == '__main__':
    sys.exit(main())
