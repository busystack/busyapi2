"""Native explicit MIME header inputs, captured from the production transport."""
import hashlib
import json
import re
from pathlib import Path

from native_multipart import MultipartFixture


class GeneratedHeadersFixture(MultipartFixture):
    header_content = True
    header_generated = True

    def __init__(self):
        super().__init__('named')

    def header(self):
        return {'required': True,
                'content': {'application/json': {'schema': {'$ref': '#/Item'}}}}

    def operation(self, format):
        media = {
            'schema': {'type': 'object', 'required': ['value'],
                       'properties': {'value': {'type': 'string', 'enum': ['value']}}},
            'encoding': {'value': {'contentType': 'text/plain',
                                  'headers': {'X-Meta': {'$ref': './model.' + format + '#/Meta'}}}},
            'examples': {'exact': {'value': {'value': 'value'}}},
        }
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': {self.media: media}},
                'responses': {'200': {'description': 'Echo', 'content': {self.media: media}}}}


class GeneratedTransferFixture(MultipartFixture):
    header_generated = True
    transfer_generated = True

    def __init__(self):
        super().__init__('named')
        self.media = 'multipart/form-data'

    def operation(self, format):
        media = {
            'schema': {'type': 'object', 'required': ['value'],
                       'properties': {'value': {'type': 'boolean', 'enum': [False]}}},
            'encoding': {'value': {'contentType': 'text/plain',
                                  'headers': {'Content-Transfer-Encoding': {
                                      'required': True, 'content': {'text/plain': {
                                          'schema': {'type': 'string', 'enum': ['base64']}}}}}}},
            'examples': {'exact': {'value': {'value': False}}},
        }
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': {self.media: media}},
                'responses': {'200': {'description': 'Echo', 'content': {self.media: media}}}}


def edit_boolean_body(native, pid):
    from test_openapi_application import keys, tree, wait_tree
    for _ in range(64):
        matches = []
        for node in tree(pid, details=True):
            if node['editable'] and node['focused']:
                try:
                    if json.loads(node['text'] or '') == {'value': False}:
                        matches.append(node)
                except json.JSONDecodeError:
                    pass
        if len(matches) == 1:
            original = matches[0]['text']
            assert original.count('false') == 1
            offset = original.index('false')
            keys(native, ['Control_L+Home'] + ['Right'] * offset
                 + ['Shift_L+Right'] * 5 + list('true'))
            expected = original.replace('false', 'true', 1)
            wait_tree(native, pid, lambda nodes: any(node['editable'] and node['focused'] and node['text'] == expected for node in nodes), 'The native boolean edit changed other draft data')
            return
        if len(matches) > 1:
            raise RuntimeError('Multiple owned boolean body fields claim focus')
        keys(native, ['Shift_L+Tab'])
    raise RuntimeError('Bounded traversal did not reach the boolean body draft')


def execute_generated_headers(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import (
        activate_control, complete_problems, contains, design_values,
        field_matches, focus_control, keys, text_keys, wait_tree,
    )
    from native_focus import wait_for_initial_focus

    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'), 'Generated header operation selection failed')
    activate_control(native, process.pid, 'Try')
    activate_control(native, process.pid, 'Examples · ' + fixture.media + ' · exact')
    transfer = getattr(fixture, 'transfer_generated', False)
    if not transfer:
        activate_control(native, process.pid, 'Declared form parts')
        activate_control(native, process.pid, 'Part headers')
    # Starting at the owned disclosure places these three fields before any
    # unrelated header or file controls. Every focused field is checked.
    for label, value in ([] if transfer else [('Multipart field name', 'value'), ('Header name', 'X-Meta')]):
        focus_control(native, process.pid, label)
        keys(native, ['Control_L+a'] + text_keys(value))
        wait_tree(native, process.pid, lambda nodes: field_matches(nodes, label, value=value, editable=True, focused=True), 'Generated header input was not retained: ' + label)
    checks = []
    start = len(fixture.records)
    for name, number in [('exact', '9007199254740993.00'), ('rounded', '9007199254740992')]:
        literal = '{"id":' + number + '}'
        if transfer:
            if name == 'rounded':
                edit_boolean_body(native, process.pid)
        else:
            focus_control(native, process.pid, 'Header value', backwards=name == 'rounded')
            chords = ['Shift_L+bracketleft', 'Shift_L+apostrophe', 'i', 'd',
                      'Shift_L+apostrophe', 'Shift_L+semicolon', *text_keys(number),
                      'Shift_L+bracketright']
            keys(native, ['Control_L+a'] + chords)
            wait_tree(native, process.pid, lambda nodes: field_matches(nodes, 'Header value', value=literal, editable=True, focused=True), 'Exact MIME header value was not retained')
        activate_control(native, process.pid, 'Send')
        expected = ('HTTP received · contract checks passed' if name == 'exact'
                    else 'HTTP received · contract findings require review')
        nodes = wait_tree(native, process.pid, lambda nodes: len(fixture.records) == start + len(checks) + 1 and contains(nodes, expected), 'Generated MIME header conformance did not match captured bytes')
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        match = re.fullmatch(re.escape(fixture.media) + r'; boundary=(busyapi-[0-9a-f]{48})', headers['content-type'])
        assert match and record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        boundary = match[1]
        content = ('Content-Transfer-Encoding: base64\r\n\r\n'
                   + ('ZmFsc2U=' if name == 'exact' else 'dHJ1ZQ==') if transfer
                   else 'X-Meta: ' + literal + '\r\n\r\nvalue')
        raw = ('--' + boundary + '\r\nContent-Disposition: form-data; name="value"\r\n'
               'Content-Type: text/plain\r\n' + content + '\r\n'
               '--' + boundary + '--\r\n').encode()
        assert record['body'] == raw
        assert any(node['text'] == raw.hex(' ')[:1024] for node in nodes), 'Generated MIME response preview changed'
        destination = evidence / (case + '-generated-headers-' + phase + '-' + name + '.bin')
        assert not destination.exists()
        activate_control(native, process.pid, 'Export original entity bytes')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: destination.is_file(), 'Generated MIME response export did not complete')
        assert not destination.is_symlink() and destination.read_bytes() == raw
        assert all(Path(path).read_bytes() == source for path, source in baseline.items())
        checks.append({'example': name, 'method': 'POST', 'target': '/items', 'input': 'keyboard',
                       'bodySha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw),
                       'expectedStatus': expected, 'exactResponse': True})
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'MIME header input changed the authored source')
    return {'complete': True, 'phase': phase, 'requests': checks,
            'sourceUnchanged': True, 'kind': 'generated-transfer' if transfer else 'generated-headers'}
