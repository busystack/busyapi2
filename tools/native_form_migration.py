"""Real-input qualification of URL-encoded form migration and exact HTTP."""
from contextlib import AbstractContextManager
import hashlib
import http.server
import json
from pathlib import Path
import threading


class FormMigrationFixture(AbstractContextManager):
    form_migration = True
    media = 'application/x-www-form-urlencoded'

    def __init__(self):
        self.records = []
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get('content-length', '0'))
                if not 0 <= length <= 1024 * 1024:
                    self.send_error(413)
                    return
                body = self.rfile.read(length)
                fixture.records.append({'method': self.command, 'target': self.path,
                                        'headers': dict(self.headers.items()), 'body': body})
                response = b'{"id":9007199254740993.00}'
                self.send_response(200)
                self.send_header('content-type', 'application/json')
                self.send_header('content-length', str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def operation(self, format):
        properties = {
            'n': {'type': 'integer', 'enum': [9007199254740993]},
            'flag': {'type': 'boolean', 'default': False},
            'empty': {'type': 'string', 'maxLength': 0},
            'label': {'type': 'string'},
            'ids': {'type': 'array', 'items': {'type': 'integer'}, 'minItems': 2},
            'csv': {'type': 'array', 'items': {'type': 'integer'}, 'minItems': 2},
        }
        return {'operationId': 'postItems', 'summary': 'Inspect items',
                'requestBody': {'required': True, 'content': {self.media: {
                    'schema': {'type': 'object', 'required': ['n'], 'properties': properties},
                    'encoding': {'ids': {'style': 'form'}, 'csv': {'explode': False}},
                }}},
                'responses': {'200': {'description': 'Actual JSON response', 'content': {
                    'application/json': {'schema': {'$ref': './model.' + format + '#/Item'}},
                }}}}

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        assert not self.thread.is_alive()


def execute_form_migration(native, process, file, baseline, version, fixture, evidence, case, phase):
    from test_openapi_application import activate_control, contains, field_matches, focus_control, keys, mode, wait_tree
    from native_swagger_forms import _focus_entry, _json_keys

    activate_control(native, process.pid, 'POST /items')
    mode(native, process.pid, 'reference')
    nodes = wait_tree(native, process.pid, lambda nodes: field_matches(nodes, 'Search', editable=True) and contains(nodes, 'Try') and contains(nodes, 'Inspect items'),
              'Migrated form operation did not retain native request navigation')
    (evidence / (case + '-' + phase + '-request-controls.json')).write_text(json.dumps(nodes, ensure_ascii=False, indent=2) + '\n')
    focus_control(native, process.pid, 'Try', tabs=128, backwards=True)
    keys(native, ['Return'])
    nodes = wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Send'), 'Native form request controls are unavailable')
    if not contains(nodes, 'Use an exact JSON value'):
        activate_control(native, process.pid, 'Include request body')
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Use an exact JSON value'), 'Native form body editor is unavailable')
    activate_control(native, process.pid, 'Use an exact JSON value')
    _focus_entry(native, process.pid, 'Use an exact JSON value')
    data = '{"n":9007199254740993,"flag":false,"empty":"","label":"\\u96ea","free":{"n":9007199254740993,"nil":null,"flag":false,"zero":0,"text":"\\u96ea"},"ids":[0,2],"csv":[0,2]}'
    keys(native, ['Control_L+a'] + _json_keys(data))
    checks = []
    for number, status in [('9007199254740993', 'HTTP received · contract checks passed'),
                           ('9007199254740992', 'HTTP received · contract findings require review')]:
        if checks:
            _focus_entry(native, process.pid, 'Use an exact JSON value')
            wait_tree(native, process.pid,
                lambda nodes: any(node['editable'] and node['focused'] and node['text'] == data for node in nodes),
                'The native form body no longer matches its exact fixture before editing')
            replacement = data.replace('"n":9007199254740993', '"n":9007199254740992', 1)
            assert replacement != data and replacement.count('9007199254740993') == 1
            keys(native, ['Control_L+a'] + _json_keys(replacement))
            wait_tree(native, process.pid,
                lambda nodes: any(node['editable'] and node['focused'] and node['text'] == replacement for node in nodes),
                'The native form edit changed more than its top-level numeric value')
        count = len(fixture.records)
        activate_control(native, process.pid, 'Send')
        wait_tree(native, process.pid, lambda nodes: len(fixture.records) == count + 1 and contains(nodes, status),
                  'Native form request did not retain its expected conformance class')
        record = fixture.records[-1]
        headers = {name.lower(): value for name, value in record['headers'].items()}
        assert record['method'] == 'POST' and record['target'] == '/items'
        assert headers['host'] == '127.0.0.1:' + str(fixture.port)
        assert headers['content-type'] == fixture.media
        expected = ('n=' + number + '&flag=false&empty=&label=%E9%9B%AA&free=%7B%22n%22%3A9007199254740993%2C%22nil%22%3Anull%2C%22flag%22%3Afalse%2C%22zero%22%3A0%2C%22text%22%3A%22%5Cu96ea%22%7D&ids=0&ids=2&csv=0'
                    + ('%2C' if version == '2.0' else ',') + '2').encode()
        assert record['body'] == expected, record
        destination = evidence / (case + '-form-migration-' + phase + '-' + number + '.bin')
        destination.write_bytes(record['body'])
        checks.append({'number': number, 'method': 'POST', 'target': '/items', 'exactWire': True,
                       'bodySha256': hashlib.sha256(record['body']).hexdigest(), 'bytes': len(record['body'])})
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    return {'kind': 'form-migration', 'phase': phase, 'requests': checks, 'sourceUnchanged': True}
