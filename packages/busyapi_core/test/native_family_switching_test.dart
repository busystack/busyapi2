import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    test(
      'four-family $format project roots share source without stale dialects or authoring plans',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-family-switch-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        const versions = ['2.0', '3.0.4', '3.1.2', '3.2.1'];
        final files = <File>[];
        for (final version in versions) {
          final file = File('${temp.path}/$version.$format');
          final swagger = version == '2.0';
          final response = {
            'description': 'Test',
            if (swagger) ...{
              'schema': {r'$ref': 'shared.yaml#/Shared'},
              'examples': {'application/json': null},
            } else
              'content': {
                'application/json': {
                  'schema': {r'$ref': 'shared.yaml#/Shared'},
                  'example': null,
                },
              },
          };
          final pathSource = swagger
              ? r'''
produces: [application/json]
paths:
  /p:
    get:
      responses:
        '200':
          description: Test
          schema: {$ref: 'shared.yaml#/Shared'}
          examples: {application/json: null}
'''
              : r'''
paths:
  /p:
    get:
      responses:
        '200':
          description: Test
          content: {application/json: {schema: {$ref: 'shared.yaml#/Shared'}, example: null}}
''';
          final value = {
            swagger ? 'swagger' : 'openapi': version,
            'info': {'title': 'Root $version', 'version': '3.2.1'},
            'paths': {
              '/p': {
                'get': {
                  'responses': {'200': response},
                },
              },
            },
            if (swagger) 'produces': ['application/json'],
            swagger ? 'definitions' : 'components': swagger
                ? {
                    'Model': {r'$ref': 'shared.yaml#/Shared'},
                  }
                : {
                    'schemas': {
                      'Model': {r'$ref': 'shared.yaml#/Shared'},
                    },
                  },
          };
          await file.writeAsString(
            format == 'json'
                ? jsonEncode(value)
                : '# Root $version\n${swagger ? 'swagger' : 'openapi'}: "$version"\ninfo: {title: "Root $version", version: "3.2.1"}\n$pathSource\n${swagger ? 'definitions' : 'components:\n  schemas'}: {Model: {\$ref: "shared.yaml#/Shared"}}\n',
          );
          files.add(file);
        }
        final shared = File('${temp.path}/shared.yaml');
        const originalShared =
            '# Shared source\nShared: {type: string, example: null}\n';
        await shared.writeAsString(originalShared);
        await File('${temp.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots:\n${files.asMap().entries.map((entry) => '  - {name: root${entry.key}, path: ${versions[entry.key]}.$format}').join('\n')}\n',
        );
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final sharedBuffer = await project.buffer(shared.uri.toString());
        for (var cycle = 0; cycle < 3; cycle++) {
          if (cycle == 1)
            project.store.replace(
              sharedBuffer.id,
              originalShared.replaceFirst(
                'type: string',
                'type: string, nullable: true',
              ),
            );
          if (cycle == 2)
            project.store.replace(sharedBuffer.id, originalShared);
          for (var index = 0; index < versions.length; index++) {
            final root = files[index].uri.toString();
            final result = await project.check(root);
            expect(
              result['projection']['specification']['declaredVersion'],
              versions[index],
            );
            expect(
              result['status'],
              cycle == 1 && index == 0 ? 'invalid' : 'complete',
              reason: '$root: $result',
            );
            final incompatible = (result['findings'] as List).any(
              (finding) => finding['code'] == 'example.schema.incompatible',
            );
            if (index != 0 || cycle != 1)
              expect(incompatible, !(cycle == 1 && index == 1));
            final page = await project.inspectObject(
              root,
              sharedBuffer.id,
              '/Shared',
            );
            final fields = (page['fields'] as List).cast<Map>();
            expect(
              fields.any((field) => field['name'] == 'nullable'),
              index == 1,
            );
            expect(
              fields.any((field) => field['name'] == r'$schema'),
              index >= 2,
            );
          }
        }
        final root = files.first.uri.toString(),
            buffer = await project.buffer(files.first.uri.toString());
        final page = await project.inspectObject(root, root, '');
        final range = List<int>.from(page['range'] as List);
        final session = PropertySession(
          root: root,
          buffer: root,
          generation: buffer.generation,
          pointer: '',
          range: range,
          expected: buffer.text.substring(range[0], range[1]),
        );
        project.store.replace(
          root,
          buffer.text.replaceFirst(
            format == 'json' ? '"swagger":"2.0"' : 'swagger: "2.0"',
            format == 'json' ? '"openapi":"3.0.4"' : 'openapi: "3.0.4"',
          ),
        );
        final changed = await project.check(root);
        expect(changed['projection']['specification']['family'], '3.0');
        expect(
          changed['status'],
          'invalid',
          reason: 'Source declaration edits do not migrate definitions',
        );
        expect(buffer.text, contains('definitions'));
        await expectLater(
          project.proposeAndApply(root, session, [
            {'kind': 'set', 'pointer': '/host', 'value': 'stale.invalid'},
          ]),
          throwsA(
            isA<CoreFailure>().having(
              (error) => error.code,
              'code',
              'draft.stale',
            ),
          ),
        );
        for (var index = 0; index < versions.length; index++)
          expect(await files[index].readAsString(), contains(versions[index]));
        expect(await shared.readAsString(), originalShared);
      },
    );
  }
}
