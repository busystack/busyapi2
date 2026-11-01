import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

(String, String) _sources(String version, String format, int port) {
  final modern = version.startsWith('3.1.');
  final schema = {
    'type': 'array',
    'items': {
      'anyOf': [
        {
          'type': 'string',
          'enum': ['one,雪', 'a&=+%', ''],
        },
        {
          'type': 'integer',
          'enum': [0, 'EXACT'],
        },
        {'type': 'boolean'},
        if (modern)
          {'type': 'null'}
        else
          {
            'type': 'string',
            'nullable': true,
            'enum': [null],
          },
      ],
    },
  };
  Map<String, Object?> parameter(String name, {bool required = false}) => {
    'name': name,
    'in': 'cookie',
    'required': required,
    'style': 'form',
    'explode': false,
    'schema': name == 'Object'
        ? {
            'type': 'object',
            'properties': {
              'x': {'type': 'string'},
            },
            'additionalProperties': false,
          }
        : {r'$ref': '#/List'},
  };
  final declarations = {
    'List': schema,
    'Required': parameter('Value', required: true),
    'Optional': parameter('Optional'),
    'Object': parameter('Object'),
    'x-literal': {r'$ref': 'literal', 'number': 'EXACT'},
  };
  final parameters = [
    for (final name in ['Required', 'Optional', 'Object'])
      {r'$ref': './parameters.$format#/$name'},
  ];
  final document = {
    'openapi': version,
    'info': {'title': 'BeforeCookie', 'version': 'api-version'},
    'servers': [
      {'url': 'http://127.0.0.1:$port/v1'},
    ],
    'paths': {
      '/cookies': {
        'post': {
          'parameters': parameters,
          'responses': {
            '204': {'description': 'Accepted'},
          },
        },
      },
    },
  };
  if (format == 'json') {
    return (
      '\ufeff${jsonEncode(document)}\r\n',
      '${jsonEncode(declarations).replaceAll('"EXACT"', '9007199254740992.00')}\r\n',
    );
  }
  return (
    '\ufeff# Retain root organization\r\nopenapi: $version\r\n'
        'info: {title: BeforeCookie, version: api-version}\r\n'
        'servers: [{url: "http://127.0.0.1:$port/v1"}]\r\n'
        'paths:\r\n  /cookies:\r\n    post:\r\n'
        '      parameters: ${jsonEncode(parameters)}\r\n'
        '      responses: {"204": {description: Accepted}}\r\n',
    '# Retain shared declarations 雪\r\n${declarations.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}\r\n').join().replaceAll('"EXACT"', '9007199254740992.00')}',
  );
}

