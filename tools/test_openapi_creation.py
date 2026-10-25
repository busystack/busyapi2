#!/usr/bin/python3
"""Qualify production Create Project, its real GTK chooser and safe publication.

Run after the ordinary production Linux build, with system Python and an unlocked
desktop. All input uses the existing owned-window guards. Only this invocation's
synthetic temporary directories are selected; no chooser contents are captured.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import test_openapi_application as app
from native_focus import (
    private_session_command, private_session_environment, restore_native_environment,
    validate_private_accessibility_address, wait_for_initial_focus,
)


VERSIONS = ('2.0', '3.0.4', '3.1.2', '3.2.1')


text_keys = app.text_keys


def select_directory(native, process, destination, *, cancel=False):
    app.mode(native, process.pid, 'Create Project')
    with native.transient_dialog():
        if cancel:
            app.keys(native, ['Escape'])
        else:
            app.keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)))
            app.keys(native, ['Return'])
    wait_for_initial_focus(native.ready, timeout=8)


def form(native, process):
    return app.wait_tree(native, process.pid,
        lambda nodes: app.field_matches(nodes, 'Name', value='api', editable=True)
        and app.contains(nodes, 'Create Project'), 'Creation form did not appear')


def click(native, process, name, point):
    nodes = app.tree(process.pid, details=True)
    if sum(node['name'] == name for node in nodes) != 1:
        raise RuntimeError('Creation did not expose one owned control: ' + name)
    native.perform({'kind': 'click', 'scale': 1, 'viewport': [1280, 720],
                    'point': point})


def text(native, process, label, value):
    for _ in range(24):
        nodes = app.tree(process.pid, details=True)
        if app.field_matches(nodes, label, editable=True, focused=True):
            app.keys(native, ['Control_L+a'] + text_keys(value))
            app.wait_tree(native, process.pid,
                lambda nodes: app.field_matches(nodes, label, value=value, focused=True),
                'Creation input did not retain ' + label)
            return
        app.keys(native, ['Tab'])
    raise RuntimeError('Creation keyboard traversal did not focus ' + label)


def combo(native, process, label, value, choices, point):
    click(native, process, label, point)
    app.wait_tree(native, process.pid,
        lambda nodes: all(app.contains(nodes, choice) for choice in choices),
        'Creation choices did not expose the approved options')
    app.keys(native, ['Home'] + ['Down'] * choices.index(value) + ['Return'])


def unchanged(original):
    for path, raw in original.items():
        assert path.read_bytes() == raw, 'Creation overwrote an original or collision file'


def generated_source(version, format):
    data = {'swagger' if version == '2.0' else 'openapi': version,
            'info': {'title': 'Production ' + version, 'version': 'api-version'},
            'paths': {}}
    if format == 'json':
        return (json.dumps(data, indent=2) + '\n').encode()
    declaration = 'swagger' if version == '2.0' else 'openapi'
    return (f'{declaration}: "{version}"\ninfo:\n'
            f'  title: "Production {version}"\n'
            '  version: "api-version"\npaths: {}\n').encode()


def snapshot(native, destination):
    window = native.ready()
    width, height = native.dimensions(window)
    pixels = app.Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
    if pixels is None:
        raise RuntimeError('Owned creation screenshot unavailable')
    pixels.savev(str(destination), 'png', [], [])


def journey(args):
    evidence = args.evidence
    if not evidence.is_absolute():
        raise RuntimeError('Evidence directory must be absolute')
    evidence.mkdir(mode=0o700, exist_ok=True)
    if (evidence.is_symlink() or evidence.stat().st_uid != os.getuid()
            or evidence.stat().st_mode & 0o077):
        raise RuntimeError('Unowned evidence directory')
    binary = app.ROOT / 'build/linux/x64/release/bundle/busyapi-desktop'
    case = args.version + '-' + args.format + '-creation'
    with tempfile.TemporaryDirectory(prefix='busyapi-native-creation-') as temporary:
        directory = Path(temporary)
        existing = directory / 'original'
        existing.mkdir()
        root = existing / ('api.' + args.format)
        fragment = existing / ('model.' + args.format)
        source, model = app.fixture_sources(args.version, args.format)
        root.write_bytes(source)
        fragment.write_bytes(model)
        destination = directory / 'destination'
        destination.mkdir()
        collision = destination / 'api'
        collision_file = collision / ('openapi.' + args.format)
        original = {path: path.read_bytes() for path in [root, fragment]}
        env = dict(os.environ, LC_ALL='C.UTF-8', **{
            key: str(directory / 'profile' / name)
            for key, name in [('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state'),
                              ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]
        })
        log = evidence / (case + '.log')
        with log.open('w') as stream:
            process = subprocess.Popen([str(binary), str(root)], env=env,
                stdout=stream, stderr=subprocess.STDOUT)
            native = None
            try:
                native = app.NativeInput(process.pid)
                wait_for_initial_focus(native.ready, timeout=8)
                app.wait_tree(native, process.pid,
                    lambda nodes: app.design_values(nodes, 'Production ' + args.version, 'api-version')
                    and app.complete_problems(nodes), 'Original contract did not open')
                select_directory(native, process, destination, cancel=True)
                app.wait_tree(native, process.pid,
                    lambda nodes: app.design_values(nodes, 'Production ' + args.version, 'api-version'),
                    'Chooser cancellation did not return to the original contract')
                unchanged(original)
                assert list(destination.iterdir()) == []
                print('BUSYAPI_NATIVE_CREATION chooser-cancel=passed', flush=True)
                select_directory(native, process, destination)
                form(native, process)
                text(native, process, 'Title', 'discarded creation')
                click(native, process, 'Cancel', [768, 543])
                app.wait_tree(native, process.pid,
                    lambda nodes: not app.contains(nodes, 'Create Project')
                    and app.design_values(nodes, 'Production ' + args.version, 'api-version'),
                    'Form cancellation did not return to the original contract')
                unchanged(original)
                assert list(destination.iterdir()) == []
                print('BUSYAPI_NATIVE_CREATION form-cancel=passed', flush=True)
                select_directory(native, process, destination)
                form(native, process)
                # Introduce the collision after selection, before publication:
                # the initializer must recheck rather than trust the chooser.
                collision.mkdir()
                collision_file.write_bytes(b'Owned collision sentinel\x00\r\n')
                original[collision_file] = collision_file.read_bytes()
                text(native, process, 'Title', 'Production ' + args.version)
                text(native, process, 'API version', 'api-version')
                combo(native, process, 'OpenAPI format version', args.version,
                      VERSIONS, [800, 410])
                combo(native, process, 'Format', args.format, ('yaml', 'json'), [800, 465])
                click(native, process, 'Apply', [850, 543])
                app.wait_tree(native, process.pid,
                    lambda nodes: app.contains(nodes, 'init.collision')
                    and app.field_matches(nodes, 'Title', value='Production ' + args.version),
                    'Creation collision did not preserve the form and report its failure')
                unchanged(original)
                assert sorted(path.name for path in collision.iterdir()) == [collision_file.name]
                print('BUSYAPI_NATIVE_CREATION collision=preserved', flush=True)
                text(native, process, 'Name', 'created')
                click(native, process, 'Apply', [850, 543])
                app.wait_tree(native, process.pid,
                    lambda nodes: app.design_values(nodes, 'Production ' + args.version, 'api-version')
                    and app.complete_problems(nodes) and not app.contains(nodes, 'Create Project'),
                    'Created contract did not open with complete validation')
                created_directory = destination / 'created'
                created = created_directory / ('openapi.' + args.format)
                manifest = created_directory / 'busyapi.yaml'
                assert sorted(path.name for path in created_directory.iterdir()) == [
                    'busyapi.yaml', 'openapi.' + args.format]
                expected = generated_source(args.version, args.format)
                assert created.read_bytes() == expected, 'Wizard published a different family, format or value'
                manifest_source = b'version: 1\nroots:\n  - name: main\n    path: openapi.' + args.format.encode() + b'\n'
                assert manifest.read_bytes() == manifest_source
                print('BUSYAPI_NATIVE_CREATION published=' + args.version + '-' + args.format, flush=True)
                # The existing editing journey proves localized source changes,
                # one-operation history, unsaved Reference and exact no-op save.
                expected, nodes = app.edit(native, process, created, fragment,
                    {str(created): expected, str(fragment): model}, args.version)
                assert manifest.read_bytes() == manifest_source
                unchanged(original)
                print('BUSYAPI_NATIVE_CREATION authoring-history-save=passed', flush=True)
                snapshot(native, evidence / (case + '-edited.png'))
                app.quit_application(native, process)
                native = None
                standalone = directory / 'standalone'
                standalone.mkdir()
                copied = standalone / created.name
                copied.write_bytes(expected)
                for startup in [created_directory, copied]:
                    process = subprocess.Popen([str(binary), str(startup)], env=env,
                        stdout=stream, stderr=subprocess.STDOUT)
                    native = app.NativeInput(process.pid)
                    wait_for_initial_focus(native.ready, timeout=8)
                    nodes = app.wait_tree(native, process.pid,
                        lambda nodes: app.design_values(nodes, 'edited ' + args.version, 'api-version2')
                        and app.complete_problems(nodes), 'Created contract did not reopen')
                    app.keys(native, ['Control_L+s'])
                    assert created.read_bytes() == expected and copied.read_bytes() == expected
                    assert manifest.read_bytes() == manifest_source
                    assert not (standalone / 'busyapi.yaml').exists()
                    app.quit_application(native, process)
                    native = None
                    unchanged(original)
                report = {'complete': True, 'version': args.version, 'format': args.format,
                    'workflow': 'production-create-real-chooser-cancel-collision-edit-history-reference-save-project-standalone-reopen',
                    'normalQuitCount': 3, 'originalsPreserved': True,
                    'sourceSha256': hashlib.sha256(expected).hexdigest(), 'nodes': nodes}
                output = evidence / (case + '.json')
                output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
                print(json.dumps({'report': str(output), 'complete': True}), flush=True)
            except Exception:
                (evidence / (case + '-failure-files.json')).write_text(json.dumps({
                    str(path.relative_to(directory)): {
                        'bytes': path.stat().st_size,
                        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    } for path in directory.rglob('*') if path.is_file()
                    and 'profile' not in path.relative_to(directory).parts
                }, indent=2) + '\n')
                if native:
                    try:
                        native.ready()
                        nodes = app.tree(process.pid, details=True)
                        (evidence / (case + '-failure-controls.json')).write_text(
                            json.dumps(nodes, indent=2, ensure_ascii=False) + '\n')
                        snapshot(native, evidence / (case + '-failure.png'))
                    except Exception as diagnostic:
                        print('Owned failure capture unavailable: ' + type(diagnostic).__name__, flush=True)
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
                if native:
                    native.close()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', action='store_true')
    parser.add_argument('--version', choices=VERSIONS, default='3.0.4')
    parser.add_argument('--format', choices=('yaml', 'json'), default='yaml')
    parser.add_argument('--evidence', type=Path, default=Path('/tmp/busyapi-native-creation-evidence'))
    args = parser.parse_args()
    if not args.session:
        env = dict(os.environ, BUSYAPI_NATIVE_DESKTOP_BUS=os.environ['DBUS_SESSION_BUS_ADDRESS'])
        with tempfile.TemporaryDirectory(prefix='busyapi-native-creation-runtime-') as runtime:
            return subprocess.run([
                *private_session_command(runtime), sys.executable, __file__, '--session',
                '--version', args.version, '--format', args.format, '--evidence', str(args.evidence)],
                env=private_session_environment(env, runtime), timeout=180).returncode
    response = subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
        '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress'],
        check=True, capture_output=True, text=True, timeout=10)
    value = ast.literal_eval(response.stdout)
    if not isinstance(value, tuple) or len(value) != 1 or not isinstance(value[0], str):
        raise RuntimeError('Invalid private accessibility identity')
    validate_private_accessibility_address(value[0], os.environ)
    restore_native_environment(os.environ)
    os.environ['AT_SPI_BUS_ADDRESS'] = value[0]
    if not app.Gdk.init_check([])[0]:
        raise RuntimeError('Native display unavailable')
    return journey(args)


if __name__ == '__main__':
    sys.exit(main())
