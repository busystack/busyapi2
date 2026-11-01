"""Owned binary payloads and native file-picker execution qualification."""
from contextlib import AbstractContextManager
from email.message import Message
import hashlib
import http.server
import json
from pathlib import Path
import re
import threading


OCTETS = bytes([0, 255, 128, 0])


def binary_wire(kind, number, boundary='Fixture', metadata=None):
    if kind == 'raw':
        return OCTETS if number == '9007199254740993' else b''
    metadata = (metadata or '{"id":9007199254740993}').replace('9007199254740993', number)
    if kind == 'named':
        return (('--' + boundary + '\r\nContent-Disposition: form-data; name="metadata"\r\n'
                 'Content-Type: application/json\r\n\r\n' + metadata + '\r\n'
                 '--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="opaque.bin"\r\n'
                 'Content-Type: application/octet-stream\r\n\r\n').encode()
                + OCTETS + ('\r\n--' + boundary + '--\r\n').encode())
    part = (b'Content-Type: multipart/mixed; boundary=Inner\r\n\r\n'
            b'--Inner\r\nContent-Type: application/octet-stream\r\n\r\n'
            + OCTETS + b'\r\n--Inner--\r\n' if kind == 'nested'
            else b'Content-Type: application/octet-stream\r\n\r\n' + OCTETS)
    return (b'--Fixture\r\n' + part + b'\r\n--Fixture\r\nContent-Type: application/json\r\n\r\n'
            + metadata.encode() + b'\r\n--Fixture--\r\n')


class BinaryFixture(AbstractContextManager):
    binary = True

    def __init__(self, kind, version='3.2.1', schema_free=False):
        self.kind = kind
        self.version = version
        self.schema_free = schema_free
        self.media = ('application/octet-stream' if kind == 'raw' else
                      'multipart/form-data' if kind == 'named' else 'multipart/mixed; boundary=Fixture')
        self.records = []
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers['content-length']))
                fixture.records.append({'method': self.command, 'target': self.path,
                                        'headers': dict(self.headers.items()), 'body': body})
                self.send_response(200)
                self.send_header('content-type', self.headers['content-type'])
                self.send_header('content-length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def operation(self, format):
        binary = ({'type': 'string', 'maxLength': 4} if self.version == '2.0' or self.version.startswith('3.0.')
                  else {'not': {'type': 'null'}})
        metadata = {'$ref': './model.' + format + '#/Item'}
        if self.kind == 'raw':
            media = {} if self.schema_free else {'schema': binary}
        elif self.kind == 'named':
            media = {'schema': {'type': 'object', 'required': ['metadata'],
                               'properties': {'file': binary, 'metadata': metadata}},
                     'encoding': {'file': {'contentType': 'application/octet-stream'},
                                  'metadata': {'contentType': 'application/json'}},
                     'examples': {'exact': {'value': {'metadata': {'id': 9007199254740993}}}}}
        else:
            first = ({'type': 'array', 'items': binary, 'minItems': 1, 'maxItems': 1}
                     if self.kind == 'nested' else binary)
            media = {'schema': {'type': 'array', 'minItems': 2, 'maxItems': 2,
                                'prefixItems': [first, metadata], 'items': False},
                     'prefixEncoding': [
                         ({'contentType': 'multipart/mixed', 'itemEncoding': {'contentType': 'application/octet-stream'}}
                          if self.kind == 'nested' else {'contentType': 'application/octet-stream'}),
                         {'contentType': 'application/json'}]}
        if self.version == '2.0':
            return {'operationId': 'postItems', 'summary': 'Inspect items',
                    'consumes': ['application/octet-stream'], 'produces': ['application/octet-stream'],
                    'parameters': [{'name': 'payload', 'in': 'body', 'required': True, 'schema': binary}],
                    'responses': {'200': {'description': 'File response', 'schema': {'$ref': './model.' + format + '#/File'}}}}
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': {self.media: media}},
                'responses': {'200': {'description': 'Actual response', 'content': {self.media: media}}}}

    def prepare(self, directory):
        self.payloads = {}
        for name, number in [('exact', '9007199254740993'), ('rounded', '9007199254740992')]:
            path = directory / ('opaque.bin' if self.kind == 'named' else name + '.bin')
            raw = OCTETS if self.kind == 'named' else binary_wire(self.kind, number)
            path.write_bytes(raw)
            self.payloads[name] = (path, raw)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise RuntimeError('Owned binary server did not stop')


