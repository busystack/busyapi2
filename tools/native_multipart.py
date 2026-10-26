"""Owned loopback fixture and real-input multipart execution qualification."""
from contextlib import AbstractContextManager
import hashlib
import http.server
import json
import re
from email.message import Message
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


def named_multipart_wire(number, boundary, metadata=None):
    metadata = metadata if metadata is not None else '{"id":' + number + '}'
    return ('--' + boundary + '\r\nContent-Disposition: form-data; name="flag"\r\n'
            'Content-Type: text/plain\r\n\r\nfalse\r\n'
            '--' + boundary + '\r\nContent-Disposition: form-data; name="metadata"\r\n'
            'Content-Type: application/json\r\n\r\n' + metadata + '\r\n'
            '--' + boundary + '\r\nContent-Disposition: form-data; name="note"\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n\r\ncafé 東京\r\n'
            '--' + boundary + '--\r\n')


def named_multipart_operation(format):
    media = {
        'schema': {'type': 'object', 'required': ['flag', 'metadata', 'note'],
                   'properties': {
                       'flag': {'type': 'boolean', 'enum': [False]},
                       'metadata': {'$ref': './model.' + format + '#/Item'},
                       'note': {'type': 'string', 'enum': ['café 東京']},
                   }},
        'encoding': {'flag': {'contentType': 'text/plain'},
                     'metadata': {'contentType': 'application/json'},
                     'note': {'contentType': 'text/plain; charset=utf-8'}},
        'examples': {'exact': {'value': {'flag': False, 'metadata': {'id': 9007199254740993},
                                         'note': 'café 東京'}}},
    }
    return {'operationId': 'postItems', 'summary': 'Inspect items',
            'requestBody': {'required': True, 'content': {'multipart/mixed': media}},
            'responses': {'200': {'description': 'Actual response',
                                  'content': {'multipart/mixed': media}}}}


class MultipartFixture(AbstractContextManager):
    def __init__(self, kind):
        self.kind = kind
        self.nested = kind == 'nested'
        self.named = kind == 'named'
        self.media = 'multipart/mixed' if self.named else MEDIA
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
                self.send_header('Content-Type', self.headers['Content-Type'] if fixture.named else MEDIA)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def expected_problem_count(self):
        return 0 if self.named else 2

    def verify_authored_examples(self, report, resource):
        assert not self.named and report['complete'] is True
        field = MEDIA.replace('~', '~0').replace('/', '~1')
        owners = ['/paths/~1items/post/requestBody/content/' + field,
                  '/paths/~1items/post/responses/200/content/' + field]
        expected = {owner + '/examples/rounded/serializedValue' for owner in owners}
        findings = report['findings']
        assert len(findings) == self.expected_problem_count
        assert all(value['code'] == 'example.serialization.incompatible'
                   and value['severity'] == 'warning' and value['resource'] == resource
                   for value in findings)
        assert {value['pointer'] for value in findings} == expected
        schemas = report['categories'][0]['results']['openapi']['schema']
        checks = schemas['serializedExamples']
        assert len(checks) == 4 and all(value['complete'] is True for value in checks)
        assert {value['pointer'] for value in checks if value['valid'] is False} == expected
        assert len([value for value in checks if value['valid'] is True]) == 2
        return {'complete': True, 'warningCount': len(findings), 'evaluated': len(checks),
                'sources': sorted(expected), 'producerVersion': schemas['producerVersion']}

    def operation(self, format):
        return named_multipart_operation(format) if self.named else multipart_operation(format, self.nested)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise RuntimeError('Owned multipart server did not stop')


def edit_named_body(native, pid, original, *, backwards=True):
    from test_openapi_application import keys, tree, wait_tree

    for _ in range(64):
        nodes = tree(pid, details=True)
        matches = [node for node in nodes if node['editable'] and node['focused']
                   and original in (node['text'] or '')]
        if len(matches) == 1:
            value = matches[0]['text']
            break
        if len(matches) > 1:
            raise RuntimeError('More than one owned body field claims keyboard focus')
        keys(native, ['Shift_L+Tab' if backwards else 'Tab'])
    else:
        raise RuntimeError('Bounded reverse traversal did not reach the exact body draft')
    assert value.count(original) == 1
    offset = value.index(original) + len(original)
    keys(native, ['Control_L+Home'] + ['Right'] * offset)
    wait_tree(native, pid,
        lambda nodes: any(node['editable'] and node['focused'] and node['caret'] == offset
                          and node['text'] == value for node in nodes),
        'The multipart body caret did not reach the exact numeric boundary')
    keys(native, ['BackSpace', '2'])
    expected = value.replace(original, '9007199254740992', 1)
    wait_tree(native, pid,
        lambda nodes: any(node['editable'] and node['focused'] and node['text'] == expected for node in nodes),
        'The native body edit did not preserve its other exact values and Unicode')


