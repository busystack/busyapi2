import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'dependency_migration_support.dart';
import 'test_support.dart';

const _body = '{"seed":false,"n":9007199254740993.00,"name":"雪","flag":true}';

void main() {
  for (final (version, conditionalSchemas) in [
    for (final version in ['3.1.2', '3.2.1'])
      for (final conditionalSchemas in [false, true])
        (version, conditionalSchemas),
  ]) {
    for (final format in ['yaml', 'json']) {
      for (final targetVersion in ['3.0.4', '2.0']) {
        test(
          '$version $format conditionalSchemas=$conditionalSchemas dependencies migrate to $targetVersion with exact HTTP semantics and reviewed publication',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-dependency-migration-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final seen = <(String, String, String?, int, List<int>, String?)>[];
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            server.listen((request) async {
              final bytes = await request.fold<List<int>>(
                [],
                (all, next) => all..addAll(next),
              );
              seen.add((
                request.method,
                request.uri.toString(),
                request.headers.contentType?.mimeType,
                request.contentLength,
                bytes,
                request.headers.value(HttpHeaders.hostHeader),
              ));
              request.response.headers.contentType = ContentType.json;
              request.response.add(bytes);
              await request.response.close();
            });
            final file = File('${temp.path}/api.$format'),
                model = File('${temp.path}/model.yaml');
            final text = dependencyMigrationApi(
                  version,
                  format,
                  port: server.port,
                ),
                modelText = dependencyMigrationModel(
                  requiredTrigger: targetVersion == '2.0',
                  conditionalSchemas: conditionalSchemas,
                );
            final original = [0xef, 0xbb, 0xbf, ...utf8.encode(text)],
                originalModel = [0xef, 0xbb, 0xbf, ...utf8.encode(modelText)];
            await file.writeAsBytes(original);
            await model.writeAsBytes(originalModel);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = file.uri.toString(),
                buffer = await project.buffer(root),
                shared = await project.buffer(model.uri.toString());
            project.store.replace(
              root,
              buffer.text.replaceFirst('Original API', 'Unsaved API'),
            );
            project.store.replace(
              shared.id,
              shared.text.replaceFirst('Original model', 'Unsaved model'),
            );
            final capturedRoot = buffer.text, capturedModel = shared.text;
            final checked = await project.check(root);
            expect(checked['status'], 'complete', reason: jsonEncode(checked));
            expect(checked['complete'], isTrue);
            final cliCheck = await Process.run(
              '$testBundle/busyapi',
              ['check', file.path, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              cliCheck.exitCode,
              0,
              reason: '${cliCheck.stdout}\n${cliCheck.stderr}',
            );
            expect(
              (jsonDecode(cliCheck.stdout as String) as Map)['complete'],
              isTrue,
            );

            Future<void> execute(
              BusyProject owner, {
              bool invalidControls = false,
            }) async {
              final current = owner.roots.single.id;
              final plan = await owner.prepareRequest(
                current,
                resource: current,
                pointer: '/paths/~1echo/post',
              );
              try {
                if (invalidControls) {
                  for (final text in [
                    '{"seed":false,"name":"雪","flag":true}',
                    _body.replaceFirst(
                      '9007199254740993.00',
                      '9007199254740992',
                    ),
                  ]) {
                    final draft = OperationRequestDraft(
                      planIdentity: plan.identity,
                      body: RequestBodyDraft.raw(
                        text: text,
                        mediaType: 'application/json',
                      ),
                    );
                    final request = await const ContractRequestBuilder().build(
                      plan,
                      draft,
                      resolveSecret: (_) async => null,
                    );
                    try {
                      final report = await const ContractRequestExecutor()
                          .validateOutgoing(
                            plan,
                            draft,
                            request.runId,
                            preparedBody: request.body,
                          );
                      expect(
                        report.complete,
                        isTrue,
                        reason: '${report.toJson()}',
                      );
                      expect(report.valid, isFalse);
                    } finally {
                      await request.body?.close();
                    }
                  }
                  expect(seen, isEmpty);
                }
                final result = await const ContractRequestExecutor().execute(
                  plan,
                  OperationRequestDraft(
                    planIdentity: plan.identity,
                    body: RequestBodyDraft.raw(
                      text: _body,
                      mediaType: 'application/json',
                    ),
                  ),
                  resolveSecret: (_) async => null,
                );
                try {
                  expect(
                    result.conforming,
                    isTrue,
                    reason:
                        '${result.outgoing.toJson()} ${result.received.toJson()}',
                  );
                  expect(await result.response.bytes(), utf8.encode(_body));
                } finally {
                  await result.close();
                }
              } finally {
                plan.close();
              }
            }

            await execute(project, invalidControls: true);
            final review = await project.prepareMigration(
              root,
              '${temp.path}/migrated',
              targetVersion: targetVersion,
            );
            addTearDown(review.close);
            expect(
              review.status,
              MigrationStatus.faithfullyConvertible,
              reason: '${review.result}',
            );
            expect(review.unsaved, isTrue);
            expect(review.result['producerVersion'], '37');
            final outputs = (review.result['outputs'] as List).cast<Map>();
            expect(
              outputs.any(
                (output) =>
                    (output['text'] as String).contains('Unsaved model'),
              ),
              isTrue,
            );
            expect(
              outputs.singleWhere(
                (output) => output['id'] == review.result['outputRoot'],
              )['text'],
              contains('Unsaved API'),
            );
            final cancellation = RunCancellation()..cancel();
            await expectLater(
              review.publish(cancelled: () => cancellation.cancelled),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'cancelled',
                ),
              ),
            );
            expect(await Directory(review.destination).exists(), isFalse);
            await review.publish();
            final copy = await BusyProject.open(review.destination, engine);
            addTearDown(copy.close);
            expect(
              (await copy.check(copy.roots.single.id))['status'],
              'complete',
            );
            await execute(copy);
            final stale = await project.prepareMigration(
              root,
              '${temp.path}/stale',
              targetVersion: targetVersion,
            );
            addTearDown(stale.close);
            project.store.replace(
              root,
              capturedRoot.replaceFirst('Unsaved API', 'Changed after review'),
            );
            await expectLater(
              stale.publish(),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'migration.stale',
                ),
              ),
            );
            expect(await Directory(stale.destination).exists(), isFalse);
            project.store.undo();
            expect(buffer.text, capturedRoot);
            expect(shared.text, capturedModel);
            final cliDestination = '${temp.path}/cli-copy';
            final arguments = [
              'migrate',
              file.path,
              '--target',
              targetVersion,
              '--output',
              cliDestination,
              '--json',
            ];
            final cliReview = await Process.run(
              '$testBundle/busyapi',
              arguments,
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              cliReview.exitCode,
              0,
              reason: '${cliReview.stdout}\n${cliReview.stderr}',
            );
            final report = jsonDecode(cliReview.stdout as String) as Map;
            expect(report['published'], isFalse);
            expect(await Directory(cliDestination).exists(), isFalse);
            final applied = await Process.run(
              '$testBundle/busyapi',
              [...arguments, '--apply', report['reviewIdentity'] as String],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              applied.exitCode,
              0,
              reason: '${applied.stdout}\n${applied.stderr}',
            );
            expect(
              (jsonDecode(applied.stdout as String) as Map)['published'],
              isTrue,
            );
            final savedCopy = await BusyProject.open(cliDestination, engine);
            addTearDown(savedCopy.close);
            final savedInfo = await savedCopy.inspectObject(
              savedCopy.roots.single.id,
              savedCopy.roots.single.id,
              '/info',
            );
            expect(savedInfo['value']['title'], 'Original API 雪');
            await execute(savedCopy);
            expect(seen, hasLength(3));
            for (final request in seen) {
              expect(request.$1, 'POST');
              expect(request.$2, '/v1/echo');
              expect(request.$3, 'application/json');
              expect(request.$4, utf8.encode(_body).length);
              expect(request.$5, utf8.encode(_body));
              expect(request.$6, '127.0.0.1:${server.port}');
            }
            expect(await file.readAsBytes(), original);
            expect(await model.readAsBytes(), originalModel);
            expect(buffer.text, capturedRoot);
            expect(shared.text, capturedModel);
          },
        );
      }
    }
  }
}
