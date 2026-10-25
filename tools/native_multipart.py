"""Owned loopback fixture and real-input multipart execution qualification."""
from contextlib import AbstractContextManager
import hashlib
import http.server
import json
from pathlib import Path
import threading


MEDIA = 'multipart/mixed; boundary=Fixture'


def multipart_wire(number, nested):
    second = (
        'Content-Type: multipart/mixed; boundary=Inner\r\n\r\n'
        '--Inner\r\nContent-Type: text/plain\r\n\r\nfalse\r\n'
        '--Inner\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n'
        'café 東京\r\n--Inner--\r\n'
        if nested else 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
    )
    return ('--Fixture\r\nContent-Type: application/json\r\n\r\n'
            '{"id":' + number + '}\r\n--Fixture\r\n' + second
            + '\r\n--Fixture--\r\n')


def multipart_operation(format, nested):
    second = ({'type': 'array', 'minItems': 2, 'maxItems': 2,
               'prefixItems': [{'type': 'boolean', 'const': False},
                               {'type': 'string', 'const': 'café 東京'}], 'items': False}
              if nested else {'type': 'string', 'maxLength': 0})
    media = {
        'schema': {'type': 'array', 'minItems': 2, 'maxItems': 2,
                   'prefixItems': [{'$ref': './model.' + format + '#/Item'}, second],
                   'items': False},
        'prefixEncoding': [
            {'contentType': 'application/json'},
            ({'contentType': 'multipart/mixed', 'itemEncoding': {'contentType': 'text/plain'}}
             if nested else {'contentType': 'text/plain; charset=utf-8'}),
        ],
        'examples': {
            name: {'serializedValue': multipart_wire(number, nested)}
            for name, number in [('exact', '9007199254740993.00'),
                                 ('rounded', '9007199254740992')]
        },
    }
    return {'operationId': 'postItems', 'summary': 'Inspect items',
            'requestBody': {'required': True, 'content': {MEDIA: media}},
            'responses': {'200': {'description': 'Actual response', 'content': {MEDIA: media}}}}


class MultipartFixture(AbstractContextManager):
    def __init__(self, kind):
        self.nested = kind == 'nested'
        self.records = []
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 <= length <= 1024 * 1024:
                    self.send_error(413)
                    return
                body = self.rfile.read(length)
                fixture.records.append({'method': self.command, 'target': self.path,
                                        'headers': dict(self.headers.items()), 'body': body})
                self.send_response(200)
                self.send_header('Content-Type', MEDIA)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise RuntimeError('Owned multipart server did not stop')


def execute_multipart(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import (
        activate_control, complete_problems, contains, design_values, keys, text_keys, wait_tree,
    )
    from native_focus import wait_for_initial_focus

    start = len(fixture.records)
    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'),
              'Multipart operation selection failed')
    activate_control(native, process.pid, 'Try')
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Examples · ' + MEDIA + ' · exact'),
              'Multipart request did not expose its serialized examples')
    checks = []
    for name, number, expected in [
        ('exact', '9007199254740993.00', 'HTTP received · contract checks passed'),
        ('rounded', '9007199254740992', 'HTTP received · contract findings require review'),
    ]:
        label = 'Examples · ' + MEDIA + ' · ' + name
        activate_control(native, process.pid, label, backwards=name == 'rounded')
        body = multipart_wire(number, fixture.nested).encode()
        wait_tree(native, process.pid,
                  lambda nodes: any(node['editable'] and number in (node['text'] or '') for node in nodes),
                  'The selected serialized multipart example was not retained')
        keys(native, ['Control_L+Return'])
        nodes = wait_tree(native, process.pid, lambda nodes: contains(nodes, expected),
                          'Native multipart conformance did not match its actual bytes')
        assert len(fixture.records) == start + len(checks) + 1
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        assert record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        assert headers['content-type'] == MEDIA and record['body'] == body
        preview = body.hex(' ')[:1024]
        assert any(node['text'] == preview for node in nodes), 'Native response byte preview changed'
        destination = evidence / (case + '-multipart-' + phase + '-' + name + '.bin')
        assert not destination.exists(), 'Response export destination already exists'
        activate_control(native, process.pid, 'Export original entity bytes')
        with native.transient_dialog():
            keys(native, ['Control_L+l', 'Control_L+a'] + text_keys(str(destination)) + ['Return'])
        wait_for_initial_focus(native.ready, timeout=8)
        wait_tree(native, process.pid, lambda nodes: destination.is_file(),
                  'Native response export did not create its reviewed destination')
        assert not destination.is_symlink() and destination.read_bytes() == body
        assert all(Path(path).read_bytes() == raw for path, raw in baseline.items())
        checks.append({'example': name, 'method': 'POST', 'target': '/items', 'input': 'keyboard',
                       'bodySha256': hashlib.sha256(body).hexdigest(),
                       'bytes': len(body), 'expectedStatus': expected, 'exactResponse': True})
        partial = {'complete': False, 'phase': phase, 'requests': checks,
                   'sourceUnchanged': True}
        (evidence / (case + '-multipart-' + phase + '.json')).write_text(
            json.dumps(partial, indent=2, ensure_ascii=False) + '\n')
        print('Native multipart request: ' + json.dumps(checks[-1]), flush=True)
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
              lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes),
              'Overview did not retain source after native multipart execution')
    result = {'complete': True, 'kind': 'nested' if fixture.nested else 'ordered', 'phase': phase,
              'requests': checks, 'sourceUnchanged': True}
    (evidence / (case + '-multipart-' + phase + '.json')).write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    return result
