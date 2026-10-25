import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test(
        'reviewed response status $version $format repairs consumers and changes actual conformance',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-response-status-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var received = 0;
          server.listen((request) async {
            received++;
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/renamed');
            expect(
              await request.fold<List<int>>(
                [],
                (bytes, chunk) => bytes..addAll(chunk),
              ),
              isEmpty,
            );
            request.response.statusCode = 202;
            request.response.headers.contentType = ContentType.text;
            request.response.headers.set('X-Trace', 'retained');
            request.response.write('okay');
            await request.response.close();
          });
          final legacy = version == '2.0',
              reference = '#/paths/~1renamed/get/responses/201';
          final data = {
            if (legacy) 'swagger': version else 'openapi': version,
            'info': {'title': 'Status 雪😀', 'version': '1'},
            if (legacy) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'produces': ['text/plain'],
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            'paths': {
              '/renamed': {
                'get': {
                  'responses': {
                    '201': {
                      'description': 'Kept response',
                      if (legacy) ...{
                        'schema': {'type': 'string'},
                        'headers': {
                          'X-Trace': {'type': 'string'},
                        },
                        'examples': {'text/plain': 'okay'},
                      } else ...{
                        'content': {
                          'text/plain': {
                            'schema': {'type': 'string'},
                            'example': 'okay',
                          },
                        },
                        'headers': {
                          'X-Trace': {
                            'schema': {'type': 'string'},
                          },
                        },
                      },
                    },
                  },
                },
              },
              '/consumer': {
                'get': {
                  'responses': {
                    '200': {r'$ref': reference},
                  },
                },
              },
            },
            'x-payload': {r'$ref': reference, 'number': 'EXACT'},
          };
          final original =
              '${format == 'yaml' ? '# retained status source\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(data).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
          File('${directory.path}/busyapi.yaml').writeAsStringSync(
            'version: 1\nroots: [{name: api, path: api.$format}]\ntests: [{name: status, operation: {method: GET, path: /renamed}, expect: {status: 202}}]\n',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(directory.path, engine);
          addTearDown(() => project.close());
          final root = file.uri.toString(),
              buffer = await project.buffer(file.uri.toString());
          Future<void> execute(bool conforming) async {
            final checked = await project.check(root);
            expect(
              checked['status'],
              'complete',
              reason: '${checked['findings']}',
            );
            final operation = (checked['projection']['operations'] as List)
                .cast<Map>()
                .singleWhere((operation) => operation['path'] == '/renamed');
            final plan = await project.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            try {
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              try {
                expect(result.conforming, conforming);
                expect(result.response.status, 202);
                expect(await result.response.bytes(), utf8.encode('okay'));
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
          }

          await execute(false);
          final target = await project.inspectObject(
            root,
            root,
            '/paths/~1renamed/get/responses/201',
          );
          expect(
            MemberNamePolicy.fromJson(target['responseStatusNamePolicy'])
                .allows('2XX'),
            !legacy,
          );
          final plan = await project.planResponseRename(target, '202');
          expect(buffer.text, original);
          await project.applyRefactoring(plan);
          final accepted = buffer.text;
          final parsed = jsonDecode(
            accepted.replaceFirst('# retained status source\r\n', ''),
          ) as Map;
          expect(
            (parsed['paths']['/renamed']['get']['responses'] as Map).keys,
            ['202'],
          );
          expect(
            parsed['paths']['/consumer']['get']['responses']['200'][r'$ref'],
            '#/paths/~1renamed/get/responses/202',
          );
          expect(parsed['x-payload'][r'$ref'], reference);
          expect(accepted, contains('9007199254740993.00'));
          project.store.undo();
          expect(buffer.text, original);
          project.store.redo();
          expect(buffer.text, accepted);
          await execute(true);
          expect(received, 2);
          expect(file.readAsBytesSync(), [
            239,
            187,
            191,
            ...utf8.encode(original),
          ]);
          expect(
            (await PublicationStore(
              '${directory.path}/publication',
            ).save(project, [buffer])).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(directory.path, engine);
          expect((await project.buffer(root)).text, accepted);
          final cli = await runCliWithSecrets([
            'test',
            directory.path,
            '--case',
            'status',
            '--json',
          ], {});
          expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
          expect(jsonDecode(cli.output)['complete'], true);
          expect(jsonDecode(cli.output)['cases'].single['passed'], true);
          expect(received, 3);
          expect(file.readAsBytesSync(), [
            239,
            187,
            191,
            ...utf8.encode(accepted),
          ]);
        },
      );
    }
  for (final format in ['yaml', 'json'])
    for (final status in ['099', '600']) {
      test(
        'Swagger $format invalid HTTP status $status remains editable and CLI refuses validation',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-invalid-status-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final source = jsonEncode({
            'swagger': '2.0',
            'info': {'title': 'Invalid status', 'version': '1'},
            'paths': {
              '/items': {
                'get': {
                  'responses': {
                    status: {'description': 'Repair me'},
                  },
                },
              },
            },
            'responses': {
              status: {'description': 'Legal reusable name'},
            },
          });
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(source);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id;
          final result = await project.check(root);
          expect(result['status'], 'invalid');
          expect(
            (result['findings'] as List)
                .where(
                  (finding) => finding['code'] == 'response.status.invalid',
                )
                .single['pointer'],
            '/paths/~1items/get/responses/$status',
          );
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 1);
          expect(
            jsonDecode(cli.stdout as String)['findings'].any(
              (finding) => finding['code'] == 'response.status.invalid',
            ),
            true,
          );
          final target = await project.inspectObject(
            root,
            root,
            '/paths/~1items/get/responses/$status',
          );
          await project.applyRefactoring(
            await project.planResponseRename(target, '200'),
          );
          expect((await project.check(root))['status'], 'complete');
          expect(file.readAsStringSync(), source);
        },
      );
    }
}
