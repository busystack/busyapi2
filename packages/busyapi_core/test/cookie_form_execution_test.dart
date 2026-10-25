import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

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
    '3.2.0',
    '3.2.1',
  ]) {
    for (final format in ['yaml', 'json']) {
      test('$version $format composite form cookies retain actual field bytes', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-cookie-form-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <(String, String, String?, List<int>)>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final body = await request.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
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
        final document = {
          'openapi': version,
          'info': {'title': 'Native form cookies', 'version': 'api-version'},
          'servers': [
            {'url': 'http://127.0.0.1:${server.port}/v1'},
          ],
          'paths': {
            '/cookies': {
              'post': {
                'security': [
                  {'Key': <String>[]},
                  <String, Object?>{},
                ],
                'parameters': [
                  {
                    'name': 'Colors',
                    'in': 'cookie',
                    'required': true,
                    'style': 'form',
                    'explode': true,
                    'schema': {
                      'type': 'array',
                      'minItems': 2,
                      'maxItems': 2,
                      'items': {
                        'type': 'string',
                        'enum': ['雪', 'a&b'],
                      },
                    },
                  },
                  {
                    'name': 'Object',
                    'in': 'cookie',
                    'required': true,
                    'style': 'form',
                    'explode': true,
                    'schema': {
                      'type': 'object',
                      'required': ['zero', 'flag', '雪'],
                      'additionalProperties': false,
                      'properties': {
                        'zero': {
                          'type': 'integer',
                          'enum': [0],
                        },
                        'flag': {
                          'type': 'boolean',
                          'enum': [false],
                        },
                        '雪': {
                          'type': 'integer',
                          'enum': [0],
                        },
                      },
                    },
                  },
                  {
                    'name': 'Plain',
                    'in': 'cookie',
                    'required': true,
                    'schema': {
                      'type': 'string',
                      'enum': ['100%'],
                    },
                  },
                  {
                    'name': 'flag',
                    'in': 'cookie',
                    'schema': {'type': 'boolean'},
                  },
                ],
                'responses': {
                  '204': {'description': 'Accepted'},
                },
              },
            },
          },
          'components': {
            'securitySchemes': {
              'Key': {'type': 'apiKey', 'in': 'cookie', 'name': 'flag'},
            },
          },
        };
        final source = File('${temp.path}/api.$format');
        final original =
            '${format == 'yaml' ? '# Retain cookie source\r\n' : ''}${jsonEncode(document)}\r\n';
        await source.writeAsString(original);
        final manifest = File('${temp.path}/busyapi.yaml');
        final configuration = jsonEncode({
          'version': 1,
          'roots': [
            {'name': 'api', 'path': 'api.$format'},
          ],
          'environments': {
            'test': {
              'authentication': {
                'schemes': {
                  'Key': {'secretRef': '11111111-1111-4111-8111-111111111111'},
                },
              },
            },
          },
          'tests': [
            {
              'name': 'cookies',
              'operation': {'method': 'post', 'path': '/cookies'},
              'parameters': {
                'cookie': {
                  'Colors': ['雪', 'a&b'],
                  'Object': {'zero': 0, 'flag': false, '雪': 0},
                  'Plain': '100%',
                },
              },
              'expect': {'status': 204},
            },
          ],
        });
        await manifest.writeAsString(configuration);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(source.path, engine);
        addTearDown(project.close);
        final checked = await project.check(source.uri.toString());
        expect(checked['complete'], true, reason: '$checked');
        expect(
          (checked['findings'] as List).whereType<Map>().where(
            (finding) => finding['severity'] == 'error',
          ),
          isEmpty,
        );
        final operation = (checked['projection']['operations'] as List)
            .whereType<Map>()
            .single;
        final plan = await project.prepareRequest(
          source.uri.toString(),
          resource: operation['resource'] as String,
          pointer: operation['pointer'] as String,
          occurrence: operation['occurrence'] as String,
        );
        addTearDown(plan.close);
        final requestValues = {
          OperationRequestDraft.parameterKey('cookie', 'Colors'):
              const RequestValue.json('["雪","a&b"]'),
          OperationRequestDraft.parameterKey('cookie', 'Object'):
              const RequestValue.json('{"zero":0,"flag":false,"雪":0}'),
          OperationRequestDraft.parameterKey('cookie', 'Plain'):
              const RequestValue.text('100%'),
        };
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: requestValues,
          ),
          resolveSecret: (_) async => null,
        );
        addTearDown(result.close);
        expect(result.response.status, 204);
        expect(result.outgoing.complete, true);
        expect(
          result.outgoing.valid,
          true,
          reason: '${result.outgoing.findings}',
        );
        expect(seen, hasLength(1));
        expect(seen.single.$1, 'POST');
        expect(seen.single.$2, '/v1/cookies');
        expect(
          seen.single.$3,
          'Colors=%E9%9B%AA&Colors=a%26b; zero=0&flag=false&%E9%9B%AA=0; Plain=100%25',
        );
        expect(seen.single.$4, isEmpty);
        for (final (values, code) in [
          (
            {
              ...requestValues,
              OperationRequestDraft.parameterKey('cookie', 'flag'):
                  const RequestValue.json('false'),
            },
            'request.cookie.duplicate',
          ),
          (
            {
              ...requestValues,
              OperationRequestDraft.parameterKey('cookie', 'Colors'):
                  const RequestValue.json('[]'),
            },
            'request.parameter.empty-serialization',
          ),
          (
            {
              ...requestValues,
              OperationRequestDraft.parameterKey('cookie', 'Colors'):
                  const RequestValue.json('[["雪"]]'),
            },
            'request.parameter.nesting',
          ),
        ]) {
          await expectLater(
            const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                parameters: values,
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                code,
              ),
            ),
          );
          expect(seen, hasLength(1));
        }
        await expectLater(
          const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: requestValues,
              environment: 'test',
              securityAlternative: 0,
            ),
            resolveSecret: (_) async => 'synthetic-cookie-secret',
          ),
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'code',
              'request.security.collision',
            ),
          ),
        );
        expect(
          seen,
          hasLength(1),
          reason: 'Grouping form fields must retain every credential collision owner',
        );
        if (format == 'json') {
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'cookies', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
          expect(seen, hasLength(2));
          expect(seen.last.$3, seen.first.$3);
          expect(seen.last.$4, isEmpty);
        }
        expect(await source.readAsString(), original);
        expect(await manifest.readAsString(), configuration);
      });
    }
  }
}
