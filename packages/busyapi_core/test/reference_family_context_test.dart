import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    test(
      '$format legacy reference context remains correctable without migration',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-reference-family-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final root = File('${temp.path}/api.$format'),
            part = File('${temp.path}/part.$format');
        String text(Map<String, Object?> value) => format == 'json'
            ? jsonEncode(value)
            : '# Keep comments 雪\r\n${jsonEncode(value)}\r\n';
        final rootText = text({
          'openapi': '3.0.4',
          'info': {'title': 'Original', 'version': 'api-version'},
          'paths': {
            '/data': {
              'post': {
                'requestBody': {
                  'content': {
                    'application/json': {
                      'schema': {
                        r'$ref': 'part.$format#/components/schemas/Value',
                      },
                    },
                  },
                },
                'responses': {
                  '204': {'description': 'Empty'},
                },
              },
            },
          },
        });
        final partText = text({
          'openapi': '3.1.2',
          'info': {'title': 'Part', 'version': 'api-version'},
          'paths': {},
          'components': {
            'schemas': {
              'Value': {'type': 'string', 'nullable': true},
            },
          },
          'x-data': {r'$ref': 'literal', 'number': 'EXACT_VALUE'},
        }).replaceFirst('"EXACT_VALUE"', '9007199254740993.00');
        await root.writeAsString(rootText);
        await part.writeAsString(partText);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        var project = await BusyProject.open(root.path, engine);
        addTearDown(() => project.close());
        final rootId = root.uri.toString(), partId = part.uri.toString();
        final originalCheck = await project.check(rootId);
        expect(originalCheck['complete'], false);
        expect(
          (originalCheck['findings'] as List).any(
            (f) =>
                f['code'] == 'reference.family.unsupported' &&
                f['resource'] == rootId &&
                f['pointer'] == '/paths/~1data/post/requestBody/content/application~1json/schema/\$ref',
          ),
          true,
        );
        final rootBuffer = await project.buffer(rootId),
            partBuffer = await project.buffer(partId);
        final choices = await project.referenceChoices(
          rootId,
          rootId,
          '/paths/~1data/post/requestBody/content/application~1json/schema',
          query: 'Value',
        );
        expect(choices.result['count'], 0);
        final object = await project.inspectObject(rootId, rootId, '/info');
        final range = List<int>.from(object['range'] as List);
        await project.proposeAndApply(
          rootId,
          PropertySession(
            root: rootId,
            buffer: rootId,
            generation: rootBuffer.generation,
            pointer: '/info',
            range: range,
            expected: rootBuffer.text.substring(range[0], range[1]),
          ),
          [
            {'kind': 'set', 'pointer': '/info/title', 'value': 'Correctable'},
          ],
        );
        final edited = rootText.replaceFirst('Original', 'Correctable');
        expect(rootBuffer.text, edited);
        project.store.undo();
        expect(rootBuffer.text, rootText);
        project.store.redo();
        expect(rootBuffer.text, edited);
        expect(
          (await project.inspectObject(
            rootId,
            partId,
            '/components/schemas/Value',
          ))['family'],
          '3.1',
        );
        final compatible = partText.replaceFirst('3.1.2', '3.0.4');
        project.store.replace(partId, compatible);
        expect((await project.check(rootId))['status'], 'complete');
        final compatibleChoices = await project.referenceChoices(
          rootId,
          rootId,
          '/paths/~1data/post/requestBody/content/application~1json/schema',
          query: 'Value',
        );
        expect(compatibleChoices.result['count'], 1);
        final plan = await project.prepareRequest(
          rootId,
          resource: rootId,
          pointer: '/paths/~1data/post',
        );
        addTearDown(plan.close);
        final runtime = await plan.evaluateRuntime([
          RuntimeSchemaInstance(
            subject: 'request-body',
            location: 'application/json',
            text: 'null',
            schemaResource: rootId,
            schemaPointer: '/paths/~1data/post/requestBody/content/application~1json/schema',
          ),
        ]);
        expect(runtime['complete'], true, reason: '$runtime');
        expect((runtime['runtimeEvaluations'] as List).single['valid'], true);
        project.store.undo();
        expect(partBuffer.text, partText);
        expect((await project.check(rootId))['complete'], false);
        expect(plan.outdated, true);
        project.store.redo();
        expect(partBuffer.text, compatible);
        expect((await project.check(rootId))['status'], 'complete');
        project.store.undo();
        expect(partBuffer.text, partText);
        expect(await root.readAsString(), rootText);
        expect(await part.readAsString(), partText);
        await project.save(rootBuffer);
        await project.save(partBuffer);
        expect(await root.readAsString(), edited);
        expect(await part.readAsString(), partText);
        project.close();
        project = await BusyProject.open(root.path, engine);
        expect((await project.check(rootId))['complete'], false);
        expect((await project.buffer(rootId)).text, edited);
        expect((await project.buffer(partId)).text, partText);
      },
    );
  }

  test('mixed-version project roots rebind one shared schema and retain independent captures', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-shared-family-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final versions = ['2.0', '3.0.4', '3.1.2', '3.2.1'];
    for (final (index, version) in versions.indexed) {
      final legacy = version == '2.0';
      final reference = {r'$ref': './shared.json#/Value'};
      await File('${temp.path}/api$index.json').writeAsString(
        jsonEncode({
          legacy ? 'swagger' : 'openapi': version,
          'info': {'title': version, 'version': 'api-version'},
          if (legacy) 'consumes': ['application/json'],
          'paths': {
            '/data': {
              'post': {
                if (legacy)
                  'parameters': [
                    {'name': 'payload', 'in': 'body', 'schema': reference},
                  ]
                else
                  'requestBody': {
                    'content': {
                      'application/json': {'schema': reference},
                    },
                  },
                'responses': {
                  '204': {'description': 'Empty'},
                },
              },
            },
          },
        }),
      );
    }
    final shared = File('${temp.path}/shared.json');
    const sharedText =
        '{"Value":{"type":"object","required":["server"],"properties":{"server":{"type":"string","readOnly":true}}},"x-number":9007199254740993.00}';
    await shared.writeAsString(sharedText);
    await File('${temp.path}/busyapi.yaml').writeAsString(
      jsonEncode({
        'version': 1,
        'roots': [
          for (var index = 0; index < versions.length; index++)
            {'name': 'api$index', 'path': 'api$index.json'},
        ],
      }),
    );
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final retained = <OperationRequestPlan>[];
    for (final index in [0, 1, 2, 3, 1, 3, 0, 2]) {
      final root = File('${temp.path}/api$index.json').uri.toString();
      expect((await project.check(root))['status'], 'complete');
      final plan = await project.prepareRequest(
        root,
        resource: root,
        pointer: '/paths/~1data/post',
      );
      addTearDown(plan.close);
      retained.add(plan);
      final result = await plan.evaluateRuntime([
        RuntimeSchemaInstance(
          subject: 'request-body',
          location: 'application/json',
          text: '{}',
          schemaResource: shared.uri.toString(),
          schemaPointer: '/Value',
        ),
      ]);
      expect(result['complete'], true, reason: '$result');
      expect(
        (result['runtimeEvaluations'] as List).single['valid'],
        index == 1,
      );
    }
    for (final plan in retained) {
      final result = await plan.evaluateRuntime([
        RuntimeSchemaInstance(
          subject: 'request-body',
          location: 'application/json',
          text: '{}',
          schemaResource: shared.uri.toString(),
          schemaPointer: '/Value',
        ),
      ]);
      expect(result['complete'], true);
      expect(
        (result['runtimeEvaluations'] as List).single['valid'],
        plan.snapshot.root.endsWith('api1.json'),
      );
    }
    expect(await shared.readAsString(), sharedText);
  });
}
