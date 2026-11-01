import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  final cases = [
    for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
      (version: version, uri: false),
    for (final version in ['3.2.0', '3.2.1']) (version: version, uri: true),
  ];
  for (final fixture in cases) {
    final version = fixture.version;
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format security rename uri=${fixture.uri} retains configured execution',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-security-refactoring-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var received = 0;
          server.listen((request) async {
            received++;
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/items');
            expect(request.headers.value('x-key'), 'synthetic-key');
            expect(request.headers.value('authorization'), isNull);
            expect(await request.toList(), isEmpty);
            request.response.statusCode = 204;
            await request.response.close();
          });
          final swagger = version == '2.0';
          final binding = fixture.uri
              ? '#/components/securitySchemes/Old'
              : 'Old';
          const nextName = '__proto__';
          final nextBinding = fixture.uri
              ? '#/components/securitySchemes/$nextName'
              : nextName;
          final definition = {
            'type': 'apiKey',
            'in': 'header',
            'name': 'X-Key',
          };
          final value = {
            if (swagger) 'swagger': version else 'openapi': version,
            'info': {'title': 'Security maintenance 雪', 'version': '1'},
            if (swagger) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'securityDefinitions': {'Old': definition},
            } else ...{
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              'components': {
                'securitySchemes': {'Old': definition},
              },
            },
            'security': [
              {binding: <String>[]},
            ],
            'paths': {
              '/items': {
                'get': {
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
            'x-payload': {'Old': 'literal'},
            'x-number': '__exact__',
          };
          final source = format == 'json'
              ? const JsonEncoder.withIndent('  ')
                    .convert(value)
                    .replaceAll('"__exact__"', '9007199254740993.00')
              : '''# retained security source
${swagger ? "swagger: '2.0'" : 'openapi: $version'}
info: {title: Security maintenance 雪, version: '1'}
${swagger ? "host: '127.0.0.1:${server.port}'\nschemes: [http]\nsecurityDefinitions: {Old: ${jsonEncode(definition)}}" : "servers: [{url: 'http://127.0.0.1:${server.port}'}]\ncomponents: {securitySchemes: {Old: ${jsonEncode(definition)}}}"}
security: [{${jsonEncode(binding)}: []}]
paths: {/items: {get: {responses: {'204': {description: Empty}}}}}
x-payload: {Old: literal}
x-number: 9007199254740993.00
''';
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(source);
          const secret = '11111111-1111-4111-8111-111111111111';
          final configuration =
              '''version: 1
# retain the reference; credentials stay outside source
roots: [{name: api, path: api.$format}]
environments:
  manual:
    authentication:
      alternative: 0
      schemes:
        ${jsonEncode(binding)}: {secretRef: '$secret'} # retained reference
tests:
  - name: maintenance
    operation: {method: GET, path: /items}
    expect: {status: 204}
x-payload: {Old: literal}
''';
          final manifest = File('${directory.path}/busyapi.yaml')
            ..writeAsStringSync(configuration);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(directory.path, engine);
          addTearDown(() => project.close());
          final root = file.uri.toString();
          Future<void> execute() async {
            final checked = await project.check(root);
            expect(
              checked['status'],
              'complete',
              reason: '${checked['findings']}',
            );
            final operation =
                (checked['projection']['operations'] as List).single as Map;
            final plan = await project.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            try {
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  environment: 'manual',
                ),
                resolveSecret: (reference) async {
                  expect(reference, secret);
                  return 'synthetic-key';
                },
              );
              try {
                expect(result.conforming, true);
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
          }

          await execute();
          expect(received, 1);
          Future<RefactoringPlan> rename() async {
            final buffer = await project.buffer(root);
            return project.planComponentRename({
              'resource': root,
              'generation': buffer.generation,
              'pointer':
                  '${swagger ? '/securityDefinitions' : '/components/securitySchemes'}/Old',
            }, nextName);
          }

          final stale = await rename();
          final configBuffer = await project.buffer(manifest.uri.toString());
          project.store.replace(
            configBuffer.id,
            '${configBuffer.text}# later configuration\n',
          );
          final later = configBuffer.text;
          await expectLater(
            project.applyRefactoring(stale),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'refactor.stale',
              ),
            ),
          );
          expect(project.store.get(root).text, source);
          expect(configBuffer.text, later);
          project.store.undo();
          expect(configBuffer.text, configuration);
          final conflict = configuration.replaceFirst(
            ' # retained reference\n',
            ' # retained reference\n        ${jsonEncode(nextBinding)}: {secretRef: different-reference}\n',
          );
          project.store.replace(configBuffer.id, conflict);
          await expectLater(
            rename(),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'refactor.configuration.collision',
              ),
            ),
          );
          expect(project.store.get(root).text, source);
          expect(configBuffer.text, conflict);
          project.store.undo();
          final review = await rename();
          expect(
            review.edits.any((edit) => edit.buffer == manifest.uri.toString()),
            true,
          );
          expect(file.readAsStringSync(), source);
          expect(manifest.readAsStringSync(), configuration);
          await project.applyRefactoring(review);
          final accepted = {
            for (final buffer in project.store.buffers.values)
              buffer.id: buffer.text,
          };
          expect(project.store.get(root).text, contains('9007199254740993.00'));
          expect(
            project.store.get(manifest.uri.toString()).text,
            contains('x-payload: {Old: literal}'),
          );
          project.store.undo();
          expect(project.store.get(root).text, source);
          expect(
            project.store.get(manifest.uri.toString()).text,
            configuration,
          );
          project.store.redo();
          for (final entry in accepted.entries) {
            expect(project.store.get(entry.key).text, entry.value);
          }
          await execute();
          expect(received, 2);
          final unrelated = File('${directory.path}/notes.txt')
            ..writeAsStringSync('original notes\n');
          final notes = await project.buffer(unrelated.uri.toString());
          project.store.replace(notes.id, 'unsaved notes 雪\n');
          final recovery = RecoveryStore('${directory.path}/drafts');
          expect(await recovery.persistFileMoves(project.recoveryOwner), true);
          final checkpoint = Directory(recovery.directory)
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.json'))
              .single;
          final record = {
            ...jsonDecode(await checkpoint.readAsString())
                as Map<String, dynamic>,
            'recordPath': checkpoint.path,
          };
          expect(record['publicationGroups'], [
            unorderedEquals([root, manifest.uri.toString()]),
          ]);
          project.close();
          project = await BusyProject.open(directory.path, engine);
          await expectLater(
            recovery.adoptFileMoves({
              ...record,
              'publicationGroups': [
                [
                  root,
                  Uri.file('${directory.path}/uncaptured.yaml').toString(),
                ],
              ],
            }, project.recoveryOwner),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'recovery.groups',
              ),
            ),
          );
          expect((await project.buffer(root)).text, source);
          expect(
            (await project.buffer(manifest.uri.toString())).text,
            configuration,
          );
          await recovery.adoptFileMoves(record, project.recoveryOwner);
          for (final entry in accepted.entries) {
            expect(project.store.get(entry.key).text, entry.value);
          }
          expect(project.store.get(notes.id).text, 'unsaved notes 雪\n');
          final publications = PublicationStore(
            '${directory.path}/publication',
          );
          manifest.writeAsStringSync('$configuration# external edit\n');
          final blocked = await publications.save(project, [
            project.store.get(root),
          ]);
          expect(blocked.complete, false);
          expect(blocked.published, isEmpty);
          expect(file.readAsStringSync(), source);
          expect(
            manifest.readAsStringSync(),
            '$configuration# external edit\n',
          );
          expect(project.store.get(root).text, accepted[root]);
          expect(
            project.store.get(manifest.uri.toString()).text,
            accepted[manifest.uri.toString()],
          );
          manifest.writeAsStringSync(configuration);
          expect(
            (await publications.save(project, [
              project.store.get(root),
            ])).complete,
            true,
          );
          expect(unrelated.readAsStringSync(), 'original notes\n');
          expect(project.store.get(notes.id).dirty, true);
          project.close();
          project = await BusyProject.open(directory.path, engine);
          final cli = await runCliWithSecrets(
            [
              'test',
              directory.path,
              '--case',
              'maintenance',
              '--environment',
              'manual',
              '--json',
            ],
            {secret: 'synthetic-key'},
          );
          expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
          expect(jsonDecode(cli.output)['complete'], true);
          expect(jsonDecode(cli.output)['cases'].single['passed'], true);
          expect(cli.output, isNot(contains('synthetic-key')));
          expect(received, 3);
          for (final entry in accepted.entries) {
            expect((await project.buffer(entry.key)).text, entry.value);
          }
          project.close();
          final crossBinding = fixture.uri
              ? '#/components/securitySchemes/Cross'
              : 'Cross';
          final other = File('${directory.path}/other.json')
            ..writeAsStringSync(
              jsonEncode({
                ...value,
                'security': [
                  {crossBinding: <String>[]},
                ],
                if (swagger)
                  'securityDefinitions': {'Cross': definition}
                else
                  'components': {
                    'securitySchemes': {'Cross': definition},
                  },
              }),
            );
          final beforeCross = manifest.readAsStringSync().replaceFirst(
            'path: api.$format}]',
            'path: api.$format}, {name: other, path: other.json}]',
          );
          manifest.writeAsStringSync(beforeCross);
          project = await BusyProject.open(directory.path, engine);
          expect(project.roots, hasLength(2));
          final current = await project.buffer(root);
          await expectLater(
            project.planComponentRename({
              'resource': root,
              'generation': current.generation,
              'pointer':
                  '${swagger ? '/securityDefinitions' : '/components/securitySchemes'}/$nextName',
            }, 'Cross'),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'refactor.configuration.ambiguous',
              ),
            ),
          );
          expect(current.text, accepted[root]);
          expect(file.readAsStringSync(), accepted[root]);
          expect(manifest.readAsStringSync(), beforeCross);
          final otherRoot = other.uri.toString();
          final checkedOther = await project.check(otherRoot);
          final otherOperation =
              (checkedOther['projection']['operations'] as List).single as Map;
          final unconfigured = await project.prepareRequest(
            otherRoot,
            resource: otherOperation['resource'] as String,
            pointer: otherOperation['pointer'] as String,
            occurrence: otherOperation['occurrence'] as String,
          );
          try {
            await expectLater(
              const ContractRequestExecutor().execute(
                unconfigured,
                OperationRequestDraft(
                  planIdentity: unconfigured.identity,
                  environment: 'manual',
                ),
                resolveSecret: (_) async => 'synthetic-key',
              ),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'request.security.configuration',
                ),
              ),
            );
          } finally {
            unconfigured.close();
          }
          expect(
            received,
            3,
            reason: 'An unconfigured root must not receive a credential alias',
          );
        },
      );
    }
  }
}
