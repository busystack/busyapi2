import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final (from, target, required, flag, blocked) in [
    for (final (from, target) in [
      ('3.0.4', '3.1.2'),
      ('3.0.4', '3.2.1'),
      ('3.1.2', '3.0.4'),
      ('3.2.1', '3.0.4'),
    ])
      for (final flag in ['readOnly', 'writeOnly'])
        (from, target, false, flag, false),
    for (final from in ['3.0.4', '3.1.2', '3.2.1'])
      for (final required in [false, true])
        (from, '2.0', required, 'readOnly', true),
    for (final from in ['3.1.2', '3.2.1'])
      for (final flag in ['readOnly', 'writeOnly'])
        (from, '3.0.4', true, flag, true),
  ]) {
    for (final format in ['yaml', 'json']) {
      test(
        '$from to $target $format $flag required=$required preserves HTTP semantics or blocks without output',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-migration-access-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <(String, String, String?, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, bytes) => all..addAll(bytes),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.contentType?.mimeType,
              bytes,
            ));
            request.response.headers.contentType = ContentType.json;
            request.response.add(bytes);
            await request.response.close();
          });
          final file = File('${temp.path}/api.$format'),
              fields = File('${temp.path}/fields.$format');
          final schema = {r'$ref': '#/components/schemas/Model'};
          final value = {
            'openapi': from,
            'info': {'title': 'Original 雪', 'version': 'api-version'},
            'servers': [
              {'url': 'http://127.0.0.1:${server.port}/v1'},
            ],
            'paths': {
              '/value': {
                'post': {
                  'requestBody': {
                    'required': true,
                    'content': {
                      'application/json': {'schema': schema},
                    },
                  },
                  'responses': {
                    '200': {
                      'description': 'Value',
                      'content': {
                        'application/json': {'schema': schema},
                      },
                    },
                  },
                },
              },
            },
            'components': {
              'schemas': {
                'Model': {
                  'type': 'object',
                  if (required) 'required': ['value'],
                  'properties': {
                    'value': {r'$ref': 'fields.$format#/Alias'},
                  },
                },
              },
            },
            'x-kept': {'exact': 'EXACT', 'flag': false, 'empty': ''},
          };
          String text(Object data) =>
              '${format == 'yaml' ? '# Keep comments 雪\r\n' : ''}${jsonEncode(data).replaceAll('"EXACT"', '9007199254740993.000')}\r\n';
          final original = text(value),
              originalFields = text({
                'Flag': {'type': 'string', flag: true},
                'Alias': {r'$ref': '#/Flag'},
              });
          await file.writeAsString(original);
          await fields.writeAsString(originalFields);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          project.store.replace(
            buffer.id,
            original.replaceFirst('Original 雪', 'Unsaved 雪'),
          );
          final current = buffer.text, destination = '${temp.path}/converted';
          final review = await project.prepareMigration(
            buffer.id,
            destination,
            targetVersion: target,
          );
          addTearDown(review.close);
          Future<void> send(BusyProject owner) async {
            final root = owner.roots.single.id,
                checked = await owner.check(root);
            expect(checked['complete'], true, reason: '$checked');
            final operation =
                (checked['projection']['operations'] as List).single as Map;
            for (final payload in ['{}', '{"value":"snow 雪"}']) {
              final plan = await owner.prepareRequest(
                root,
                resource: operation['resource'] as String,
                pointer: operation['pointer'] as String,
              );
              addTearDown(plan.close);
              final run = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(
                    mediaType: 'application/json',
                    text: payload,
                  ),
                ),
                resolveSecret: (_) async => null,
              );
              addTearDown(run.close);
              expect(
                run.outgoing.complete && run.outgoing.valid,
                true,
                reason: '${run.outgoing.findings}',
              );
              expect(
                run.received.complete && run.received.valid,
                true,
                reason: '${run.received.findings}',
              );
              expect(run.conforming, true);
              expect(await run.response.bytes(), utf8.encode(payload));
              expect(seen.last.$1, 'POST');
              expect(seen.last.$2, '/v1/value');
              expect(seen.last.$3, 'application/json');
              expect(seen.last.$4, utf8.encode(payload));
            }
          }

          if (blocked) {
            expect(review.status, MigrationStatus.blocked);
            expect(review.result['outputs'], isEmpty);
            final problem = review.problems.firstWhere(
              (p) => p.code == 'migration.schema.direction',
            );
            expect(problem.resource, fields.uri.toString());
            expect(problem.pointer, '/Flag');
            await expectLater(
              review.publish(),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'migration.blocked',
                ),
              ),
            );
            expect(seen, isEmpty);
          } else {
            expect(review.publishable, true, reason: '${review.result}');
            expect(review.unsaved, true);
            await send(project);
            final fieldBuffer = await project.buffer(fields.uri.toString());
            project.store.replace(
              fieldBuffer.id,
              originalFields.replaceFirst('true', 'false'),
            );
            await expectLater(
              review.publish(),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'migration.stale',
                ),
              ),
            );
            expect(Directory(destination).existsSync(), false);
            project.store.replace(fieldBuffer.id, originalFields);
            final fresh = await project.prepareMigration(
              buffer.id,
              destination,
              targetVersion: target,
            );
            addTearDown(fresh.close);
            expect(fresh.publishable, true, reason: '${fresh.result}');
            await fresh.publish();
            final output = await BusyProject.open(destination, engine);
            addTearDown(output.close);
            final checked = await output.check(output.roots.single.id);
            expect(
              checked['projection']['specification']['declaredVersion'],
              target,
            );
            await send(output);
            final outputText = (await output.buffer(output.roots.single.id))
                .text;
            expect(outputText, contains('Unsaved 雪'));
            expect(outputText, contains('9007199254740993.000'));
          }
          expect(buffer.text, current);
          expect(buffer.dirty, true);
          expect(await file.readAsString(), original);
          expect(await fields.readAsString(), originalFields);
          final cliDestination = '${temp.path}/cli-converted';
          Future<ProcessResult> cli(List<String> extra) => Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              target,
              '--output',
              cliDestination,
              '--json',
              ...extra,
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final first = await cli([]);
          expect(
            first.exitCode,
            blocked ? 2 : 0,
            reason: '${first.stdout}\n${first.stderr}',
          );
          final report = jsonDecode(first.stdout as String) as Map;
          expect(report['published'], false);
          expect(Directory(cliDestination).existsSync(), false);
          if (blocked) {
            expect(report['status'], 'blocked');
            expect(report['outputs'], isEmpty);
            expect(
              (report['problems'] as List).any(
                (p) => p['code'] == 'migration.schema.direction',
              ),
              true,
            );
          } else {
            final applied = await cli([
              '--apply',
              report['reviewIdentity'] as String,
            ]);
            expect(
              applied.exitCode,
              0,
              reason: '${applied.stdout}\n${applied.stderr}',
            );
            expect(
              (jsonDecode(applied.stdout as String) as Map)['published'],
              true,
            );
            final copy = await BusyProject.open(cliDestination, engine);
            addTearDown(copy.close);
            await send(copy);
            expect(
              (await copy.buffer(copy.roots.single.id)).text,
              contains('Original 雪'),
            );
          }
          expect(await file.readAsString(), original);
          expect(await fields.readAsString(), originalFields);
          if (blocked) expect(Directory(destination).existsSync(), false);
          expect(seen, hasLength(blocked ? 0 : 6));
        },
      );
    }
  }
}