void main() {
  for (final version in [
    '3.0.0',
    '3.0.1',
    '3.0.2',
    '3.0.3',
    '3.0.4',
    '3.1.0',
    '3.1.1',
    '3.1.2',
  ]) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format non-exploded cookies preserve one-item boundaries and omit empty collections',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-cookie-unexploded-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final seen = <(String, String, String?, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final body = await request.fold<List<int>>(
              [],
              (bytes, chunk) => bytes..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('cookie'),
              body,
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          final sources = _sources(version, format, server.port);
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(sources.$1);
          final fragment = File('${directory.path}/parameters.$format')
            ..writeAsStringSync(sources.$2);
          final manifest = File('${directory.path}/busyapi.yaml')
            ..writeAsStringSync(
              jsonEncode({
                'version': 1,
                'roots': [
                  {'name': 'api', 'path': 'api.$format'},
                ],
                'tests': [
                  for (final name in ['text', 'exact'])
                    {
                      'name': name,
                      'operation': {'method': 'POST', 'path': '/cookies'},
                      'parameters': {
                        'cookie': {
                          'Value': name == 'text' ? ['one,雪'] : ['EXACT'],
                        },
                      },
                      'expect': {'status': 204},
                    },
                ],
              }).replaceAll('"EXACT"', '9007199254740993.00'),
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
            'BeforeCookie',
            'CapturedCookie',
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
          expect(
            (checked['findings'] as List).whereType<Map>().where(
              (finding) => finding['severity'] == 'error',
            ),
            isEmpty,
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
          Map<String, RequestValue> values(
            String text, {
            String optional = '[]',
            String object = '{}',
          }) => {
            OperationRequestDraft.parameterKey('cookie', 'Value'):
                RequestValue.json(text),
            OperationRequestDraft.parameterKey('cookie', 'Optional'):
                RequestValue.json(optional),
            OperationRequestDraft.parameterKey('cookie', 'Object'):
                RequestValue.json(object),
          };
          Future<ContractRequestResult> send(
            Map<String, RequestValue> parameters,
          ) => const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: parameters,
            ),
            resolveSecret: (_) async => null,
          );
          for (final (text, wire) in [
            ('["one,雪"]', 'one%2C%E9%9B%AA'),
            ('["a&=+%"]', 'a%26%3D%2B%25'),
            ('[""]', ''),
            ('[false]', 'false'),
            ('[0]', '0'),
            ('[9007199254740993.00]', '9007199254740993.00'),
            ('[null]', 'null'),
          ]) {
            final result = await send(values(text));
            addTearDown(result.close);
            expect(
              result.conforming,
              true,
              reason: '${result.outgoing.findings} ${result.received.findings}',
            );
            expect(seen.last.$3, 'Value=$wire');
          }
          for (final (parameters, code, pointer) in [
            (
              values('[]'),
              'request.parameter.empty-serialization',
              '/Required',
            ),
            (values('["one,雪",""]'), 'request.cookie.encoding', '/Required'),
            (
              values('["one,雪"]', object: '{"x":"one"}'),
              'request.cookie.encoding',
              '/Object',
            ),
            (values('[["one,雪"]]'), 'request.parameter.nesting', '/Required'),
          ]) {
            await expectLater(
              send(parameters),
              throwsA(
                isA<CoreFailure>()
                    .having((error) => error.code, 'code', code)
                    .having(
                      (error) => error.source?.resource,
                      'resource',
                      shared.id,
                    )
                    .having(
                      (error) => error.source?.pointer,
                      'pointer',
                      pointer,
                    ),
              ),
            );
            expect(
              seen,
              hasLength(7),
              reason: 'Unsupported representations must not dispatch',
            );
          }
          final report = await const ContractTestRunner().run(
            project,
            root,
            selectedCases: ['text', 'exact'],
            saved: false,
            resolveSecret: (_) async => null,
          );
          expect(
            report.complete && report.passed,
            true,
            reason: '${report.toJson()}',
          );
          expect(seen, hasLength(9));
          final textCase = await runCliWithSecrets([
            'test',
            directory.path,
            '--case',
            'text',
            '--json',
          ], {});
          expect(
            textCase.code,
            0,
            reason: '${textCase.output}\n${textCase.error}',
          );
          expect(seen.last.$3, 'Value=one%2C%E9%9B%AA');
          final before = await runCliWithSecrets([
            'test',
            directory.path,
            '--case',
            'exact',
            '--json',
          ], {});
          expect(before.code, 1, reason: before.output);
          final beforeReport = jsonDecode(before.output) as Map;
          expect(beforeReport['complete'], true, reason: before.output);
          expect(beforeReport['passed'], false);
          expect(beforeReport['input'], 'saved-source');
          final beforeCase = (beforeReport['cases'] as List).cast<Map>().single;
          expect(beforeCase['dispatched'], true);
          expect(
            (beforeCase['findings'] as List).whereType<Map>().any(
              (finding) =>
                  finding['code'] == 'runtime.schema.incompatible' &&
                  finding['subject'] == 'request-parameter' &&
                  finding['schema'] is Map &&
                  finding['schema']['resource'] == shared.id,
            ),
            true,
            reason: before.output,
          );
          expect(seen, hasLength(11));
          expect(seen.last.$3, 'Value=9007199254740993.00');
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
          expect((await project.buffer(shared.id)).text, workingFragment);
          final after = await runCliWithSecrets([
            'test',
            directory.path,
            '--case',
            'exact',
            '--json',
          ], {});
          expect(after.code, 0, reason: '${after.output}\n${after.error}');
          expect(jsonDecode(after.output)['passed'], true);
          expect(seen, hasLength(12));
          expect(seen.last.$3, 'Value=9007199254740993.00');
          for (final request in seen) {
            expect(request.$1, 'POST');
            expect(request.$2, '/v1/cookies');
            expect(request.$4, isEmpty);
          }
          expect(manifest.readAsBytesSync(), originalManifest);
          expect(file.readAsBytesSync(), [
            239,
            187,
            191,
            ...utf8.encode(workingRoot),
          ]);
          expect(fragment.readAsStringSync(), workingFragment);
        },
      );
    }
  }
}
