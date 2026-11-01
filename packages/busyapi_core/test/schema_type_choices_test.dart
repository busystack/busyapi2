import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const versions = [
  '2.0',
  '3.0.0',
  '3.0.1',
  '3.0.2',
  '3.0.3',
  '3.0.4',
  '3.1.0',
  '3.1.1',
  '3.1.2',
  '3.2.0',
  '3.2.1',
];

Map<String, Object?> document(String version, {String? reference}) => {
  version == '2.0' ? 'swagger' : 'openapi': version,
  'info': {'title': 'Keep 雪😀', 'version': 'unrelated'},
  'paths': {
    '/value': {
      'get': {
        'responses': {
          '200': {
            'description': 'Keep response',
            if (version == '2.0')
              'schema': reference == null
                  ? {'type': 'string', 'description': 'Keep schema'}
                  : {r'$ref': reference}
            else
              'content': {
                'application/json': {
                  'schema': {'type': 'string', 'description': 'Keep schema'},
                },
              },
          },
        },
      },
    },
  },
  'x-number': '@exact',
  'x-data': {r'$ref': 'literal.json', 'false': false, 'empty': '', 'zero': 0},
};

String render(Object value, bool json) =>
    '${json ? '' : '# Keep comment and CRLF\r\n'}'
    '${jsonEncode(value).replaceFirst('"@exact"', '9007199254740993.00')}\r\n';

PropertySession session(Map<String, dynamic> item, DocumentBuffer buffer) {
  final range = List<int>.from(item['range'] as List);
  return PropertySession(
    root: item['root'] as String,
    buffer: buffer.id,
    generation: buffer.generation,
    pointer: item['pointer'] as String,
    range: range,
    expected: buffer.text.substring(range[0], range[1]),
  );
}

Map<String, dynamic> typeField(Map<String, dynamic> item) =>
    (item['fields'] as List).cast<Map<String, dynamic>>().singleWhere(
      (field) => field['name'] == 'type',
    );

