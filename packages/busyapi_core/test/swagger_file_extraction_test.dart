import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final kind in ['response', 'parameter']) {
      test('2.0 $format $kind definition move repairs all captured roots', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-swagger-move-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final root = File('${temp.path}/api.$format');
        final destination = File('${temp.path}/other.$format');
        final group = kind == 'response' ? 'responses' : 'parameters';
        final operation = kind == 'response'
            ? {
                'responses': {
                  '200': {r'$ref': '#/responses/Stored'},
                },
              }
            : {
                'parameters': [
                  {r'$ref': '#/parameters/Stored'},
                ],
                'responses': {
                  '204': {'description': 'Empty'},
                },
              };
        final original = jsonEncode({
          'swagger': '2.0',
          'info': {'title': 'Move', 'version': '1'},
          'paths': {
            '/items': {'get': operation},
          },
          group: {
            'Stored': kind == 'response'
                ? {
                    'description': 'Stored',
                    'schema': {r'$ref': '#/definitions/Model'},
                  }
                : {'name': 'q', 'in': 'query', 'type': 'string'},
          },
          'definitions': {
            'Model': {'type': 'integer', 'minimum': '@exact'},
          },
        }).replaceAll('"@exact"', '9007199254740993.00');
        const originalDestination =
            '{"swagger":"2.0","info":{"title":"Other","version":"1"},"paths":{}}';
        await root.writeAsString(original);
        await destination.writeAsString(originalDestination);
        await File('${temp.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots:\n  - name: source\n    path: api.$format\n  - name: destination\n    path: other.$format\n',
        );
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final owner = await project.buffer(root.uri.toString());
        final other = await project.buffer(destination.uri.toString());
        final plan = await project.planComponentDefinitionMove(
          {
            'root': owner.id,
            'resource': owner.id,
            'pointer': '/$group/Stored',
            'generation': owner.generation,
          },
          'Stored',
          destinationResource: other.id,
        );
        expect(plan.checkedRoots.toSet(), {owner.id, other.id});
        expect(plan.result['removedBinding'], {
          'resource': owner.id,
          'pointer': '/$group/Stored',
        });
        expect(plan.result['preservedBinding'], isNull);
        await project.applyRefactoring(plan);
        final changed = owner.text, moved = other.text;
        final occurrence = await project.inspectObject(
          owner.id,
          owner.id,
          kind == 'response'
              ? '/paths/~1items/get/responses/200'
              : '/paths/~1items/get/parameters/0',
        );
        expect(occurrence['value'][r'$ref'], 'other.$format#/$group/Stored');
        expect((await project.check(owner.id))['status'], 'complete');
        expect((await project.check(other.id))['status'], 'complete');
        expect(await root.readAsString(), original);
        expect(await destination.readAsString(), originalDestination);
        project.store.undo();
        expect(owner.text, original);
        expect(other.text, originalDestination);
        project.store.redo();
        expect(owner.text, changed);
        expect(other.text, moved);
        final saved = await PublicationStore('${temp.path}/state')
            .save(project, [owner, other]);
        expect(saved.complete, true);
        expect(saved.published.toSet(), {owner.id, other.id});
        expect(await root.readAsString(), changed);
        expect(await destination.readAsString(), moved);
        final reopened = await BusyProject.open(temp.path, engine);
        addTearDown(reopened.close);
        expect((await reopened.check(owner.id))['status'], 'complete');
        expect((await reopened.check(other.id))['status'], 'complete');
      });
    }
    for (final kind in ['response', 'body', 'query']) {
      test(
        '2.0 $format $kind file extraction keeps valid native references',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-swagger-file-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final root = File('${temp.path}/api.$format');
          final destination = File('${temp.path}/shared 雪.$format');
          final pointer = kind == 'response'
              ? '/paths/~1items/get/responses/200'
              : '/paths/~1items/get/parameters/0';
          const schema = {r'$ref': '#/definitions/Model'};
          final object = kind == 'response'
              ? {
                  'description': 'Response 雪',
                  'schema': schema,
                  'examples': {
                    'application/json': {
                      'id': '@exact',
                      r'$ref': 'literal data',
                    },
                  },
                }
              : kind == 'body'
              ? {'name': 'payload', 'in': 'body', 'schema': schema}
              : {
                  'name': 'q',
                  'in': 'query',
                  'type': 'array',
                  'items': {'type': 'integer'},
                  'collectionFormat': 'multi',
                };
          final operation = kind == 'response'
              ? {
                  'responses': {'200': object},
                }
              : {
                  'parameters': [object],
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                };
          final json = jsonEncode({
            'swagger': '2.0',
            'info': {'title': 'Extraction', 'version': '1'},
            'paths': {
              '/items': {'get': operation},
            },
            'definitions': {
              'Model': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'integer', 'minimum': '@exact'},
                  'next': {r'$ref': '#/definitions/Model'},
                },
              },
            },
            'x-kept': {r'$ref': 'literal extension', 'zero': 0, 'null': null},
          }).replaceAll('"@exact"', '9007199254740993.00');
          final original = utf8.encode(
            format == 'yaml' ? '\ufeff# Keep 雪\r\n$json\r\n' : '\ufeff$json',
          );
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
          expect(plan.result['binding'], {
            'resource': destination.uri.toString(),
            'pointer': '/Stored',
          });
          expect(await destination.exists(), false);
          expect(await root.readAsBytes(), original);
          await project.applyRefactoring(plan);
          final created = project.store.get(destination.uri.toString());
          final changed = owner.bytes(), definition = created.bytes();
          final check = await project.check(owner.id);
          expect(check['status'], 'complete', reason: '${check['findings']}');
          final occurrence = await project.inspectObject(
            owner.id,
            owner.id,
            pointer,
          );
          expect(
            occurrence['value'][r'$ref'],
            'shared%20%E9%9B%AA.$format#/Stored',
          );
          final native = await project.inspectObject(
            owner.id,
            created.id,
            '/Stored',
          );
          expect(native['kind'], kind == 'response' ? 'response' : 'parameter');
          if (kind != 'query') {
            final schema = await project.inspectObject(
              owner.id,
              created.id,
              '/Stored/schema',
            );
            expect(schema['value'][r'$ref'], 'api.$format#/definitions/Model');
          }
          expect(owner.text, contains('9007199254740993.00'));
          expect(owner.text, contains('literal extension'));
          expect(created.text, isNot(contains('swagger')));
          expect(created.publishedPresent, false);
          project.store.undo();
          expect(owner.bytes(), original);
          expect(project.store.buffers.containsKey(created.id), false);
          project.store.redo();
          expect(owner.bytes(), changed);
          expect(project.store.get(created.id).bytes(), definition);
          final saved = await PublicationStore('${temp.path}/state')
              .save(project, [created]);
          expect(saved.complete, true);
          expect(saved.published, hasLength(2));
          expect(await root.readAsBytes(), changed);
          expect(await destination.readAsBytes(), definition);
          final reopened = await BusyProject.open(root.path, engine);
          addTearDown(reopened.close);
          expect((await reopened.check(owner.id))['status'], 'complete');
          expect((await reopened.buffer(created.id)).bytes(), definition);
          expect(await File('${temp.path}/busyapi.yaml').exists(), false);
        },
      );
    }
    for (final fault in ['source', 'declaration', 'destination', 'cancelled']) {
      test('2.0 $format extraction rejects $fault without partial publication', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-swagger-stale-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final root = File('${temp.path}/api.$format'),
            destination = File('${temp.path}/shared.$format');
        const source =
            '{"swagger":"2.0","info":{"title":"Original","version":"1"},"paths":{"/items":{"get":{"responses":{"200":{"description":"Empty"}}}}}}';
        await root.writeAsString(source);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final owner = await project.buffer(root.uri.toString());
        final plan = await project.planComponentExtractionToFile(
          {
            'root': owner.id,
            'resource': owner.id,
            'pointer': '/paths/~1items/get/responses/200',
            'generation': owner.generation,
          },
          'Stored',
          destination.path,
        );
        switch (fault) {
          case 'source':
            project.store.replace(owner.id, ' ${owner.text}');
          case 'declaration':
            final start = owner.text.indexOf('2.0');
            project.store.replace(
              owner.id,
              owner.text.replaceRange(start, start + 3, 'unsupported'),
            );
          case 'destination':
            await destination.writeAsString('external owner');
          case 'cancelled':
            break;
        }
        final before = owner.bytes();
        await expectLater(
          project.applyRefactoring(plan, current: () => fault != 'cancelled'),
          throwsA(isA<CoreFailure>()),
        );
        expect(owner.bytes(), before);
        expect(
          project.store.buffers.containsKey(destination.uri.toString()),
          false,
        );
        expect(await root.readAsString(), source);
        if (fault == 'destination') {
          expect(await destination.readAsString(), 'external owner');
        } else {
          expect(await destination.exists(), false);
        }
      });
    }
  }
}
