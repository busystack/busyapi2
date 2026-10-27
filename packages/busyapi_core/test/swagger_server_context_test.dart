import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'swagger_server_support.dart';
import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final target in ['3.0.4', '3.1.2', '3.2.1']) {
      test(
        'Swagger $format native IPv6 HTTP and explicit $target migration preserve host, override and source',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-swagger-ipv6-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
          addTearDown(() => server.close(force: true));
          final received = <String>[];
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/v1/items');
            expect(
              request.headers.value(HttpHeaders.hostHeader),
              '[::1]:${server.port}',
            );
            expect(
              await request.fold<List<int>>([], (a, b) => a..addAll(b)),
              isEmpty,
            );
            received.add(request.uri.toString());
            request.response.headers.contentType = ContentType.text;
            request.response.write('Native IPv6 雪');
            await request.response.close();
          });
          final repaired = '[::1]:${server.port}', invalid = 'user@$repaired';
          final source = swaggerServerSource(format, invalid);
          final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
          final file = File('${temp.path}/api.$format')
            ..writeAsBytesSync(bytes);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(file.path, engine);
          addTearDown(() => project.close());
          final root = project.roots.single.id,
              buffer = await project.buffer(root);
          final before = await project.check(root);
          expect(before['status'], 'invalid');
          expect(
            (before['findings'] as List).any(
              (dynamic f) =>
                  f['code'] == 'swagger.host.syntax' && f['pointer'] == '/host',
            ),
            true,
          );
          await expectLater(
            project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1items/get',
            ),
            throwsA(
              isA<CoreFailure>()
                  .having((e) => e.code, 'code', 'swagger.host.syntax')
                  .having((e) => e.source?.pointer, 'source pointer', '/host'),
            ),
          );
          expect(received, isEmpty);
          final cliBefore = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            cliBefore.exitCode,
            1,
            reason: '${cliBefore.stdout}\n${cliBefore.stderr}',
          );
          final page = await project.inspectObject(root, root, ''),
              range = List<int>.from(page['range'] as List);
          await project.proposeAndApply(
            root,
            PropertySession(
              root: root,
              buffer: root,
              generation: buffer.generation,
              pointer: '',
              range: range,
              expected: buffer.text.substring(range[0], range[1]),
            ),
            [
              {'kind': 'set', 'pointer': '/host', 'value': repaired},
            ],
          );
          final working = source.replaceFirst(invalid, repaired);
          expect(buffer.text, working);
          expect(file.readAsBytesSync(), bytes);
          final checked = await project.check(root);
          expect(checked['status'], 'complete', reason: jsonEncode(checked));
          expect((checked['versions'] as Map)['swaggerServerRules'], '1');
          Future<void> execute(BusyProject current) async {
            final active = current.roots.single.id;
            final plan = await current.prepareRequest(
              active,
              resource: active,
              pointer: '/paths/~1items/get',
            );
            try {
              expect(plan.result['servers'][0]['url'], 'http://$repaired/v1');
              if (identical(current, project)) {
                expect(
                  (plan.result['servers'][0]['sources'] as List).any(
                    (dynamic s) => s['pointer'] == '/paths/~1items/get/schemes',
                  ),
                  true,
                );
              }
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              try {
                expect(result.conforming, true);
                expect(
                  await File(result.response.bodyFile).readAsBytes(),
                  utf8.encode('Native IPv6 雪'),
                );
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
          }

          await execute(project);
          project.store.undo();
          expect(buffer.text, source);
          expect((await project.check(root))['status'], 'invalid');
          project.store.redo();
          final destination = '${temp.path}/migrated';
          final review = await project.prepareMigration(
            root,
            destination,
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.unsaved, true);
          final cancel = RunCancellation()..cancel();
          await expectLater(
            review.publish(cancelled: () => cancel.cancelled),
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
            ),
          );
          expect(Directory(destination).existsSync(), false);
          expect(file.readAsBytesSync(), bytes);
          await review.publish();
          final migrated = await BusyProject.open(destination, engine);
          addTearDown(migrated.close);
          expect(
            (await migrated.check(migrated.roots.single.id))['status'],
            'complete',
          );
          await execute(migrated);
          expect(file.readAsBytesSync(), bytes);
          expect(buffer.text, working);
          await project.save(buffer);
          final saved = file.readAsBytesSync();
          expect(saved, [0xef, 0xbb, 0xbf, ...utf8.encode(working)]);
          await project.save(buffer);
          expect(file.readAsBytesSync(), saved);
          project.close();
          project = await BusyProject.open(file.path, engine);
          await execute(project);
          expect(
            (await project.check(project.roots.single.id))['status'],
            'complete',
          );
          expect(received, hasLength(3));
          expect(file.readAsBytesSync(), saved);
        },
      );
    }
  }
}
