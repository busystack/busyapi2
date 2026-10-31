import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _versions = [
  '3.0.0',
  '3.0.1',
  '3.0.2',
  '3.0.3',
  '3.0.4',
  '2.0',
  '3.1.0',
  '3.1.1',
  '3.1.2',
  '3.2.0',
  '3.2.1',
];

String _source(String version, String format, {String? shared}) {
  final value = <String, Object?>{
    version == '2.0' ? 'swagger' : 'openapi': version,
    'info': {'title': 'Native field forms 雪😀', 'version': 'business'},
    'paths': {},
    version == '2.0' ? 'definitions' : 'components': version == '2.0'
        ? {
            'Record': shared == null ? {} : {r'$ref': shared},
          }
        : {
            'schemas': {
              'Record': shared == null ? {} : {r'$ref': shared},
            },
          },
    'x-number': '@exact',
    'x-payload': {r'$ref': 'literal.json', 'items': false, 'zero': 0},
  };
  final text = jsonEncode(value)
      .replaceFirst('"@exact"', '9007199254740993.00');
  return '${format == 'yaml' ? '# Keep field source\r\n' : ''}$text\r\n';
}

PropertySession _session(Map<String, dynamic> page, DocumentBuffer buffer) {
  final range = List<int>.from(page['range'] as List);
  return PropertySession(
    root: page['root'] as String,
    buffer: buffer.id,
    generation: buffer.generation,
    pointer: page['pointer'] as String,
    range: range,
    expected: buffer.text.substring(range[0], range[1]),
  );
}

