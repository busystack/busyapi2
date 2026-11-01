import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'test_support.dart';

void main() {
  late Directory dir;
  late EngineProcess engine;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('busyapi-authoring-integrity-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    await engine.close();
    await dir.delete(recursive: true);
  });
  for (final version in ['3.1.2', '3.2.1'])
    test(
      'R02 R03 core proposals preserve structure exact data and one-step history $version',
      () async {
        final file = File('${dir.path}/openapi.yaml');
        final original =
            'openapi: $version\r\ninfo: {title: API, version: "1"}\r\nservers:\r\n  - description: First\r\n    url: https://first.example\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      default: # retained empty default\r\n      type: [string, "null"]\r\nx-kept: 9007199254740993.00\r\n';
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id, b = await project.buffer(root);
        Future<void> edit(
          String pointer,
          List<Map<String, Object?>> actions,
        ) async {
          final item = await project.inspectObject(root, root, pointer);
          final range = List<int>.from(item['range'] as List);
          await project.proposeAndApply(
            root,
            PropertySession(
              root: root,
              buffer: root,
              generation: b.generation,
              pointer: pointer,
              range: range,
              expected: b.text.substring(range[0], range[1]),
            ),
            actions,
          );
        }

        await edit('/servers/0', [
          {'kind': 'remove', 'pointer': '/servers/0/description'},
        ]);
        final removed = b.text;
        expect(loadYaml(removed)['servers'], [
          {'url': 'https://first.example'},
        ]);
        project.store.undo();
        expect(b.text, original);
        project.store.redo();
        expect(b.text, removed);
        project.store.undo();
        await edit('/components/schemas/Model', [
          {
            'kind': 'setData',
            'pointer': '/components/schemas/Model/default',
            'raw': '{"n":9007199254740993.00}',
          },
        ]);
        final changed = b.text;
        expect(changed, contains('# retained empty default'));
        expect(changed, contains('9007199254740993.00'));
        expect(
          loadYaml(changed)['components']['schemas']['Model']['default'],
          isA<Map>(),
        );
        project.store.undo();
        expect(b.text, original);
        project.store.redo();
        expect(b.text, changed);
      },
    );
  test('R04 core plans repair cross-resource consumers and reject stale application atomically', () async {
    final file = File('${dir.path}/openapi.json');
    const pointer =
        '/paths/~1pets/get/responses/200/content/application~1json/schema/properties/old';
    await file.writeAsString(
      jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Cross resource', 'version': '1'},
        'paths': {
          '/pets': {
            'get': {
              'responses': {
                '200': {
                  'description': 'before',
                  'content': {
                    'application/json': {
                      'schema': {
                        'type': 'object',
                        'properties': {
                          'old': {'type': 'string'},
                        },
                        'required': ['old'],
                        'dependentRequired': {
                          'other': ['old'],
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
        'components': {
          'schemas': {
            'External': {'\$ref': './consumer.yaml'},
          },
          'responses': {
            'External': {'\$ref': './response.yaml'},
          },
        },
      }),
    );
    await File('${dir.path}/consumer.yaml')
        .writeAsString('\$ref: "./openapi.json#$pointer"\n');
    await File('${dir.path}/response.yaml').writeAsString(
      '\$ref: "./openapi.json#/paths/~1pets/get/responses/200"\n',
    );
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final root = project.roots.single.id;
    await project.check(root, schemaEvaluation: false);
    final b = await project.buffer(root),
        consumer = await project.buffer(
          File('${dir.path}/consumer.yaml').uri.toString(),
        ),
        response = await project.buffer(
          File('${dir.path}/response.yaml').uri.toString(),
        );
    final before = {
      for (final buffer in [b, consumer, response]) buffer: buffer.text,
    };
    var target = await project.inspectObject(root, root, pointer);
    final cancelled = await project.planPropertyRename(
      target,
      'new',
      actions: [
        {'kind': 'set', 'pointer': '$pointer/description', 'value': 'together'},
      ],
    );
    expect(cancelled.hasChanges, true);
    expect(b.text, before[b]);
    await project.applyRefactoring(cancelled);
    expect(consumer.text, contains('/properties/new'));
    expect(b.text, contains('together'));
    expect(b.text, contains('"other":["new"]'));
    final accepted = {for (final buffer in before.keys) buffer: buffer.text};
    project.store.undo();
    for (final entry in before.entries) {
      expect(entry.key.text, entry.value);
    }
    project.store.redo();
    for (final entry in accepted.entries) {
      expect(entry.key.text, entry.value);
    }
    project.store.undo();
    target = await project.inspectObject(root, root, pointer);
    final stale = await project.planPropertyRename(target, 'new');
    project.store.replace(consumer.id, '${consumer.text}# later\n');
    final rootBefore = b.text;
    await expectLater(
      project.applyRefactoring(stale),
      throwsA(isA<CoreFailure>()),
    );
    expect(b.text, rootBefore);
    expect(consumer.text, endsWith('# later\n'));
    project.store.undo();
    final responseTarget = await project.inspectObject(
      root,
      root,
      '/paths/~1pets/get/responses/200',
    );
    final move = await project.planResponseRename(
      responseTarget,
      '201',
      actions: [
        {
          'kind': 'set',
          'pointer': '/paths/~1pets/get/responses/200/description',
          'value': 'response together',
        },
      ],
    );
    await project.applyRefactoring(move);
    expect(response.text, contains('/responses/201'));
    expect(consumer.text, contains('/responses/201/'));
    expect(b.text, contains('response together'));
    project.store.undo();
    for (final entry in before.entries) {
      expect(entry.key.text, entry.value);
    }
    final blocked = await project.planObjectDeletion(
      await project.inspectObject(root, root, pointer),
    );
    expect(blocked.result['blockers'], isNotEmpty);
    await expectLater(
      project.applyRefactoring(blocked),
      throwsA(isA<CoreFailure>()),
    );
    expect(b.text, before[b]);
  });

  for (final version in ['3.1.2', '3.2.1'])
    test(
      'R05-A same-instance name collision refuses the complete form transaction $version',
      () async {
        final file = File('${dir.path}/openapi.json');
        final original = jsonEncode({
          'openapi': version,
          'info': {'title': 'Names', 'version': '1'},
          'paths': {},
          'components': {
            'schemas': {
              'Model': {
                'type': 'object',
                'required': ['old', 'new'],
                'properties': {
                  'old': {'type': 'string'},
                },
              },
            },
          },
        });
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id, b = await project.buffer(root);
        expect((await project.check(root))['status'], 'complete');
        final target = await project.inspectObject(
          root,
          root,
          '/components/schemas/Model/properties/old',
        );
        await expectLater(
          project.planPropertyRename(
            target,
            'new',
            actions: [
              {
                'kind': 'set',
                'pointer':
                    '/components/schemas/Model/properties/old/description',
                'value': 'must remain unapplied',
              },
            ],
          ),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'edit.collision'),
          ),
        );
        expect(b.text, original);
        expect(b.dirty, false);
        expect(project.store.canUndo, false);
      },
    );
  for (final version in ['3.1.2', '3.2.1'])
    test(
      'R03-B nested collection data proposals retain exact values and history $version',
      () async {
        final file = File('${dir.path}/openapi.yaml');
        final newline = version == '3.1.2' ? '\n' : '\r\n';
        final original =
            ('openapi: $version\ninfo: {title: Data, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default:\n        - - a: one\n            b: two\n          - last\n      description: keep # source\n')
                .replaceAll('\n', newline);
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id, b = await project.buffer(root);
        final target = await project.inspectObject(
          root,
          root,
          '/components/schemas/Model',
        );
        final range = List<int>.from(target['range'] as List);
        await project.proposeAndApply(
          root,
          PropertySession(
            root: root,
            buffer: root,
            generation: b.generation,
            pointer: target['pointer'] as String,
            range: range,
            expected: b.text.substring(range[0], range[1]),
          ),
          [
            {
              'kind': 'setData',
              'pointer': '/components/schemas/Model/default',
              'raw': jsonEncode([
                ['hello\nworld', 'last'],
              ]),
            },
          ],
        );
        final changed = b.text;
        expect(loadYaml(changed)['components']['schemas']['Model']['default'], [
          ['hello\nworld', 'last'],
        ]);
        expect(
          (await project.check(root, schemaEvaluation: false))['findings'],
          isEmpty,
        );
        project.store.undo();
        expect(b.text, original);
        project.store.redo();
        expect(b.text, changed);
      },
    );
  for (final version in ['3.1.2', '3.2.1'])
    test(
      'R05-B aliased required constraints reject the complete core rename $version',
      () async {
        final original =
            'openapi: $version\ninfo: {title: Shared, version: "1"}\npaths: {}\nx-shared: &names [old]\ncomponents:\n  schemas:\n    Model: {type: object, properties: {old: {type: string}}, required: *names}\n';
        final file = File('${dir.path}/openapi.yaml');
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id, b = await project.buffer(root);
        final target = await project.inspectObject(
          root,
          root,
          '/components/schemas/Model/properties/old',
        );
        await expectLater(
          project.planPropertyRename(
            target,
            'new',
            actions: [
              {
                'kind': 'set',
                'pointer':
                    '/components/schemas/Model/properties/old/description',
                'value': 'no partial edit',
              },
            ],
          ),
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'refactor.property.shared',
            ),
          ),
        );
        expect(b.text, original);
        expect(b.baseline, original);
        expect(project.store.canUndo, false);
      },
    );
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'R03-C R03-E block string proposals preserve whitespace comments and one-step history $version',
      () async {
        final newline = version == '3.1.2' ? '\n' : '\r\n';
        final style = version == '3.1.2' ? '|-' : '>-';
        final original =
            ('openapi: $version\ninfo: {title: Whitespace, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default:\n        # value comment\n        message: $style  # preserve this user note\n          original # scalar data\n          text\n        keep: unchanged # surrounding source\nx-number: 9007199254740993.00\n')
                .replaceAll('\n', newline);
        final file = File('${dir.path}/openapi.yaml');
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id, b = await project.buffer(root);
        const pointer = '/components/schemas/Model';
        for (final kind in ['set', 'setData']) {
          for (final value in [
            'hello\nworld',
            'hello\nworld\n\n',
            'hello\nworld  ',
            'hello\n\nworld\n\n',
          ]) {
            final target = await project.inspectObject(root, root, pointer);
            final range = List<int>.from(target['range'] as List);
            await project.proposeAndApply(
              root,
              PropertySession(
                root: root,
                buffer: root,
                generation: b.generation,
                pointer: pointer,
                range: range,
                expected: b.text.substring(range[0], range[1]),
              ),
              [
                {
                  'kind': kind,
                  'pointer': '$pointer/default/message',
                  if (kind == 'set')
                    'value': value
                  else
                    'raw': jsonEncode(value),
                },
              ],
            );
            final changed = b.text;
            expect(
              loadYaml(
                changed,
              )['components']['schemas']['Model']['default']['message'],
              value,
            );
            expect(changed, contains('        # value comment$newline'));
            expect(changed, contains('  # preserve this user note$newline'));
            expect(
              changed,
              endsWith(
                '        keep: unchanged # surrounding source${newline}x-number: 9007199254740993.00$newline',
              ),
            );
            expect(
              (await project.check(root, schemaEvaluation: false))['findings'],
              isEmpty,
            );
            project.store.undo();
            expect(b.text, original);
            expect(project.store.canUndo, false);
            project.store.redo();
            expect(b.text, changed);
            project.store.undo();
          }
        }
      },
    );
  }
  test('R03-F multiline exact data proposals retain YAML syntax and one-step history', () async {
    final original =
        'openapi: 3.2.1\r\ninfo: {title: Data, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      default: |- # keep\r\n        original\r\n      type: object\r\n';
    final file = File('${dir.path}/openapi.yaml');
    await file.writeAsString(original);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final root = project.roots.single.id, b = await project.buffer(root);
    const pointer = '/components/schemas/Model';
    final target = await project.inspectObject(root, root, pointer);
    final range = List<int>.from(target['range'] as List);
    await project.proposeAndApply(
      root,
      PropertySession(
        root: root,
        buffer: root,
        generation: b.generation,
        pointer: pointer,
        range: range,
        expected: b.text.substring(range[0], range[1]),
      ),
      [
        {
          'kind': 'setData',
          'pointer': '$pointer/default',
          'raw': '{\n"n":9007199254740993.00\n}',
        },
      ],
    );
    final changed = b.text;
    expect(
      loadYaml(changed)['components']['schemas']['Model']['default'],
      isA<Map>(),
    );
    expect(
      (await project.check(root, schemaEvaluation: false))['findings'],
      isEmpty,
    );
    expect(changed, contains('9007199254740993.00'));
    expect(changed, contains('# keep\r\n'));
    project.store.undo();
    expect(b.text, original);
    project.store.redo();
    expect(b.text, changed);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'R03-F whole schema defaults retain compact context exact values and history $version',
      () async {
        final newline = version == '3.1.2' ? '\n' : '\r\n';
        for (final nested in [false, true]) {
          final body = nested
              ? '        - - value: null\n            keep: yes\n'
              : '        - value: null\n          keep: yes\n';
          final prefix =
              'openapi: $version\ninfo: {title: API, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default:\n';
          const suffix = '      description: sentinel # source\n';
          final original = (prefix + body + suffix).replaceAll('\n', newline);
          final file = File('${dir.path}/openapi-$nested.yaml');
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          try {
            final root = project.roots.single.id,
                b = await project.buffer(root);
            expect(
              (await project.check(root, schemaEvaluation: false))['findings'],
              isEmpty,
            );
            for (final replacement in [
              '{\n"n":9007199254740993.00\n}',
              '[\n9007199254740993.00\n]',
            ]) {
              final raw =
                  '${nested ? '[' : ''}[{"value":$replacement,"keep":"yes"}]${nested ? ']' : ''}';
              final item = await project.inspectObject(
                root,
                root,
                '/components/schemas/Model',
              );
              final field = (item['fields'] as List).cast<Map>().singleWhere(
                (f) => f['name'] == 'default',
              );
              expect(field['type'], 'any');
              final range = List<int>.from(item['range'] as List),
                  generation = b.generation;
              await project.proposeAndApply(
                root,
                PropertySession(
                  root: root,
                  buffer: root,
                  generation: generation,
                  pointer: '/components/schemas/Model',
                  range: range,
                  expected: b.text.substring(range[0], range[1]),
                ),
                [
                  {
                    'kind': 'setData',
                    'pointer': '/components/schemas/Model/default',
                    'raw': raw,
                  },
                ],
              );
              final changed = b.text;
              expect(b.dirty, true);
              expect(b.generation, greaterThan(generation));
              expect(b.baseline, original);
              expect(
                (await project.check(
                  root,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              final refreshed = await project.inspectObject(
                root,
                root,
                '/components/schemas/Model',
              );
              final target = (refreshed['fields'] as List)
                  .cast<Map>()
                  .singleWhere((f) => f['name'] == 'default')['target'];
              final data = await project.readDataValue(
                Map<String, dynamic>.from(target as Map),
              );
              expect(jsonDecode(data), jsonDecode(raw));
              expect(data, contains('9007199254740993.00'));
              expect(changed, startsWith(prefix.replaceAll('\n', newline)));
              expect(changed, endsWith(suffix.replaceAll('\n', newline)));
              project.store.undo();
              expect(b.text, original);
              expect(project.store.canUndo, false);
              project.store.redo();
              expect(b.text, changed);
              expect(
                (await project.check(
                  root,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              project.store.undo();
            }
          } finally {
            project.close();
          }
        }
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'R03-G R03-H whole defaults preserve flow separators through additions and sole-member removal $version',
      () async {
        final newline = version == '3.1.2' ? '\n' : '\r\n';
        final comment = version == '3.2.1'
            ? ' # collection note\n          '
            : '';
        for (final mapping in [true, false]) {
          final flow = mapping ? '{keep: yes,$comment}' : '[yes,$comment]';
          final prefix =
              'openapi: $version\ninfo: {title: API, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default:\n';
          const suffix = '      description: sentinel # source\n';
          final original = (prefix + '        - $flow\n' + suffix).replaceAll(
            '\n',
            newline,
          );
          final file = File('${dir.path}/flow-$mapping.yaml');
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          try {
            final root = project.roots.single.id,
                b = await project.buffer(root);
            expect(
              (await project.check(root, schemaEvaluation: false))['findings'],
              isEmpty,
            );
            for (final action
                in version == '3.1.2'
                    ? ['add', 'empty', 'replace']
                    : ['empty', 'add', 'replace']) {
              const value = '{\n"n":9007199254740993.00\n}';
              final raw = mapping
                  ? action == 'empty'
                        ? '[{}]'
                        : action == 'add'
                        ? '[{"keep":"yes","value":$value}]'
                        : '[{"value":$value}]'
                  : action == 'empty'
                  ? '[[]]'
                  : action == 'add'
                  ? '[["yes",$value]]'
                  : '[[$value]]';
              const pointer = '/components/schemas/Model';
              final item = await project.inspectObject(root, root, pointer);
              final range = List<int>.from(item['range'] as List);
              await project.proposeAndApply(
                root,
                PropertySession(
                  root: root,
                  buffer: root,
                  generation: b.generation,
                  pointer: pointer,
                  range: range,
                  expected: b.text.substring(range[0], range[1]),
                ),
                [
                  {
                    'kind': 'setData',
                    'pointer': '$pointer/default',
                    'raw': raw,
                  },
                ],
              );
              final changed = b.text;
              expect(b.dirty, true);
              expect(b.baseline, original);
              expect(
                (await project.check(
                  root,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              final current = await project.inspectObject(root, root, pointer);
              final target = (current['fields'] as List)
                  .cast<Map>()
                  .singleWhere((f) => f['name'] == 'default')['target'];
              final exact = await project.readDataValue(
                Map<String, dynamic>.from(target as Map),
              );
              expect(jsonDecode(exact), jsonDecode(raw));
              if (action != 'empty')
                expect(exact, contains('9007199254740993.00'));
              if (comment.isNotEmpty)
                expect(changed, contains('# collection note'));
              expect(changed, startsWith(prefix.replaceAll('\n', newline)));
              expect(changed, endsWith(suffix.replaceAll('\n', newline)));
              project.store.undo();
              expect(b.text, original);
              expect(project.store.canUndo, false);
              project.store.redo();
              expect(b.text, changed);
              expect(
                (await project.check(
                  root,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              project.store.undo();
            }
          } finally {
            project.close();
          }
        }
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final member in ['? keep: yes,', 'keep', '? keep']) {
      test('R03-H whole-default member boundaries $member $version', () async {
        final newline = version == '3.1.2' ? '\n' : '\r\n';
        final prefix =
            'openapi: $version\ninfo: {title: API, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default:\n';
        const suffix = '      description: sentinel # source\n';
        final original = (prefix + '        - {$member}\n' + suffix).replaceAll(
          '\n',
          newline,
        );
        final file = File('${dir.path}/member.yaml');
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        try {
          final root = project.roots.single.id, b = await project.buffer(root);
          expect(
            (await project.check(root, schemaEvaluation: false))['findings'],
            isEmpty,
          );
          for (final raw in ['[{}]', '[{"value":{"n":9007199254740993.00}}]']) {
            const pointer = '/components/schemas/Model';
            final item = await project.inspectObject(root, root, pointer);
            final range = List<int>.from(item['range'] as List);
            await project.proposeAndApply(
              root,
              PropertySession(
                root: root,
                buffer: root,
                generation: b.generation,
                pointer: pointer,
                range: range,
                expected: b.text.substring(range[0], range[1]),
              ),
              [
                {'kind': 'setData', 'pointer': '$pointer/default', 'raw': raw},
              ],
            );
            final changed = b.text;
            expect(b.dirty, true);
            expect(b.baseline, original);
            expect(changed, startsWith(prefix.replaceAll('\n', newline)));
            expect(changed, endsWith(suffix.replaceAll('\n', newline)));
            Future<void> checkValue() async {
              expect(
                (await project.check(
                  root,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              final current = await project.inspectObject(root, root, pointer);
              final target = (current['fields'] as List)
                  .cast<Map>()
                  .singleWhere((f) => f['name'] == 'default')['target'];
              final exact = await project.readDataValue(
                Map<String, dynamic>.from(target as Map),
              );
              expect(jsonDecode(exact), jsonDecode(raw));
              if (raw != '[{}]') expect(exact, contains('9007199254740993.00'));
            }

            await checkValue();
            project.store.undo();
            expect(b.text, original);
            expect(project.store.canUndo, false);
            project.store.redo();
            expect(b.text, changed);
            await checkValue();
            project.store.undo();
          }
        } finally {
          project.close();
        }
      });
    }
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final marker in ['?', ':']) {
      for (final action in ['replace', 'remove', 'expand']) {
        test('R03-I whole-default comment separator $action $marker $version', () async {
          for (final newline in ['\n', '\r\n']) {
            final prefix =
                'openapi: $version\ninfo: {title: API, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default: [';
            const tail =
                '# key note\n        ]\n      description: sentinel # source\n';
            final original = (prefix + marker + ' ' + tail).replaceAll(
              '\n',
              newline,
            );
            final file = File('${dir.path}/pair.yaml');
            await file.writeAsString(original);
            final project = await BusyProject.open(file.path, engine);
            try {
              final root = project.roots.single.id,
                  b = await project.buffer(root);
              expect(
                (await project.check(
                  root,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              final raw = action == 'replace'
                  ? '[7]'
                  : action == 'remove'
                  ? '[{}]'
                  : '[{"":null,"next":1}]';
              const pointer = '/components/schemas/Model';
              final item = await project.inspectObject(root, root, pointer);
              final range = List<int>.from(item['range'] as List),
                  generation = b.generation;
              final field = (item['fields'] as List).cast<Map>().singleWhere(
                (f) => f['name'] == 'default',
              );
              expect(field['type'], 'any');
              expect(
                jsonDecode(
                  await project.readDataValue(
                    Map<String, dynamic>.from(field['target'] as Map),
                  ),
                ),
                [
                  {'': null},
                ],
              );
              await project.proposeAndApply(
                root,
                PropertySession(
                  root: root,
                  buffer: root,
                  generation: generation,
                  pointer: pointer,
                  range: range,
                  expected: b.text.substring(range[0], range[1]),
                ),
                [
                  {
                    'kind': 'setData',
                    'pointer': '$pointer/default',
                    'raw': raw,
                  },
                ],
              );
              final changed = b.text;
              expect(b.dirty, true);
              expect(b.baseline, original);
              expect(b.generation, greaterThan(generation));
              Future<void> checkValue() async {
                expect(
                  (await project.check(
                    root,
                    schemaEvaluation: false,
                  ))['findings'],
                  isEmpty,
                );
                final current = await project.inspectObject(
                  root,
                  root,
                  pointer,
                );
                final target = (current['fields'] as List)
                    .cast<Map>()
                    .singleWhere((f) => f['name'] == 'default')['target'];
                final value = await project.readDataValue(
                  Map<String, dynamic>.from(target as Map),
                );
                expect(jsonDecode(value), jsonDecode(raw));
                expect(b.text, startsWith(prefix.replaceAll('\n', newline)));
                expect(b.text, endsWith(tail.replaceAll('\n', newline)));
                expect(b.text, contains(RegExp(r'\s# key note')));
              }

              await checkValue();
              project.store.undo();
              expect(b.text, original);
              expect(project.store.canUndo, false);
              project.store.redo();
              expect(b.text, changed);
              await checkValue();
            } finally {
              project.close();
            }
          }
        });
      }
    }
  }
}
