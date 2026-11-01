import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _response =
    '{"number":9007199254740993.00,"flag":false,"nil":null,"text":"雪😀"}';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final target in ['3.1.2', '3.2.1']) {
      test(
        '3.0 $format independent Terms proof to $target preserves actual URLs and captured publication',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-terms-variables-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final requests = <String>[];
          server.listen((request) async {
            requests.add('${request.method} ${request.uri}');
            await request.drain<void>();
            request.response.headers.contentType = ContentType.json;
            request.response.add(utf8.encode(_response));
            await request.response.close();
          });
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          final url = 'http://127.0.0.1:${server.port}/{version}/';
          final value = {
            'openapi': '3.0.4',
            'info': {
              'title': 'Original',
              'version': 'api-version',
              'termsOfService': '/terms',
            },
            'servers': [
              {
                'url': url,
                'variables': {
                  'version': {'default': 'v1'},
                },
              },
            ],
            'paths': {
              '/echo': {
                'get': {
                  'responses': {
                    '200': {
                      'description': 'Exact',
                      'content': {
                        'application/json': {
                          'schema': {
                            'type': 'object',
                            'required': ['number'],
                            'properties': {
                              'number': {
                                'type': 'integer',
                                'enum': ['EXACT'],
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
            'x-exact': 'EXACT',
          };
          final original =
              '${format == 'yaml' ? '# Keep Terms 雪\r\n' : ''}${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(), buffer = await project.buffer(root);
          project.store.replace(
            root,
            original.replaceFirst('Original', 'Unsaved terms'),
          );
          final unsaved = buffer.text;
          Future<void> execute(BusyProject owner) async {
            final current = owner.roots.single.id;
            final plan = await owner.prepareRequest(
              current,
              resource: current,
              pointer: '/paths/~1echo/get',
            );
            try {
              for (final version in ['v1', 'nested/path', '雪']) {
                final result = await const ContractRequestExecutor().execute(
                  plan,
                  OperationRequestDraft(
                    planIdentity: plan.identity,
                    variables: {'version': version},
                  ),
                  resolveSecret: (_) async => null,
                );
                try {
                  expect(result.conforming, true);
                  expect(await result.response.bytes(), utf8.encode(_response));
                } finally {
                  await result.close();
                }
              }
            } finally {
              plan.close();
            }
          }

          await execute(project);
          final review = await project.prepareMigration(
            root,
            '${temp.path}/migrated',
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(review.status, MigrationStatus.faithfullyConvertible);
          expect(review.unsaved, true);
          final output = (review.result['outputs'] as List)
              .cast<Map>()
              .singleWhere((o) => o['id'] == review.result['outputRoot']);
          expect(
            output['text'],
            contains('http://127.0.0.1:${server.port}/terms'),
          );
          expect(output['text'], contains(url));
          expect(output['text'], contains('Unsaved terms'));
          expect(output['text'], contains('9007199254740993.00'));
          expect(await Directory(review.destination).exists(), false);
          final cancellation = RunCancellation()..cancel();
          await expectLater(
            review.publish(cancelled: () => cancellation.cancelled),
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
            ),
          );
          expect(await Directory(review.destination).exists(), false);
          await review.publish();
          final copy = await BusyProject.open(review.destination, engine);
          addTearDown(copy.close);
          expect(
            (await copy.check(copy.roots.single.id))['status'],
            'complete',
          );
          final copiedInfo = await copy.inspectObject(
            copy.roots.single.id,
            copy.roots.single.id,
            '/info',
          );
          expect(copiedInfo['value']['title'], 'Unsaved terms');
          await execute(copy);
          expect(requests.take(3).toList(), requests.skip(3).toList());
          expect(requests.take(3).toList(), [
            'GET /v1/echo',
            'GET /nested/path/echo',
            'GET /%E9%9B%AA/echo',
          ]);
          expect(await file.readAsString(), original);
          expect(buffer.text, unsaved);
          expect(buffer.dirty, true);
          final stale = await project.prepareMigration(
            root,
            '${temp.path}/stale',
            targetVersion: target,
          );
          addTearDown(stale.close);
          project.store.replace(
            root,
            unsaved.replaceFirst('Unsaved terms', 'Changed after review'),
          );
          await expectLater(
            stale.publish(),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'migration.stale',
              ),
            ),
          );
          expect(await Directory(stale.destination).exists(), false);
          expect(await file.readAsString(), original);
          final cliOutput = '${temp.path}/cli';
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              target,
              '--output',
              cliOutput,
              '--json',
            ],
            environment: {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout} ${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['status'], 'faithfully-convertible');
          expect(report['published'], false);
          expect(await Directory(cliOutput).exists(), false);
          final applied = await Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              target,
              '--output',
              cliOutput,
              '--json',
              '--apply',
              report['reviewIdentity'] as String,
            ],
            environment: {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(
            applied.exitCode,
            0,
            reason: '${applied.stdout} ${applied.stderr}',
          );
          expect(
            (jsonDecode(applied.stdout as String) as Map)['published'],
            true,
          );
          expect(await Directory(cliOutput).exists(), true);
          final checked = await Process.run(
            '$testBundle/busyapi',
            ['check', cliOutput, '--json'],
            environment: {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(
            checked.exitCode,
            0,
            reason: '${checked.stdout} ${checked.stderr}',
          );
          final cliCopy = await BusyProject.open(cliOutput, engine);
          addTearDown(cliCopy.close);
          final cliInfo = await cliCopy.inspectObject(
            cliCopy.roots.single.id,
            cliCopy.roots.single.id,
            '/info',
          );
          expect(cliInfo['value']['title'], 'Original');
          expect(await file.readAsString(), original);
        },
      );
    }
  }
}
