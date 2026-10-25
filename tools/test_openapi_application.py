#!/usr/bin/python3
"""Exercise the actual production Linux entry on owned synthetic OpenAPI files.

Build with `flutter build linux --release --no-pub`, then run with system Python:
`/usr/bin/python3 tools/test_openapi_application.py --version 3.0.4 --edit`.
Add `--project` for the optional busyapi.yaml folder workflow and `--format json`
for JSON. The default is read-only opening/Design inspection.

Real XTest input retains the existing PID, focus, lock, pointer and GTK geometry
checks. The editing journey verifies Design/Source/history, unsaved Reference,
exact Save, Quit and cold reopen. Other application workflows have separate
qualification. Evidence contains only these synthetic files and owned windows.
`--edit --mock-samples` also drives local mock preparation/start/stop and checks
exact generated HTTP bodies both before Quit and after cold reopen.
`--mock-methods` selects a case-sensitive 3.2 additional operation for that journey.
"""
import argparse
import ast
import hashlib
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
from test_file_controls import NativeInput, Gdk, Atspi
from native_focus import (
    private_session_command, private_session_environment, restore_native_environment,
    validate_private_accessibility_address, wait_for_initial_focus,
)


def fixture_sources(version, format, mock_samples=False, mock_methods=False, mock_nested=False):
    swagger = version == '2.0'
    schema = {
        'type': 'object',
        'required': ['id'],
        'properties': {'id': {'type': 'integer', **({'enum': ['EXACT']} if mock_nested else {})}},
        'additionalProperties': False,
        **({'default': {'id': 'EXACT'}} if mock_samples and not mock_nested else {}),
    }
    reference = {'$ref': './model.' + format + '#/Item'}
    response = {
        'description': 'Actual response',
        **({'schema': reference} if swagger else {
            'content': {'application/json': {'schema': reference}},
        }),
    }
    document = {
        'swagger' if swagger else 'openapi': version,
        'info': {'title': 'Production ' + version, 'version': 'api-version'},
        **({
            'host': '127.0.0.1:1',
            'schemes': ['http'],
            'produces': ['application/json'],
        } if swagger else {'servers': [{'url': 'http://127.0.0.1:1'}]}),
        'paths': {'/items': {'get': {
            'operationId': 'getItems',
            'summary': 'Inspect items',
            'responses': {'200': response},
        }}},
    }
    if mock_methods:
        document['paths']['/items'] = {
            'additionalOperations': document['paths']['/items'],
        }
    model = {
        'Item': schema,
        'x-literal': {'$ref': 'literal', 'number': 'EXACT'},
    }
    if format == 'json':
        source = json.dumps(document, ensure_ascii=False, indent=2) + '\r\n'
        shared = json.dumps(model, ensure_ascii=False, indent=2)
        shared = shared.replace('"EXACT"', '9007199254740993.00') + '\r\n'
    else:
        declaration = 'swagger' if swagger else 'openapi'
        server = (
            'host: 127.0.0.1:1\nschemes: [http]\nproduces: [application/json]\n'
            if swagger else 'servers:\n  - url: http://127.0.0.1:1\n'
        )
        body = (
            "          schema:\n            $ref: './model.yaml#/Item'\n"
            if swagger else
            "          content:\n            application/json:\n"
            "              schema:\n                $ref: './model.yaml#/Item'\n"
        )
        operations = (
            '    get:\n'
            '      operationId: getItems\n'
            '      summary: Inspect items\n'
            '      responses:\n'
            "        '200':\n"
            '          description: Actual response\n'
            + body
        )
        if mock_methods:
            operations = '    additionalOperations:\n' + textwrap.indent(operations, '  ')
        source = (
            '# Retain source organization\n'
            f'{declaration}: "{version}"\n'
            'info:\n'
            f"  title: 'Production {version}'\n"
            '  version: api-version\n'
            + server +
            'paths:\n'
            '  /items:\n'
            + operations
        ).replace('\n', '\r\n')
        shared = (
            '# Retain shared model and alias ownership\n'
            'Item: &item\n'
            '  type: object\n'
            '  required: [id]\n'
            '  properties:\n'
            + ('    id: {type: integer, enum: [9007199254740993.00]}\n' if mock_nested
               else '    id: {type: integer}\n') +
            '  additionalProperties: false\n'
            + ('  default: {id: 9007199254740993.00}\n' if mock_samples and not mock_nested else '') +
            'Mirror: *item\n'
            'x-literal:\n'
            '  $ref: literal\n'
            '  number: 9007199254740993.00\n'
            "  text: 'café 東京'\n"
        ).replace('\n', '\r\n')
    return b'\xef\xbb\xbf' + source.encode(), shared.encode()