void main() {
  for (final invalid in <Object?>[
    null,
    {},
    {
      'version': 2,
      'supported': true,
      'forms': ['object'],
    },
    {
      'version': 1,
      'supported': 'true',
      'forms': ['object'],
    },
    {'version': 1, 'supported': true, 'forms': 'object'},
    {'version': 1, 'supported': true, 'forms': []},
    {
      'version': 1,
      'supported': false,
      'forms': ['object'],
    },
    {
      'version': 1,
      'supported': true,
      'forms': ['object', 'object'],
    },
    {
      'version': 1,
      'supported': true,
      'forms': ['array'],
    },
    {
      'version': 1,
      'supported': true,
      'forms': [false],
    },
  ]) {
    test(
      'malformed schema value form metadata is refused: ${jsonEncode(invalid)}',
      () {
        expect(
          () => SchemaValueForms.fromJson(invalid),
          throwsA(
            isA<CoreFailure>().having(
              (error) => error.code,
              'code',
              'engine.schema-value-forms',
            ),
          ),
        );
      },
    );
  }

  test('an unsupported field selection cannot claim a valid data value', () {
    final forms = SchemaValueForms.fromJson({
      'version': 1,
      'supported': false,
      'forms': [],
    });
    expect(forms.supported, false);
    expect(forms.accepts('{}'), false);
    expect(forms.accepts('false'), false);
    expect(forms.jsonTypes, isEmpty);
  });

  for (final version in _versions)
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format captured schema forms, exact source transactions, history and saved CLI',
        () async {
          final directory = await Directory.systemTemp.createTemp('bvf-');
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/api.$format');
          final original = [
            239,
            187,
            191,
            ...utf8.encode(_source(version, format)),
          ];
          await file.writeAsBytes(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(file.path, engine);
          addTearDown(() => project.close());
          final root = file.uri.toString();
          var buffer = await project.buffer(root);
          final pointer = version == '2.0'
              ? '/definitions/Record'
              : '/components/schemas/Record';
          final initial = await project.check(root);
          expect(initial['status'], 'complete', reason: jsonEncode(initial));
          expect((initial['versions'] as Map)['authoringFieldRules'], '1');
          await project.save(buffer);
          expect(await file.readAsBytes(), original);
          final values = <String, String>{
            'items': version == '2.0'
                ? '[{"type":"integer","minimum":9007199254740993.00},{"enum":["雪😀"]}]'
                : version.startsWith('3.0.')
                ? '{"type":"integer","minimum":9007199254740993.00,"nullable":true}'
                : 'false',
            'additionalProperties': 'false',
            if (version != '2.0')
              'not': version.startsWith('3.0.') ? '{"type":"string"}' : 'false',
          };
          for (final entry in values.entries) {
            final page = await project.inspectObject(root, root, pointer);
            final field = (page['fields'] as List).cast<Map>().singleWhere(
              (field) => field['name'] == entry.key,
            );
            final forms = SchemaValueForms.fromJson(field['schemaValueForms']);
            expect(forms.supported, true);
            expect(forms.accepts(entry.value), true);
            expect(
              forms.accepts('[]'),
              version == '2.0' && entry.key == 'items',
            );
            expect(forms.accepts('null'), false);
            expect(forms.accepts('0'), false);
            expect(forms.accepts('""'), false);
            if (entry.key == 'items' || entry.key == 'not') {
              expect(
                forms.accepts('false'),
                version != '2.0' && !version.startsWith('3.0.'),
              );
            }
            final before = buffer.bytes(), beforeText = buffer.text;
            await expectLater(
              project.proposeAndApply(root, _session(page, buffer), [
                {
                  'kind': 'setData',
                  'pointer': '$pointer/${entry.key}',
                  'raw': '[false]',
                  'schemaValueForms': field['schemaValueForms'],
                },
              ]),
              throwsA(
                isA<CoreFailure>().having(
                  (error) => error.code,
                  'code',
                  'edit.schema.value',
                ),
              ),
            );
            expect(buffer.bytes(), before);
            if (entry.key == 'items') {
              await expectLater(
                project.proposeAndApply(root, _session(page, buffer), [
                  {
                    'kind': 'setData',
                    'pointer': '$pointer/${entry.key}',
                    'raw': entry.value,
                    'schemaValueForms': field['schemaValueForms'],
                  },
                ], current: () => false),
                throwsA(
                  isA<CoreFailure>().having(
                    (error) => error.code,
                    'code',
                    'proposal.stale',
                  ),
                ),
              );
              expect(buffer.bytes(), before);
              expect(await file.readAsBytes(), original);
            }
            await project.proposeAndApply(root, _session(page, buffer), [
              {
                'kind': 'setData',
                'pointer': '$pointer/${entry.key}',
                'raw': entry.value,
                'schemaValueForms': field['schemaValueForms'],
              },
            ]);
            final changed = buffer.bytes(), changedText = buffer.text;
            final authored = await project.inspectObject(root, root, pointer);
            expect(
              (authored['fields'] as List).cast<Map>().singleWhere(
                (field) => field['name'] == entry.key,
              )['raw'],
              entry.value,
            );
            expect(changedText, isNot(beforeText));
            expect(changedText, contains('9007199254740993.00'));
            expect(changedText, contains('literal.json'));
            if (format == 'yaml')
              expect(changedText, startsWith('# Keep field source\r\n'));
            expect(await file.readAsBytes(), original);
            project.store.undo();
            expect(buffer.bytes(), before);
            project.store.redo();
            expect(buffer.bytes(), changed);
            expect((await project.check(root))['status'], 'complete');
          }
          await project.save(buffer);
          final saved = await file.readAsBytes();
          expect(saved, buffer.bytes());
          await project.save(buffer);
          expect(await file.readAsBytes(), saved);
          final cli = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(cli.exitCode, 0, reason: cli.stderr as String);
          expect(jsonDecode(cli.stdout as String)['complete'], true);
          project.close();
          project = await BusyProject.open(file.path, engine);
          buffer = await project.buffer(root);
          expect(buffer.bytes(), saved);
          expect((await project.check(root))['status'], 'complete');
        },
      );
    }

  for (final format in ['yaml', 'json']) {
    test(
      '$format a changed root cannot apply old value forms to an unchanged shared fragment',
      () async {
        final directory = await Directory.systemTemp.createTemp('bvs-');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/api.$format');
        final shared = File('${directory.path}/shared.$format');
        await file.writeAsString(
          _source('3.1.2', format, shared: 'shared.$format#/Shared'),
        );
        await shared.writeAsString(
          '${format == 'yaml' ? '# Keep shared\r\n' : ''}{"Shared":{}}\r\n',
        );
        final originalRoot = await file.readAsBytes(),
            originalShared = await shared.readAsBytes();
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = file.uri.toString(),
            buffer = await project.buffer(shared.uri.toString());
        final rootBuffer = await project.buffer(root);
        final page = await project.inspectObject(root, buffer.id, '/Shared');
        final field = (page['fields'] as List).cast<Map>().singleWhere(
          (field) => field['name'] == 'items',
        );
        final session = _session(page, buffer);
        project.store.replace(
          root,
          rootBuffer.text.replaceFirst('3.1.2', '3.0.4'),
        );
        final changed = rootBuffer.text, sharedGeneration = buffer.generation;
        await expectLater(
          project.proposeAndApply(root, session, [
            {
              'kind': 'setData',
              'pointer': '/Shared/items',
              'raw': 'false',
              'schemaValueForms': field['schemaValueForms'],
            },
          ]),
          throwsA(
            isA<CoreFailure>().having(
              (error) => error.code,
              'code',
              'edit.stale',
            ),
          ),
        );
        expect(buffer.generation, sharedGeneration);
        expect(rootBuffer.text, changed);
        expect(await file.readAsBytes(), originalRoot);
        expect(await shared.readAsBytes(), originalShared);
        final fresh = await project.inspectObject(root, buffer.id, '/Shared');
        final current = (fresh['fields'] as List).cast<Map>().singleWhere(
          (field) => field['name'] == 'items',
        );
        expect(
          SchemaValueForms.fromJson(current['schemaValueForms'])
              .accepts('false'),
          false,
        );
        await project.proposeAndApply(root, _session(fresh, buffer), [
          {
            'kind': 'setData',
            'pointer': '/Shared/items',
            'raw': '{}',
            'schemaValueForms': current['schemaValueForms'],
          },
        ]);
        expect((await project.check(root))['status'], 'complete');
        expect(rootBuffer.text, changed);
        expect(await file.readAsBytes(), originalRoot);
        expect(await shared.readAsBytes(), originalShared);
        final changedShared = buffer.text;
        project.store.undo();
        expect(buffer.bytes(), originalShared);
        project.store.redo();
        expect(buffer.text, changedShared);
      },
    );
  }
}
