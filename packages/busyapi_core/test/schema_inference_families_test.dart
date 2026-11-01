import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format reviewed inference retains native schema semantics', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-inference-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final legacy = version == '2.0';
        const responsePointer = '/paths/~1items/get/responses/200';
        final pointer = legacy
            ? responsePointer
            : '$responsePointer/content/application~1json';
        final examplePointer = legacy
            ? '$pointer/examples/application~1json'
            : '$pointer/example';
        final document = {
          if (legacy) 'swagger': version else 'openapi': version,
          'info': {'title': 'Keep 雪', 'version': 'api'},
          if (legacy) 'produces': ['application/json'],
          'paths': {
            '/items': {
              'get': {
                'responses': {
                  '200': {
                    'description': 'Read',
                    if (legacy)
                      'examples': {'application/json': null}
                    else
                      'content': {
                        'application/json': {'example': null},
                      },
                  },
                },
              },
            },
          },
          'x-exact': 'EXACT',
        };
        final source =
            '${format == 'yaml' ? '# Keep comments\r\n' : ''}${jsonEncode(document).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
        final file = File('${temp.path}/api.$format');
        file.writeAsStringSync('\ufeff$source');
        final original = file.readAsBytesSync();
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id;
        final buffer = await project.buffer(root);
        final page = await project.inspectObject(root, root, pointer);
        expect(page['schemaSuggestion']['nullable'], isTrue);
        expect(page['schemaSuggestion']['samples'], [
          {'pointer': examplePointer, if (legacy) 'name': 'application/json'},
        ]);
        Future<RefactoringPlan> plan({bool nullable = false}) =>
            project.planSchemaSuggestion(root, root, examplePointer, {
              'resource': root,
              'pointer': pointer,
              'generation': buffer.generation,
              'range': page['range'],
            }, nullable: nullable);
        final proposal = await plan(nullable: true);
        if (legacy) {
          expect(proposal.result['schema'], {
            'type': ['null'],
          });
        } else if (version == '3.0.4') {
          expect(
            proposal.result['schema']['anyOf'],
            everyElement({
              'type': 'string',
              'nullable': true,
              'enum': [null],
            }),
          );
        } else {
          expect(
            proposal.result['schema']['anyOf'],
            everyElement({'type': 'null'}),
          );
        }
        expect(buffer.text, source);
        expect(file.readAsBytesSync(), original);
        await project.applyRefactoring(proposal);
        final accepted = buffer.bytes();
        expect(buffer.text, contains('9007199254740993.00'));
        expect(buffer.text, endsWith('\r\n'));
        expect(buffer.hasBom, isTrue);
        final report = await project.check(root);
        expect(report['complete'], isTrue, reason: jsonEncode(report));
        expect(
          (report['findings'] as List).where((f) => f['severity'] == 'error'),
          isEmpty,
        );
        project.store.undo();
        expect(buffer.bytes(), original);
        project.store.redo();
        expect(buffer.bytes(), accepted);
        await project.save(buffer);
        expect(file.readAsBytesSync(), accepted);
        project.store.undo();
        final stale = await plan();
        project.store.replace(
          root,
          buffer.text.replaceFirst('Keep 雪', 'Changed 雪'),
        );
        await expectLater(
          project.applyRefactoring(stale),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
          ),
        );
        expect(buffer.text, contains('Changed 雪'));
        expect(file.readAsBytesSync(), accepted);
      });
    }
  }
}
