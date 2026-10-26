"""Real native file grouping with original-source and MIME byte oracles."""
import hashlib
import json
from pathlib import Path
import re

from native_multipart import MultipartFixture


class FileShapesFixture(MultipartFixture):
    file_shapes = True

    def __init__(self, version):
        super().__init__('named')
        self.version = version
        self.media = 'multipart/form-data'

    def prepare(self, directory):
        self.upload = directory / 'group.txt'
        self.upload.write_bytes(b'abc')

    def operation(self, format):
        scalar = {'type': 'string', 'minLength': 3,
                  **({'format': 'binary'} if self.version.startswith('3.0.') else {})}
        reference = {'$ref': './model.' + format + '#/Item'}
        encoding = {'metadata': {'contentType': 'application/json'}}
        media = {
            'schema': {'type': 'object', 'required': ['metadata'],
                       'properties': {'metadata': reference, 'asset': {'oneOf': [
                           {**scalar, 'minLength': 4},
                           {'type': 'array', 'minItems': 1, 'maxItems': 2, 'items': scalar},
                       ]}}},
            'encoding': encoding,
            'examples': {'exact': {'value': {'metadata': {'id': 9007199254740993}}}},
        }
        response = {'schema': {'type': 'object', 'required': ['metadata'],
                               'properties': {'metadata': reference, 'asset': {'type': 'string'}}}, 'encoding': {**encoding, 'asset': {'contentType': 'text/plain'}}}
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': {self.media: media}},
                'responses': {'200': {'description': 'Original MIME entity',
                                      'content': {self.media: response}}}}


def execute_file_shapes(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import (
        activate_control, complete_problems, contains, design_values,
        field_matches, focus_control, keys, text_keys, tree, wait_tree,
    )
    from native_focus import wait_for_initial_focus

    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'), 'File grouping operation selection failed')
    activate_control(native, process.pid, 'Try')
    activate_control(native, process.pid, 'Examples · ' + fixture.media + ' · exact')
    metadata = '{"id":9007199254740993}'
    if file.suffix == '.json':
        values = re.findall(r'"metadata": (\{\s*"id": 9007199254740993\s*\})', file.read_text())
        assert len(values) == 1 and json.loads(values[0]) == {'id': 9007199254740993}
        metadata = values[0]
    focus_control(native, process.pid, 'Multipart field name')
    keys(native, ['Control_L+a'] + text_keys('asset'))
    wait_tree(native, process.pid, lambda nodes: field_matches(nodes, 'Multipart field name', value='asset', editable=True), 'The selected file part name changed')
    activate_control(native, process.pid, 'Add binary file')
    with native.transient_dialog():
        keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(fixture.upload)) + ['Return'])
    wait_for_initial_focus(native.ready, timeout=8)
    wait_tree(native, process.pid, lambda nodes: contains(nodes, fixture.upload.name), 'File grouping lost the selected upload')
    checks = []
    start = len(fixture.records)
    for choice, index in [('array', 2), ('single', 1)]:
        if not contains(tree(process.pid, details=True), 'asset · File values'):
            activate_control(native, process.pid, 'Declared form parts')
        activate_control(native, process.pid, 'asset · File values')
        wait_tree(native, process.pid, lambda nodes: all(contains(nodes, label) for label in ['Choose a value shape', 'Single value', 'Array of values']), 'GTK did not expose the captured file shapes')
        keys(native, ['Home'] + ['Down'] * index + ['Return'])
        activate_control(native, process.pid, 'Send')
        expected = ('HTTP received · contract checks passed' if choice == 'array'
                    else 'HTTP received · contract findings require review')
        nodes = wait_tree(native, process.pid, lambda nodes: len(fixture.records) == start + len(checks) + 1 and contains(nodes, expected), 'File shape validation did not match the selected data model')
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        match = re.fullmatch(r'multipart/form-data; boundary=(busyapi-[0-9a-f]{48})', headers['content-type'])
        assert match and record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        boundary = match[1]
        part_type = 'application/octet-stream' if version.startswith('3.0.') else 'text/plain'
        raw = ('--' + boundary + '\r\nContent-Disposition: form-data; name="metadata"\r\n'
               'Content-Type: application/json\r\n\r\n' + metadata + '\r\n'
               '--' + boundary + '\r\nContent-Disposition: form-data; name="asset"; filename="group.txt"\r\n'
               'Content-Type: ' + part_type + '\r\n\r\nabc\r\n'
               '--' + boundary + '--\r\n').encode()
        assert record['body'] == raw
        assert any(node['text'] == raw.hex(' ')[:1024] for node in nodes), 'The MIME response preview changed the captured bytes'
        destination = evidence / (case + '-file-shapes-' + phase + '-' + choice + '.bin')
        assert not destination.exists()
        activate_control(native, process.pid, 'Export original entity bytes')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: destination.is_file(), 'File shape response export did not complete')
        assert not destination.is_symlink() and destination.read_bytes() == raw
        assert fixture.upload.read_bytes() == b'abc'
        assert all(Path(path).read_bytes() == source for path, source in baseline.items())
        checks.append({'shape': choice, 'method': 'POST', 'target': '/items', 'input': 'keyboard',
                       'bodySha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw),
                       'expectedStatus': expected, 'exactResponse': True})
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'File shape input changed authored source')
    return {'complete': True, 'phase': phase, 'requests': checks,
            'sourceUnchanged': True, 'kind': 'file-shapes'}
