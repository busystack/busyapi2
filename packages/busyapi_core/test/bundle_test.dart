import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _BundleEngine extends EngineProcess {
  _BundleEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  String? fault;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'deriveBundle') {
      final gate = release;
      if (gate != null) {
        entered?.complete();
        await gate.future;
      }
      if (fault == 'crash')
        throw CoreFailure('engine.exit', 'Synthetic bundle adapter exit');
      if (fault == 'malformed')
        return {'version': 1, 'snapshot': params['snapshot'], 'complete': true};
      if (fault == 'alias-provenance') {
        final result = await super.request(
          method,
          params,
          requestId: requestId,
        );
        (result['provenance'] as List).first['source'].addAll({
          'physicalPointer': '/x-template',
          'range': [0, 1 << 30],
          'occurrenceRange': [0, 1],
        });
        return result;
      }
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  late Directory temp;
  late _BundleEngine engine;
  late BusyProject project;
  late File source, model;
  Future<void> open(String version, bool json) async {
    source = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
    final document = {
      'openapi': version,
      'info': {'title': 'Bundle 😀', 'version': '1'},
      'paths': <String, Object?>{},
      'components': {
        'schemas': {
          'Value': {r'$ref': 'model.json#/a~1b'},
          'Boolean': false,
        },
        'examples': {
          'Serialized': {'externalValue': 'https://unapproved.invalid/data'},
        },
      },
      'x-data': {r'$ref': 'literal payload', 'number': 111},
    };
    final jsonText = jsonEncode(document)
        .replaceFirst('111', '9007199254740993');
    // JSON flow syntax is also valid YAML. Exercise a genuine block document
    // with comments / mixed line endings separately from strict JSON.
    await source.writeAsString(
      json
          ? jsonText
          : '\ufeff# retained header\r\nopenapi: $version\ninfo: {title: "Bundle 😀", version: "1"}\r\npaths: {}\ncomponents:\n  schemas:\n    Value: {\$ref: "model.json#/a~1b"}\n    Boolean: false\n  examples:\n    Serialized: {externalValue: "https://unapproved.invalid/data"}\nx-data: {\$ref: literal payload, number: 9007199254740993}',
    );
    model = File('${temp.path}/model.json');
    await model.writeAsString(
      '{"a/b":{"type":"string","description":"Original model"},"a~1b":{"type":"integer"}}\r\n',
    );
    engine = _BundleEngine();
    project = await BusyProject.open(source.path, engine);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-bundle-core-');
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'literal constraint schema $version $json preserves unsaved fragments, independent relocation and CLI content',
        () async {
          await open(version, json);
          project.close();
          final extension = json ? 'json' : 'yaml';
          model = File('${temp.path}/models.$extension');
          final tree = File('${temp.path}/tree.$extension');
          final payload = {r'$ref': 'tree.$extension', 'x-count': 111};
          final document = {
            'openapi': version,
            'info': {'title': 'Literal 雪😀', 'version': '1'},
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'Data': {
                  r'$ref': 'models.$extension',
                  'examples': [
                    payload,
                    {...payload, 'x-count': 222},
                  ],
                },
                'Use': {
                  r'$ref': 'models.$extension#/const',
                  'examples': [
                    {
                      'value': 111,
                      'child': {'value': 111},
                    },
                    {
                      'value': 111,
                      'child': {'value': 222},
                    },
                  ],
                },
              },
            },
          };
          String render(Object value) {
            final text = jsonEncode(value)
                .replaceAll('111', '9007199254740993.00')
                .replaceAll('222', '9007199254740992');
            return json ? text : '\ufeff# retained Unicode 雪😀\r\n$text\r\n';
          }

          await source.writeAsString(render(document));
          await model.writeAsString(
            render({r'$id': 'models.$extension', 'const': payload}),
          );
          await tree.writeAsString(
            render({
              r'$id': 'tree.$extension',
              r'$dynamicAnchor': 'node',
              'description': 'Saved tree',
              'type': 'object',
              'properties': {
                'value': {'type': 'integer', 'minimum': 111},
                'child': {r'$dynamicRef': '#node'},
              },
              'required': ['value'],
              'unevaluatedProperties': false,
            }),
          );
          final original = {
            for (final file in [source, model, tree])
              file.path: await file.readAsBytes(),
          };
          project = await BusyProject.open(source.path, engine);
          final buffer = await project.buffer(tree.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Saved tree', 'Unsaved tree'),
          );
          final destination = '${temp.path}/literal output 雪';
          final plan = await project.prepareBundle(
            source.uri.toString(),
            destination,
          );
          addTearDown(plan.close);
          expect(plan.unsaved, true);
          expect(plan.result['producerVersion'], '4');
          expect(plan.result['output']['text'], contains('Unsaved tree'));
          expect(
            plan.result['output']['text'],
            contains('9007199254740993.00'),
          );
          expect(
            (plan.result['provenance'] as List).where(
              (entry) =>
                  entry['kind'] == 'literal-data-occurrence' &&
                  entry['source']['resource'] == model.uri.toString() &&
                  entry['source']['pointer'] == '/const',
            ),
            isNotEmpty,
          );
          await plan.publish();
          for (final file in original.entries)
            expect(await File(file.key).readAsBytes(), file.value);
          final relocated = await Directory(destination)
              .rename('${temp.path}/relocated literal 雪');
          final independent = await BusyProject.open(
            '${relocated.path}/openapi.json',
            engine,
          );
          addTearDown(independent.close);
          final checked = await independent.check(independent.roots.single.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(
            (checked['findings'] as List).where(
              (entry) => entry['code'] == 'example.schema.incompatible',
            ),
            hasLength(2),
          );
          await project.save(buffer);
          final saved = await project.prepareBundle(
            source.uri.toString(),
            '${temp.path}/saved literal',
            saved: true,
          );
          addTearDown(saved.close);
          final cliDestination = '${temp.path}/CLI literal 雪';
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['bundle', source.path, '--output', cliDestination, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect(cli.stderr, isEmpty);
          expect(
            await File('$cliDestination/openapi.json').readAsString(),
            saved.result['output']['text'],
          );
          expect(
            await File('$cliDestination/provenance.json').readAsString(),
            '${jsonEncode(saved.metadata)}\n',
          );
          expect(await source.readAsBytes(), original[source.path]);
          expect(await model.readAsBytes(), original[model.path]);
          expect(await tree.readAsBytes(), buffer.bytes());
        },
      );
    }
  }
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [true, false])
      test(
        'frozen bundle $version $json uses unsaved dependencies without publishing or rounding source',
        () async {
          await open(version, json);
          final before = {
            for (final file in [source, model])
              file.path: await file.readAsBytes(),
          };
          final buffer = await project.buffer(model.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Original model', 'Unsaved model'),
          );
          final destination = '${temp.path}/output 雪';
          final plan = await project.prepareBundle(
            source.uri.toString(),
            destination,
          );
          addTearDown(plan.close);
          expect(plan.unsaved, true);
          expect(plan.outdated, false);
          expect(await Directory(destination).exists(), false);
          expect(plan.result['output']['text'], contains('Unsaved model'));
          expect(plan.result['output']['text'], contains('9007199254740993'));
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Unsaved model', 'Later input'),
          );
          expect(plan.outdated, true);
          await plan.publish();
          final published = File('$destination/openapi.json');
          expect(await published.readAsString(), plan.result['output']['text']);
          final provenance = await File('$destination/provenance.json')
              .readAsString();
          expect(provenance, contains('working-copy'));
          expect(provenance, contains('./model.json'));
          expect(provenance, isNot(contains(temp.path)));
          final normalized = jsonDecode(provenance);
          expect(normalized['snapshot'], plan.snapshot.sourceIdentity);
          final repeated = await project.prepareBundle(
            source.uri.toString(),
            '${temp.path}/saved',
            saved: true,
          );
          addTearDown(repeated.close);
          expect(repeated.unsaved, false);
          expect(repeated.result['output']['text'], contains('Original model'));
          for (final entry in before.entries)
            expect(await File(entry.key).readAsBytes(), entry.value);
          project.store.undo();
          expect(buffer.text, contains('Unsaved model'));
          project.store.redo();
          expect(buffer.text, contains('Later input'));
        },
      );
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'aliased schema bundle $version retains physical provenance, exact bytes and relocated evaluation',
      () async {
        await open(version, false);
        project.close();
        final original =
            '# retained 😀\r\nopenapi: $version\r\ninfo: {title: Alias, version: "1"}\r\npaths: {}\r\nx-template: &schema\r\n  type: object\r\n  properties:\r\n    value: {type: integer, minimum: 9007199254740993}\r\n    child: {\$ref: "#/components/schemas/Tree"}\r\n  examples: [{value: 9007199254740993}, {value: 9007199254740992}]\r\ncomponents:\r\n  schemas:\r\n    Tree: *schema';
        final bytes = [239, 187, 191, ...utf8.encode(original)];
        await source.writeAsBytes(bytes);
        project = await BusyProject.open(source.path, engine);
        final destination = '${temp.path}/derived';
        final prepared = await project.prepareBundle(
          source.uri.toString(),
          destination,
        );
        addTearDown(prepared.close);
        await prepared.publish();
        final metadata = jsonDecode(
          await File('$destination/provenance.json').readAsString(),
        );
        final mapped = (metadata['provenance'] as List)
            .whereType<Map>()
            .singleWhere(
              (entry) =>
                  entry['source']['pointer'] ==
                  '/components/schemas/Tree/properties/value',
            );
        expect(
          mapped['source']['physicalPointer'],
          '/x-template/properties/value',
        );
        final range = mapped['source']['range'] as List;
        expect(
          original.substring(range[0] as int, range[1] as int),
          contains('9007199254740993'),
        );
        final occurrence = mapped['source']['occurrenceRange'] as List;
        expect(
          original.substring(occurrence[0] as int, occurrence[1] as int),
          '*schema',
        );
        expect(await source.readAsBytes(), bytes);
        final relocated = await Directory(destination)
            .rename('${temp.path}/relocated 雪');
        final derived = await BusyProject.open(
          '${relocated.path}/openapi.json',
          engine,
        );
        addTearDown(derived.close);
        final checked = await derived.check(derived.roots.single.id);
        expect(checked['complete'], true, reason: jsonEncode(checked));
        expect(
          (checked['findings'] as List).where(
            (finding) => finding['code'] == 'example.schema.incompatible',
          ),
          hasLength(1),
        );
        expect(await source.readAsBytes(), bytes);
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'shared root dialect $version $json preserves unsaved input, relocation and installed CLI parity',
        () async {
          await open(version, json);
          project.close();
          const dialect = 'https://json-schema.org/draft/2020-12/schema';
          model = File('${temp.path}/schemas.${json ? 'json' : 'yaml'}');
          final document = {
            'openapi': version,
            'info': {'title': 'Dialect 雪😀', 'version': '1'},
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'Use': {
                  r'$ref': '${model.uri}#/components/schemas/Tree',
                  'examples': [
                    {
                      'value': 111,
                      'child': {'value': 111},
                    },
                    {
                      'value': 111,
                      'child': {'value': 222},
                    },
                  ],
                },
              },
            },
          };
          final text = jsonEncode(document)
              .replaceAll('111', '9007199254740993')
              .replaceAll('222', '9007199254740992');
          await source.writeAsString(
            json ? text : '\ufeff# retained root 雪😀\r\n$text\r\n',
          );
          final schemas = {
            'openapi': version,
            'info': {'title': 'Schemas', 'version': '1'},
            'jsonSchemaDialect': dialect,
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'Tree': {
                  r'$schema': dialect,
                  r'$dynamicAnchor': 'tree',
                  'description': 'Saved schema',
                  'type': 'object',
                  'properties': {
                    'value': {'type': 'integer', 'const': 111},
                    'child': {r'$dynamicRef': '#tree'},
                  },
                  'required': ['value'],
                  'unevaluatedProperties': false,
                },
                'Other': {r'$schema': dialect, 'type': 'string'},
                'Boolean': false,
              },
            },
          };
          await model.writeAsString(
            json
                ? jsonEncode(schemas).replaceAll('111', '9007199254740993')
                : '\ufeff# retained schemas 雪😀\r\nopenapi: $version\r\ninfo: {title: Schemas, version: "1"}\r\njsonSchemaDialect: $dialect\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Tree:\r\n      \$schema: $dialect\r\n      \$dynamicAnchor: tree\r\n      description: Saved schema\r\n      type: object\r\n      properties:\r\n        value: {type: integer, const: 9007199254740993}\r\n        child: {\$dynamicRef: "#tree"}\r\n      required: [value]\r\n      unevaluatedProperties: false\r\n    Other: {\$schema: "$dialect", type: string}\r\n    Boolean: false',
          );
          final original = [
            await source.readAsBytes(),
            await model.readAsBytes(),
          ];
          project = await BusyProject.open(source.path, engine);
          final buffer = await project.buffer(model.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Saved schema', 'Unsaved schema'),
          );
          final destination = '${temp.path}/dialect output 雪';
          final plan = await project.prepareBundle(
            source.uri.toString(),
            destination,
          );
          addTearDown(plan.close);
          expect(plan.unsaved, true);
          expect(plan.result['output']['text'], contains('Unsaved schema'));
          expect(plan.result['output']['text'], contains('9007199254740993'));
          final declarations = (plan.result['provenance'] as List)
              .where((entry) => entry['kind'] == 'schema-dialect-declaration')
              .toList();
          expect(declarations, hasLength(2));
          expect(
            declarations.map((entry) => entry['derived']['pointer']).toSet(),
            hasLength(1),
          );
          expect(
            declarations.every(
              (entry) => entry['source']['resource'] == model.uri.toString(),
            ),
            true,
          );
          await plan.publish();
          expect(await source.readAsBytes(), original[0]);
          expect(await model.readAsBytes(), original[1]);
          final relocated = await Directory(destination)
              .rename('${temp.path}/relocated dialect 雪');
          final independent = await BusyProject.open(
            '${relocated.path}/openapi.json',
            engine,
          );
          addTearDown(independent.close);
          final checked = await independent.check(independent.roots.single.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(
            (checked['findings'] as List).where(
              (entry) => entry['code'] == 'example.schema.incompatible',
            ),
            hasLength(1),
          );
          await project.save(buffer);
          final savedBytes = buffer.bytes();
          project.close();
          project = await BusyProject.open(source.path, engine);
          expect(
            (await project.buffer(model.uri.toString())).bytes(),
            savedBytes,
          );
          final cliDestination = '${temp.path}/CLI dialect 雪';
          final saved = await project.prepareBundle(
            source.uri.toString(),
            cliDestination,
            saved: true,
          );
          addTearDown(saved.close);
          final run = await Process.run(
            '$testBundle/busyapi',
            ['bundle', source.path, '--output', cliDestination, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
          expect(run.stderr, isEmpty);
          expect(
            jsonDecode(run.stdout as String)['snapshot'],
            saved.snapshot.sourceIdentity,
          );
          expect(
            await File('$cliDestination/openapi.json').readAsString(),
            saved.result['output']['text'],
          );
          expect(
            await File('$cliDestination/provenance.json').readAsString(),
            '${jsonEncode(saved.metadata)}\n',
          );
          expect(await source.readAsBytes(), original[0]);
          expect(await model.readAsBytes(), savedBytes);
        },
      );
      test(
        'dual entry bundle $version $json publishes literal and schema meanings independently',
        () async {
          await open(version, json);
          project.close();
          final target = '${source.uri}#/components/schemas/Value';
          final literal = {r'$ref': target, 'x-count': 111};
          final text = json
              ? jsonEncode({
                      'openapi': version,
                      'info': {'title': 'Dual', 'version': '1'},
                      'paths': <String, Object?>{},
                      'components': {
                        'schemas': {
                          'Literal': {
                            'const': literal,
                            'examples': [
                              literal,
                              {...literal, 'x-count': 222},
                            ],
                          },
                          'Consumer': {
                            r'$ref': '#/components/schemas/Literal/const',
                            'examples': ['accepted', 123],
                          },
                          'Value': {'type': 'string', 'const': 'accepted'},
                        },
                      },
                    })
                    .replaceAll('111', '9007199254740993.00')
                    .replaceAll('222', '9007199254740992')
              : '# retained 😀\r\nopenapi: $version\ninfo: {title: Dual, version: "1"}\r\npaths: {}\ncomponents:\n  schemas:\n    Literal:\n      const: {\$ref: "$target", x-count: 9007199254740993.00}\n      examples: [{\$ref: "$target", x-count: 9007199254740993.00}, {\$ref: "$target", x-count: 9007199254740992}]\n    Consumer: {\$ref: "#/components/schemas/Literal/const", examples: [accepted, 123]}\n    Value: {type: string, const: accepted}';
          final bytes = [239, 187, 191, ...utf8.encode(text)];
          await source.writeAsBytes(bytes);
          project = await BusyProject.open(source.path, engine);
          final destination = '${temp.path}/dual output 雪';
          final plan = await project.prepareBundle(
            source.uri.toString(),
            destination,
          );
          addTearDown(plan.close);
          final value = jsonDecode(plan.result['output']['text'] as String);
          expect(
            value['components']['schemas']['Literal']['const'][r'$ref'],
            target,
          );
          expect(
            value['components']['schemas']['Consumer'][r'$ref'],
            isNot('#/components/schemas/Literal/const'),
          );
          await plan.publish();
          final relocated = await Directory(destination)
              .rename('${temp.path}/relocated dual 雪');
          final derived = await BusyProject.open(
            '${relocated.path}/openapi.json',
            engine,
          );
          addTearDown(derived.close);
          final checked = await derived.check(derived.roots.single.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(
            (checked['findings'] as List).where(
              (finding) => finding['code'] == 'example.schema.incompatible',
            ),
            hasLength(2),
          );
          expect(await source.readAsBytes(), bytes);
        },
      );
    }
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'external dual bundle $version $json preserves unsaved literal data, schema identity and installed CLI parity',
        () async {
          await open(version, json);
          project.close();
          model = File('${temp.path}/fragment.${json ? 'json' : 'yaml'}');
          final reference = '${model.uri}#/Example/value';
          final rootText = json
              ? jsonEncode({
                  'openapi': version,
                  'info': {'title': 'External dual', 'version': '1'},
                  'paths': <String, Object?>{},
                  'components': {
                    'schemas': {
                      'Use': {
                        r'$ref': reference,
                        'examples': [
                          {
                            'value': 'accepted',
                            'child': {'value': 'accepted'},
                          },
                          {
                            'value': 'accepted',
                            'child': {'value': 123},
                          },
                        ],
                      },
                    },
                    'examples': {
                      'Payload': {r'$ref': '${model.uri}#/Example'},
                    },
                  },
                })
              : '# unchanged root 雪😀\r\nopenapi: $version\r\ninfo: {title: External dual, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Use:\r\n      \$ref: "$reference"\r\n      examples: [{value: accepted, child: {value: accepted}}, {value: accepted, child: {value: 123}}]\r\n  examples:\r\n    Payload: {\$ref: "${model.uri}#/Example"}';
          final modelText = json
              ? '{"Example":{"summary":"Saved example 雪😀","value":{"\$id":"https://identities.invalid/dual","\$dynamicAnchor":"node","type":"object","properties":{"value":{"type":"string","const":"accepted"},"child":{"\$dynamicRef":"#node"}},"required":["value"],"unevaluatedProperties":false,"x-count":9007199254740993.00}}}'
              : '# retained fragment 雪😀\r\nExample:\r\n  summary: \'Saved example 雪😀\'\r\n  value:\r\n    \$id: https://identities.invalid/dual\r\n    \$dynamicAnchor: node\r\n    type: object\r\n    properties:\r\n      value: {type: string, const: accepted}\r\n      child: {\$dynamicRef: "#node"}\r\n    required: [value]\r\n    unevaluatedProperties: false\r\n    x-count: 9007199254740993.00';
          final sourceBytes = [239, 187, 191, ...utf8.encode(rootText)],
              modelBytes = [239, 187, 191, ...utf8.encode(modelText)];
          await source.writeAsBytes(sourceBytes);
          await model.writeAsBytes(modelBytes);
          project = await BusyProject.open(source.path, engine);
          final buffer = await project.buffer(model.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Saved example', 'Unsaved example'),
          );
          final destination = '${temp.path}/working output 雪';
          final plan = await project.prepareBundle(
            source.uri.toString(),
            destination,
          );
          addTearDown(plan.close);
          expect(plan.unsaved, true);
          final text = plan.result['output']['text'] as String;
          expect(text, contains('Unsaved example 雪😀'));
          expect(
            RegExp(r'"x-count"\s*:\s*9007199254740993\.00').allMatches(text),
            hasLength(2),
          );
          final provenance = (plan.result['provenance'] as List).cast<Map>();
          final literal = provenance.singleWhere(
            (item) =>
                item['source']['resource'] == model.uri.toString() &&
                item['source']['pointer'] == '/Example/value' &&
                item['kind'] == 'literal-data-occurrence',
          );
          final schema = provenance.singleWhere(
            (item) =>
                item['source']['resource'] == model.uri.toString() &&
                item['source']['pointer'] == '/Example/value' &&
                item['kind'] == 'schema',
          );
          expect(
            literal['derived']['pointer'],
            isNot(schema['derived']['pointer']),
          );
          Object? at(String pointer) {
            dynamic value = jsonDecode(text);
            for (final token in pointer.substring(1).split('/')) {
              value = value[token.replaceAll('~1', '/').replaceAll('~0', '~')];
            }
            return value;
          }

          expect(
            at('${literal['derived']['pointer']}/\$id'),
            'https://identities.invalid/dual',
          );
          expect(
            at(
              '${literal['derived']['pointer']}/properties/child/\$dynamicRef',
            ),
            '#node',
          );
          await plan.publish();
          expect(await source.readAsBytes(), sourceBytes);
          expect(await model.readAsBytes(), modelBytes);
          final relocated = await Directory(destination)
              .rename('${temp.path}/relocated output 雪');
          final derived = await BusyProject.open(
            '${relocated.path}/openapi.json',
            engine,
          );
          addTearDown(derived.close);
          final checked = await derived.check(derived.roots.single.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(
            (checked['findings'] as List).where(
              (finding) => finding['code'] == 'example.schema.incompatible',
            ),
            hasLength(1),
          );
          final savedBytes = buffer.bytes();
          await project.save(buffer);
          expect(await model.readAsBytes(), savedBytes);
          final cliDestination = '${temp.path}/CLI output 雪';
          final saved = await project.prepareBundle(
            source.uri.toString(),
            cliDestination,
            saved: true,
          );
          addTearDown(saved.close);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['bundle', source.path, '--output', cliDestination, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect(
            jsonDecode(cli.stdout as String)['snapshot'],
            saved.snapshot.sourceIdentity,
          );
          expect(
            await File('$cliDestination/openapi.json').readAsString(),
            saved.result['output']['text'],
          );
          expect(
            await File('$cliDestination/provenance.json').readAsString(),
            jsonEncode(saved.metadata) + '\n',
          );
          expect(await source.readAsBytes(), sourceBytes);
          expect(await model.readAsBytes(), savedBytes);
        },
      );
    }
  }
  test('bundle snapshots remain captured through later edits; malformed/crashed workers cannot publish', () async {
    await open('3.2.1', true);
    final buffer = await project.buffer(model.uri.toString());
    engine.entered = Completer();
    engine.release = Completer();
    final pending = project.prepareBundle(
      source.uri.toString(),
      '${temp.path}/delayed',
    );
    await engine.entered!.future;
    project.store.replace(
      buffer.id,
      buffer.text.replaceFirst('Original model', 'Later model'),
    );
    engine.release!.complete();
    final plan = await pending;
    addTearDown(plan.close);
    expect(plan.outdated, true);
    expect(plan.result['output']['text'], contains('Original model'));
    engine.release = null;
    for (final fault in ['malformed', 'crash', 'alias-provenance']) {
      engine.fault = fault;
      await expectLater(
        project.prepareBundle(source.uri.toString(), '${temp.path}/$fault'),
        throwsA(isA<CoreFailure>()),
      );
      expect(await Directory('${temp.path}/$fault').exists(), false);
    }
    expect(await model.readAsString(), contains('Original model'));
  });
  test('bundle refuses source directories, invalid contracts, incomplete resources and cancellation', () async {
    await open('3.1.2', true);
    await expectLater(
      project.prepareBundle(source.uri.toString(), temp.path),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'output.source'),
      ),
    );
    await expectLater(
      project.prepareBundle(
        source.uri.toString(),
        '${temp.path}/cancel',
        cancelled: () => true,
      ),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    final buffer = await project.buffer(source.uri.toString());
    project.store.replace(
      buffer.id,
      buffer.text.replaceFirst('"version":"1"', '"version":false'),
    );
    await expectLater(
      project.prepareBundle(source.uri.toString(), '${temp.path}/invalid'),
      throwsA(
        isA<OutputAnalysisFailure>().having(
          (e) => e.code,
          'code',
          'bundle.contract',
        ),
      ),
    );
    project.store.undo();
    project.store.replace(
      buffer.id,
      buffer.text.replaceFirst(
        'model.json#/a~1b',
        'https://unapproved.invalid/model',
      ),
    );
    await expectLater(
      project.prepareBundle(source.uri.toString(), '${temp.path}/incomplete'),
      throwsA(
        isA<OutputAnalysisFailure>().having(
          (e) => e.code,
          'code',
          'bundle.incomplete',
        ),
      ),
    );
    expect(temp.listSync().whereType<Directory>(), isEmpty);
  });
  test('a configured root inside an owned output is still canonical source and cannot be replaced', () async {
    await open('3.2.1', true);
    final destination = '${temp.path}/second-api';
    final plan = await project.prepareBundle(
      source.uri.toString(),
      destination,
      saved: true,
    );
    await plan.publish();
    plan.close();
    project.close();
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots:\n  - {name: main, path: root.json}\n  - {name: second, path: second-api/openapi.json}\n',
    );
    project = await BusyProject.open(temp.path, engine);
    final before = await File('$destination/openapi.json').readAsBytes();
    await expectLater(
      project.prepareBundle(source.uri.toString(), destination),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'output.source',
        ),
      ),
    );
    expect(await File('$destination/openapi.json').readAsBytes(), before);
  });
  test('compiled headless bundle and shared core agree; collision and validity exits are truthful', () async {
    await open('3.2.1', true);
    Future<ProcessResult> run(List<String> arguments) => Process.run(
      '$testBundle/busyapi',
      arguments,
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    final destination = '${temp.path}/CLI 雪';
    final prepared = await project.prepareBundle(
      source.uri.toString(),
      destination,
      saved: true,
    );
    addTearDown(prepared.close);
    final result = await run([
      'bundle',
      source.path,
      '--output',
      destination,
      '--json',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, isEmpty);
    final machine = jsonDecode(result.stdout as String);
    expect(machine['snapshot'], prepared.snapshot.sourceIdentity);
    expect(machine['output']['identity'], prepared.identity);
    expect(
      await File('$destination/openapi.json').readAsString(),
      prepared.result['output']['text'],
    );
    expect(
      await File('$destination/provenance.json').readAsString(),
      jsonEncode(prepared.metadata) + '\n',
    );
    final receipt = await prepared.existing();
    expect(
      (await run(['bundle', source.path, '--output', destination, '--json']))
          .exitCode,
      3,
    );
    expect((await prepared.existing())!.identity, receipt!.identity);
    final replaced = await run([
      'bundle',
      source.path,
      '--output',
      destination,
      '--replace-output',
      receipt.identity,
      '--json',
    ]);
    expect(
      replaced.exitCode,
      0,
      reason: '${replaced.stdout}\n${replaced.stderr}',
    );
    final previous =
        jsonDecode(replaced.stdout as String)['output']['previous'] as String;
    expect(
      await File('$previous/openapi.json').readAsString(),
      prepared.result['output']['text'],
    );
    await source.writeAsString(
      (await source.readAsString()).replaceFirst(
        '"version":"1"',
        '"version":false',
      ),
    );
    final invalid = await run([
      'bundle',
      source.path,
      '--output',
      '${temp.path}/invalid',
      '--json',
    ]);
    expect(invalid.exitCode, 1, reason: invalid.stdout as String);
    expect(jsonDecode(invalid.stdout as String)['findings'], isNotEmpty);
    expect(await Directory('${temp.path}/invalid').exists(), false);
    project.close();
    project = await BusyProject.open(temp.path, engine);
    expect(
      project.roots.map((root) => root.id),
      [source.uri.toString()],
      reason: 'Owned exports and retained output versions are not new canonical roots',
    );
  });
  for (final json in [false, true])
    test(
      '3.1 entry-resource bundle $json preserves mapped back-references through core and headless publication',
      () async {
        await open('3.1.2', json);
        project.close();
        final document = {
          'openapi': '3.1.2',
          'info': {'title': 'Entry', 'version': '1'},
          'paths': <String, Object?>{},
          'components': {
            'schemas': {
              'Value': {'type': 'string'},
              'Remote': {r'$ref': 'https://schemas.invalid/consumer'},
            },
          },
        };
        await source.writeAsString(
          '${json ? '' : '# retained 😀\r\n'}${jsonEncode(document)}',
        );
        await model.writeAsString(
          jsonEncode({
            r'$id': 'https://schemas.invalid/consumer',
            'type': 'object',
            'properties': {
              'value': {r'$ref': '${source.uri}#/components/schemas/Value'},
            },
            'examples': [
              {'value': 'valid'},
              {'value': 42},
            ],
          }),
        );
        final original = [
          await source.readAsBytes(),
          await model.readAsBytes(),
        ];
        project = await BusyProject.open(source.path, engine);
        await project.approveResource(
          'https://schemas.invalid/consumer',
          model.uri.toString(),
        );
        final destination = '${temp.path}/entry output 雪';
        final prepared = await project.prepareBundle(
          source.uri.toString(),
          destination,
          saved: true,
        );
        addTearDown(prepared.close);
        expect(
          (jsonDecode(prepared.result['output']['text'] as String) as Map)
              .containsKey(r'$self'),
          false,
        );
        final run = await Process.run(
          '$testBundle/busyapi',
          [
            'bundle',
            source.path,
            '--output',
            destination,
            '--map-resource',
            'https://schemas.invalid/consumer',
            model.path,
            '--json',
          ],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        expect(run.stderr, isEmpty);
        expect(
          await File('$destination/openapi.json').readAsString(),
          prepared.result['output']['text'],
        );
        expect(
          await File('$destination/provenance.json').readAsString(),
          jsonEncode(prepared.metadata) + '\n',
        );
        expect(await source.readAsBytes(), original[0]);
        expect(await model.readAsBytes(), original[1]);
        final relocated = Directory('${temp.path}/relocated elsewhere 雪');
        await relocated.create();
        final file = await File('$destination/openapi.json')
            .copy('${relocated.path}/api.json');
        final independent = await BusyProject.open(file.path, engine);
        try {
          final checked = await independent.check(file.uri.toString());
          expect(checked['complete'], true);
          expect(
            (checked['findings'] as List).where(
              (f) => f['severity'] == 'error',
            ),
            isEmpty,
          );
          expect(
            checked['findings'],
            isNotEmpty,
            reason: 'The deliberately invalid example remains visible advice, not erased data',
          );
        } finally {
          independent.close();
        }
      },
    );
}
