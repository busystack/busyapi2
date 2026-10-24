import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory dir;
  late EngineProcess engine;
  final projects = <BusyProject>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('busyapi-review-ownership-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    for (final project in projects) {
      project.close();
    }
    projects.clear();
    await engine.close();
    await dir.delete(recursive: true);
  });
  Future<ProcessResult> git(List<String> arguments) async {
    final result = await Process.run(
      '/usr/bin/git',
      arguments,
      workingDirectory: dir.path,
      environment: const {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return result;
  }

  for (final deleting in [false, true]) {
    test(
      'F11 ordinary Save acknowledges its retained owner during virtual ${deleting ? 'deletion' : 'move'}',
      () async {
        final root = File('${dir.path}/openapi.json')
          ..writeAsStringSync(
            '{"openapi":"3.2.1","info":{"title":"Owner","version":"1"},"paths":{}}',
          );
        final file = File('${dir.path}/fragment.json')
          ..writeAsStringSync('{"description":"A"}');
        final project = await BusyProject.open(root.path, engine);
        projects.add(project);
        final owner = await project.buffer(file.uri.toString());
        project.store.replace(owner.id, '{"description":"B"}');
        final written = owner.text;
        final reached = Completer<void>(), release = Completer<void>();
        final publications = PublicationStore('${dir.path}/publication');
        final saving = publications.save(
          project,
          [owner],
          beforePublish: (_) async {
            reached.complete();
            await release.future;
          },
        );
        await reached.future;
        try {
          final plan = deleting
              ? await project.planFileDeletion(owner.id)
              : await project.planFileMove(owner.id, '${dir.path}/moved.json');
          expect(plan.result['blockers'] ?? [], isEmpty);
          await project.applyRefactoring(plan);
          if (!deleting) project.store.replace(owner.id, '{"description":"C"}');
        } finally {
          release.complete();
        }
        expect((await saving).complete, true);
        expect(await file.readAsString(), written);
        expect(owner.baseline, written);
        expect(owner.diskIdentity, contentIdentity(utf8.encode(written)));
        expect(owner.externalConflict, false);
        if (!deleting) expect(owner.dirty, true);
        final finalSave = await publications.save(project, [owner]);
        expect(finalSave.complete, true, reason: '${finalSave.failed}');
        expect(await file.exists(), false);
        if (!deleting)
          expect(await File(owner.path).readAsString(), '{"description":"C"}');
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final yaml in [false, true]) {
      test(
        'F12 Git root retrieval alias precedes first historical analysis $version yaml=$yaml',
        () async {
          await git(['init', '-b', 'synthetic']);
          await git(['config', 'user.name', 'BusyAPI Synthetic']);
          await git(['config', 'user.email', 'synthetic@example.invalid']);
          final name = yaml ? 'openapi.yaml' : 'openapi.json';
          final root = File('${dir.path}/$name')
            ..writeAsStringSync(
              yaml
                  ? 'openapi: $version\ninfo: {title: Historical, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: {\$ref: schema.json}}}\n'
                  : jsonEncode({
                      'openapi': version,
                      'info': {'title': 'Historical', 'version': '1'},
                      'paths': {},
                      'components': {
                        'schemas': {
                          'Value': {r'$ref': 'schema.json'},
                        },
                      },
                    }),
            );
          final cache = Directory('${dir.path}/cache')..createSync();
          final schema = File('${cache.path}/original.json')
            ..writeAsStringSync('{"type":"integer","const":9007199254740993}');
          File('${dir.path}/busyapi.yaml').writeAsStringSync(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': name},
              ],
              'resourceMappings': {
                'https://example.test/$name': name,
                'https://example.test/schema.json': 'cache/original.json',
              },
            }),
          );
          await git(['add', '.']);
          await git(['commit', '-m', 'Synthetic base']);
          final project = await BusyProject.open(dir.path, engine);
          projects.add(project);
          final live = await project.check(root.uri.toString());
          expect(live['complete'], true);
          final repository = (await GitRepository.discover(dir.path))!;
          await schema.rename('${cache.path}/renamed-in-working-tree.json');
          File('${dir.path}/busyapi.yaml')
              .writeAsStringSync('invalid working configuration');
          final historical = await repository.historicalSnapshot(
            revision: 'HEAD',
            projectBoundary: dir.path,
            rootPath: name,
            engine: engine,
          );
          expect(
            historical.analysis['complete'],
            true,
            reason: '${historical.analysis['findings']}',
          );
          expect(historical.snapshot.resources, hasLength(2));
          expect(historical.snapshot.resources.first['aliases'], [
            'https://example.test/$name',
          ]);
          expect(
            historical.snapshot.resources.singleWhere(
              (r) => r['id'] == schema.uri.toString(),
            )['text'],
            '{"type":"integer","const":9007199254740993}',
          );
        },
      );
    }
  }
  for (final sample in [
    (255, 0, true),
    (256, 0, false),
    (0, 4100, false),
    (100, 600, false),
  ]) {
    test(
      'F13 URL import reader boundary children=${sample.$1} URI padding=${sample.$2}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final padding = 'a' * sample.$2;
        final rootPath = sample.$1 == 0
            ? '/${padding}openapi.json'
            : '/openapi.json';
        final base = 'http://127.0.0.1:${server.port}';
        final children = [
          for (var i = 0; i < sample.$1; i++) '/$padding/schema$i.json',
        ];
        server.listen((request) async {
          expect(request.headers.value('authorization'), isNull);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            request.uri.path == rootPath
                ? jsonEncode({
                    'openapi': '3.2.1',
                    'info': {'title': 'Import', 'version': '1'},
                    'paths': {},
                    'components': {
                      'schemas': {
                        for (var i = 0; i < children.length; i++)
                          'S$i': {r'$ref': '$base${children[i]}'},
                      },
                    },
                  })
                : '{"type":"string"}',
          );
          await request.response.close();
        });
        final target = '${dir.path}/imported';
        final future = ProjectImporter(engine).prepare(
          kind: ProjectImportKind.url,
          source: '$base$rootPath',
          destination: target,
          approvedUrls: children.map((p) => '$base$p').toSet(),
        );
        if (!sample.$3) {
          await expectLater(
            future,
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'reader rejection',
                anyOf(
                  'resource.configuration',
                  'resource.limit',
                  'limit.manifest',
                ),
              ),
            ),
          );
          expect(await Directory(target).exists(), false);
        } else {
          final plan = await future;
          try {
            expect(plan.complete, true);
            final output = await plan.publish();
            final reopened = await BusyProject.open(output.destination, engine);
            projects.add(reopened);
            expect(reopened.discoveryFailure, isNull);
            expect(
              (await reopened.check(
                File(output.root).uri.toString(),
              ))['complete'],
              true,
            );
          } finally {
            plan.close();
          }
        }
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final yaml in [false, true]) {
      test(
        'F10 reviewed deletion preserves legal implicit IDs $version yaml=$yaml',
        () async {
          const identifier = 'get pets #?% 雪';
          final file = File('${dir.path}/openapi.${yaml ? 'yaml' : 'json'}');
          final data = {
            'openapi': version,
            'info': {'title': 'Delete', 'version': '1'},
            'paths': {
              '/pets': {
                'get': {
                  'operationId': identifier,
                  'responses': {
                    '200': {'description': 'ok'},
                  },
                },
              },
              '/consumer': {
                'get': {
                  'responses': {
                    '200': {
                      'description': 'ok',
                      'links': {
                        'next': {'operationId': identifier},
                      },
                    },
                  },
                },
              },
            },
            'components': {
              'schemas': {
                'Unused': {'type': 'string'},
                'Kept': {'const': 1},
              },
            },
            'x-payload': {r'$ref': 'literal payload'},
          };
          final original = yaml
              ? '''# retained comment 雪\r
openapi: $version\r
info: {title: Delete, version: '1'}\r
paths:\r
  /pets:\r
    get: {operationId: "get pets #?% 雪", responses: {'200': {description: ok}}}\r
  /consumer:\r
    get: {responses: {'200': {description: ok, links: {next: {operationId: "get pets #?% 雪"}}}}}\r
components: {schemas: {Unused: {type: string}, Kept: {const: 1.00}}}\r
x-payload: {\u0024ref: literal payload}\r
'''
              : '${jsonEncode(data).replaceFirst('"const":1', '"const":1.00')}\r\n';
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          projects.add(project);
          final buffer = await project.buffer(file.uri.toString());
          expect((await project.check(buffer.id))['complete'], true);
          final review = await project.planObjectDeletion({
            'resource': buffer.id,
            'generation': buffer.generation,
            'pointer': '/components/schemas/Unused',
          });
          expect(review.result['blockers'], isEmpty);
          expect(buffer.text, original);
          await project.applyRefactoring(review);
          final applied = buffer.text;
          expect(applied, isNot(contains('Unused')));
          expect(applied, contains(identifier));
          expect(applied, contains('1.00'));
          expect(applied, contains('literal payload'));
          expect(await file.readAsString(), original);
          project.store.undo();
          expect(buffer.text, original);
          project.store.redo();
          expect(buffer.text, applied);
          await expectLater(
            project.applyRefactoring(review),
            throwsA(isA<CoreFailure>()),
          );
          final blocked = await project.planObjectDeletion({
            'resource': buffer.id,
            'generation': buffer.generation,
            'pointer': '/paths/~1pets/get',
          });
          expect(blocked.result['blockers'], isNotEmpty);
          await expectLater(
            project.applyRefactoring(blocked),
            throwsA(isA<CoreFailure>()),
          );
          expect(buffer.text, applied);
          await project.save(buffer);
          expect(await file.readAsString(), applied);
          final reopened = await BusyProject.open(file.path, engine);
          projects.add(reopened);
          expect((await reopened.check(file.uri.toString()))['complete'], true);
        },
      );
    }
  }
  test('F11 a replacement object reusing the old map key cannot inherit a Save receipt', () async {
    final root = File('${dir.path}/openapi.json')
      ..writeAsStringSync(
        '{"openapi":"3.2.1","info":{"title":"Receipt","version":"1"},"paths":{}}',
      );
    final file = File('${dir.path}/fragment.json')
      ..writeAsStringSync('{"description":"A"}');
    final project = await BusyProject.open(root.path, engine);
    projects.add(project);
    final owner = await project.buffer(file.uri.toString());
    final replacement = DocumentBuffer.decode(
      file.path,
      utf8.encode('{"description":"replacement owner"}'),
    );
    project.store.replace(owner.id, '{"description":"B"}');
    final result = await PublicationStore('${dir.path}/publication').save(
      project,
      [owner],
      beforePublish: (_) async {
        // Exercise the public store's object-ownership boundary independently of
        // path admission. A map key alone must never transfer this receipt.
        project.store.buffers[owner.id] = replacement;
      },
    );
    expect(result.complete, true);
    expect(await file.readAsString(), '{"description":"B"}');
    expect(replacement.baseline, '{"description":"replacement owner"}');
    expect(
      replacement.diskIdentity,
      contentIdentity(utf8.encode(replacement.baseline)),
    );
  });
  test('F13 generated resource configuration uses actual URI/path/syntax reader checks', () async {
    final access = await ProjectAccess.open(dir.path);
    addTearDown(access.close);
    Future<void> validate(String text) =>
        BusyProject.validateGeneratedConfiguration(
          access,
          engine,
          text: text,
          id: File('${dir.path}/busyapi.yaml').uri.toString(),
        );
    await validate(
      jsonEncode({
        'version': 1,
        'roots': [],
        'resourceMappings': {'https://example.test/a': 'a.json'},
      }),
    );
    for (final value in [
      {
        'version': 1,
        'roots': [],
        'resourceMappings': {
          'https://EXAMPLE.test:443/a': 'a.json',
          'https://example.test/a': 'different.json',
        },
      },
      {
        'version': 1,
        'roots': [],
        'resourceMappings': {
          'https://example.test/a': './a.json',
          'https://example.test/b': 'nested/../a.json',
        },
      },
      {
        'version': 1,
        'roots': [],
        'resourceMappings': {'https://example.test/a': 'a\u0000.json'},
      },
      {
        'version': 1,
        'roots': [],
        'resourceMappings': {
          'https://example.test/a': ['not a path'],
        },
      },
    ]) {
      await expectLater(
        validate(jsonEncode(value)),
        throwsA(isA<CoreFailure>()),
      );
    }
    await expectLater(
      validate('version: 1\nresourceMappings: [\n'),
      throwsA(isA<CoreFailure>()),
    );
    expect(await Directory('${dir.path}/unpublished').exists(), false);
  });
  for (final sample in [('3.1.2', false), ('3.2.1', false), ('3.2.1', true)]) {
    test(
      'F12 production historical comparison detects dependency changes ${sample.$1} self=${sample.$2}',
      () async {
        await git(['init', '-b', 'synthetic']);
        await git(['config', 'user.name', 'BusyAPI Synthetic']);
        await git(['config', 'user.email', 'synthetic@example.invalid']);
        final root = File('${dir.path}/openapi.json');
        final cache = Directory('${dir.path}/cache')..createSync();
        final schema = File('${cache.path}/original.json')
          ..writeAsStringSync('{"type":"integer","const":9007199254740993}');
        root.writeAsStringSync(
          jsonEncode({
            'openapi': sample.$1,
            if (sample.$2)
              r'$self': 'https://identity.example.test/openapi.json',
            'info': {'title': 'History', 'version': '1'},
            'paths': {
              '/pets': {
                'get': {
                  'responses': {
                    '200': {
                      'description': 'ok',
                      'content': {
                        'application/json': {
                          'schema': {r'$ref': 'schema.json'},
                        },
                      },
                    },
                  },
                },
              },
            },
          }),
        );
        File('${dir.path}/busyapi.yaml').writeAsStringSync(
          jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'openapi.json'},
            ],
            'resourceMappings': {
              'https://retrieval.example.test/openapi.json': 'openapi.json',
              '${sample.$2 ? 'https://identity.example.test' : 'https://retrieval.example.test'}/schema.json':
                  'cache/original.json',
            },
          }),
        );
        await git(['add', '.']);
        await git(['commit', '-m', 'Before']);
        schema.writeAsStringSync('{"type":"string"}');
        await git(['add', '--', 'cache/original.json']);
        await git(['commit', '-m', 'Changed dependency']);
        schema.deleteSync();
        File('${dir.path}/busyapi.yaml')
            .writeAsStringSync('invalid current mappings');
        final repository = (await GitRepository.discover(dir.path))!;
        final before = await repository.historicalSnapshot(
          revision: 'HEAD^',
          projectBoundary: dir.path,
          rootPath: 'openapi.json',
          engine: engine,
        );
        final after = await repository.historicalSnapshot(
          revision: 'HEAD',
          projectBoundary: dir.path,
          rootPath: 'openapi.json',
          engine: engine,
        );
        expect(before.analysis['complete'], true);
        expect(after.analysis['complete'], true);
        expect(before.snapshot.resources.first['aliases'], [
          'https://retrieval.example.test/openapi.json',
        ]);
        final comparator = OasdiffAdapter(
          executable: '$testBundle/libexec/busyapi/oasdiff',
        );
        final same = await comparator.compare(
          before.snapshot,
          before.snapshot,
          engine,
          baselineAnalysis: before.analysis,
          currentAnalysis: before.analysis,
        );
        expect(same.complete, true);
        expect(same.changes, isEmpty);
        final changed = await comparator.compare(
          before.snapshot,
          after.snapshot,
          engine,
          baselineAnalysis: before.analysis,
          currentAnalysis: after.analysis,
        );
        expect(changed.complete, true);
        expect(changed.breaking, true);
        expect(changed.changes, isNotEmpty);
        expect(
          before.snapshot.resources.singleWhere(
            (r) => r['id'] == schema.uri.toString(),
          )['text'],
          contains('9007199254740993'),
        );
        expect(
          after.snapshot.resources.singleWhere(
            (r) => r['id'] == schema.uri.toString(),
          )['text'],
          '{"type":"string"}',
        );
        expect(schema.existsSync(), false);
      },
    );
  }
}
