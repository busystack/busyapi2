import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _ChoicesEngine extends EngineProcess {
  _ChoicesEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  String? malformed;
  Completer<void>? entered, release;
  Completer<void>? planEntered, planRelease;
  int planCalls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'planReference') {
      planCalls++;
      if (planRelease case final gate?) {
        planRelease = null;
        planEntered!.complete();
        await gate.future;
      }
    }
    if (method == 'referenceChoices') {
      if (release case final gate?) {
        release = null;
        entered!.complete();
        await gate.future;
      }
      if (malformed == 'range') result['range'] = [-1, 5];
      if (malformed == 'target')
        (result['entries'] as List)[0]['target']['generation'] = -1;
      if (malformed == 'kind')
        (result['entries'] as List)[0]['kind'] = 'header';
    }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true]) {
      test('identified external selection $version $json survives cold reopen', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-choice-identity-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = _ChoicesEngine();
        addTearDown(engine.close);
        final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
        final part = File('${temp.path}/models.json');
        const external =
            r'{"$id":"urn:busyapi:choice:model","$defs":{"Old":{"type":"string"},"New":{"type":"integer","minimum":9007199254740993}},"x-kept":{"$ref":"literal payload"}}';
        await part.writeAsString(external);
        final original = json
            ? jsonEncode({
                'openapi': version,
                'info': {'title': 'Cold', 'version': '1'},
                'paths': {},
                'components': {
                  'schemas': {
                    'Use': {
                      r'$ref': r'models.json#/$defs/Old',
                      'examples': ['wrong', 9007199254740992],
                    },
                  },
                },
              })
            : '# keep 😀\r\nopenapi: $version\r\ninfo: {title: Cold, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Use: {\$ref: models.json#/\$defs/Old, examples: [wrong, 9007199254740992]}';
        await file.writeAsBytes([239, 187, 191, ...utf8.encode(original)]);
        var project = await BusyProject.open(file.path, engine);
        addTearDown(() => project.close());
        final root = project.roots.single.id;
        final page = await project.referenceChoices(
          root,
          root,
          '/components/schemas/Use',
          query: 'New',
        );
        expect(page.result['count'], 1);
        final plan = await project.planReferenceSelection(page, 0);
        await project.applyRefactoring(plan);
        final changed = (await project.buffer(root)).text;
        expect(changed, isNot(original));
        final warm = await project.check(root);
        expect(warm['complete'], true);
        expect(
          (warm['findings'] as List).where(
            (f) => f['code'] == 'example.schema.incompatible',
          ),
          hasLength(2),
        );
        expect(
          (await PublicationStore(
            '${temp.path}/publication',
          ).save(project, project.store.buffers.values)).complete,
          true,
        );
        project.close();
        project = await BusyProject.open(file.path, engine);
        final cold = await project.check(root);
        expect(cold['complete'], true, reason: '${cold['findings']}');
        expect(
          (cold['references'] as List).single['targetResource'],
          part.uri.toString(),
        );
        expect(
          (cold['references'] as List).single['targetPointer'],
          r'/$defs/New',
        );
        expect(
          (cold['findings'] as List).where(
            (f) => f['code'] == 'example.schema.incompatible',
          ),
          hasLength(2),
        );
        expect(await file.readAsBytes(), [
          239,
          187,
          191,
          ...utf8.encode(changed),
        ]);
        expect(await part.readAsString(), external);
      });
    }
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true]) {
      test(
        'typed reference choices $version $json preserve owned source, no-op, undo and reopen',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-reference-choices-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = _ChoicesEngine();
          addTearDown(engine.close);
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}'),
              part = File('${temp.path}/models.json');
          final original = json
              ? jsonEncode({
                  'openapi': version,
                  'info': {'title': 'Choices', 'version': '1'},
                  'paths': <String, Object?>{},
                  'components': {
                    'schemas': {
                      'Use': {r'$ref': '#/components/schemas/Old'},
                      'Old': {'type': 'string'},
                      'New': false,
                      'External': {r'$ref': 'models.json#/Model'},
                    },
                  },
                  'x-kept': {r'$ref': 'literal'},
                })
              : '# keep 😀\r\nopenapi: $version\r\ninfo: {title: Choices, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Use: {\$ref: \'#/components/schemas/Old\'}\r\n    Old: {type: string}\r\n    New: false\r\n    External: {\$ref: models.json#/Model}\r\nx-kept: {\$ref: literal, number: 9007199254740993.00}';
          await file.writeAsBytes([239, 187, 191, ...utf8.encode(original)]);
          await part.writeAsString(
            '{"Model":{"type":"number","x-kept":9007199254740993.00}}',
          );
          var project = await BusyProject.open(file.path, engine);
          addTearDown(() => project.close());
          final root = project.roots.single.id,
              pointer = '/components/schemas/Use';
          final b = await project.buffer(root);
          final captured = await project.referenceChoices(
            root,
            root,
            pointer,
            query: 'New',
          );
          expect(captured.result['count'], 1);
          final plan = await project.planReferenceSelection(captured, 0);
          expect(plan.edits, hasLength(1));
          expect(plan.transitions, isEmpty);
          expect(await file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(original),
          ]);
          await project.applyRefactoring(plan);
          final accepted = original.replaceFirst(
            '#/components/schemas/Old',
            '#/components/schemas/New',
          );
          expect(b.text, accepted);
          expect(b.hasBom, true);
          project.store.undo();
          expect(b.text, original);
          project.store.redo();
          expect(b.text, accepted);
          final noopPage = await project.referenceChoices(
            root,
            root,
            pointer,
            query: 'New',
          );
          expect(
            (await project.planReferenceSelection(noopPage, 0)).edits,
            isEmpty,
          );
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
          project = await BusyProject.open(file.path, engine);
          expect((await project.buffer(root)).text, accepted);
          expect(
            await part.readAsString(),
            '{"Model":{"type":"number","x-kept":9007199254740993.00}}',
          );
        },
      );
    }
  test(
    'malformed, cancelled and stale choices never retarget or apply',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-reference-stale-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final engine = _ChoicesEngine();
      addTearDown(engine.close);
      final file = File('${temp.path}/root.json');
      final text = jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Stale', 'version': '1'},
        'paths': {},
        'components': {
          'schemas': {
            'Use': {r'$ref': '#/components/schemas/Old'},
            'Old': true,
            'New': false,
            'External': {r'$ref': 'models.json#/Model'},
          },
        },
      });
      await file.writeAsString(text);
      final model = File('${temp.path}/models.json');
      await model.writeAsString('{"Model":{"type":"number"},"x-note":1}');
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final root = project.roots.single.id, pointer = '/components/schemas/Use';
      for (final kind in ['range', 'target', 'kind']) {
        engine.malformed = kind;
        await expectLater(
          project.referenceChoices(root, root, pointer, query: 'New'),
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'reference.choice.response',
            ),
          ),
        );
      }
      engine.malformed = null;
      final diskPage = await project.referenceChoices(
        root,
        root,
        pointer,
        query: 'New',
      );
      expect(project.store.buffers.containsKey(model.uri.toString()), false);
      await model.writeAsString('{"Model":{"type":"number"},"x-note":2}');
      // Neither selected occurrence changes range or text. The whole captured
      // graph, not merely the two visible rows, must nevertheless be current.
      await expectLater(
        project.planReferenceSelection(diskPage, 0),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'reference.choice.stale',
          ),
        ),
      );
      await expectLater(
        project.referenceChoices(root, root, pointer, cancelled: () => true),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      final page = await project.referenceChoices(
        root,
        root,
        pointer,
        query: 'New',
      );
      await project.buffer(root);
      project.store.replace(root, '$text\n');
      expect(page.current, false);
      await expectLater(
        project.planReferenceSelection(page, 0),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'reference.choice.stale',
          ),
        ),
      );
      engine.entered = Completer<void>();
      final gate = Completer<void>();
      engine.release = gate;
      final pending = project.referenceChoices(
        root,
        root,
        pointer,
        query: 'New',
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'reference.choice.stale',
          ),
        ),
      );
      await engine.entered!.future;
      project.store.replace(root, '$text\n\n');
      gate.complete();
      await rejected;
      expect(project.store.get(root).text, '$text\n\n');
      expect(await file.readAsString(), text);
      final fresh = await project.referenceChoices(
        root,
        root,
        pointer,
        query: 'New',
      );
      final calls = engine.planCalls;
      await expectLater(
        project.planReferenceSelection(fresh, 0, cancelled: () => true),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      expect(engine.planCalls, calls);
      engine.planEntered = Completer<void>();
      final planGate = Completer<void>();
      engine.planRelease = planGate;
      var cancel = false;
      final planning = project.planReferenceSelection(
        fresh,
        0,
        requestId: 'cancelled-reference-plan',
        cancelled: () => cancel,
      );
      final stopped = expectLater(
        planning,
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      await engine.planEntered!.future;
      cancel = true;
      planGate.complete();
      await stopped;
      expect(project.store.get(root).text, '$text\n\n');
    },
  );
}
