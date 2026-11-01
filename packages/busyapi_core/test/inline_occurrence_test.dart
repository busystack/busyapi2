import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final external in [false, true]) {
        test(
          'inline acyclic shared target $version $json external=$external survives stale review, history and saving',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-inline-acyclic-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final extension = json ? 'json' : 'yaml',
                source = File('${temp.path}/source.$extension'),
                destination = external
                    ? File('${temp.path}/destination.$extension')
                    : source;
            final model = {
                  'description': 'Saved model',
                  'type': 'object',
                  r'$defs': {
                    'a/b~1': {'type': 'integer', 'minimum': 111},
                  },
                  'properties': {
                    'value': {
                      r'$ref': '#/components/schemas/Model/\$defs/a~1b~01',
                    },
                  },
                  'required': ['value'],
                  'unevaluatedProperties': false,
                },
                use = {
                  r'$ref':
                      '${external ? 'source.$extension' : ''}#/components/schemas/Model',
                  'examples': [
                    {'value': 111},
                    {'value': 222},
                    {'value': 'not an integer'},
                  ],
                };
            String encode(Map<String, Object?> schemas) {
              final text =
                  jsonEncode({
                        'openapi': version,
                        'info': {'title': 'Acyclic inline', 'version': '1'},
                        'paths': <String, Object?>{},
                        'components': {'schemas': schemas},
                      })
                      .replaceAll('111', '9007199254740993.00')
                      .replaceAll('222', '9007199254740992');
              return json ? text : '\ufeff# keep Unicode 雪😀\r\n$text';
            }

            await source.writeAsString(
              encode({'Model': model, if (!external) 'Use': use}),
            );
            if (external) await destination.writeAsString(encode({'Use': use}));
            if (external) {
              await File('${temp.path}/busyapi.yaml').writeAsString(
                'version: 1\nroots:\n  - {name: Source, path: source.$extension}\n  - {name: Destination, path: destination.$extension}\n',
              );
            }
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(
              external ? temp.path : destination.path,
              engine,
            );
            addTearDown(project.close);
            final sourceBuffer = await project.buffer(source.uri.toString()),
                targetBuffer = await project.buffer(destination.uri.toString()),
                originalTarget = targetBuffer.bytes(),
                originalSource = sourceBuffer.bytes();
            Future<RefactoringPlan> prepare() => project.planReferenceInlining({
              'root': targetBuffer.id,
              'resource': targetBuffer.id,
              'generation': targetBuffer.generation,
              'pointer': '/components/schemas/Use',
            });
            Future<void> check(BusyProject owner) async {
              final checked = await owner.check(destination.uri.toString());
              expect(checked['complete'], true, reason: jsonEncode(checked));
              expect(
                (checked['findings'] as List).where(
                  (finding) => finding['code'] == 'example.schema.incompatible',
                ),
                hasLength(2),
              );
            }

            await check(project);
            final stale = await prepare();
            project.store.replace(
              sourceBuffer.id,
              sourceBuffer.text.replaceFirst('Saved model', 'Unsaved model'),
            );
            final workingSource = sourceBuffer.bytes(),
                workingTarget = targetBuffer.bytes();
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
            expect(targetBuffer.bytes(), workingTarget);
            expect(sourceBuffer.bytes(), workingSource);
            final plan = await prepare();
            expect(plan.result['changes'], hasLength(1));
            await project.applyRefactoring(plan);
            final accepted = targetBuffer.bytes();
            expect(targetBuffer.text, contains('9007199254740993.00'));
            expect(targetBuffer.text, contains('Unsaved model'));
            await check(project);
            if (external) expect(sourceBuffer.bytes(), workingSource);
            project.store.undo();
            expect(targetBuffer.bytes(), workingTarget);
            project.store.redo();
            expect(targetBuffer.bytes(), accepted);
            await project.save(targetBuffer);
            expect(await destination.readAsBytes(), accepted);
            if (external) expect(await source.readAsBytes(), originalSource);
            final reopened = await BusyProject.open(destination.path, engine);
            addTearDown(reopened.close);
            await check(reopened);
            expect(
              (await reopened.buffer(destination.uri.toString())).bytes(),
              accepted,
            );
            expect(accepted, isNot(originalTarget));
          },
        );
      }
      for (final identified in [false, true]) {
        test(
          'inline occurrence $version $json identified=$identified preserves data, prior unsaved edits and independent reopening',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-inline-occurrence-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final extension = json ? 'json' : 'yaml',
                source = File('${temp.path}/source/root.$extension'),
                destination = File('${temp.path}/destination/root.$extension'),
                other = File('${temp.path}/source/other.$extension'),
                manifest = File('${temp.path}/busyapi.yaml');
            await source.parent.create();
            await destination.parent.create();
            final payload = {
              if (identified) ...{
                r'$id': 'https://identities.invalid/data',
                r'$dynamicAnchor': 'data',
              },
              r'$ref': 'other.$extension#/Thing',
              'description': 'Literal [link](../not-loaded)',
              'x-count': 111,
            };
            String encode(Object value) {
              final text = jsonEncode(value)
                  .replaceAll('111', '9007199254740993.00')
                  .replaceAll('222', '9007199254740992');
              return json ? text : '\ufeff# retained Unicode 雪😀\r\n$text';
            }

            await source.writeAsString(
              encode({
                'openapi': version,
                'info': {'title': 'Source', 'version': '1'},
                'paths': <String, Object?>{},
                'components': {
                  'schemas': {
                    'Model': {
                      'description': 'Saved model',
                      'const': payload,
                      'examples': [
                        {...payload},
                        {...payload, 'x-count': 222},
                      ],
                    },
                    'Inner': {r'$ref': '#/components/schemas/Model/const'},
                  },
                },
              }),
            );
            await destination.writeAsString(
              encode({
                'openapi': version,
                'info': {'title': 'Destination', 'version': '1'},
                'paths': <String, Object?>{},
                'components': {
                  'schemas': {
                    'Use': {
                      r'$ref':
                          '../source/root.$extension#/components/schemas/Model',
                    },
                  },
                },
              }),
            );
            await other.writeAsString(
              encode({
                'Thing': {'type': 'string'},
              }),
            );
            await manifest.writeAsString(
              'version: 1\nroots:\n  - {name: Source, path: source/root.$extension}\n  - {name: Destination, path: destination/root.$extension}\n${identified ? 'resourceMappings: {"https://identities.invalid/other.$extension": source/other.$extension}\n' : ''}unknown: {\$ref: untouched data}\n',
            );
            final original = {
              for (final file in [source, destination, other, manifest])
                file.path: await file.readAsBytes(),
            };
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(temp.path, engine);
            addTearDown(project.close);
            final sourceBuffer = await project.buffer(source.uri.toString()),
                targetBuffer = await project.buffer(destination.uri.toString());
            project.store.replace(
              sourceBuffer.id,
              sourceBuffer.text.replaceFirst('Saved model', 'Unsaved model'),
            );
            final working = sourceBuffer.bytes();
            Future<String> data(
              String root,
              String resource,
              String pointer,
            ) async {
              final page = await project.inspectObject(root, resource, pointer);
              final field = (page['fields'] as List).cast<Map>().singleWhere(
                (field) => field['name'] == 'const',
              );
              return project.readDataValue(
                Map<String, dynamic>.from(field['target'] as Map),
              );
            }

            final before = await data(
              sourceBuffer.id,
              sourceBuffer.id,
              '/components/schemas/Model',
            );
            final plan = await project.planReferenceInlining({
              'root': targetBuffer.id,
              'resource': targetBuffer.id,
              'generation': targetBuffer.generation,
              'pointer': '/components/schemas/Use',
            });
            expect(plan.result['checkedRoots'], hasLength(2));
            await project.applyRefactoring(plan);
            expect(sourceBuffer.bytes(), working);
            expect(targetBuffer.text, contains('Unsaved model'));
            expect(
              await data(
                targetBuffer.id,
                targetBuffer.id,
                '/components/schemas/Use',
              ),
              before,
            );
            expect(targetBuffer.text, contains('9007199254740993.00'));
            final accepted = targetBuffer.bytes();
            project.store.undo();
            expect(targetBuffer.bytes(), original[destination.path]);
            expect(sourceBuffer.bytes(), working);
            project.store.redo();
            expect(targetBuffer.bytes(), accepted);
            expect(sourceBuffer.bytes(), working);
            for (final file in original.entries)
              expect(await File(file.key).readAsBytes(), file.value);
            final publication = PublicationStore('${temp.path}/private');
            expect(
              (await publication.save(project, [targetBuffer])).complete,
              true,
            );
            expect(await destination.readAsBytes(), accepted);
            expect(await source.readAsBytes(), original[source.path]);
            expect(await other.readAsBytes(), original[other.path]);
            expect(await manifest.readAsBytes(), original[manifest.path]);
            // A copied literal's ref-looking strings and $id are not acquisition
            // capabilities. Reopen with no permission to read the source project.
            final independentFile = File(
              '${temp.path}/independent/root.$extension',
            );
            await independentFile.parent.create();
            await independentFile.writeAsBytes(accepted);
            final independent = await BusyProject.open(
              independentFile.path,
              engine,
            );
            addTearDown(independent.close);
            final checked = await independent.check(
              independent.roots.single.id,
            );
            expect(checked['complete'], true, reason: jsonEncode(checked));
            expect(
              (checked['findings'] as List).where(
                (finding) => finding['code'] == 'example.schema.incompatible',
              ),
              hasLength(1),
            );
            await project.save(sourceBuffer);
            final reopened = await BusyProject.open(temp.path, engine);
            addTearDown(reopened.close);
            expect(
              (await reopened.buffer(source.uri.toString())).bytes(),
              working,
            );
            expect(
              (await reopened.buffer(destination.uri.toString())).bytes(),
              accepted,
            );
            expect(await other.readAsBytes(), original[other.path]);
            expect(await manifest.readAsBytes(), original[manifest.path]);
          },
        );
      }
    }
  }
}
