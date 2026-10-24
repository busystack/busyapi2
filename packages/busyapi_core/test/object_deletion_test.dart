import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'reviewed deletion $version verifies all roots and publishes exact source',
      () async {
        final temp = await Directory.systemTemp.createTemp('busyapi-delete-');
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final root = File('${temp.path}/a.json'),
            other = File('${temp.path}/b.json'),
            part = File('${temp.path}/part.json');
        final data = {
          'openapi': version,
          'info': {'title': 'Deletion', 'version': '1'},
          'paths': <String, Object?>{},
          'components': {
            'schemas': {
              'Model': {r'$ref': 'part.json#/Model'},
            },
          },
        };
        await root.writeAsString(jsonEncode(data));
        await other.writeAsString(jsonEncode(data));
        await File('${temp.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots:\n  - name: first\n    path: a.json\n  - name: second\n    path: b.json\n',
        );
        const original =
            '{ "Model": { "type": "object", "properties": { "old": { "type": "string", "maxLength": 12 }, "keep": { "type": "number" } }, "required": ["old", "keep"], "examples": [{"old":9007199254740993}], "x-kept": 1.00 } }\r\n';
        await part.writeAsString('\ufeff$original');
        var project = await BusyProject.open(temp.path, engine);
        addTearDown(() => project.close());
        final buffer = await project.buffer(part.uri.toString()),
            before = buffer.bytes();
        Future<RefactoringPlan> plan() => project.planObjectDeletion({
          'resource': buffer.id,
          'generation': buffer.generation,
          'pointer': '/Model/properties/old',
        });
        final review = await plan();
        expect(review.checkedRoots.toSet(), {
          root.uri.toString(),
          other.uri.toString(),
        });
        expect(review.result['usages'], hasLength(2));
        expect(review.result['blockers'], isEmpty);
        expect(
          buffer.bytes(),
          before,
          reason: 'Collecting or cancelling review cannot change a buffer',
        );
        await project.applyRefactoring(review);
        final accepted = buffer.bytes();
        expect(jsonDecode(buffer.text)['Model']['required'], ['keep']);
        expect(buffer.text, contains('9007199254740993'));
        expect(buffer.text, contains('"x-kept": 1.00'));
        expect(buffer.hasBom, true);
        expect(buffer.text, endsWith('\r\n'));
        var selected = '/Model/properties/old';
        for (final transition in review.transitions) {
          selected = transition.map(selected);
        }
        expect(selected, '/Model/properties');
        for (final transition in project.store.undo()) {
          selected = transition.map(selected);
        }
        expect(selected, '/Model/properties/old');
        expect(buffer.bytes(), before);
        project.store.redo();
        expect(buffer.bytes(), accepted);
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
        expect(await part.readAsBytes(), accepted);
        project.close();
        project = await BusyProject.open(temp.path, engine);
        expect((await project.buffer(buffer.id)).bytes(), accepted);
        expect(
          (await project.check(root.uri.toString()))['status'],
          'complete',
        );
      },
    );
  }
  test('blocked deletion and later unsaved or external consumers change no reviewed buffer', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-delete-stale-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json'),
        part = File('${temp.path}/part.json');
    await root.writeAsString(
      r'{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{},"components":{"schemas":{"Model":{"$ref":"part.json#/Model"},"Unused":false}}}',
    );
    await part.writeAsString('{"Model":{"type":"string"}}');
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final buffer = await project.buffer(root.uri.toString());
    final definition = await project.buffer(part.uri.toString());
    final blocked = await project.planObjectDeletion({
      'resource': part.uri.toString(),
      'generation': definition.generation,
      'pointer': '/Model',
    });
    expect(blocked.result['blockers'], isNotEmpty);
    final before = buffer.text;
    await expectLater(
      project.applyRefactoring(blocked),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.blocked'),
      ),
    );
    expect(buffer.text, before);
    Future<RefactoringPlan> plan() => project.planObjectDeletion({
      'resource': buffer.id,
      'generation': buffer.generation,
      'pointer': '/components/schemas/Unused',
    });
    final stale = await plan();
    final dependency = await project.buffer(part.uri.toString());
    project.store.replace(dependency.id, '{"Model":{"type":"number"}}');
    await expectLater(
      project.applyRefactoring(stale),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    expect(buffer.text, before);
    expect(dependency.text, '{"Model":{"type":"number"}}');
    await project.save(dependency);
    final external = await plan();
    await part.writeAsString('{"Model":{"type":"boolean"}}');
    await expectLater(
      project.applyRefactoring(external),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    expect(buffer.text, before);
    expect(await part.readAsString(), '{"Model":{"type":"boolean"}}');
  });
  test(
    'removal/restoration never maps unrelated descendants of the collection',
    () {
      const transition = SemanticTransition(
        'resource',
        '/schemas/Deleted',
        '/schemas',
        mode: 'removal',
      );
      expect(transition.map('/schemas/Deleted/properties/x'), '/schemas');
      expect(transition.map('/schemas/Other'), '/schemas/Other');
      expect(transition.reversed.map('/schemas'), '/schemas/Deleted');
      expect(transition.reversed.map('/schemas/Other'), '/schemas/Other');
    },
  );
}