def execute_multipart(native, process, file, baseline, version, fixture, evidence, case, phase):
    if getattr(fixture, 'saved_file_media', False):
        from native_saved_file_media import execute_saved_file_media
        return execute_saved_file_media(native, process, file, baseline, version, fixture, evidence, case, phase)
    if getattr(fixture, 'file_shapes', False):
        from native_file_shapes import execute_file_shapes
        return execute_file_shapes(native, process, file, baseline, version, fixture, evidence, case, phase)
    if getattr(fixture, 'header_generated', False):
        from native_generated_headers import execute_generated_headers
        return execute_generated_headers(native, process, file, baseline, version, fixture, evidence, case, phase)
    if getattr(fixture, 'header_content', False):
        from native_header_content import execute_header_content
        return execute_header_content(native, process, file, baseline, version, fixture, evidence, case, phase)
    if getattr(fixture, 'swagger_forms', False):
        from native_swagger_forms import execute_swagger_forms
        return execute_swagger_forms(native, process, file, baseline, version, fixture, evidence, case, phase)
    if getattr(fixture, 'binary', False):
        from native_binary import execute_binary
        return execute_binary(native, process, file, baseline, version, fixture, evidence, case, phase)
    from test_openapi_application import (
        activate_control, complete_problems, contains, design_values, keys, text_keys, wait_tree,
    )
    from native_focus import wait_for_initial_focus

    start = len(fixture.records)
    metadata = None
    if fixture.named and file.suffix == '.json':
        # The exact-value editor retains the authored JSON object's whitespace.
        # Request and response examples have equal values at different indents;
        # the request's first occurrence owns the outgoing representation.
        values = re.findall(r'"metadata": (\{\s*"id": 9007199254740993\s*\})', file.read_text())
        assert len(values) == 2 and all(json.loads(value) == {'id': 9007199254740993} for value in values)
        metadata = values[0]
    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Try') and contains(nodes, 'Inspect items'),
              'Multipart operation selection failed')
    activate_control(native, process.pid, 'Try')
    wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Examples · ' + fixture.media + ' · exact'),
              'Multipart request did not expose its serialized examples')
    checks = []
    for name, number, expected in [
        ('exact', '9007199254740993' if fixture.named else '9007199254740993.00', 'HTTP received · contract checks passed'),
        ('rounded', '9007199254740992', 'HTTP received · contract findings require review'),
    ]:
        label = 'Examples · ' + fixture.media + ' · ' + name
        if fixture.named and name == 'rounded':
            edit_named_body(native, process.pid, '9007199254740993')
        else:
            activate_control(native, process.pid, label, backwards=name == 'rounded')
        wait_tree(native, process.pid,
                  lambda nodes: any(node['editable'] and number in (node['text'] or '') for node in nodes),
                  'The selected serialized multipart example was not retained')
        if fixture.named:
            activate_control(native, process.pid, 'Send')
        else:
            keys(native, ['Control_L+Return'])
        nodes = wait_tree(native, process.pid, lambda nodes: contains(nodes, expected),
                          'Native multipart conformance did not match its actual bytes')
        assert len(fixture.records) == start + len(checks) + 1
        record = fixture.records[-1]
        headers = {key.lower(): value for key, value in record['headers'].items()}
        assert record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        if fixture.named:
            media = Message()
            media['content-type'] = headers['content-type']
            assert media.get_content_type() == 'multipart/mixed'
            boundary = media.get_param('boundary')
            assert isinstance(boundary, str) and re.fullmatch(r'busyapi-[0-9a-f]{48}', boundary)
            assert headers['content-type'] == 'multipart/mixed; boundary=' + boundary
            body = named_multipart_wire(number, boundary,
                metadata.replace('9007199254740993', number) if metadata is not None else None).encode()
        else:
            assert headers['content-type'] == MEDIA
            body = multipart_wire(number, fixture.nested).encode()
        assert record['body'] == body
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
              lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes, fixture.expected_problem_count),
              'Overview did not retain source after native multipart execution')
    result = {'complete': True, 'kind': fixture.kind, 'phase': phase,
              'requests': checks, 'sourceUnchanged': True}
    (evidence / (case + '-multipart-' + phase + '.json')).write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    return result