def tree(pid, details=False):
    desktop = Atspi.get_desktop(0)
    queue = [
        (desktop.get_child_at_index(index), 0)
        for index in range(desktop.get_child_count())
        if desktop.get_child_at_index(index).get_process_id() == pid
    ]
    result = []
    while queue:
        node, depth = queue.pop(0)
        if len(result) >= 2048 or depth > 32:
            raise RuntimeError('Owned accessibility inspection exceeded its bound')
        name = node.get_name()[:512]
        role = node.get_role_name()
        value = None
        caret = None
        editable = False
        if details and role in ['text', 'entry']:
            text = node.get_text_iface()
            if text:
                value = Atspi.Text.get_text(
                    text, 0, min(text.get_character_count(), 1024))
                caret = Atspi.Text.get_caret_offset(text)
            editable = node.get_state_set().contains(Atspi.StateType.EDITABLE)
        result.append({
            'text': value, 'name': name, 'role': role, 'depth': depth,
            'caret': caret,
            'editable': editable,
            'focused': node.get_state_set().contains(Atspi.StateType.FOCUSED),
        })
        count = node.get_child_count()
        if count > 512:
            raise RuntimeError('Owned accessibility child count exceeded its bound')
        queue.extend(((node.get_child_at_index(i), depth + 1) for i in range(count)))
    return result


def field_matches(nodes, name, *, value=None, editable=False, focused=False):
    return any(
        node['name'] == name and (value is None or node['text'] == value)
        and (not editable or node['editable'])
        and (not focused or node['focused'])
        for node in nodes
    )


def contains(nodes, text):
    return any(text in (node['text'] or '') + ' ' + node['name'] for node in nodes)


def design_values(nodes, title, api_version):
    return (
        field_matches(nodes, 'Title', value=title, editable=True)
        and field_matches(nodes, 'API version', value=api_version)
    )


def complete_problems(nodes):
    return any(
        node['name'] == 'Problems · Complete for captured scope · 0'
        for node in nodes
    )


def keys(native, chords):
    for at in range(0, len(chords), 128):
        native.perform({'kind': 'keys', 'chords': chords[at:at + 128]})

def letters(text):
    names = {' ': 'space', '.': 'period', '-': 'minus'}
    return [names.get(character, character) for character in text]

def wait_tree(native, pid, predicate, label):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        native.ready()
        nodes = tree(pid, details=True)
        if predicate(nodes):
            return nodes
        time.sleep(0.1)
    raise RuntimeError(label)

def mode(native, pid, name):
    keys(native, ['Control_L+Shift_L+p'])
    wait_tree(
        native, pid,
        lambda nodes: any(node['editable'] and node['focused'] for node in nodes),
        'Command palette did not expose focused input',
    )
    keys(native, letters(name) + ['Return'])


def quit_application(native, process):
    keys(native, ['Control_L+q'])
    code = process.wait(timeout=15)
    assert code == 0, f'Production Quit failed: exit {code}'
    native.close()


