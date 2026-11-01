"""Owned native Header.content requests using complete captured MIME entities."""
import hashlib
import json
from pathlib import Path

from native_binary import BinaryFixture


def header_wire(number):
    return ('--Fixture\r\nContent-Disposition: form-data; name="value"\r\n'
            'Content-Type: text/plain\r\nX-Meta: {"id":' + number + '}\r\n'
            '\r\nvalue\r\n--Fixture--\r\n').encode()


class HeaderContentFixture(BinaryFixture):
    binary = False
    header_content = True

    def __init__(self, version):
        super().__init__('raw', version)
        self.media = 'multipart/mixed; boundary=Fixture'

    def header(self):
        return {'required': True,
                'content': {'application/json': {'schema': {'$ref': '#/Item'}}}}

    def operation(self, format):
        rule = {'contentType': 'text/plain',
                'headers': {'X-Meta': {'$ref': './model.' + format + '#/Meta'}}}
        media = ({'schema': {'type': 'array', 'items': {'type': 'string'}},
                  'itemEncoding': rule} if self.version.startswith('3.2.') else
                 {'schema': {'type': 'object', 'required': ['value'],
                             'properties': {'value': {'type': 'string'}}},
                  'encoding': {'value': rule}})
        content = {self.media: media}
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': content},
                'responses': {'200': {'description': 'Echo', 'content': content}}}

    def prepare(self, directory):
        self.payloads = {}
        for name, number in [('exact', '9007199254740993.00'),
                             ('rounded', '9007199254740992')]:
            path = directory / ('header-' + name + '.bin')
            raw = header_wire(number)
            path.write_bytes(raw)
            self.payloads[name] = (path, raw)


def execute_header_content(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import activate_control, complete_problems, contains, design_values, keys, text_keys, wait_tree
    from native_focus import wait_for_initial_focus

    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'), 'Header content operation selection failed')
    activate_control(native, process.pid, 'Try')
    nodes = wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Send'), 'Header content request controls are unavailable')
    if contains(nodes, 'Use a serialized entity'):
        activate_control(native, process.pid, 'Use a serialized entity')
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Use binary file'), 'Serialized entity input did not expose the complete-body file control')
    checks = []
    start = len(fixture.records)
    for name in ['exact', 'rounded']:
        path, raw = fixture.payloads[name]
        activate_control(native, process.pid, 'Use binary file')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(path)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: contains(nodes, path.name), 'The native entity picker did not retain its complete file')
        activate_control(native, process.pid, 'Send')
        expected = ('HTTP received · contract checks passed' if name == 'exact'
                    else 'HTTP received · contract findings require review')
        wait_tree(native, process.pid, lambda nodes: len(fixture.records) == start + len(checks) + 1 and contains(nodes, expected), 'Native Header content conformance did not match actual bytes')
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        assert record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        assert headers['content-type'] == fixture.media and record['body'] == raw
        destination = evidence / (case + '-header-content-' + phase + '-' + name + '.bin')
        assert not destination.exists()
        activate_control(native, process.pid, 'Export original entity bytes')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: destination.is_file(), 'Header content response export did not complete')
        assert not destination.is_symlink() and destination.read_bytes() == raw
        assert path.read_bytes() == raw
        assert all(Path(name).read_bytes() == source for name, source in baseline.items())
        checks.append({'example': name, 'method': 'POST', 'target': '/items',
                       'input': 'keyboard', 'bodySha256': hashlib.sha256(raw).hexdigest(),
                       'bytes': len(raw), 'expectedStatus': expected,
                       'exactResponse': True, 'fileUnchanged': True})
        print('Native Header content request: ' + json.dumps(checks[-1]), flush=True)
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'Header entity input changed the authored contract')
    return {'complete': True, 'phase': phase, 'requests': checks,
            'sourceUnchanged': True, 'kind': 'header-content'}
