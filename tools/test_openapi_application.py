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
`--documentation` reviews, cancels and publishes native HTML from an unsaved
working copy, independently checks its source ranges, then restores saved input.
`--migrate-target VERSION` separately reviews and publishes a
migrated copy, checks a destination race and reopens the target before returning
to the original source. JSON targets additionally reopen without a manifest.
`--multipart ordered|nested` sends exact and rounded serialized 3.2 examples.
`--multipart named` generates older-family named MIME and edits its exact body
draft through keyboard input. Both exercise the production request panel before
Quit and after cold reopen.
"""
import argparse
import signal
import ast
import hashlib
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
from contextlib import ExitStack
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
from test_file_controls import NativeInput, Gdk, Atspi
from native_focus import (
    private_session_command, private_session_environment, restore_native_environment,
    validate_private_accessibility_address, wait_for_initial_focus,
)


def fixture_sources(version, format, mock_samples=False, mock_methods=False, mock_nested=False, schema_definitions=False, multipart=None):
    swagger = version == '2.0'
    schema = {
        'type': 'object',
        'required': ['id'],
        'properties': {'id': {'type': 'integer', **({'enum': ['EXACT']} if mock_nested or multipart else {})}},
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
    if multipart:
        if swagger:
            document['host'] = '127.0.0.1:' + str(multipart.port)
        else:
            document['servers'] = [{'url': 'http://127.0.0.1:' + str(multipart.port)}]
        document['paths']['/items'] = {'post': multipart.operation(format)}
    if mock_methods:
        document['paths']['/items'] = {
            'additionalOperations': document['paths']['/items'],
        }
    model = {
        'Item': schema,
        'x-literal': {'$ref': 'literal', 'number': 'EXACT'},
    }
    if swagger and multipart:
        model['File'] = {'type': 'file'}
    if getattr(multipart, 'header_content', False):
        model['Meta'] = multipart.header()
    if schema_definitions:
        document['components'] = {'schemas': {
            'Envelope': {'$ref': './model.' + format + '#/Envelope'},
            'Use': {'$ref': './model.' + format + '#/Envelope/$defs/Old'},
        }}
        model['Envelope'] = {'type': 'object', '$defs': {'Old': False}}
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
        if multipart:
            source = (
                '# Retain source organization\r\n'
                f'{declaration}: "{version}"\r\n'
                'info:\r\n'
                f"  title: 'Production {version}'\r\n"
                '  version: api-version\r\n'
                + (f'host: "127.0.0.1:{multipart.port}"\r\nschemes: [http]\r\nproduces: [application/json]\r\n' if swagger
                   else f'servers: [{{url: "http://127.0.0.1:{multipart.port}"}}]\r\n') +
                'paths:\r\n  /items:\r\n    post: '
                + json.dumps(document['paths']['/items']['post'], ensure_ascii=False) + '\r\n'
            )
        shared = (
            '# Retain shared model and alias ownership\n'
            'Item: &item\n'
            '  type: object\n'
            '  required: [id]\n'
            '  properties:\n'
            + ('    id: {type: integer, enum: [9007199254740993.00]}\n' if mock_nested or multipart
               else '    id: {type: integer}\n') +
            '  additionalProperties: false\n'
            + ('  default: {id: 9007199254740993.00}\n' if mock_samples and not mock_nested else '') +
            'Mirror: *item\n'
            'x-literal:\n'
            '  $ref: literal\n'
            '  number: 9007199254740993.00\n'
            "  text: 'café 東京'\n"
        ).replace('\n', '\r\n')
        if swagger and multipart:
            shared += 'File:\r\n  type: file\r\n'
        if getattr(multipart, 'header_content', False):
            shared += 'Meta: ' + json.dumps(multipart.header()) + '\r\n'
        if schema_definitions:
            source += (
                'components:\r\n  schemas:\r\n'
                "    Envelope: {$ref: './model.yaml#/Envelope'}\r\n"
                "    Use: {$ref: './model.yaml#/Envelope/$defs/Old'}\r\n"
            )
            shared += "Envelope:\r\n  type: object\r\n  $defs:\r\n    'Old': false\r\n"
    return b'\xef\xbb\xbf' + source.encode(), shared.encode()


def tree(pid, details=False):
    desktop = Atspi.get_desktop(0)
    queue = []
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child is not None and child.get_process_id() == pid:
            queue.append((child, 0))
    result = []
    while queue:
        node, depth = queue.pop(0)
        # AT-SPI may remove an accessible between child enumeration and lookup.
        # Missing children contribute no controls; bounded callers still require
        # the actual owned control and fail if it never becomes available.
        if node is None:
            continue
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


def complete_problems(nodes, expected=0):
    return any(
        node['name'] == 'Problems · Complete for captured scope · ' + str(expected)
        for node in nodes
    )


def keys(native, chords):
    for at in range(0, len(chords), 128):
        native.perform({'kind': 'keys', 'chords': chords[at:at + 128]})

def letters(text):
    names = {' ': 'space', '.': 'period', '-': 'minus'}
    return [names.get(character, character) for character in text]

def text_keys(value):
    names = {'/': 'slash', '_': 'Shift_L+minus', '.': 'period',
             '-': 'minus', ' ': 'space'}
    return [('Shift_L+' + character.lower()) if 'A' <= character <= 'Z'
            else names.get(character, character) for character in value]

def focus_control(native, pid, label, *, tabs=64, backwards=False):
    for _ in range(tabs):
        nodes = tree(pid, details=True)
        matches = [node for node in nodes if node['focused']
                   and node['name'].split('\n')[0] == label]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RuntimeError('Multiple focused controls claim ' + label)
        keys(native, ['Shift_L+Tab' if backwards else 'Tab'])
    raise RuntimeError('Bounded native keyboard traversal did not focus ' + label)

def activate_control(native, pid, label, *, backwards=False):
    focus_control(native, pid, label, backwards=backwards)
    keys(native, ['Return'])

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


def prepare_documentation(native, process, destination):
    mode(native, process.pid, 'Build documentation')
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Documentation preset') and contains(nodes, 'Choose output folder'),
        'Documentation preset did not appear')
    keys(native, ['Tab'])
    native.perform({'kind': 'click', 'scale': 1, 'point': [800, 426], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: field_matches(nodes, 'Output folder', editable=True, focused=True),
        'Output destination did not own focus')
    keys(native, ['Control_L+a'] + text_keys(str(destination)) + ['Return'])
    nodes = wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Ready to review') or contains(nodes, 'Output did not complete'),
        'Documentation preparation did not finish')
    assert contains(nodes, 'Ready to review'), nodes
    assert contains(nodes, 'unsaved working copy'), nodes
    assert not destination.exists(), 'Preparation published before review'


def documentation(native, process, file, baseline, version, evidence, case):
    from native_documentation_artifacts import verify_documentation

    destination = file.parent.parent / 'documentation'
    native.perform({'kind': 'click', 'scale': 1, 'point': [700, 250], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: field_matches(nodes, 'Title', focused=True), 'Title did not own focus')
    title = 'documented ' + version
    keys(native, ['Control_L+a'] + text_keys(title) + ['Tab'])
    wait_tree(native, process.pid,
        lambda nodes: field_matches(nodes, 'Title', value=title), 'Unsaved title was not retained')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    prepare_documentation(native, process, destination)
    native.perform({'kind': 'click', 'scale': 1, 'point': [598, 674], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: not contains(nodes, 'Ready to review') and not contains(nodes, 'Create documentation'),
        'Documentation cancellation did not discard its captured output')
    assert not destination.exists()
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    prepare_documentation(native, process, destination)
    destination.mkdir()
    sentinel = destination / 'other-writer.txt'
    sentinel.write_bytes(b'Preserve this destination race\r\n')
    native.perform({'kind': 'click', 'scale': 1, 'point': [467, 674], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Output did not complete (output.exists)'),
              'Changed documentation destination was not refused')
    assert sorted(path.name for path in destination.iterdir()) == [sentinel.name]
    assert sentinel.read_bytes() == b'Preserve this destination race\r\n'
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    sentinel.unlink()
    destination.rmdir()
    prepare_documentation(native, process, destination)
    native.perform({'kind': 'click', 'scale': 1, 'point': [467, 674], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Output created') or contains(nodes, 'Output did not complete'),
        'Documentation publication did not finish')
    assert contains(tree(process.pid, details=True), 'Output created')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    working = baseline[str(file)].replace(('edited ' + version).encode(), title.encode(), 1)
    sources = {'./' + Path(name).name: working if name == str(file) else raw
               for name, raw in baseline.items() if Path(name).name != 'busyapi.yaml'}
    verification = verify_documentation(destination, sources, version, title)
    preserved = evidence / (case + '-documentation')
    shutil.copytree(destination, preserved, symlinks=True)
    mode(native, process.pid, 'source')
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and title in (node['text'] or '') for node in nodes),
        'Source did not retain the exported working copy')
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and node['focused'] for node in nodes),
        'Source did not own focus after export')
    keys(native, ['Control_L+z'])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and 'edited ' + version in (node['text'] or '')
                          and title not in (node['text'] or '') for node in nodes),
        'One source undo did not restore the saved title after export')
    mode(native, process.pid, 'design')
    wait_tree(native, process.pid,
        lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes),
        'Design did not retain the restored source after export')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    return {'output': str(preserved), 'cancelledOutputAbsent': True, 'destinationRacePreserved': True,
            'unsavedSnapshotPublished': True, 'sourcePreserved': True,
            'oneOperationUndo': True, **verification}


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
    parser.add_argument('--documentation', action='store_true')
    parser.add_argument('--schema-definitions', action='store_true')
    parser.add_argument('--operations', action='store_true')
    parser.add_argument('--migrate-target', choices=['2.0', '3.0.4', '3.1.2', '3.2.1'])
    parser.add_argument('--multipart', choices=['ordered', 'nested', 'named'])
    parser.add_argument('--binary', choices=['raw', 'named', 'ordered', 'nested'])
    parser.add_argument('--binary-schema-free', action='store_true')
    parser.add_argument('--swagger-form', choices=['urlencoded', 'multipart'])
    parser.add_argument('--header-content', action='store_true')
    parser.add_argument('--generated-headers', choices=['generic', 'transfer'])
    parser.add_argument('--evidence', type=Path,
                        default=Path('/tmp/busyapi-production-main-evidence'))
    parser.add_argument('--version', default='3.0.4', choices=['2.0', '3.0.0', '3.0.1', '3.0.2', '3.0.3', '3.0.4', '3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1'])
    parser.add_argument('--format', default='yaml', choices=['yaml', 'json'])
    args = parser.parse_args()
    if args.generated_headers and (not args.edit or args.version == '2.0'
                                    or args.generated_headers == 'generic' and not args.version.startswith(('3.0.', '3.1.'))
                                    or args.operations or args.schema_definitions or args.documentation
                                    or args.mock_samples or args.mock_nested or args.mock_methods
                                    or args.migrate_target or args.multipart or args.binary
                                    or args.swagger_form or args.header_content):
        parser.error('--generated-headers requires --edit, an applicable 3.x root (generic: 3.0/3.1), and its dedicated MIME journey')
    if args.mock_nested:
        args.mock_samples = True
    if args.mock_methods:
        if not args.version.startswith('3.2.'):
            parser.error('--mock-methods requires an OpenAPI 3.2 root')
        args.mock_samples = True
    if args.mock_samples and not args.edit:
        parser.error('--mock-samples requires --edit for the save/reopen journey')
    if args.documentation and not args.edit:
        parser.error('--documentation requires --edit for the save/reopen journey')
    if args.schema_definitions and (not args.edit or not args.version.startswith(('3.1.', '3.2.'))):
        parser.error('--schema-definitions requires --edit and a modern OpenAPI family')
    if args.operations and not args.edit:
        parser.error('--operations requires --edit for the save/reopen journey')
    if args.migrate_target and (not args.edit or args.operations or args.schema_definitions
                               or args.documentation or args.mock_samples or args.multipart or args.binary or args.swagger_form or args.header_content):
        parser.error('--migrate-target requires --edit and its dedicated migration journey')
    if args.multipart and (not args.edit or (args.multipart != 'named' and not args.version.startswith('3.2.'))
                          or (args.multipart == 'named' and not args.version.startswith(('3.0.', '3.1.'))) or args.operations
                          or args.schema_definitions or args.documentation or args.mock_samples
                          or args.migrate_target or args.binary or args.swagger_form or args.header_content):
        parser.error('--multipart requires --edit, an applicable family (named: 3.0/3.1; ordered/nested: 3.2), and its dedicated execution journey')
    if args.binary_schema_free and (args.binary != 'raw' or args.version == '2.0'):
        parser.error('--binary-schema-free requires a 3.x raw binary media declaration')
    if args.binary and (not args.edit or args.version == '2.0' and args.binary != 'raw'
                        or args.binary in ['ordered', 'nested'] and not args.version.startswith('3.2.')
                        or args.operations or args.schema_definitions or args.documentation
                        or args.mock_samples or args.migrate_target or args.multipart or args.swagger_form or args.header_content):
        parser.error('--binary requires --edit, an applicable family, and its dedicated execution journey')
    if args.swagger_form and (not args.edit or args.version != '2.0'
                              or args.operations or args.schema_definitions or args.documentation
                              or args.mock_samples or args.migrate_target or args.multipart or args.binary or args.header_content):
        parser.error('--swagger-form requires --edit, Swagger 2.0 and its dedicated formData journey')
    if args.header_content and (not args.edit or args.version == '2.0'
                               or args.operations or args.schema_definitions or args.documentation
                               or args.mock_samples or args.migrate_target or args.multipart or args.binary or args.swagger_form):
        parser.error('--header-content requires --edit, a 3.x root and its dedicated MIME journey')
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
                *(['--documentation'] if args.documentation else []),
                *(['--schema-definitions'] if args.schema_definitions else []),
                *(['--operations'] if args.operations else []),
                *(['--migrate-target', args.migrate_target] if args.migrate_target else []),
                *(['--multipart', args.multipart] if args.multipart else []),
                *(['--binary', args.binary] if args.binary else []),
                *(['--binary-schema-free'] if args.binary_schema_free else []),
                *(['--swagger-form', args.swagger_form] if args.swagger_form else []),
                *(['--header-content'] if args.header_content else []),
                *(['--generated-headers', args.generated_headers] if args.generated_headers else []),
            ]
            # Own the complete private session, including accessibility and
            # the application, so a timed-out journey leaves no native fixture.
            with subprocess.Popen(
                command, env=private_session_environment(environment, runtime),
                start_new_session=True,
            ) as session:
                try:
                    # Multipart adds two HTTP requests and two native export
                    # dialogs per opening. Keep each control's existing bound;
                    # allocate the original journey budget to each opening.
                    return session.wait(timeout=180 if args.multipart or args.binary or args.swagger_form or args.header_content or args.generated_headers else 90)
                except subprocess.TimeoutExpired:
                    os.killpg(session.pid, signal.SIGTERM)
                    session.wait(timeout=5)
                    raise
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
    with tempfile.TemporaryDirectory(prefix='busyapi-prod-main-') as temporary, ExitStack() as fixtures:
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
            + ('-documentation' if args.documentation else '')
            + ('-schema-definitions' if args.schema_definitions else '')
            + ('-operations' if args.operations else '')
            + ('-migrate-' + args.migrate_target if args.migrate_target else '')
            + ('-multipart-' + args.multipart if args.multipart else '')
            + ('-binary-' + args.binary if args.binary else '')
            + ('-schema-free' if args.binary_schema_free else '')
            + ('-swagger-form-' + args.swagger_form if args.swagger_form else '')
            + ('-header-content' if args.header_content else '')
            + ('-generated-headers-' + args.generated_headers if args.generated_headers else '')
        )
        file = project_directory / ('api.' + args.format)
        fragment = project_directory / ('model.' + args.format)
        multipart = None
        if args.generated_headers:
            from native_generated_headers import GeneratedHeadersFixture, GeneratedTransferFixture
            multipart = fixtures.enter_context(GeneratedTransferFixture() if args.generated_headers == 'transfer' else GeneratedHeadersFixture())
        elif args.header_content:
            from native_header_content import HeaderContentFixture
            multipart = fixtures.enter_context(HeaderContentFixture(args.version))
            multipart.prepare(project_directory)
        elif args.swagger_form:
            from native_swagger_forms import SwaggerFormFixture
            multipart = fixtures.enter_context(SwaggerFormFixture(args.swagger_form))
            multipart.prepare(project_directory)
        elif args.binary:
            from native_binary import BinaryFixture
            multipart = fixtures.enter_context(BinaryFixture(args.binary, args.version, args.binary_schema_free))
            multipart.prepare(project_directory)
        elif args.multipart:
            from native_multipart import MultipartFixture
            multipart = fixtures.enter_context(MultipartFixture(args.multipart))
        source, shared = fixture_sources(args.version, args.format, args.mock_samples, args.mock_methods, args.mock_nested, args.schema_definitions, multipart)
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
        authored_examples = None
        problem_count = 0
        if args.multipart in ['ordered', 'nested']:
            cli = subprocess.run([str(ROOT / 'build/linux/x64/release/bundle/busyapi'),
                                  'check', str(file), '--json'],
                                 env={'PATH': '', 'LANG': 'C.UTF-8'},
                                 capture_output=True, text=True, timeout=30)
            assert cli.returncode == 0, cli.stderr
            authored_examples = multipart.verify_authored_examples(json.loads(cli.stdout), file.as_uri())
            problem_count = authored_examples['warningCount']
            assert all(Path(name).read_bytes() == raw for name, raw in original.items())
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
        documentation_result = None
        schema_definition_result = None
        operation_result = None
        migration_result = None
        multipart_results = []
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
                            and complete_problems(nodes, problem_count)):
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
                    if args.migrate_target:
                        from native_migration import migrate
                        migration_result = migrate(native, process, file, fragment,
                            expected_sources, args.version, args.migrate_target, evidence, case)
                        nodes = tree(process.pid, details=True)
                    if args.operations:
                        from native_operation_maintenance import maintain_operation
                        changed, operation_result = maintain_operation(
                            native, process, file, fragment, expected_sources, args.version)
                        expected_sources.update(changed)
                        nodes = tree(process.pid, details=True)
                    if args.schema_definitions:
                        from native_schema_definitions import maintain_definitions
                        changed, schema_definition_result = maintain_definitions(
                            native, process, file, fragment, expected_sources, args.version)
                        expected_sources.update(changed)
                        nodes = tree(process.pid, details=True)
                    if args.documentation:
                        documentation_result = documentation(
                            native, process, file, expected_sources, args.version, evidence, case)
                        nodes = tree(process.pid, details=True)
                    if args.mock_samples:
                        mock_samples(native, process, args.format, 'get' if args.mock_methods else 'GET', args.mock_nested)
                    if multipart:
                        from native_multipart import execute_multipart
                        multipart_results.append(execute_multipart(native, process, file, expected_sources,
                            args.version, multipart, evidence, case, 'initial'))
                    quit_application(native, process)
                    native = None
                    if migration_result is not None:
                        from native_migration import inspect_copy
                        target_directory = Path(migration_result['outputDirectory'])
                        target_startup = target_directory
                        if args.format == 'json':
                            target_directory = directory / 'standalone-migrated'
                            target_directory.mkdir()
                            source_directory = Path(migration_result['outputDirectory'])
                            for name in [migration_result['entry'], 'resources']:
                                source = source_directory / name
                                if source.is_dir():
                                    shutil.copytree(source, target_directory / name)
                                else:
                                    shutil.copyfile(source, target_directory / name)
                            target_startup = target_directory / migration_result['entry']
                            assert not (target_directory / 'busyapi.yaml').exists()
                        copied = {path: path.read_bytes() for path in target_directory.rglob('*') if path.is_file()}
                        process = subprocess.Popen([str(binary), str(target_startup)], stdout=stream,
                            stderr=subprocess.STDOUT, env=env)
                        native = NativeInput(process.pid)
                        wait_for_initial_focus(native.ready, timeout=8)
                        inspect_copy(native, process, args.version, args.migrate_target)
                        assert all(path.read_bytes() == raw for path, raw in copied.items())
                        quit_application(native, process)
                        native = None
                        assert all(path.read_bytes() == raw for path, raw in copied.items())
                        migration_result['targetReopened'] = True
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
                        ) and complete_problems(nodes, problem_count),
                        'Production reopen did not retain the saved native contract',
                    )
                    assert (
                        args.project or not (project_directory / 'busyapi.yaml').exists()
                    ), 'Standalone editing created a project wrapper'
                    if args.mock_samples:
                        mock_samples(native, process, args.format, 'get' if args.mock_methods else 'GET', args.mock_nested)
                    if multipart:
                        multipart_results.append(execute_multipart(native, process, file, expected_sources,
                            args.version, multipart, evidence, case, 'reopened'))
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
                    'nativeDocumentation': documentation_result,
                    'nativeSchemaDefinitions': schema_definition_result,
                    'nativeOperations': operation_result,
                    'nativeMigration': migration_result,
                    'nativeMultipart': multipart_results,
                    'nativeAuthoredExamples': authored_examples,
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
