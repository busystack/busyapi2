import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  dynamic decode(String text) => jsonDecode(text.substring(text.indexOf('{')));
  test('semantic resource transitions are scoped, reversible and do not retarget siblings', () {
    const transition = SemanticTransition(
      'file:///old.yaml',
      '/components/schemas/A',
      '/components/schemas/B',
      destinationResource: 'file:///new.yaml',
    );
    expect(
      transition.mapResource(
        'file:///old.yaml',
        '/components/schemas/A/properties/n',
      ),
      'file:///new.yaml',
    );
    expect(
      transition.map('/components/schemas/A/properties/n'),
      '/components/schemas/B/properties/n',
    );
    expect(
      transition.mapResource('file:///old.yaml', '/components/schemas/Other'),
      'file:///old.yaml',
    );
    expect(
      transition.mapResource('file:///unrelated.yaml', '/components/schemas/A'),
      'file:///unrelated.yaml',
    );
    final reverse = transition.reversed;
    expect(
      reverse.mapResource(
        'file:///new.yaml',
        '/components/schemas/B/properties/n',
      ),
      'file:///old.yaml',
    );
    expect(
      reverse.map('/components/schemas/B/properties/n'),
      '/components/schemas/A/properties/n',
    );
    expect(
      reverse.mapResource('file:///new.yaml', '/components/schemas/Other'),
      'file:///new.yaml',
    );
    const samePointer = SemanticTransition(
      'a',
      '/Value',
      '/Value',
      destinationResource: 'b',
    );
    expect(samePointer.mapResource('a', '/Value/child'), 'b');
    expect(samePointer.reversed.mapResource('b', '/Value/child'), 'a');
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'extract and inline $version $json preserve all buffers through undo and reopening',
        () async {
          final temp = await Directory.systemTemp.createTemp('busyapi-copy-');
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final root = File('${temp.path}/root.${json ? 'json' : 'yaml'}'),
              other = File('${temp.path}/other.json'),
              consumer = File('${temp.path}/consumer.json');
          final data = {
            'openapi': version,
            'info': {'title': 'Copies', 'version': '1'},
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'Owner': {
                  'properties': {
                    'inline': {
                      'type': 'object',
                      'properties': {
                        'value': {'type': 'integer'},
                      },
                      'description': 'First\n😀 second\n',
                      'examples': [
                        {'value': 'EXACT_NUMBER', r'$ref': 'literal payload'},
                      ],
                    },
                    'boolean': false,
                  },
                },
                'External': {r'$ref': 'consumer.json#/Schema'},
              },
            },
          };
          var text = const JsonEncoder.withIndent('  ')
              .convert(data)
              .replaceAll('"EXACT_NUMBER"', '900719925474099312345');
          if (!json) text = '# retained\r\n${text.replaceAll('\n', '\r\n')}';
          await root.writeAsString('\ufeff$text');
          const pointer = '/components/schemas/Owner/properties/inline';
          await consumer.writeAsString(
            jsonEncode({
              'Schema': {
                r'$ref':
                    '${root.uri.pathSegments.last}#$pointer/properties/value',
              },
            }),
          );
          await other.writeAsString(
            jsonEncode({
              'openapi': version,
              'info': {'title': 'Other', 'version': '1'},
              'paths': <String, Object?>{},
              'components': {
                'schemas': {
                  'Use': {r'$ref': 'consumer.json#/Schema'},
                },
              },
            }),
          );
          await File('${temp.path}/busyapi.yaml').writeAsString(
            'version: 1\nroots:\n  - name: first\n    path: ${root.uri.pathSegments.last}\n  - name: second\n    path: other.json\n',
          );
          var project = await BusyProject.open(temp.path, engine);
          addTearDown(() => project.close());
          final buffer = await project.buffer(root.uri.toString()),
              original = buffer.bytes(),
              oldConsumer = await consumer.readAsBytes(),
              otherBytes = await other.readAsBytes();
          final target = <String, Object?>{
            'root': root.uri.toString(),
            'resource': buffer.id,
            'generation': buffer.generation,
            'pointer': pointer,
          };
          final plan = await project.planComponentExtraction(
            target,
            'Extracted',
          );
          expect(plan.checkedRoots.toSet(), {
            root.uri.toString(),
            other.uri.toString(),
          });
          expect(plan.edits, hasLength(2));
          expect(
            buffer.bytes(),
            original,
            reason: 'Review/cancel does not mutate any source',
          );
          await project.applyRefactoring(plan);
          final accepted = buffer.bytes(),
              fragment = project.store.get(consumer.uri.toString());
          expect(buffer.text, contains('900719925474099312345'));
          expect(buffer.text, isNot(endsWith('\n')));
          expect(buffer.hasBom, true);
          expect(
            decode(
              buffer.text,
            )['components']['schemas']['Owner']['properties']['inline'],
            {r'$ref': '#/components/schemas/Extracted'},
          );
          expect(
            fragment.text,
            contains('#/components/schemas/Extracted/properties/value'),
          );
          final consumerAccepted = fragment.bytes();
          final undo = project.store.undo();
          expect(
            undo.single.map('/components/schemas/Extracted/properties/value'),
            '$pointer/properties/value',
          );
          expect(buffer.bytes(), original);
          expect(fragment.bytes(), oldConsumer);
          project.store.redo();
          expect(buffer.bytes(), accepted);
          expect(fragment.bytes(), consumerAccepted);
          final inlinePlan = await project.planReferenceInlining({
            ...target,
            'generation': buffer.generation,
          });
          await project.applyRefactoring(inlinePlan);
          final inlined = decode(buffer.text)['components']['schemas'];
          expect(inlined['Owner']['properties']['inline']['type'], 'object');
          expect(inlined['Extracted']['description'], 'First\n😀 second\n');
          expect(buffer.text, contains('900719925474099312345'));
          project.store.undo();
          expect(buffer.bytes(), accepted);
          expect(fragment.bytes(), consumerAccepted);
          project.store.redo();
          final finalBytes = buffer.bytes();
          final publication = PublicationStore(
            '${temp.path}/private-publication',
          );
          expect(
            (await publication.save(
              project,
              project.store.buffers.values,
            )).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(temp.path, engine);
          expect((await project.buffer(buffer.id)).bytes(), finalBytes);
          expect((await project.buffer(fragment.id)).bytes(), consumerAccepted);
          expect(await other.readAsBytes(), otherBytes);
          expect(
            (await project.check(root.uri.toString()))['status'],
            'complete',
          );
        },
      );
    }
  }
  test('later unopened disk input or unsaved consumer rejects the entire extraction', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-copy-stale-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json'),
        part = File('${temp.path}/part.json');
    await root.writeAsString(
      r'{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{},"components":{"schemas":{"A":{"properties":{"child":false}},"External":{"$ref":"part.json#/Use"}}}}',
    );
    await part.writeAsString(
      r'{"Use":{"$ref":"root.json#/components/schemas/A/properties/child"}}',
    );
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final buffer = await project.buffer(root.uri.toString()),
        before = buffer.bytes();
    Future<RefactoringPlan> plan() => project.planComponentExtraction({
      'root': buffer.id,
      'resource': buffer.id,
      'generation': buffer.generation,
      'pointer': '/components/schemas/A/properties/child',
    }, 'Child');
    final unopened = await plan();
    expect(project.store.buffers.containsKey(part.uri.toString()), false);
    await part.writeAsString(
      r'{"Use":{"$ref":"root.json#/components/schemas/A/properties/child"},"later":true}',
    );
    await expectLater(
      project.applyRefactoring(unopened),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    expect(buffer.bytes(), before);
    final stale = await plan(),
        fragment = await project.buffer(part.uri.toString());
    project.store.replace(fragment.id, '${fragment.text}\n');
    await expectLater(
      project.applyRefactoring(stale),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    expect(buffer.bytes(), before);
    expect(fragment.dirty, true);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'cross-file extraction $version $json captures destination, history and publication',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-extract-destination-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final extension = json ? 'json' : 'yaml';
          final root = File('${temp.path}/a.$extension'),
              destination = File('${temp.path}/b.$extension'),
              consumer = File('${temp.path}/consumer.json');
          const pointer = '/components/schemas/Owner/properties/inline';
          final data = {
            'openapi': version,
            'info': {'title': 'A', 'version': '1'},
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'Owner': {
                  'properties': {
                    'inline': {
                      'type': 'object',
                      'description': '😀 preserved\n',
                      'properties': {'n': false},
                      'examples': ['EXACT'],
                    },
                  },
                },
                'External': {r'$ref': 'consumer.json#/Use'},
              },
            },
          };
          final source =
              '${json ? '' : '# retained\r\n'}${const JsonEncoder.withIndent('  ').convert(data).replaceAll('"EXACT"', '900719925474099312345')}';
          await root.writeAsString('\ufeff$source');
          await destination.writeAsString(
            jsonEncode({
              'openapi': version,
              'info': {'title': 'B', 'version': '1'},
              'paths': <String, Object?>{},
            }),
          );
          await consumer.writeAsString(
            jsonEncode({
              'Use': {r'$ref': 'a.$extension#$pointer/properties/n'},
            }),
          );
          await File('${temp.path}/busyapi.yaml').writeAsString(
            'version: 1\nroots:\n  - name: first\n    path: a.$extension\n  - name: models\n    path: b.$extension\n',
          );
          var project = await BusyProject.open(temp.path, engine);
          addTearDown(() => project.close());
          final original = {
            for (final f in [root, destination, consumer])
              f.uri.toString(): await f.readAsBytes(),
          };
          final buffer = await project.buffer(root.uri.toString());
          final plan = await project.planComponentExtraction(
            {
              'root': buffer.id,
              'resource': buffer.id,
              'generation': buffer.generation,
              'pointer': pointer,
            },
            'Copied',
            destinationResource: destination.uri.toString(),
          );
          expect(plan.edits, hasLength(3));
          expect(plan.transition.toResource, destination.uri.toString());
          for (final entry in original.entries)
            expect(
              await File(Uri.parse(entry.key).toFilePath()).readAsBytes(),
              entry.value,
            );
          await project.applyRefactoring(plan);
          expect(
            decode(
              buffer.text,
            )['components']['schemas']['Owner']['properties']['inline'][r'$ref'],
            'b.$extension#/components/schemas/Copied',
          );
          expect(
            project.store.get(destination.uri.toString()).text,
            contains('900719925474099312345'),
          );
          expect((await project.check(buffer.id))['status'], 'complete');
          final saved = {
            for (final b in project.store.buffers.values) b.id: b.bytes(),
          };
          final reverse = project.store.undo().single;
          expect(
            reverse.mapResource(
              destination.uri.toString(),
              '/components/schemas/Copied/properties/n',
            ),
            buffer.id,
          );
          for (final entry in original.entries)
            expect(project.store.get(entry.key).bytes(), entry.value);
          final forward = project.store.redo().single;
          expect(
            forward.mapResource(buffer.id, '$pointer/properties/n'),
            destination.uri.toString(),
          );
          final publication = PublicationStore(
            '${temp.path}/private-publication',
          );
          if (version == '3.2.1' && !json) {
            final partial = await publication.save(
              project,
              project.store.buffers.values,
              beforePublish: (path) async {
                if (path == destination.path)
                  throw StateError('Injected destination publication failure');
              },
            );
            expect(partial.complete, false);
            expect(partial.failed.keys, contains(destination.uri.toString()));
            final inspection = await publication.inspect(project);
            expect(inspection.single['outcomes'], isNotEmpty);
            expect(
              project.store.get(destination.uri.toString()).bytes(),
              saved[destination.uri.toString()],
            );
            // An external writer after partial publication wins disk ownership;
            // neither restart inspection nor another save may overwrite it.
            final external = '${await destination.readAsString()}\n';
            await destination.writeAsString(external);
            expect(
              (await publication.save(
                project,
                project.store.buffers.values,
              )).complete,
              false,
            );
            expect(await destination.readAsString(), external);
            expect(
              project.store.get(destination.uri.toString()).bytes(),
              saved[destination.uri.toString()],
            );
            return;
          }
          expect(
            (await publication.save(
              project,
              project.store.buffers.values,
            )).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(temp.path, engine);
          expect((await project.check(buffer.id))['status'], 'complete');
          for (final entry in saved.entries)
            expect((await project.buffer(entry.key)).bytes(), entry.value);
        },
      );
    }
  }
  test('real block YAML preserves mixed lines, quotes, comments and BOM through publication', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-copy-block-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.yaml');
    const text = r'''# retained
openapi: 3.2.1
info: {title: Block, version: "1"}
paths: {}
components:
  schemas:
    Owner:
      properties:
        child:
          type: object # constraint comment
          description: |
            First 😀
            Second
          properties: {n: {type: integer}}
          examples:
            - {n: 900719925474099312345, "$ref": "literal payload"}
        after: false
    'Last': {x-kept: 1.00}''';
    final authored = text
        .replaceAll('\n', '\r\n')
        .replaceFirst('paths: {}\r\n', 'paths: {}\n');
    await root.writeAsString('\ufeff$authored');
    var project = await BusyProject.open(root.path, engine);
    addTearDown(() => project.close());
    final buffer = await project.buffer(root.uri.toString()),
        before = buffer.bytes();
    const pointer = '/components/schemas/Owner/properties/child';
    final plan = await project.planComponentExtraction({
      'root': buffer.id,
      'resource': buffer.id,
      'generation': buffer.generation,
      'pointer': pointer,
    }, 'Extracted');
    await project.applyRefactoring(plan);
    expect(buffer.text, contains('type: object # constraint comment\r\n'));
    expect(buffer.text, contains('First 😀\r\n'));
    expect(buffer.text, contains('900719925474099312345'));
    expect(buffer.text, contains("'Last': {x-kept: 1.00}"));
    expect(buffer.text, contains('paths: {}\n'));
    expect(buffer.text, contains('after: false\r\n'));
    expect(buffer.text, isNot(endsWith('\n')));
    final extracted = buffer.bytes();
    project.store.undo();
    expect(buffer.bytes(), before);
    project.store.redo();
    expect(buffer.bytes(), extracted);
    await project.applyRefactoring(
      await project.planReferenceInlining({
        'root': buffer.id,
        'resource': buffer.id,
        'generation': buffer.generation,
        'pointer': pointer,
      }),
    );
    expect(buffer.text, contains('900719925474099312345'));
    final accepted = buffer.bytes();
    final publication = PublicationStore('${temp.path}/private-publication');
    expect(
      (await publication.save(project, project.store.buffers.values)).complete,
      true,
    );
    expect(await root.readAsBytes(), accepted);
    project.close();
    project = await BusyProject.open(root.path, engine);
    expect((await project.buffer(buffer.id)).bytes(), accepted);
    expect((await project.check(buffer.id))['status'], 'complete');
  });
}