def click_control(native, pid, name):
    nodes = tree(pid, details=True)
    if sum(node['name'] == name for node in nodes) != 1:
        raise RuntimeError('Owned accessibility tree did not expose one ' + name)
    # The fixed viewport has a PID/GTK client-geometry proof in NativeInput.
    # Child component extent RPCs are not needed to acquire coordinate authority.
    points = {'Start Mock': [790, 556], 'Stop': [1236, 407]}
    native.perform({'kind': 'click', 'scale': 1, 'viewport': [1280, 720],
                    'point': points[name]})


def mock_samples(native, process, format, method='GET', nested=False):
    mode(native, process.pid, 'Local mock')
    wait_tree(
        native, process.pid,
        lambda nodes: contains(nodes, 'Ready to start') and contains(nodes, 'Start Mock'),
        'Native mock preparation did not expose its start control',
    )
    click_control(native, process.pid, 'Start Mock')

    def ports(nodes):
        return {
            int(match.group(1))
            for node in nodes
            if (match := re.match(r'^http://127\.0\.0\.1:(\d+)(?=[/\s]|$)', node['name']))
            and 1024 <= int(match.group(1)) <= 65535
        }

    nodes = wait_tree(
        native, process.pid,
        lambda nodes: len(ports(nodes)) == 1 and contains(nodes, 'Running'),
        'Native mock did not expose one controlled loopback listener',
    )
    port = ports(nodes).pop()
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        for _ in range(2):
            native.ready()
            connection.request(method, '/items')
            response = connection.getresponse()
            body = response.read()
            assert response.status == 200, body
            expected = (b'{\n      "id": 9007199254740993.00\n    }'
                        if format == 'json' and not nested else b'{"id":9007199254740993.00}')
            assert body == expected, body
            assert response.getheader('content-length') == str(len(body))
            assert response.getheader('busyapi-response-validation-complete') == 'true'
            assert json.loads(response.getheader('sl-violations') or '[]') == []
    finally:
        connection.close()
    click_control(native, process.pid, 'Stop')
    wait_tree(
        native, process.pid, lambda nodes: contains(nodes, 'Stopped'),
        'Native mock did not finish its explicit stop action',
    )