def execute_binary(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import activate_control, complete_problems, contains, design_values, focus_control, keys, text_keys, wait_tree
    from native_focus import wait_for_initial_focus
    from native_multipart import edit_named_body

    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'), 'Binary operation selection failed')
    activate_control(native, process.pid, 'Try')
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Send'), 'Binary request controls are unavailable')
    metadata = None
    if fixture.kind == 'named':
        if file.suffix == '.json':
            values = re.findall(r'"metadata": (\{\s*"id": 9007199254740993\s*\})', file.read_text())
            assert len(values) == 2 and all(json.loads(value) == {'id': 9007199254740993} for value in values)
            metadata = values[0]
        activate_control(native, process.pid, 'Examples · ' + fixture.media + ' · exact')
    checks = []
    start = len(fixture.records)
    for name, number in [('exact', '9007199254740993'), ('rounded', '9007199254740992')]:
        path, original = fixture.payloads[name]
        if fixture.kind == 'named' and name == 'rounded':
            focus_control(native, process.pid, 'Include request body')
            edit_named_body(native, process.pid, '9007199254740993', backwards=False)
        else:
            activate_control(native, process.pid, 'Add binary file' if fixture.kind == 'named' else 'Use binary file')
            with native.transient_dialog():
                keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(path)) + ['Return'])
            wait_for_initial_focus(native.ready, timeout=8)
            wait_tree(native, process.pid, lambda nodes: contains(nodes, path.name), 'The native file picker did not retain its selected binary file')
        activate_control(native, process.pid, 'Send')
        expected = ('HTTP received · contract checks passed' if name == 'exact' or fixture.kind == 'raw'
                    else 'HTTP received · contract findings require review')
        nodes = wait_tree(native, process.pid, lambda nodes: len(fixture.records) == start + len(checks) + 1 and contains(nodes, expected), 'Binary byte conformance did not complete')
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        assert record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        boundary = 'Fixture'
        if fixture.kind == 'named':
            media = Message()
            media['content-type'] = headers['content-type']
            assert media.get_content_type() == 'multipart/form-data'
            boundary = media.get_param('boundary')
            assert isinstance(boundary, str) and re.fullmatch(r'busyapi-[0-9a-f]{48}', boundary)
            assert headers['content-type'] == 'multipart/form-data; boundary=' + boundary
        else:
            assert headers['content-type'] == fixture.media
        body = binary_wire(fixture.kind, number, boundary, metadata)
        assert record['body'] == body
        if body:
            assert any(node['text'] == body.hex(' ')[:1024] for node in nodes)
        destination = evidence / (case + '-binary-' + phase + '-' + name + '.bin')
        assert not destination.exists()
        activate_control(native, process.pid, 'Export original entity bytes')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: destination.is_file(), 'Native binary export did not complete')
        assert not destination.is_symlink() and destination.read_bytes() == body
        assert path.read_bytes() == original
        assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
        checks.append({'example': name, 'method': 'POST', 'target': '/items', 'input': 'keyboard',
                       'bodySha256': hashlib.sha256(body).hexdigest(), 'bytes': len(body),
                       'expectedStatus': expected, 'exactResponse': True, 'fileUnchanged': True})
        print('Native binary request: ' + json.dumps(checks[-1]), flush=True)
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'Binary execution changed the authored contract')
    return {'complete': True, 'kind': fixture.kind, 'phase': phase, 'requests': checks, 'sourceUnchanged': True}
