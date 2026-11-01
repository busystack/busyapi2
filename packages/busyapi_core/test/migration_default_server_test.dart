import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final empty in [false, true]) {
      test(
        '3.0 $format implicit Server empty=$empty retains its actual origin after migration',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-default-origin-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final received = <String>[];
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(
              request.headers.value(HttpHeaders.hostHeader),
              '127.0.0.1:${server.port}',
            );
            expect(
              await request.fold<List<int>>([], (a, b) => a..addAll(b)),
              isEmpty,
            );
            received.add(request.uri.toString());
            request.response.statusCode = 204;
            await request.response.close();
          });
          final source = format == 'json'
              ? '${const JsonEncoder.withIndent('  ').convert({
                  'openapi': '3.0.4',
                  'info': {'title': 'Saved default 雪', 'version': 'API-1'},
                  if (empty) 'servers': [],
                  'paths': {
                    '/items': {
                      'get': {
                        'responses': {
                          '204': {'description': 'No body'},
                        },
                      },
                    },
                  },
                  'x-exact': 'EXACT',
                }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n'
              : '# Keep implicit Server\r\nopenapi: "3.0.4"\r\n'
                    'info: {title: "Saved default 雪", version: "API-1"}\r\n'
                    '${empty ? 'servers: [] # Keep empty choice\r\n' : ''}'
                    'paths: {/items: {get: {responses: {"204": {description: "No body"}}}}}\r\n'
                    'x-exact: 9007199254740993.00\r\n';
          final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
          final file = File('${temp.path}/api.$format')
            ..writeAsBytesSync(original);
          final manifest = File('${temp.path}/busyapi.yaml')
            ..writeAsStringSync(
              jsonEncode({
                'version': 1,
                'roots': [
                  {'name': 'api', 'path': 'api.$format'},
                ],
                'resourceMappings': {
                  'http://127.0.0.1:${server.port}/source/api.$format':
                      'api.$format',
                },
                'tests': [
                  {
                    'name': 'default',
                    'operation': {'method': 'get', 'path': '/items'},
                    'expect': {'status': 204},
                  },
                ],
              }),
            );
          final manifestBytes = manifest.readAsBytesSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              buffer = await project.buffer(project.roots.single.id);
          await project.save(buffer);
          expect(file.readAsBytesSync(), original);
          final working = buffer.text.replaceFirst(
            'Saved default',
            'Unsaved default',
          );
          project.store.replace(root, working);
          Future<void> send(BusyProject owner) async {
            final id = owner.roots.single.id;
            final plan = await owner.prepareRequest(
              id,
              resource: id,
              pointer: '/paths/~1items/get',
            );
            try {
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              try {
                expect(result.conforming, true);
                expect(result.response.status, 204);
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
          }

          await send(project);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'default', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
          for (final target in ['3.0.4', '3.1.2', '3.2.1']) {
            final review = await project.prepareMigration(
              root,
              '${temp.path}/migrated-$target',
              targetVersion: target,
            );
            addTearDown(review.close);
            expect(
              review.status,
              MigrationStatus.faithfullyConvertible,
              reason: '${review.result}',
            );
            expect(review.unsaved, true);
            expect(review.result['producerVersion'], '37');
            await review.publish();
            final copy = await BusyProject.open(review.destination, engine);
            addTearDown(copy.close);
            final text = (await copy.buffer(copy.roots.single.id)).text;
            expect(text, contains('Unsaved default'));
            expect(text, contains('9007199254740993.00'));
            if (format == 'yaml')
              expect(text, contains('# Keep implicit Server'));
            expect(
              (await copy.check(copy.roots.single.id))['status'],
              'complete',
            );
            await send(copy);
          }
          expect(received, List.filled(5, '/items'));
          expect(file.readAsBytesSync(), original);
          expect(manifest.readAsBytesSync(), manifestBytes);
          expect(buffer.text, working);
        },
      );
    }
  }
}