def edit(native, process, file, fragment, original, version):
    before = original[str(file)]
    shared = original[str(fragment)]
    native.perform({
        'kind': 'click', 'scale': 1, 'point': [700, 250], 'viewport': [1280, 720],
    })
    wait_tree(
        native, process.pid,
        lambda nodes: field_matches(nodes, 'Title', focused=True),
        'Native title did not own focus',
    )
    title = 'edited ' + version
    keys(native, ['Control_L+a'] + letters(title) + ['Tab'])
    wait_tree(
        native, process.pid,
        lambda nodes: field_matches(nodes, 'Title', value=title),
        'Native title draft did not retain typed input',
    )
    keys(native, ['Control_L+s'])
    expected = before.replace(('Production ' + version).encode(), title.encode(), 1)
    deadline = time.monotonic() + 30
    while file.read_bytes() != expected:
        native.ready()
        if time.monotonic() > deadline:
            raise RuntimeError('Native Design save did not preserve the targeted source bytes')
        time.sleep(0.1)
    assert fragment.read_bytes() == shared
    mode(native, process.pid, 'source')

    def source_nodes(nodes):
        return [
            node for node in nodes
            if node['editable'] and 'api-version' in (node['text'] or '')
            and (any(token in (node['text'] or '') for token in [
                '"openapi"', '"swagger"', '\nopenapi:', '\nswagger:',
            ]) or (node['text'] or '').lstrip('\ufeff').startswith(('openapi:', 'swagger:')))
        ]
    wait_tree(native, process.pid, lambda nodes: bool(source_nodes(nodes)), 'Source did not expose the current root')
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: any(node['focused'] for node in source_nodes(nodes)),
        'Source text did not own focus before history navigation')
    keys(native, ['Control_L+z'])
    wait_tree(
        native, process.pid,
        lambda nodes: contains(source_nodes(nodes), 'Production ' + version),
        'One-operation Design undo failed',
    )
    assert file.read_bytes() == expected
    keys(native, ['Control_L+Shift_L+z'])
    nodes = wait_tree(
        native, process.pid, lambda nodes: contains(source_nodes(nodes), title)
        and any(node['focused'] for node in source_nodes(nodes)),
        'One-operation Design redo failed',
    )
    value = source_nodes(nodes)[0]['text']
    offset = value.index('api-version') + len('api-version')
    line = value[:offset].count('\n')
    line_end = value.find('\n', offset)
    suffix = value[offset:line_end if line_end >= 0 else len(value)].rstrip('\r')
    # Each native navigation step settles before the next. Verify the actual
    # caret before typing rather than guessing from rendered source offsets.
    for chord in ['Control_L+Home'] + ['Down'] * line + ['End'] + ['Left'] * len(suffix):
        keys(native, [chord])
    wait_tree(native, process.pid,
        lambda nodes: any(node['focused'] and node['caret'] == offset
                          for node in source_nodes(nodes)),
        'Native Source caret did not reach the API version boundary')
    keys(native, ['2'])
    wait_tree(
        native, process.pid,
        lambda nodes: contains(source_nodes(nodes), 'api-version2'),
        'Native Source edit failed',
    )
    assert file.read_bytes() == expected, 'Unsaved Source edit was published automatically'
    mode(native, process.pid, 'reference')
    wait_tree(
        native, process.pid,
        lambda nodes: contains(nodes, 'api-version2') and contains(nodes, title),
        'Native Reference did not use unsaved buffers',
    )
    assert file.read_bytes() == expected
    keys(native, ['Control_L+s'])
    expected = expected.replace(b'api-version', b'api-version2', 1)
    deadline = time.monotonic() + 30
    while file.read_bytes() != expected:
        native.ready()
        if time.monotonic() > deadline:
            raise RuntimeError('Source publication did not preserve the reviewed bytes')
        time.sleep(0.1)
    mode(native, process.pid, 'design')
    nodes = wait_tree(
        native, process.pid,
        lambda nodes: design_values(nodes, title, 'api-version2'),
        'Saved Design projection did not retain both edits',
    )
    keys(native, ['Control_L+s'])
    assert file.read_bytes() == expected
    assert fragment.read_bytes() == shared
    return (expected, nodes)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--session', action='store_true')
    parser.add_argument('--edit', action='store_true')
    parser.add_argument('--project', action='store_true')
    parser.add_argument('--mock-samples', action='store_true')
    parser.add_argument('--mock-methods', action='store_true')
    parser.add_argument('--mock-nested', action='store_true')
    parser.add_argument('--evidence', type=Path,
                        default=Path('/tmp/busyapi-production-main-evidence'))
    parser.add_argument('--version', default='3.0.4', choices=['3.0.0', '3.0.4', '2.0', '3.1.2', '3.2.0', '3.2.1'])
    parser.add_argument('--format', default='yaml', choices=['yaml', 'json'])
    args = parser.parse_args()
    if args.mock_nested:
        args.mock_samples = True
    if args.mock_methods:
        if not args.version.startswith('3.2.'):
            parser.error('--mock-methods requires an OpenAPI 3.2 root')
        args.mock_samples = True
    if args.mock_samples and not args.edit:
        parser.error('--mock-samples requires --edit for the save/reopen journey')
    if not args.session:
        environment = dict(os.environ, BUSYAPI_NATIVE_DESKTOP_BUS=os.environ['DBUS_SESSION_BUS_ADDRESS'])
        with tempfile.TemporaryDirectory(prefix='busyapi-main-runtime-') as runtime:
            command = [
                *private_session_command(runtime), sys.executable, __file__,
                '--session', '--version', args.version, '--format', args.format,
                '--evidence', str(args.evidence),
                *(['--edit'] if args.edit else []),
                *(['--project'] if args.project else []),
                *(['--mock-samples'] if args.mock_samples else []),
                *(['--mock-methods'] if args.mock_methods else []),
                *(['--mock-nested'] if args.mock_nested else []),
            ]
            return subprocess.run(
                command, env=private_session_environment(environment, runtime),
                timeout=90,
            ).returncode
    response = subprocess.run([
        'gdbus', 'call', '--session', '--dest', 'org.a11y.Bus',
        '--object-path', '/org/a11y/bus', '--method', 'org.a11y.Bus.GetAddress',
    ], check=True, capture_output=True, text=True, timeout=10)
    value = ast.literal_eval(response.stdout)
    if not isinstance(value, tuple) or len(value) != 1 or (not isinstance(value[0], str)):
        raise RuntimeError('Invalid private accessibility identity')
    validate_private_accessibility_address(value[0], os.environ)
    restore_native_environment(os.environ)
    os.environ['AT_SPI_BUS_ADDRESS'] = value[0]
    if not Gdk.init_check([])[0]:
        raise RuntimeError('Native display unavailable')
    evidence = args.evidence
    if not evidence.is_absolute():
        raise RuntimeError('Evidence directory must be absolute')
    evidence.mkdir(mode=0o700, exist_ok=True)
    if (evidence.is_symlink() or evidence.stat().st_uid != os.getuid()
            or evidence.stat().st_mode & 0o077):
        raise RuntimeError('Unowned evidence directory')
    with tempfile.TemporaryDirectory(prefix='busyapi-prod-main-') as temporary:
        directory = Path(temporary)
        project_directory = directory / 'project'
        project_directory.mkdir()
        case = (
            args.version + '-' + args.format
            + ('-project' if args.project else '-standalone')
            + ('-journey' if args.edit else '')
            + ('-mock-samples' if args.mock_samples else '')
            + ('-methods' if args.mock_methods else '')
            + ('-nested' if args.mock_nested else '')
        )
        file = project_directory / ('api.' + args.format)
        fragment = project_directory / ('model.' + args.format)
        source, shared = fixture_sources(args.version, args.format, args.mock_samples, args.mock_methods, args.mock_nested)
        file.write_bytes(source)
        fragment.write_bytes(shared)
        files = [file, fragment]
        if args.project:
            manifest = project_directory / 'busyapi.yaml'
            manifest.write_bytes((
                'version: 1\r\n# Retain project options\r\n'
                f'roots: [{{name: api, path: api.{args.format}}}]\r\n'
            ).encode())
            files.append(manifest)
        original = {str(p): p.read_bytes() for p in files}
        startup = project_directory if args.project else file
        env = dict(os.environ, LC_ALL='C.UTF-8', **{
            key: str(directory / 'profile' / name)
            for key, name in [
                ('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state'),
                ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data'),
            ]
        })
        original_hashes = {
            Path(name).name: hashlib.sha256(raw).hexdigest()
            for name, raw in original.items()
        }
        expected_sources = dict(original)
        binary = ROOT / 'build/linux/x64/release/bundle/busyapi-desktop'
        log = evidence / (case + '.log')
        with log.open('w') as stream:
            process = subprocess.Popen([str(binary), str(startup)], stdout=stream, stderr=subprocess.STDOUT, env=env)
            native = None
            try:
                native = NativeInput(process.pid)
                wait_for_initial_focus(native.ready, timeout=8)
                time.sleep(1)
                window = native.ready()
                width, height = native.dimensions(window)
                initial = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
                if initial is None:
                    raise RuntimeError('Owned initial screenshot unavailable')
                initial.savev(str(evidence / (case + '-initial.png')), 'png', [], [])
                deadline = time.monotonic() + 30
                nodes = []
                while time.monotonic() < deadline:
                    nodes = tree(process.pid)
                    if (contains(nodes, 'format version: ' + args.version)
                            and complete_problems(nodes)):
                        break
                    if process.poll() is not None:
                        raise RuntimeError('Production entry exited before inspection')
                    time.sleep(0.1)
                else:
                    (evidence / (case + '-incomplete.json')).write_text(
                        json.dumps(nodes, indent=2, ensure_ascii=False) + '\n')
                    raise RuntimeError('Production contract was not exposed by the owned accessibility tree')
                window = native.ready()
                width, height = native.dimensions(window)
                loaded = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
                if loaded is None:
                    raise RuntimeError('Owned loaded screenshot unavailable')
                loaded.savev(str(evidence / (case + '-loaded.png')), 'png', [], [])
                nodes = tree(process.pid, details=True)
                assert field_matches(
                    nodes, 'Title', value='Production ' + args.version, editable=True,
                ), 'Native title is not editable with its captured value'
                assert field_matches(
                    nodes, 'API version', value='api-version',
                ), 'API and specification versions were conflated'
                for name, raw in original.items():
                    assert Path(name).read_bytes() == raw, 'Opening changed source'
                if args.edit:
                    edited, nodes = edit(native, process, file, fragment, original, args.version)
                    expected_sources[str(file)] = edited
                    if args.mock_samples:
                        mock_samples(native, process, args.format, 'get' if args.mock_methods else 'GET', args.mock_nested)
                    quit_application(native, process)
                    native = None
                    process = subprocess.Popen(
                        [str(binary), str(startup)], stdout=stream,
                        stderr=subprocess.STDOUT, env=env,
                    )
                    native = NativeInput(process.pid)
                    wait_for_initial_focus(native.ready, timeout=8)
                    nodes = wait_tree(
                        native, process.pid,
                        lambda nodes: design_values(
                            nodes, 'edited ' + args.version, 'api-version2',
                        ) and complete_problems(nodes),
                        'Production reopen did not retain the saved native contract',
                    )
                    assert (
                        args.project or not (project_directory / 'busyapi.yaml').exists()
                    ), 'Standalone editing created a project wrapper'
                    if args.mock_samples:
                        mock_samples(native, process, args.format, 'get' if args.mock_methods else 'GET', args.mock_nested)
                window = native.ready()
                width, height = native.dimensions(window)
                pixels = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
                if pixels is None:
                    raise RuntimeError('Owned production screenshot unavailable')
                pixels.savev(str(evidence / (case + '.png')), 'png', [], [])
                report = {
                    'version': args.version, 'format': args.format,
                    'project': args.project, 'originalFiles': original_hashes,
                    'workflow': (
                        'production-main-design-source-reference-save-history-quit-reopen'
                        if args.edit else 'production-main-open-design-inspection-quit'
                    ),
                    'complete': True, 'nodes': nodes,
                    'nativeMockSamples': args.mock_samples,
                    'nativeMockMethods': args.mock_methods,
                    'nativeMockNested': args.mock_nested,
                    'files': {
                        str(Path(name).relative_to(project_directory)):
                            hashlib.sha256(raw).hexdigest()
                        for name, raw in expected_sources.items()
                    },
                }
                for name, raw in expected_sources.items():
                    assert Path(name).read_bytes() == raw, 'Source differs from targeted changes'
                quit_application(native, process)
                native = None
                for name, raw in expected_sources.items():
                    assert Path(name).read_bytes() == raw, 'Quit changed source'
                destination = evidence / (case + '.json')
                destination.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
                print(json.dumps({
                    'report': str(destination), 'nodes': len(nodes),
                    'sourceUnchanged': not args.edit, 'untouchedSourcePreserved': True,
                }), flush=True)
            except Exception:
                for label, path in [('api', file), ('model', fragment)]:
                    (evidence / (case + '-failure-' + label + '.txt')).write_bytes(path.read_bytes())
                (evidence / (case + '-failure-original.txt')).write_bytes(original[str(file)])
                try:
                    native.ready()
                    failed = tree(process.pid, details=True)
                    (evidence / (case + '-failure-controls.json')).write_text(
                        json.dumps(failed, indent=2, ensure_ascii=False) + '\n')
                    window = native.ready()
                    width, height = native.dimensions(window)
                    pixels = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
                    if pixels:
                        pixels.savev(str(evidence / (case + '-failure.png')), 'png', [], [])
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
if __name__ == '__main__':
    sys.exit(main())
