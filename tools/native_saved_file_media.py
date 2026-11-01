"""Native saved-case file media selection, dispatch and source-byte oracles."""
import hashlib
from pathlib import Path
import re

from native_multipart import MultipartFixture


class SavedFileMediaFixture(MultipartFixture):
    saved_file_media = True

    def __init__(self, version):
        super().__init__('named')
        self.version = version
        self.media = 'multipart/form-data'
        self.payloads = [b'\x00\xffA', b'\x00\x80B']
        self.names = ['asset', 'other' if version == '2.0' else 'asset']

    def prepare(self, directory):
        self.uploads = [directory / 'one.bin', directory / 'two.bin']
        for file, raw in zip(self.uploads, self.payloads):
            file.write_bytes(raw)

    def operation(self, format):
        if self.version == '2.0':
            parameters = [
                {'name': 'n', 'in': 'formData', 'type': 'integer', 'required': True},
                {'name': 'zero', 'in': 'formData', 'type': 'integer', 'required': True},
                {'name': 'flag', 'in': 'formData', 'type': 'boolean', 'required': True},
                *[{'name': name, 'in': 'formData', 'type': 'file', 'required': True}
                  for name in self.names],
            ]
            return {'operationId': 'postItems', 'summary': 'Inspect items',
                    'consumes': [self.media], 'produces': [self.media],
                    'parameters': parameters,
                    'responses': {'200': {'description': 'Original entity',
                                          'schema': {'$ref': './model.' + format + '#/File'}}}}
        item = ({'type': 'string', 'format': 'binary', 'minLength': 3, 'maxLength': 3}
                if self.version.startswith('3.0.') else {})
        media = {'schema': {'type': 'object', 'required': ['metadata', 'asset'],
                            'properties': {
                                'metadata': {'$ref': './model.' + format + '#/Item'},
                                'asset': {'type': 'array', 'minItems': 2, 'maxItems': 2, 'items': item}}},
                 'encoding': {'metadata': {'contentType': 'application/json'},
                              'asset': {'contentType': 'image/*'}}}
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': {self.media: media}},
                'responses': {'200': {'description': 'Original entity', 'content': {self.media: media}}}}

    def cases(self):
        value = ({'n': 'EXACT', 'zero': 0, 'flag': False} if self.version == '2.0'
                 else {'metadata': {'id': 'EXACT'}})
        return [{'name': 'Per-file types' if valid else 'Wrong MIME',
                 'operation': {'method': 'post', 'path': '/items'},
                 'body': {'mediaType': self.media, 'value': value,
                          'partMediaTypes': {'asset': 'image/gif'},
                          'files': [{'name': self.names[index], 'path': file.name,
                                     'mediaType': ('text/plain' if not valid and index == 0 else
                                                   'image/png' if index == 0 else 'image/jpeg')}
                                    for index, file in enumerate(self.uploads)]},
                 'expect': {'status': 200}} for valid in [True, False]]

    def expected(self, boundary):
        fields = [('n', '9007199254740993.00'), ('zero', '0'), ('flag', 'false')] if self.version == '2.0' else [('metadata', '{"id":9007199254740993.00}')]
        raw = b''.join(('--' + boundary + '\r\nContent-Disposition: form-data; name="' + name
                        + '"\r\n' + ('' if self.version == '2.0' else 'Content-Type: application/json\r\n')
                        + '\r\n' + value + '\r\n').encode() for name, value in fields)
        for index, file in enumerate(self.uploads):
            raw += ('--' + boundary + '\r\nContent-Disposition: form-data; name="' + self.names[index]
                    + '"; filename="' + file.name + '"\r\nContent-Type: '
                    + ('image/png' if index == 0 else 'image/jpeg') + '\r\n\r\n').encode()
            raw += self.payloads[index] + b'\r\n'
        return raw + ('--' + boundary + '--\r\n').encode()


def execute_saved_file_media(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import activate_control, complete_problems, contains, design_values, mode, wait_tree

    start = len(fixture.records)
    mode(native, process.pid, 'Contract tests')
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Per-file types') and contains(nodes, 'Test selected cases'), 'Native saved-case selection did not open')
    activate_control(native, process.pid, 'Per-file types')
    activate_control(native, process.pid, 'Test selected cases')
    wait_tree(native, process.pid, lambda nodes: len(fixture.records) == start + 1 and contains(nodes, 'Selected cases passed') and contains(nodes, 'HTTP 200'), 'Native saved files did not dispatch with complete successful checks')
    record = fixture.records[-1]
    headers = {key.lower(): value for key, value in record['headers'].items()}
    match = re.fullmatch(r'multipart/form-data; boundary=(busyapi-[0-9a-f]{48})', headers['content-type'])
    assert match and record['method'] == 'POST' and record['target'] == '/items'
    assert headers['host'] == '127.0.0.1:' + str(fixture.port)
    raw = fixture.expected(match[1])
    assert record['body'] == raw
    if version != '2.0':
        activate_control(native, process.pid, 'Per-file types')
        activate_control(native, process.pid, 'Wrong MIME')
        activate_control(native, process.pid, 'Test selected cases')
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Selected cases failed') and contains(nodes, 'Request not sent') and contains(nodes, 'request.form.content-type'), 'The native invalid file type was not refused before dispatch')
        assert len(fixture.records) == start + 1
    activate_control(native, process.pid, 'Close')
    assert all(Path(path).read_bytes() == source for path, source in baseline.items())
    assert all(path.read_bytes() == data for path, data in zip(fixture.uploads, fixture.payloads))
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'Native saved cases changed contract source')
    return {'complete': True, 'phase': phase, 'kind': 'saved-file-media', 'sourceUnchanged': True,
            'rangeRestriction': version != '2.0', 'invalidRangeRefused': True if version != '2.0' else None,
            'requests': [{'method': 'POST', 'target': '/items', 'input': 'keyboard',
                          'bodySha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw), 'exactWire': True}]}