void main() {
  for (final version in versions) {
    for (final json in [false, true]) {
      test(
        '$version ${json ? 'JSON' : 'YAML'} captured native type edits preserve source, history and save/reopen',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-schema-types-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${directory.path}/api.${json ? 'json' : 'yaml'}');
          final original = render(document(version), json);
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              buffer = await project.buffer(root);
          final pointer =
              '/paths/~1value/get/responses/200/'
              '${version == '2.0' ? 'schema' : 'content/application~1json/schema'}';
          final page = await project.inspectObject(root, root, pointer);
          final field = typeField(page), raw = field['schemaTypeChoices'];
          final choices = SchemaTypeChoices.fromJson(raw);
          expect(choices.context.rootVersion, version);
          expect(choices.scalarTypes.contains('file'), version == '2.0');
          expect(choices.unionTypes.contains('file'), false);
          expect(choices.unionTypes.isEmpty, version.startsWith('3.0.'));
          final Object next = version == '2.0'
              ? 'file'
              : version.startsWith('3.0.')
              ? 'integer'
              : ['string', 'null'];
          expect(choices.allows(next), true);
          if (version.startsWith('3.0.')) {
            await expectLater(
              project.proposeAndApply(root, session(page, buffer), [
                {
                  'kind': 'set',
                  'pointer': '$pointer/type',
                  'value': ['string', 'null'],
                  'schemaTypeChoices': raw,
                },
              ]),
              throwsA(
                isA<CoreFailure>()
                    .having(
                      (e) => e.kind,
                      'kind',
                      CoreFailureKind.specification,
                    )
                    .having((e) => e.source?.resource, 'resource', root)
                    .having((e) => e.source?.pointer, 'pointer', pointer),
              ),
            );
            expect(buffer.text, original);
          }
          await project.proposeAndApply(root, session(page, buffer), [
            {
              'kind': 'set',
              'pointer': '$pointer/type',
              'value': next,
              'schemaTypeChoices': raw,
            },
          ]);
          final changed = buffer.text;
          expect(
            changed,
            original.replaceFirst(
              '"type":"string"',
              '"type":${jsonEncode(next)}',
            ),
          );
          expect(changed, contains('9007199254740993.00'));
          expect(changed, contains('literal.json'));
          expect(await file.readAsString(), original);
          project.store.undo();
          expect(buffer.text, original);
          project.store.redo();
          expect(buffer.text, changed);
          await project.save(buffer);
          expect(await file.readAsString(), changed);
          project.close();
          final reopened = await BusyProject.open(file.path, engine);
          addTearDown(reopened.close);
          final saved = await reopened.inspectObject(root, root, pointer);
          expect(jsonDecode(typeField(saved)['raw'] as String), next);
        },
      );
    }
  }
  for (final json in [false, true]) {
    test(
      'Swagger ${json ? 'JSON' : 'YAML'} unsaved shared consumer rejects stale file type without changing history',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-shared-type-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final suffix = json ? 'json' : 'yaml';
        final file = File('${directory.path}/api.$suffix'),
            shared = File('${directory.path}/part.$suffix');
        final value = document('2.0', reference: './part.$suffix#/Shared');
        final original = render(value, json),
            sharedOriginal = render({
              'Shared': {'type': 'string', 'description': 'Keep shared 雪😀'},
            }, json);
        await file.writeAsString(original);
        await shared.writeAsString(sharedOriginal);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id,
            buffer = await project.buffer(root),
            part = await project.buffer(shared.uri.toString());
        final page = await project.inspectObject(root, part.id, '/Shared');
        final raw = typeField(page)['schemaTypeChoices'];
        expect(SchemaTypeChoices.fromJson(raw).scalarTypes, contains('file'));
        final captured = session(page, part), generation = part.generation;
        final paths = value['paths'] as Map;
        ((paths['/value'] as Map)['get'] as Map)['parameters'] = [
          {
            'name': 'body',
            'in': 'body',
            'schema': {r'$ref': './part.$suffix#/Shared'},
          },
        ];
        final changedRoot = render(value, json);
        project.store.apply([
          TextEdit(
            buffer: root,
            generation: buffer.generation,
            start: 0,
            end: buffer.text.length,
            expected: buffer.text,
            replacement: changedRoot,
          ),
        ], label: 'Source');
        await expectLater(
          project.proposeAndApply(root, captured, [
            {
              'kind': 'set',
              'pointer': '/Shared/type',
              'value': 'file',
              'schemaTypeChoices': raw,
            },
          ]),
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'edit.schema-type.stale',
            ),
          ),
        );
        expect(part.text, sharedOriginal);
        expect(part.generation, generation);
        expect(buffer.text, changedRoot);
        expect(await file.readAsString(), original);
        expect(await shared.readAsString(), sharedOriginal);
        project.store.undo();
        expect(buffer.text, original);
        expect(part.text, sharedOriginal);
        final fresh = await project.inspectObject(root, part.id, '/Shared');
        await expectLater(
          project.proposeAndApply(root, session(fresh, part), [
            {
              'kind': 'set',
              'pointer': '/Shared/type',
              'value': 'file',
              'schemaTypeChoices': typeField(fresh)['schemaTypeChoices'],
            },
          ], current: () => false),
          throwsA(isA<CoreFailure>()),
        );
        expect(part.text, sharedOriginal);
        expect(await shared.readAsString(), sharedOriginal);
        await project.proposeAndApply(root, session(fresh, part), [
          {
            'kind': 'set',
            'pointer': '/Shared/type',
            'value': 'file',
            'schemaTypeChoices': typeField(fresh)['schemaTypeChoices'],
          },
        ]);
        final changedPart = sharedOriginal.replaceFirst(
          '"type":"string"',
          '"type":"file"',
        );
        expect(part.text, changedPart);
        expect(buffer.text, original);
        project.store.undo();
        expect(part.text, sharedOriginal);
        project.store.redo();
        expect(part.text, changedPart);
        await project.save(part);
        expect(await shared.readAsString(), changedPart);
        expect(await file.readAsString(), original);
      },
    );
  }
}
