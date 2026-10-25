import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _cookieLines = [
  'lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT',
  'foo=bar',
];

(String, String) _sources(String version, String format, int port) {
  final swagger = version == '2.0';
  final modern = version.startsWith('3.1.') || version.startsWith('3.2.');
  final sequential = version.startsWith('3.2.');
  final exact = {
    'type': 'array',
    'minItems': 2,
    'maxItems': 2,
    'items': {
      'type': 'integer',
      'enum': [0, 'EXACT'],
    },
  };
  final headers = {
    'X-Values': swagger
        ? {...exact, 'collectionFormat': 'csv'}
        : {'schema': exact},
    'X-Empty': swagger
        ? {
            'type': 'string',
            'enum': [''],
          }
        : {
            'schema': {
              'type': 'string',
              'enum': [''],
            },
          },
    'X-Flag': swagger
        ? {
            'type': 'boolean',
            'enum': [false],
          }
        : {
            'schema': {
              'type': 'boolean',
              'enum': [false],
            },
          },
    if (modern) 'X-Any': {'schema': true},
    if (modern) 'X-Reject': {'schema': false},
    if (sequential) ...{
      'Set-Cookie': {
        'content': {
          'text/plain': {
            'schema': {
              'type': 'string',
              'enum': [_cookieLines.join('\n')],
            },
          },
        },
      },
      'X-Items': {
        'content': {
          'application/x-ndjson': {
            'schema': {'type': 'array', 'minItems': 1},
            'itemSchema': {
              'type': 'integer',
              'enum': [0, 'EXACT'],
            },
          },
        },
      },
    },
  };
  final response = {'description': 'Captured headers', 'headers': headers};
  String render(Object value) =>
      const JsonEncoder.withIndent('  ')
          .convert(value)
          .replaceAll('"EXACT"', '9007199254740992.00');
  final root = format == 'yaml'
      ? '\uFEFF# Retain root 雪\r\n'
            '${swagger ? 'swagger' : 'openapi'}: "$version"\r\n'
            'info: {title: BeforeRoot, version: api-version}\r\n'
            '${swagger ? 'host: "127.0.0.1:$port"\r\nschemes: [http]\r\n' : 'servers: [{url: "http://127.0.0.1:$port"}]\r\n'}'
            'paths:\r\n  /headers:\r\n    get:\r\n      responses: {"204": {\$ref: "responses.yaml#/Response"}}\r\n'
      : render({
          if (swagger) 'swagger': version else 'openapi': version,
          'info': {'title': 'BeforeRoot', 'version': 'api-version'},
          if (swagger) ...{
            'host': '127.0.0.1:$port',
            'schemes': ['http'],
          } else
            'servers': [
              {'url': 'http://127.0.0.1:$port'},
            ],
          'paths': {
            '/headers': {
              'get': {
                'responses': {
                  '204': {r'$ref': 'responses.json#/Response'},
                },
              },
            },
          },
        });
  final fragment = format == 'yaml'
      ? '# Retain response alias and exact number\r\nResponse: &response ${render(response)}\r\n'
      : render({'Response': response});
  return (root, fragment);
}

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format direct, captured cases and installed CLI share native header semantics',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-header-wire-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final modern =
              version.startsWith('3.1.') || version.startsWith('3.2.');
          final sequential = version.startsWith('3.2.');
          var valid = true;
          final requests = <(String, String, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            requests.add((request.method, request.uri.toString(), bytes));
            request.response.statusCode = 204;
            request.response.headers.noFolding('X-Values');
            request.response.headers.set('X-Values', [
              '0',
              valid ? '9007199254740993.000' : '9007199254740992',
            ]);
            request.response.headers.set('X-Empty', '');
            request.response.headers.set('X-Flag', 'false');
            if (modern) {
              request.response.headers.set('X-Any', 'literal,false');
              if (!valid) request.response.headers.set('X-Reject', 'anything');
            }
            if (sequential) {
              request.response.headers.set(
                'Set-Cookie',
                valid ? _cookieLines : [_cookieLines.first, 'foo=wrong'],
              );
              request.response.headers.set(
                'X-Items',
                valid ? '9007199254740993' : '9007199254740992',
              );
            }
            await request.response.close();
          });
          final sources = _sources(version, format, server.port);
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(sources.$1);
          final fragment = File('${directory.path}/responses.$format')
            ..writeAsStringSync(sources.$2);
          final manifest = File('${directory.path}/busyapi.yaml')
            ..writeAsStringSync(
              'version: 1\nroots: [{name: api, path: api.$format}]\ntests: [{name: headers, operation: {method: GET, path: /headers}, expect: {status: 204}}]\n',
            );
          final original = file.readAsBytesSync(),
              originalFragment = fragment.readAsBytesSync(),
              originalManifest = manifest.readAsBytesSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(directory.path, engine);
          addTearDown(() => project.close());
          final root = file.uri.toString(),
              buffer = await project.buffer(root),
              shared = await project.buffer(fragment.uri.toString());
          final workingRoot = buffer.text.replaceFirst(
            'BeforeRoot',
            'CapturedRoot',
          );
          final workingFragment = shared.text.replaceAll(
            '9007199254740992.00',
            '9007199254740993.00',
          );
          project.store.replace(buffer.id, workingRoot);
          project.store.replace(shared.id, workingFragment);
          final checked = await project.check(root);
          expect(
            checked['status'],
            'complete',
            reason: '${checked['findings']}',
          );
          final operation = (checked['projection']['operations'] as List)
              .cast<Map>()
              .single;
          final plan = await project.prepareRequest(
            root,
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          Future<ContractRequestResult> send() async {
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(planIdentity: plan.identity),
              resolveSecret: (_) async => null,
            );
            addTearDown(result.close);
            expect(result.response.status, 204);
            expect(await result.response.bytes(), isEmpty);
            expect(result.outgoing.complete && result.outgoing.valid, true);
            return result;
          }

          final good = await send();
          expect(
            good.received.complete,
            true,
            reason: '${good.received.findings}',
          );
          expect(good.conforming, true, reason: '${good.received.findings}');
          expect(
            good.response.headers
                .where((header) => header.$1 == 'x-values')
                .map((header) => header.$2),
            ['0', '9007199254740993.000'],
          );
          if (sequential)
            expect(
              good.response.headers
                  .where((header) => header.$1 == 'set-cookie')
                  .map((header) => header.$2),
              _cookieLines,
            );
          valid = false;
          final bad = await send();
          expect(
            bad.received.complete,
            true,
            reason: '${bad.received.findings}',
          );
          expect(bad.received.valid, false);
          expect(bad.conforming, false);
          for (final name in [
            'X-Values',
            if (modern) 'X-Reject',
            if (sequential) ...['Set-Cookie', 'X-Items'],
          ]) {
            expect(
              bad.received.findings.any((finding) {
                final schema = finding['schema'];
                final range = schema is Map && schema['range'] is List
                    ? (schema['range'] as List).cast<int>()
                    : const <int>[];
                return finding['code'] == 'runtime.schema.incompatible' &&
                    finding['location'] == name &&
                    schema is Map &&
                    schema['resource'] == shared.id &&
                    range.length == 2 &&
                    range.last > range.first;
              }),
              true,
              reason: '$name: ${bad.received.findings}',
            );
          }
          valid = true;
          final report = await const ContractTestRunner().run(
            project,
            root,
            selectedCases: ['headers'],
            saved: false,
            resolveSecret: (_) async => null,
          );
          expect(report.saved, false);
          expect(
            report.complete && report.passed,
            true,
            reason: '${report.toJson()}',
          );
          final before = await runCliWithSecrets([
            'test',
            directory.path,
            '--case',
            'headers',
            '--json',
          ], {});
          expect(before.code, isNot(0));
          final beforeReport = jsonDecode(before.output) as Map;
          expect(beforeReport['complete'], true, reason: before.output);
          expect(beforeReport['passed'], false);
          expect(beforeReport['input'], 'saved-source');
          project.store.replace(
            shared.id,
            workingFragment.replaceAll(
              '9007199254740993.00',
              '9007199254740994.00',
            ),
          );
          expect(plan.outdated, true);
          final retained = await const ContractRequestExecutor()
              .validateResponse(
                plan,
                good.response,
                'captured-header-retained',
              );
          expect(
            retained.complete && retained.valid,
            true,
            reason: '${retained.findings}',
          );
          project.store.replace(shared.id, workingFragment);
          expect(file.readAsBytesSync(), original);
          expect(fragment.readAsBytesSync(), originalFragment);
          expect(manifest.readAsBytesSync(), originalManifest);
          expect(
            (await PublicationStore(
              '${directory.path}/publication',
            ).save(project, [buffer, shared])).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(directory.path, engine);
          expect((await project.buffer(root)).text, workingRoot);
          expect(
            (await project.buffer(fragment.uri.toString())).text,
            workingFragment,
          );
          final after = await runCliWithSecrets([
            'test',
            directory.path,
            '--case',
            'headers',
            '--json',
          ], {});
          expect(after.code, 0, reason: '${after.output}\n${after.error}');
          expect(jsonDecode(after.output)['passed'], true);
          expect(file.readAsBytesSync(), [
            ...(format == 'yaml' ? [239, 187, 191] : <int>[]),
            ...utf8.encode(workingRoot),
          ]);
          expect(fragment.readAsBytesSync(), utf8.encode(workingFragment));
          expect(manifest.readAsBytesSync(), originalManifest);
          expect(requests, hasLength(5));
          for (final request in requests) {
            expect(request.$1, 'GET');
            expect(request.$2, '/headers');
            expect(request.$3, isEmpty);
          }
        },
      );
    }
  }
}
