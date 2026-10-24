import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const pointer =
    '/paths/~1items/get/responses/200/content/application~1json/schema';

class _ExtractionEngine extends EngineProcess {
  _ExtractionEngine(this.fault)
    : super(executable: runtimeNode, helper: runtimeHelper);
  final String fault;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'planExtractToFile') {
      final created = (result['creations'] as List).single as Map;
      switch (fault) {
        case 'digest':
          created['identity'] = 'unrelated';
        case 'destination':
          created['resource'] = 'file:///unapproved/new.json';
        case 'count':
          (result['creations'] as List).add(Map.of(created));
        case 'kind':
          result['kind'] = 'component-move';
      }
    }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true])
      for (final boolean in [false, true]) {
        test(
          'extract into a new fragment $version json=$json boolean=$boolean is one virtual transaction',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-extract-file-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final ext = json ? 'json' : 'yaml',
                root = File('${temp.path}/root.$ext'),
                destination = File('${temp.path}/definition 雪.$ext');
            final schema = boolean
                ? false
                : <String, Object>{
                    'type': 'object',
                    'properties': {
                      'n': {'type': 'integer'},
                    },
                    'examples': [
                      {'n': 'EXACT', r'$ref': 'literal payload'},
                    ],
                    'x-kept': {'unknown': false},
                  };
            final source = json
                ? jsonEncode({
                    'openapi': version,
                    'info': {'title': 'New definition 雪😀', 'version': '1'},
                    'paths': {
                      '/items': {
                        'get': {
                          'responses': {
                            '200': {
                              'description': 'OK',
                              'content': {
                                'application/json': {'schema': schema},
                              },
                            },
                            '204': {'description': 'Bodyless'},
                          },
                        },
                      },
                    },
                    'x-data': {r'$ref': 'payload only'},
                  }).replaceAll('"EXACT"', '900719925474099312345678901')
                : '# owner 雪😀\r\nopenapi: $version\r\ninfo: {title: "New definition 雪😀", version: "1"}\npaths:\n  /items:\n    get:\n      responses:\n        "200":\n          description: OK\n          content:\n            application/json:\n              schema: ${boolean ? 'false' : '\n                type: object # retain constraint\n                properties:\n                  n: {type: integer}\n                examples:\n                  - {n: 900719925474099312345678901, \$ref: "literal payload"}\n                x-kept: {unknown: false}'}\n        "204": {description: Bodyless}\nx-data: {\$ref: "payload only"}';
            final original = utf8.encode('\ufeff$source');
            await root.writeAsBytes(original);
            final project = await BusyProject.open(root.path, engine);
            addTearDown(project.close);
            final owner = await project.buffer(root.uri.toString());
            final plan = await project.planComponentExtractionToFile(
              {
                'root': owner.id,
                'resource': owner.id,
                'pointer': pointer,
                'generation': owner.generation,
              },
              'Stored',
              destination.path,
            );
            expect(plan, isA<FileCreationPlan>());
            expect(plan.checkedRoots, [root.uri.toString()]);
            expect(
              plan.result['binding']['pointer'],
              '/components/schemas/Stored',
            );
            expect(await destination.exists(), false);
            expect(await root.readAsBytes(), original);
            expect(
              project.store.buffers.containsKey(destination.uri.toString()),
              false,
            );
            await project.applyRefactoring(plan);
            final created = project.store.get(destination.uri.toString()),
                rootText = owner.text,
                definitionText = created.text;
            expect(created.present, true);
            expect(created.publishedPresent, false);
            expect(
              definitionText,
              boolean ? 'false' : contains('900719925474099312345678901'),
            );
            expect(definitionText, isNot(contains('openapi:')));
            expect(rootText, contains('payload only'));
            expect(
              (await project.check(owner.id))['complete'],
              true,
              reason: 'The unsaved creation must be visible to canonical graph acquisition',
            );
            project.store.undo();
            expect(owner.bytes(), original);
            expect(project.store.buffers.containsKey(created.id), false);
            expect(project.store.canUndo, false);
            project.store.redo();
            expect(project.store.get(created.id), same(created));
            expect(owner.text, rootText);
            expect(created.text, definitionText);
            final saved = await PublicationStore('${temp.path}/state')
                .save(project, [created]);
            expect(saved.complete, true);
            expect(
              saved.published,
              hasLength(2),
              reason: 'Saving only the new file must also publish its required reference repairs',
            );
            expect(await destination.readAsBytes(), created.bytes());
            expect(await root.readAsBytes(), owner.bytes());
            expect(await File('${temp.path}/busyapi.yaml').exists(), false);
            final reopened = await BusyProject.open(root.path, engine);
            addTearDown(reopened.close);
            expect(
              (await reopened.check(root.uri.toString()))['complete'],
              true,
            );
            expect(
              (await reopened.buffer(destination.uri.toString())).text,
              definitionText,
            );
            expect((await reopened.buffer(root.uri.toString())).text, rootText);
          },
        );
      }
  for (final changed in ['source', 'destination'])
    test(
      'later $changed rejects the coupled creation and repairs without losing either version',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-extract-stale-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final root = File('${temp.path}/root.json'),
            destination = File('${temp.path}/new.json');
        const source =
            '{"openapi":"3.2.1","info":{"title":"Stale","version":"1"},"paths":{},"components":{"schemas":{"Owner":{"properties":{"child":false}}}}}';
        await root.writeAsString(source);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final owner = await project.buffer(root.uri.toString());
        final plan = await project.planComponentExtractionToFile(
          {
            'root': owner.id,
            'resource': owner.id,
            'generation': owner.generation,
            'pointer': '/components/schemas/Owner/properties/child',
          },
          'Child',
          destination.path,
        );
        if (changed == 'source')
          project.store.replace(owner.id, '$source ');
        else
          await destination.writeAsString('new external version');
        final before = owner.text;
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(isA<CoreFailure>()),
        );
        expect(owner.text, before);
        expect(
          project.store.buffers.containsKey(destination.uri.toString()),
          false,
        );
        expect(await root.readAsString(), source);
        if (changed == 'destination')
          expect(await destination.readAsString(), 'new external version');
        else
          expect(await destination.exists(), false);
      },
    );

  for (final fault in ['digest', 'destination', 'count', 'kind']) {
    test('an inconsistent $fault worker creation cannot become a source plan', () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-extract-protocol-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final engine = _ExtractionEngine(fault);
      addTearDown(engine.close);
      final root = File('${temp.path}/root.json'),
          destination = File('${temp.path}/new.json');
      const original =
          '{"openapi":"3.2.1","info":{"title":"Protocol","version":"1"},"paths":{},"components":{"schemas":{"Owner":{"properties":{"child":false}}}}}';
      await root.writeAsString(original);
      final project = await BusyProject.open(root.path, engine);
      addTearDown(project.close);
      final owner = await project.buffer(root.uri.toString());
      await expectLater(
        project.planComponentExtractionToFile(
          {
            'root': owner.id,
            'resource': owner.id,
            'generation': owner.generation,
            'pointer': '/components/schemas/Owner/properties/child',
          },
          'Child',
          destination.path,
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.protocol'),
        ),
      );
      expect(owner.text, original);
      expect(project.store.canUndo, false);
      expect(await destination.exists(), false);
      expect(await root.readAsString(), original);
    });
  }

  test('two roots sharing an unsaved inline fragment keep one extraction owner', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-extract-roots-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final roots = [
          File('${temp.path}/first.json'),
          File('${temp.path}/second.json'),
        ],
        shared = File('${temp.path}/shared.json'),
        destination = File('${temp.path}/child.json'),
        manifest = File('${temp.path}/busyapi.yaml');
    const rootText =
        '{"openapi":"3.2.1","info":{"title":"Root","version":"1"},"paths":{},"components":{"schemas":{"Model":{"\$ref":"shared.json#/Model"}}}}';
    for (final root in roots) {
      await root.writeAsString(rootText);
    }
    const config =
        '# configuration kept\r\nversion: 1\nroots:\n  - {name: first, path: first.json}\n  - {name: second, path: second.json}\nx-kept: false';
    await manifest.writeAsString(config);
    await shared.writeAsString(
      '{"Model":{"properties":{"child":{"type":"integer","examples":[1]}}}}',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final source = await project.buffer(shared.uri.toString());
    project.store.replace(
      source.id,
      source.text.replaceFirst('[1]', '[900719925474099312345678901]'),
    );
    final captured = source.bytes();
    final plan = await project.planComponentExtractionToFile(
      {
        'root': roots.first.uri.toString(),
        'resource': source.id,
        'generation': source.generation,
        'pointer': '/Model/properties/child',
      },
      'Child',
      destination.path,
    );
    expect(plan.checkedRoots, roots.map((file) => file.uri.toString()));
    expect(plan.result['binding']['resource'], roots.first.uri.toString());
    await project.applyRefactoring(plan);
    for (final root in roots) {
      expect((await project.check(root.uri.toString()))['complete'], true);
    }
    expect(
      project.store.get(destination.uri.toString()).text,
      contains('900719925474099312345678901'),
    );
    expect(await manifest.readAsString(), config);
    project.store.undo();
    expect(source.bytes(), captured);
    project.store.redo();
    final result = await PublicationStore('${temp.path}/state')
        .save(project, [project.store.get(destination.uri.toString())]);
    expect(result.complete, true, reason: '${result.failed}');
    expect(await manifest.readAsString(), config);
    expect(await roots.last.readAsString(), rootText);
    final reopened = await BusyProject.open(temp.path, engine);
    addTearDown(reopened.close);
    for (final root in roots) {
      expect((await reopened.check(root.uri.toString()))['complete'], true);
    }
  });
}
