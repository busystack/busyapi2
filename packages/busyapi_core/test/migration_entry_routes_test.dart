import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final primaryVersion in ['3.1.2', '3.2.1']) {
    final secondaryVersion = primaryVersion == '3.1.2' ? '3.2.1' : '3.1.2';
    for (final format in ['yaml', 'json']) {
      for (final target in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
        test(
          '$primaryVersion + $secondaryVersion $format captured migration to $target retains both entry workflows',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-entry-routes-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final seen = <(String, String, List<int>)>[];
            const body = '9007199254740993.000';
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            server.listen((request) async {
              final bytes = await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              );
              seen.add((request.method, request.uri.toString(), bytes));
              request.response.headers.contentType = ContentType.json;
              request.response.write(body);
              await request.response.close();
            });
            final source = File('${temp.path}/api.$format'),
                other = File('${temp.path}/other.$format');
            Map<String, Object?> document(
              String version,
              String name,
              bool primary,
            ) => {
              'openapi': version,
              'info': {'title': name, 'version': 'api-version'},
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}/$name'},
              ],
              'paths': {
                '/items': {
                  'get': {
                    'responses': {
                      '200': {
                        'description': '[Guide](/guide)',
                        'content': {
                          'application/json': {
                            'schema': {
                              r'$ref': primary
                                  ? 'other.$format#/components/schemas/Model'
                                  : '#/components/schemas/Model',
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
              'components': {
                'schemas': {
                  'Model': {'type': 'integer', 'minimum': 'EXACT'},
                },
              },
              'x-kept': {'n': 'EXACT', 'false': false, 'empty': ''},
            };
            String text(Object value) =>
                '${format == 'yaml' ? '# Keep comments 雪\r\n' : ''}${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.000')}\r\n';
            final original = text(document(primaryVersion, 'primary', true)),
                originalOther = text(
                  document(secondaryVersion, 'secondary', false),
                );
            await source.writeAsString(original);
            await other.writeAsString(originalOther);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(source.path, engine);
            addTearDown(project.close);
            final root = source.uri.toString(),
                part = await project.buffer(other.uri.toString());
            project.store.replace(
              part.id,
              part.text.replaceFirst(
                '"title":"secondary"',
                '"title":"Unsaved secondary"',
              ),
            );
            final captured = part.text;
            Future<void> send(
              BusyProject owner,
              String entry,
              String expectedPath,
            ) async {
              final check = await owner.check(entry);
              expect(check['complete'], true, reason: '$check');
              final operation =
                  (check['projection']['operations'] as List).single as Map;
              final plan = await owner.prepareRequest(
                entry,
                resource: operation['resource'] as String,
                pointer: operation['pointer'] as String,
              );
              addTearDown(plan.close);
              final run = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              addTearDown(run.close);
              expect(run.conforming, true, reason: '${run.received.findings}');
              expect(await run.response.bytes(), utf8.encode(body));
              expect(seen.last.$1, 'GET');
              expect(seen.last.$2, expectedPath);
              expect(seen.last.$3, isEmpty);
            }

            await send(project, root, '/primary/items');
            final cancelled = await project.prepareMigration(
              root,
              '${temp.path}/cancelled',
              targetVersion: target,
            );
            expect(cancelled.publishable, true, reason: '${cancelled.result}');
            cancelled.close();
            expect(Directory('${temp.path}/cancelled').existsSync(), false);
            final stale = await project.prepareMigration(
              root,
              '${temp.path}/stale',
              targetVersion: target,
            );
            addTearDown(stale.close);
            project.store.replace(part.id, '$captured ');
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
            expect(Directory('${temp.path}/stale').existsSync(), false);
            project.store.replace(part.id, captured);
            final output = await project.prepareMigration(
              root,
              '${temp.path}/converted',
              targetVersion: target,
            );
            addTearDown(output.close);
            expect(output.unsaved, true);
            expect(output.publishable, true, reason: '${output.result}');
            expect(output.entryRoutes, hasLength(2));
            expect(
              output.entryRoutes.map((e) => e.from.declaredVersion).toSet(),
              {primaryVersion, secondaryVersion},
            );
            expect(
              output.entryRoutes.every(
                (e) => e.target.declaredVersion == target,
              ),
              true,
            );
            await output.publish();
            expect(await source.readAsString(), original);
            expect(await other.readAsString(), originalOther);
            final migrated = await BusyProject.open(output.destination, engine);
            addTearDown(migrated.close);
            expect(migrated.roots, hasLength(2));
            for (final entry in migrated.roots) {
              final check = await migrated.check(entry.id);
              expect(
                check['projection']['specification']['declaredVersion'],
                target,
              );
              final origin = output.changes
                  .singleWhere((change) => change.destination == entry.id)
                  .resource;
              await send(
                migrated,
                entry.id,
                origin == root ? '/primary/items' : '/secondary/items',
              );
            }
            final cli = await Process.run(
              '$testBundle/busyapi',
              [
                'migrate',
                source.path,
                '--target',
                target,
                '--output',
                '${temp.path}/cli',
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 0, reason: '${cli.stdout}${cli.stderr}');
            final report = jsonDecode(cli.stdout as String) as Map;
            expect((report['entryRoutes'] as List), hasLength(2));
            expect(
              Directory('${temp.path}/cli').existsSync(),
              false,
              reason: 'CLI review does not publish without --apply',
            );
            final applied = await Process.run(
              '$testBundle/busyapi',
              [
                'migrate',
                source.path,
                '--target',
                target,
                '--output',
                '${temp.path}/cli',
                '--apply',
                report['reviewIdentity'] as String,
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              applied.exitCode,
              0,
              reason: '${applied.stdout}${applied.stderr}',
            );
            final appliedReport = jsonDecode(applied.stdout as String) as Map;
            final cliProject = await BusyProject.open(
              '${temp.path}/cli',
              engine,
            );
            addTearDown(cliProject.close);
            expect(cliProject.roots, hasLength(2));
            for (final entry in cliProject.roots) {
              final origin = (appliedReport['changes'] as List).singleWhere(
                (change) => change['destination'] == entry.id,
              )['resource'];
              await send(
                cliProject,
                entry.id,
                origin == root ? '/primary/items' : '/secondary/items',
              );
            }

            expect(await source.readAsString(), original);
            expect(await other.readAsString(), originalOther);
          },
        );
      }
    }
  }
}
