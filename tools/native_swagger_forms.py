"""Real native Swagger formData input, upload and original-byte oracles."""
from email.message import Message
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlencode

from native_binary import BinaryFixture, OCTETS


class SwaggerFormFixture(BinaryFixture):
    binary = False
    swagger_forms = True

    def __init__(self, mode):
        super().__init__('raw', '2.0')
        self.mode = mode
        self.media = ('multipart/form-data' if mode == 'multipart'
                      else 'application/x-www-form-urlencoded')

    def operation(self, format):
        required = self.mode == 'urlencoded'
        parameters = [
            {'name': 'n', 'in': 'formData', 'type': 'integer', 'required': required,
             'enum': [9007199254740993]},
            {'name': 'flag', 'in': 'formData', 'type': 'boolean', 'required': required,
             'enum': [False]},
            {'name': 'empty', 'in': 'formData', 'type': 'string', 'required': required,
             'allowEmptyValue': True, 'maxLength': 0},
            {'name': 'label', 'in': 'formData', 'type': 'string', 'required': required,
             'enum': ['雪']},
            {'name': 'ids', 'in': 'formData', 'type': 'array', 'required': required,
             'collectionFormat': 'multi', 'items': {'type': 'integer'},
             'minItems': 2, 'maxItems': 2},
        ]
        if self.mode == 'multipart':
            parameters.append({'name': 'file', 'in': 'formData', 'type': 'file',
                               'required': False})
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'consumes': [self.media], 'produces': [self.media],
                'parameters': parameters,
                'responses': {'200': {'description': 'Original form entity',
                                     'schema': {'$ref': './model.' + format + '#/File'}}}}

    def prepare(self, directory):
        self.upload = directory / 'opaque.bin'
        self.upload.write_bytes(OCTETS)


def swagger_form_wire(mode, number, boundary=None):
    fields = [('n', number), ('flag', 'false'), ('empty', ''),
              ('label', '雪'), ('ids', '0'), ('ids', '2')]
    if mode == 'urlencoded':
        return urlencode(fields).encode()
    assert boundary is not None
    body = b''.join((
        '--' + boundary + '\r\nContent-Disposition: form-data; name="' + name
        + '"\r\n\r\n' + value + '\r\n'
    ).encode() for name, value in fields)
    return (body + ('--' + boundary + '\r\nContent-Disposition: form-data; '
                    'name="file"; filename="opaque.bin"\r\n'
                    'Content-Type: application/octet-stream\r\n\r\n').encode()
            + OCTETS + ('\r\n--' + boundary + '--\r\n').encode())


def _json_keys(text):
    names = {'{': 'Shift_L+bracketleft', '}': 'Shift_L+bracketright',
             '"': 'Shift_L+apostrophe', ':': 'Shift_L+semicolon',
             ',': 'comma', '[': 'bracketleft', ']': 'bracketright',
             '\\': 'backslash'}
    assert text.isascii()
    return [names.get(character, character) for character in text]


def _focus_entry(native, pid, label):
    from test_openapi_application import focus_control, keys, tree
    focus_control(native, pid, 'Include request body')
    for _ in range(64):
        nodes = tree(pid, details=True)
        matches = [node for node in nodes if node['editable'] and node['focused']
                   and node['name'].split('\n')[0] == label]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RuntimeError('Multiple owned form editors claim focus')
        keys(native, ['Tab'])
    raise RuntimeError('Bounded native traversal did not reach ' + label)


def execute_swagger_forms(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import activate_control, complete_problems, contains, design_values, keys, text_keys, wait_tree
    from native_focus import wait_for_initial_focus
    from native_multipart import edit_named_body

    assert version == '2.0'
    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'), 'Swagger form operation selection failed')
    activate_control(native, process.pid, 'Try')
    nodes = wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Send'), 'Swagger form request controls are unavailable')
    if not contains(nodes, 'Use an exact JSON value'):
        activate_control(native, process.pid, 'Include request body')
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Use an exact JSON value'), 'The optional Swagger body did not expose its native editor')
    activate_control(native, process.pid, 'Use an exact JSON value')
    _focus_entry(native, process.pid, 'Use an exact JSON value')
    if fixture.mode == 'multipart':
        before = len(fixture.records)
        keys(native, ['Control_L+a'] + _json_keys('{}'))
        activate_control(native, process.pid, 'Send')
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'A multipart body requires at least one part.'), 'Empty native multipart preparation did not show its actionable failure')
        assert len(fixture.records) == before
        entry = _focus_entry(native, process.pid, 'Use an exact JSON value')
        assert entry['text'] == '{}'
    data = '{"n":9007199254740993,"flag":false,"empty":"","label":"\\u96ea","ids":[0,2]}'
    keys(native, ['Control_L+a'] + _json_keys(data))
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['focused'] and node['text'] == data for node in nodes), 'The native Swagger form draft lost exact JSON input')
    if fixture.mode == 'multipart':
        entry = _focus_entry(native, process.pid, 'Multipart field name')
        assert entry['text'] == 'file'
        activate_control(native, process.pid, 'Add binary file')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(fixture.upload)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: contains(nodes, fixture.upload.name), 'Swagger file input did not retain the selected upload')
    checks = []
    start = len(fixture.records)
    for name, number in [('exact', '9007199254740993'), ('rounded', '9007199254740992')]:
        if name == 'rounded':
            _focus_entry(native, process.pid, 'Use an exact JSON value')
            edit_named_body(native, process.pid, '9007199254740993', backwards=False)
        activate_control(native, process.pid, 'Send')
        status = ('HTTP received · contract checks passed' if name == 'exact'
                  else 'HTTP received · contract findings require review')
        nodes = wait_tree(native, process.pid, lambda nodes: len(fixture.records) == start + len(checks) + 1 and contains(nodes, status), 'Native Swagger form dispatch did not finish with the expected checks')
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        assert record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        boundary = None
        if fixture.mode == 'multipart':
            media = Message()
            media['content-type'] = headers['content-type']
            boundary = media.get_param('boundary')
            assert isinstance(boundary, str) and re.fullmatch(r'busyapi-[0-9a-f]{48}', boundary)
            assert headers['content-type'] == fixture.media + '; boundary=' + boundary
        else:
            assert headers['content-type'] == fixture.media
        expected = swagger_form_wire(fixture.mode, number, boundary)
        assert record['body'] == expected
        destination = evidence / (case + '-swagger-form-' + phase + '-' + name + '.bin')
        assert not destination.exists()
        activate_control(native, process.pid, 'Export original entity bytes')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: destination.is_file(), 'Native Swagger form export did not complete')
        assert not destination.is_symlink() and destination.read_bytes() == expected
        assert fixture.upload.read_bytes() == OCTETS
        assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
        checks.append({'example': name, 'method': 'POST', 'target': '/items',
                       'input': 'keyboard', 'bodySha256': hashlib.sha256(expected).hexdigest(),
                       'bytes': len(expected), 'expectedStatus': status,
                       'exactResponse': True, 'fileUnchanged': True})
        print('Native Swagger form request: ' + json.dumps(checks[-1]), flush=True)
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'Swagger form execution changed the authored contract')
    return {'complete': True, 'mode': fixture.mode, 'phase': phase,
            'requests': checks, 'sourceUnchanged': True,
            'emptyPreparationRefused': fixture.mode == 'multipart'}
