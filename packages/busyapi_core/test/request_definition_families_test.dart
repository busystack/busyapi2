import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final rootVersion in ['3.1.2', '3.2.1']) {
    for (final definitionVersion in ['3.1.2', '3.2.1']) {
      for (final format in ['yaml', 'json']) {
        test('$rootVersion $format sends cookies using $definitionVersion definitions', () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-request-owners-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <(String, String, String?, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('cookie'),
              bytes,
            ));
            request.response.statusCode = 200;
            request.response.headers.add('X-Values', '9007199254740993.000,0');
            await request.response.close();
          });
          final newer = definitionVersion.startsWith('3.2.');
          final root = File('${temp.path}/api.$format');
          final definitions = File('${temp.path}/definitions.$format');
          final sources = {
            root: {
              'openapi': rootVersion,
              'info': {
                'title': 'Mixed family request',
                'version': 'api-version',
              },
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}/v1'},
              ],
              'paths': {
                '/cookies': {
                  'post': {
                    'parameters': [
                      {
                        r'$ref':
                            'definitions.$format#/components/parameters/Value~1~0',
                      },
                    ],
                    'responses': {
                      '200': {
                        'description': 'Values',
                        'headers': {
                          'X-Values': {
                            r'$ref':
                                'definitions.$format#/components/headers/Value~1~0',
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
            definitions: {
              'openapi': definitionVersion,
              'info': {'title': 'Definitions', 'version': 'api-version'},
              'paths': <String, Object?>{},
              'components': {
                'parameters': {
                  'Value/~': {
                    'name': 'Value',
                    'in': 'cookie',
                    'required': true,
                    'style': newer ? 'cookie' : 'form',
                    if (!newer) 'explode': false,
                    'schema': {
                      'type': 'array',
                      'minItems': 1,
                      'items': {'type': 'string'},
                    },
                  },
                },
                'headers': {
                  'Value/~': {
                    'required': true,
                    'schema': {
                      'type': 'array',
                      'minItems': 2,
                      'maxItems': 2,
                      'items': {
                        'type': 'integer',
                        'enum': ['EXACT', 0],
                      },
                    },
                  },
                },
              },
            },
          };
          final original = <File, String>{};
          for (final entry in sources.entries) {
            final text =
                '${format == 'yaml' ? '# Keep definition source 雪\r\n' : ''}${jsonEncode(entry.value).replaceAll('"EXACT"', '9007199254740993.000')}\r\n';
            original[entry.key] = text;
            await entry.key.writeAsString(text);
          }
          final manifest = File('${temp.path}/busyapi.yaml');
          final configuration = jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'tests': [
              {
                'name': 'owned-cookie',
                'operation': {'method': 'post', 'path': '/cookies'},
                'parameters': {
                  'cookie': {
                    'Value': newer
                        ? ['100%25', '', 'false', '9007199254740993']
                        : ['雪'],
                  },
                },
                'expect': {'status': 200},
              },
            ],
          });
          await manifest.writeAsString(configuration);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          await project.buffer(root.uri.toString());
          await project.buffer(definitions.uri.toString());
          final checked = await project.check(root.uri.toString());
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
            root.uri.toString(),
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: {
                OperationRequestDraft.parameterKey(
                  'cookie',
                  'Value',
                ): RequestValue.json(
                  newer ? '["100%25","","false","9007199254740993"]' : '["雪"]',
                ),
              },
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(
            result.outgoing.complete && result.outgoing.valid,
            true,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.received.complete && result.received.valid,
            true,
            reason: '${result.received.findings}',
          );
          expect(result.conforming, true);
          expect(result.response.status, 200);
          expect(await result.response.bytes(), isEmpty);
          expect(seen, hasLength(1));
          expect(seen.single.$1, 'POST');
          expect(seen.single.$2, '/v1/cookies');
          expect(
            seen.single.$3,
            newer
                ? 'Value=100%25; Value=; Value=false; Value=9007199254740993'
                : 'Value=%E9%9B%AA',
          );
          expect(seen.single.$4, isEmpty);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'owned-cookie', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
          expect(seen, hasLength(2));
          expect(seen.last.$1, seen.first.$1);
          expect(seen.last.$2, seen.first.$2);
          expect(seen.last.$3, seen.first.$3);
          expect(seen.last.$4, isEmpty);
          expect(await manifest.readAsString(), configuration);
          for (final entry in original.entries) {
            expect(await entry.key.readAsString(), entry.value);
            expect(
              project.store.get(entry.key.uri.toString()).text,
              entry.value,
            );
          }
        });
      }
    }
  }
}
