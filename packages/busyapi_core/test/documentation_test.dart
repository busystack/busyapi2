import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:busyapi_core/src/atomic_directory_writer.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _DocumentationEngine extends EngineProcess {
  _DocumentationEngine()
    : super(executable: runtimeNode, helper: runtimeHelper);
  String? fault;
  String? sourceFault;
  String? displayFault;
  bool derivedOnly = false;
  Completer<void>? entered, release;
  Map<String, dynamic> displayContent(Map<String, dynamic> packet) =>
      jsonDecode(packet['content'] as String) as Map<String, dynamic>;
  Map<String, dynamic> displayPacket(Map<String, dynamic> content) => {
    'version': 1,
    'producer': 'busyapi-reference-display-packet',
    'producerVersion': '2',
    'encoding': 'json',
    'content': jsonEncode(content),
  };
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'referenceDisplay' && displayFault != null) {
      final packet = await super.request(method, params, requestId: requestId);
      switch (displayFault) {
        case 'packet-version':
          return {...packet, 'version': 2};
        case 'packet-producer':
          return {...packet, 'producer': 'other'};
        case 'packet-producer-version':
          return {...packet, 'producerVersion': '1'};
        case 'packet-encoding':
          return {...packet, 'encoding': 'yaml'};
        case 'packet-shape':
          return {...packet, 'content': []};
        case 'packet-syntax':
          return {...packet, 'content': '{'};
        case 'packet-record':
          return {...packet, 'content': '[]'};
      }
      final result = displayContent(packet);
      switch (displayFault) {
        case 'version':
          result['version'] = 2;
        case 'producer':
          result['producer'] = 'other';
        case 'producer-version':
          result['producerVersion'] = '1';
        case 'representation':
          result['representation'] = 'openapi-bundle';
        case 'root':
          result['root'] = 'https://unowned.invalid/root.json';
        case 'snapshot':
          result['snapshot'] = 'stale';
        case 'incomplete':
          result['complete'] = false;
        case 'identity':
          result['output']['identity'] = 'wrong';
        case 'text':
          result['output']['text'] += ' ';
        case 'output':
          result['output']['id'] = 'https://unowned.invalid/display.json';
        case 'coordinates':
          result['projection']['coordinateSpace'] = 'original-source';
        case 'display-only':
          result['projection']['displayOnly'] = false;
        case 'projection-root':
          result['projection']['root'] = params['root'];
        case 'projection-snapshot':
          result['projection']['snapshot'] = 'stale';
      }
      return displayPacket(result);
    }
    if (method == 'referenceDisplay' && sourceFault != null) {
      final result = displayContent(
        await super.request(method, params, requestId: requestId),
      );
      final entry = (result['provenance'] as List).firstWhere(
        (record) =>
            record['kind'] == 'root' && record['source']['pointer'] == '',
      );
      if (sourceFault == 'source')
        entry['source']['pointer'] = '/not-in-original';
      if (sourceFault == 'display')
        entry['derived']['pointer'] = '/not-in-display';
      if (sourceFault == 'kind') entry['kind'] = 'schema-dialect-declaration';
      if (sourceFault == 'ambiguous')
        result['provenance'].add({
          ...entry as Map,
          'source': {...entry['source'] as Map, 'pointer': '/info'},
        });
      return displayPacket(result);
    }
    if (method == 'referenceDocument' || method == 'referenceDisplay') {
      if (entered?.isCompleted == false) entered!.complete();
      await release?.future;
      final inject =
          !derivedOnly ||
          method == 'referenceDisplay' ||
          (params['root'] as String).startsWith(
            'https://busyapi-display.invalid/',
          );
      if (inject && fault == 'crash')
        throw CoreFailure('engine.exit', 'Synthetic documentation worker exit');
      final payload = await super.request(method, params, requestId: requestId);
      if (!inject) return payload;
      final display = method == 'referenceDisplay'
          ? displayContent(payload)
          : payload;
      final result = method == 'referenceDisplay'
          ? display[derivedOnly ? 'projection' : 'original']
                as Map<String, dynamic>
          : payload;
      if (fault == 'incomplete') result['complete'] = false;
      if (fault?.startsWith('markdown-') == true) {
        final source =
            ((result['sections'] as List).first as Map)['source'] as Map;
        switch (fault) {
          case 'markdown-missing':
            source.remove('markdownBase');
          case 'markdown-type':
            source['markdownBase'] = false;
          case 'markdown-relative':
            source['markdownBase'] = '../unowned';
          case 'markdown-uri':
            source['markdownBase'] = 'https://[';
        }
      }

      if (fault == 'location')
        result['sections'][0]['source']['range'] = [0, 1 << 30];
      if (fault == 'missing-target')
        result['sections'][0]['entries'][0]['target'] = {
          ...(result['sections'][0]['source'] as Map),
          'pointer': '/not-a-section',
        };
      if (fault == 'dynamic-target') {
        final reference =
            (result['sections'] as List)
                    .expand((section) => section['references'] as List)
                    .first
                as Map;
        reference['dynamic'] = {
          'anchor': 'node',
          'candidates': [
            {...(reference['target'] as Map), 'pointer': '/not-a-section'},
          ],
        };
      }
      if (fault == 'effective-target') {
        final operation = (result['sections'] as List).firstWhere(
          (section) => section['kind'] == 'operation',
        ) as Map;
        operation['effective'][0]['source'] = {
          ...(operation['source'] as Map),
          'pointer': '/not-a-section',
        };
      }
      return method == 'referenceDisplay' ? displayPacket(display) : payload;
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  late Directory temp;
  late _DocumentationEngine engine;
  BusyProject? project;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-native-docs-');
    engine = _DocumentationEngine();
  });
  tearDown(() async {
    project?.close();
    project = null;
    await engine.close();
    await temp.delete(recursive: true);
  });
  Future<File> open(String version, bool json) async {
    final source = File('${temp.path}/api.${json ? 'json' : 'yaml'}');
    final value = {
      'openapi': version,
      'info': {
        'title': 'Offline 雪',
        'version': '1',
        'description': '# Description\n\n**Strong** ![never fetched](https://must-not-load.invalid/image) <script>unsafe()</script> [unsafe](javascript:bad)',
      },
      'paths': {
        '/p': {
          'post': {
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {r'$ref': 'model.json'},
                  'example': {
                    'n': 111,
                    r'$ref': 'literal payload',
                    'description': '**literal data**',
                  },
                },
              },
            },
            'responses': {
              '204': {'description': 'Intentionally bodyless'},
            },
          },
        },
      },
      'components': {
        'schemas': {
          'Never': false,
          'Composed': {
            'oneOf': [
              {r'$ref': 'model.json'},
              {'type': 'string'},
            ],
          },
        },
      },
      'x-data': {'n': 222, r'$ref': 'literal extension'},
    };
    if (version.startsWith('3.2')) {
      final path = (value['paths'] as Map)['/p'] as Map;
      path['query'] = {
        'responses': {
          '204': {'description': 'QUERY sentinel'},
        },
      };
      path['additionalOperations'] = {
        'COPY': {
          'responses': {
            '204': {'description': 'COPY sentinel'},
          },
        },
      };
    }
    // JSON flow syntax is valid YAML; preserve mixed endings/BOM/header in the
    // YAML file, and exercise block YAML aliases in the dedicated regression.
    final text = jsonEncode(value)
        .replaceFirst('111', '9007199254740993')
        .replaceFirst('222', '1.00000000000000000001');
    await source.writeAsString(
      json ? text : '\ufeff# preserved header\r\n$text\r\n',
    );
    await File('${temp.path}/model.json').writeAsString(
      '{"\$id":"https://schema.example/Model","type":"object","properties":{"sentinel":{"type":"integer"},"next":{"\$ref":"#"}}}',
    );
    project = await BusyProject.open(source.path, engine);
    return source;
  }

  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [true, false]) {
      test(
        'authored dialect source actions $version $json retain separate original declarations without promotion',
        () async {
          final source = await open(version, json);
          project!.close();
          const dialect = 'https://json-schema.org/draft/2020-12/schema';
          final model = File('${temp.path}/model.json');
          await source.writeAsString(
            jsonEncode({
              'openapi': version,
              'info': {'title': 'Dialect', 'version': '1'},
              'paths': <String, Object?>{},
              'components': {
                'schemas': {
                  'Use': {r'$ref': '${model.uri}#/components/schemas/A'},
                },
              },
            }),
          );
          await model.writeAsString(
            jsonEncode({
              'openapi': version,
              'info': {'title': 'Shared owner', 'version': '1'},
              'paths': <String, Object?>{},
              'components': {
                'schemas': {
                  'A': {r'$schema': dialect, 'type': 'string'},
                  'B': {r'$schema': dialect, 'type': 'integer'},
                  'Independent': {r'$id': 'independent', 'type': 'integer'},
                },
              },
            }),
          );
          final bytes = [await source.readAsBytes(), await model.readAsBytes()];
          project = await BusyProject.open(source.path, engine);
          final presentation = await project!.captureDocumentationPresentation(
            source.uri.toString(),
          );
          expect(
            presentation.sourceProvenance.where(
              (entry) => entry['kind'] == 'schema-dialect-declaration',
            ),
            isEmpty,
          );
          final actions = presentation.sourceActions
              .where(
                (action) =>
                    action.role == 'field' &&
                    action.source['resource'] == model.uri.toString() &&
                    [
                      r'/components/schemas/A/$schema',
                      r'/components/schemas/B/$schema',
                    ].contains(action.source['pointer']),
              )
              .toList();
          expect(actions, hasLength(2));
          expect(actions.map((action) => action.pointer).toSet(), hasLength(2));
          for (final action in actions) {
            expect(action.authored, true);
            expect(action.source['resource'], model.uri.toString());
            final buffer = await project!.buffer(model.uri.toString());
            final range = action.source['range'] as List;
            expect(
              buffer.text.substring(range[0] as int, range[1] as int),
              jsonEncode(dialect),
            );
            expect(
              presentation.resolveSourceAction(action.index),
              same(action),
            );
          }
          final independentRecord = presentation.sourceProvenance.singleWhere(
            (entry) =>
                entry['kind'] == 'schema' &&
                entry['source']['resource'] == model.uri.toString() &&
                entry['source']['pointer'] == '/components/schemas/Independent',
          );
          final independent = presentation.sourceActions.firstWhere(
            (action) =>
                action.pointer == independentRecord['derived']['pointer'] &&
                action.role == 'node',
          );
          expect(independent.authored, true);
          expect(
            independent.source['pointer'],
            '/components/schemas/Independent',
          );
          expect(
            presentation.sourceActionFor(
              '${independent.pointer}/\$schema',
              role: 'field',
            ),
            null,
          );
          final section = (presentation.projection['sections'] as List)
              .singleWhere(
                (section) =>
                    section['source']['pointer'] == independent.pointer,
              );
          expect(
            section['dialect'],
            'https://spec.openapis.org/oas/${version.substring(0, 3)}/dialect/base',
          );
          expect(await source.readAsBytes(), bytes[0]);
          expect(await model.readAsBytes(), bytes[1]);
        },
      );
      test(
        'renderer capture $version $json uses the shared proved snapshot without an output capability',
        () async {
          final source = await open(version, json),
              sourceBytes = await source.readAsBytes();
          final model = await project!.buffer(
            File('${temp.path}/model.json').uri.toString(),
          );
          final disk = await File(model.path).readAsBytes();
          project!.store.replace(
            model.id,
            model.text.replaceFirst('sentinel', 'unsaved-sentinel'),
          );
          final filesBefore =
              (await temp.list().map((file) => file.path).toList())..sort();
          final presentation = await project!.captureDocumentationPresentation(
            source.uri.toString(),
            requestId: 'renderer-capture',
          );
          expect(presentation.saved, false);
          expect(presentation.belongsTo(project!), true);
          expect(presentation.unsaved, true);
          expect(presentation.outdated, false);
          expect(presentation.snapshot.root, source.uri.toString());
          expect(
            presentation.displayCoordinates.root,
            'https://busyapi-display.invalid/${presentation.snapshot.sourceIdentity}/reference.json',
          );
          expect(
            presentation.identity,
            await textIdentityAsync(presentation.text),
          );
          for (final sentinel in [
            '9007199254740993',
            '1.00000000000000000001',
            'unsaved-sentinel',
            'literal payload',
            'literal extension',
            'Intentionally bodyless',
            'false',
            'oneOf',
          ]) {
            expect(presentation.text, contains(sentinel));
          }
          expect(presentation.originalProjection['complete'], true);
          expect(presentation.projection['complete'], true);
          expect(
            (presentation.originalProjection['sections'] as List).any(
              (section) => section['source']['resource'] == model.id,
            ),
            true,
          );
          expect(
            (presentation.projection['sections'] as List).every(
              (section) =>
                  section['source']['resource'] ==
                  presentation.displayCoordinates.root,
            ),
            true,
          );
          expect(
            presentation.sourceProvenance.any(
              (entry) =>
                  entry['source']['resource'] == model.id &&
                  entry['derived']['resource'] ==
                      presentation.displayCoordinates.root,
            ),
            true,
          );
          final actions = presentation.sourceActions;
          final locations = <String, Map>{
            for (final section
                in presentation.originalProjection['sections'] as List)
              jsonEncode([
                section['source']['resource'],
                section['source']['pointer'],
              ]): section['source'] as Map,
            for (final section
                in presentation.originalProjection['sections'] as List)
              for (final field in section['entries'] as List)
                jsonEncode([
                  field['source']['resource'],
                  field['source']['pointer'],
                ]): field['source'] as Map,
          };
          for (final action in actions) {
            expect(
              presentation.resolveSourceAction(action.index),
              same(action),
            );
            expect(
              presentation.sourceActionFor(action.pointer, role: action.role),
              same(action),
            );
            expect(
              action.source,
              locations[jsonEncode([
                action.source['resource'],
                action.source['pointer'],
              ])],
            );
          }
          final recursiveDefinition = actions.firstWhere(
            (action) =>
                action.role == 'node' &&
                action.source['resource'] == model.id &&
                action.source['pointer'] == '/properties/next',
          );
          expect(recursiveDefinition.authored, true);
          expect(recursiveDefinition.source['generation'], model.generation);
          final recursiveRef = presentation.sourceActionFor(
            '${recursiveDefinition.pointer}/\$ref',
            role: 'reference',
          )!;
          expect(recursiveRef.source['resource'], model.id);
          expect(recursiveRef.source['pointer'], r'/properties/next/$ref');
          expect(recursiveRef.authored, true);
          // Effective defaults remain metadata, not fabricated authored nodes
          // or source actions in the disposable renderer coordinates.
          expect(presentation.sourceActionFor('/servers/0'), null);
          expect(
            (jsonDecode(presentation.text) as Map).containsKey('servers'),
            false,
          );
          final operation = (presentation.projection['sections'] as List)
              .firstWhere((section) => section['kind'] == 'operation');
          final servers = (operation['effective'] as List).firstWhere(
            (field) => field['name'] == 'servers',
          );
          expect(servers['origin'], 'specification');
          expect(servers['source'], null);
          expect(servers['default'], [
            {'url': '/'},
          ]);
          expect(presentation.sourceActionFor('/not-a-field'), null);
          expect(
            () => presentation.resolveSourceAction(-1),
            throwsA(isA<CoreFailure>()),
          );
          expect(
            () => presentation.resolveSourceAction(actions.length),
            throwsA(isA<CoreFailure>()),
          );
          expect(() => actions.clear(), throwsUnsupportedError);
          expect(
            () => actions.first.source['range'][0] = 9,
            throwsUnsupportedError,
          );
          final packet = presentation.toJson();
          expect(packet['root'], presentation.displayCoordinates.root);
          expect(packet['representation'], 'graph-addressed-display-only');
          expect(packet['unsaved'], true);
          expect(packet.containsKey('originalProjection'), false);
          expect(packet.containsKey('sourceProvenance'), false);
          expect((packet['sourceActions'] as List).length, actions.length);
          for (final action in packet['sourceActions'] as List) {
            expect(
              (action as Map).keys,
              unorderedEquals(['index', 'pointer', 'role', 'authored']),
            );
          }
          expect(
            (jsonDecode(jsonEncode(packet)) as Map)['text'],
            presentation.text,
          );
          expect(() => packet['root'] = 'changed', throwsUnsupportedError);
          expect(
            () => presentation.projection['sections'].clear(),
            throwsUnsupportedError,
          );
          expect(
            () =>
                presentation
                        .originalProjection['sections'][0]['source']['resource'] =
                    'changed',
            throwsUnsupportedError,
          );
          expect(
            () => presentation.sourceProvenance.first['source']['resource'] =
                'changed',
            throwsUnsupportedError,
          );
          expect(
            (await temp.list().map((file) => file.path).toList())..sort(),
            filesBefore,
          );
          final capturedText = presentation.text,
              capturedPacket = jsonEncode(packet);
          project!.store.replace(
            model.id,
            model.text.replaceFirst('unsaved-sentinel', 'later-sentinel'),
          );
          expect(presentation.outdated, true);
          expect(
            () => presentation.resolveSourceAction(recursiveRef.index),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'documentation.stale',
              ),
            ),
          );
          expect(presentation.text, capturedText);
          expect(jsonEncode(packet), capturedPacket);
          expect(await source.readAsBytes(), sourceBytes);
          expect(await File(model.path).readAsBytes(), disk);
          await project!.save(model);
          expect(await File(model.path).readAsString(), model.text);
          final next = await project!.captureDocumentationPresentation(
            source.uri.toString(),
            saved: true,
          );
          expect(next.saved, true);
          expect(next.unsaved, false);
          expect(next.text, contains('later-sentinel'));
          final repeated = await project!.captureDocumentationPresentation(
            source.uri.toString(),
            saved: true,
          );
          expect(repeated.toJson(), next.toJson());
          expect(await source.readAsBytes(), sourceBytes);
        },
      );
      test(
        'native documentation $version $json freezes complete unsaved content and relocates without source publication',
        () async {
          final source = await open(version, json),
              sourceBytes = await source.readAsBytes();
          final model = await project!.buffer(
            File('${temp.path}/model.json').uri.toString(),
          );
          final disk = await File(model.path).readAsBytes();
          project!.store.replace(
            model.id,
            model.text.replaceFirst('sentinel', 'unsaved-sentinel'),
          );
          final plan = await project!.prepareDocumentation(
            source.uri.toString(),
            '${temp.path}/output 雪',
          );
          addTearDown(plan.close);
          expect(plan.unsaved, true);
          expect(plan.outdated, false);
          expect(Directory(plan.destination).existsSync(), false);
          await plan.publish();
          final html = await File('${plan.destination}/index.html')
              .readAsString();
          for (final sentinel in [
            '9007199254740993',
            '1.00000000000000000001',
            'unsaved-sentinel',
            'literal payload',
            'literal extension',
            'Intentionally bodyless',
            'false',
            'oneOf',
          ])
            expect(html, contains(sentinel));
          expect(html, contains('<strong>Strong</strong>'));
          expect(html, contains('never fetched'));
          expect(html, isNot(contains('<script>')));
          expect(html, isNot(contains('<img')));
          expect(html, isNot(contains('href="javascript:')));
          expect(html, isNot(contains('src="https:')));
          expect(html, contains('connect-src \'none\''));
          expect(html, contains('img-src \'none\''));
          if (version.startsWith('3.2'))
            for (final sentinel in ['QUERY', 'COPY'])
              expect(html, contains(sentinel));
          final metadata = await File('${plan.destination}/provenance.json')
              .readAsString();
          expect(metadata, contains('working-copy'));
          expect(metadata, contains('./model.json'));
          expect(metadata, isNot(contains(temp.path)));
          expect(html, isNot(contains(temp.path)));
          project!.store.replace(
            model.id,
            model.text.replaceFirst('unsaved-sentinel', 'later-sentinel'),
          );
          expect(plan.outdated, true);
          expect(
            await File('${plan.destination}/index.html').readAsString(),
            html,
          );
          expect(await source.readAsBytes(), sourceBytes);
          expect(await File(model.path).readAsBytes(), disk);
          final relocated = await Directory(plan.destination)
              .rename('${temp.path}/relocated docs 空');
          final receipt = await AtomicDirectoryWriter.inspect(relocated.path);
          expect(receipt.metadata['entry'], 'index.html');
          expect(
            receipt.files.keys,
            containsAll([
              'README.txt',
              'NOTICE.txt',
              'index.html',
              'provenance.json',
            ]),
          );
          expect(
            await File('${relocated.path}/index.html').readAsString(),
            html,
          );
        },
      );
    }
  test('renderer capture rejects failed/malformed reference work and cancellation without output or source changes', () async {
    final source = await open('3.2.1', true),
        bytes = await source.readAsBytes();
    final files = (await temp.list().map((file) => file.path).toList())..sort();
    for (final derivedOnly in [false, true]) {
      engine.derivedOnly = derivedOnly;
      for (final fault in [
        'crash',
        'incomplete',
        'location',
        'missing-target',
        'dynamic-target',
        'effective-target',
        'markdown-missing',
        'markdown-type',
        'markdown-relative',
        'markdown-uri',
      ]) {
        engine.fault = fault;
        await expectLater(
          project!.captureDocumentationPresentation(source.uri.toString()),
          throwsA(isA<CoreFailure>()),
        );
        expect(await source.readAsBytes(), bytes);
        expect(
          (await temp.list().map((file) => file.path).toList())..sort(),
          files,
        );
      }
    }
    engine.fault = null;
    engine.entered = Completer<void>();
    engine.release = Completer<void>();
    var cancelled = false;
    final pending = project!.captureDocumentationPresentation(
      source.uri.toString(),
      cancelled: () => cancelled,
    );
    await engine.entered!.future;
    cancelled = true;
    engine.release!.complete();
    await expectLater(
      pending,
      throwsA(
        isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled'),
      ),
    );
    expect(await source.readAsBytes(), bytes);
    expect(
      (await temp.list().map((file) => file.path).toList())..sort(),
      files,
    );
  });
  test('renderer capture rejects mismatched display identities and protocol metadata', () async {
    final source = await open('3.2.1', true),
        bytes = await source.readAsBytes();
    final files = (await temp.list().map((file) => file.path).toList())..sort();
    for (final fault in [
      'packet-version',
      'packet-producer',
      'packet-producer-version',
      'packet-encoding',
      'packet-shape',
      'packet-syntax',
      'packet-record',
      'version',
      'producer',
      'producer-version',
      'representation',
      'root',
      'snapshot',
      'incomplete',
      'identity',
      'text',
      'output',
      'coordinates',
      'display-only',
      'projection-root',
      'projection-snapshot',
    ]) {
      engine.displayFault = fault;
      await expectLater(
        project!.captureDocumentationPresentation(source.uri.toString()),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'documentation.protocol',
          ),
        ),
        reason: fault,
      );
      expect(await source.readAsBytes(), bytes);
      expect(
        (await temp.list().map((file) => file.path).toList())..sort(),
        files,
      );
    }
  });
  test('saved documentation GUI/core and headless CLI produce equivalent bytes, refuse collisions and select roots explicitly', () async {
    final source = await open('3.2.1', true);
    final first = await project!.prepareDocumentation(
      source.uri.toString(),
      '${temp.path}/gui',
      saved: true,
    );
    addTearDown(first.close);
    await first.publish();
    Future<ProcessResult> command(List<String> arguments) => Process.run(
      '$testBundle/busyapi',
      arguments,
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    final result = await command([
      'build-docs',
      source.path,
      '--output',
      '${temp.path}/cli',
      '--json',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final record = jsonDecode(result.stdout as String);
    expect(record['complete'], true);
    expect(record['preset'], 'native-reference');
    expect(record['output']['entry'], 'index.html');
    expect(record['snapshot'], first.snapshot.sourceIdentity);
    for (final name in [
      'index.html',
      'provenance.json',
      'NOTICE.txt',
      'README.txt',
    ])
      expect(
        await File('${temp.path}/cli/$name').readAsBytes(),
        await File('${temp.path}/gui/$name').readAsBytes(),
      );
    final collision = await command([
      'build-docs',
      source.path,
      '--output',
      '${temp.path}/cli',
      '--json',
    ]);
    expect(collision.exitCode, 3);
    expect(jsonDecode(collision.stdout as String)['complete'], false);
    final wrong = await command([
      'build-docs',
      source.path,
      '--output',
      '${temp.path}/absent',
      '--preset',
      'not-installed',
      '--json',
    ]);
    expect(wrong.exitCode, 3);
    expect(Directory('${temp.path}/absent').existsSync(), false);
    await File('${temp.path}/second.json')
        .writeAsString(await source.readAsString());
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots:\n  - {name: first, path: ${source.uri.pathSegments.last}}\n  - {name: second, path: second.json}\n',
    );
    final ambiguous = await command([
      'build-docs',
      temp.path,
      '--output',
      '${temp.path}/ambiguous',
      '--json',
    ]);
    expect(ambiguous.exitCode, 3);
    expect(
      jsonDecode(ambiguous.stdout as String)['error']['code'],
      'cli.ambiguous',
    );
    final selected = await command([
      'build-docs',
      temp.path,
      '--root',
      'second',
      '--output',
      '${temp.path}/selected',
      '--json',
    ]);
    expect(
      selected.exitCode,
      0,
      reason: '${selected.stdout}\n${selected.stderr}',
    );
    expect(
      jsonDecode(selected.stdout as String)['checkedRoots'][0]['name'],
      'second',
    );
  });
  test('cancel, invalid input, changed ownership and failed adapters never publish empty or speculative documentation', () async {
    final source = await open('3.2.1', true);
    for (final fault in [
      'crash',
      'incomplete',
      'location',
      'missing-target',
      'dynamic-target',
      'effective-target',
      'markdown-missing',
      'markdown-type',
      'markdown-relative',
      'markdown-uri',
    ]) {
      engine.fault = fault;
      await expectLater(
        project!.prepareDocumentation(
          source.uri.toString(),
          '${temp.path}/$fault',
        ),
        throwsA(isA<CoreFailure>()),
      );
      expect(Directory('${temp.path}/$fault').existsSync(), false);
    }
    engine.fault = null;
    engine.entered = Completer<void>();
    engine.release = Completer<void>();
    var cancelled = false;
    final pending = project!.prepareDocumentation(
      source.uri.toString(),
      '${temp.path}/cancelled',
      cancelled: () => cancelled,
    );
    final checked = expectLater(
      pending,
      throwsA(
        isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled'),
      ),
    );
    await engine.entered!.future;
    cancelled = true;
    engine.release!.complete();
    await checked;
    expect(Directory('${temp.path}/cancelled').existsSync(), false);
    engine.entered = null;
    engine.release = null;
    final output = await project!.prepareDocumentation(
      source.uri.toString(),
      '${temp.path}/owned',
    );
    addTearDown(output.close);
    await output.publish();
    final receipt = await output.existing();
    await File('${output.destination}/index.html')
        .writeAsString('External version must survive');
    await expectLater(
      output.publish(replaceIdentity: receipt!.identity),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'output.ownership',
        ),
      ),
    );
    expect(
      await File('${output.destination}/index.html').readAsString(),
      'External version must survive',
    );
    await expectLater(
      project!.prepareDocumentation(source.uri.toString(), temp.path),
      throwsA(isA<CoreFailure>()),
    );
    final buffer = await project!.buffer(source.uri.toString());
    project!.store.replace(
      buffer.id,
      '{"openapi":"3.2.1","info":{"title":42,"version":"1"},"paths":{}}',
    );
    await expectLater(
      project!.prepareDocumentation(
        source.uri.toString(),
        '${temp.path}/invalid',
      ),
      throwsA(isA<OutputAnalysisFailure>()),
    );
    expect(Directory('${temp.path}/invalid').existsSync(), false);
  });
  test('block YAML alias data and schema occurrences retain separate display semantics and provenance', () async {
    final source = File('${temp.path}/api.yaml');
    const original =
        '\ufeff# exact header\r\nopenapi: 3.2.1\ninfo: {title: Alias, version: "1"}\npaths: {}\nx-template: &template\n  description: "**Shared schema description**"\n  const: 9007199254740993\ncomponents:\n  schemas:\n    Value: *template\n';
    await source.writeAsString(original);
    project = await BusyProject.open(source.path, engine);
    final output = await project!.prepareDocumentation(
      source.uri.toString(),
      '${temp.path}/aliases',
    );
    addTearDown(output.close);
    await output.publish();
    final html = await File('${output.destination}/index.html').readAsString();
    expect(html, contains('<strong>Shared schema description</strong>'));
    expect(html, contains('9007199254740993'));
    expect(html, contains('**Shared schema description**'));
    final provenance = jsonDecode(
      await File('${output.destination}/provenance.json').readAsString(),
    );
    final schema = (provenance['provenance'] as List).firstWhere(
      (section) => section['source']['pointer'] == '/components/schemas/Value',
    );
    expect(schema['source']['physicalPointer'], '/x-template');
    final sourceText = (await project!.buffer(source.uri.toString())).text;
    expect(schema['source']['occurrenceRange'], [
      sourceText.indexOf('*template'),
      sourceText.indexOf('*template') + 9,
    ]);
    final presentation = await project!.captureDocumentationPresentation(
      source.uri.toString(),
    );
    final definition = presentation.sourceActions.firstWhere(
      (action) =>
          action.role == 'node' &&
          action.authored &&
          action.source['pointer'] == '/components/schemas/Value',
    );
    expect(definition.source['physicalPointer'], '/x-template');
    expect(
      definition.source['occurrenceRange'],
      schema['source']['occurrenceRange'],
    );
    final literal = presentation.sourceActionFor('/x-template', role: 'field')!;
    expect(literal.authored, true);
    expect(literal.source['pointer'], '/x-template');
    expect(provenance['sources'][0]['hasBom'], true);
    expect(provenance['rangeEncoding'], 'utf16-half-open-without-bom');
    expect(await source.readAsBytes(), utf8.encode(original));
  });
  test('source actions retain an authored 3.2 security URI key, definition, and original scope', () async {
    final source = File('${temp.path}/api.json');
    final security = File('${temp.path}/security 雪.json');
    const key = 'security%20%E9%9B%AA.json';
    await source.writeAsString(
      jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Security ownership', 'version': '1'},
        'paths': {},
        'security': [
          {
            key: ['read'],
          },
        ],
      }),
    );
    await security.writeAsString(
      '{"type":"oauth2","flows":{"clientCredentials":{"tokenUrl":"token","scopes":{"read":"Read only"}}}}',
    );
    final before = await source.readAsBytes(),
        securityBefore = await security.readAsBytes();
    project = await BusyProject.open(source.path, engine);
    final presentation = await project!.captureDocumentationPresentation(
      source.uri.toString(),
    );
    final connection = presentation.sourceProvenance.singleWhere(
      (record) =>
          record['kind'] == 'reference' && record['connection'] == 'security',
    );
    final pointer = connection['derived']['pointer'] as String;
    expect(pointer, '/security/0/$key');
    for (final role in ['reference', 'field', 'node']) {
      final action = presentation.sourceActionFor(pointer, role: role)!;
      expect(action.authored, true);
      expect(action.source['resource'], source.uri.toString());
      expect(action.source['pointer'], '/security/0/$key');
      expect(presentation.resolveSourceAction(action.index), same(action));
    }
    final definition = presentation.sourceActions.firstWhere(
      (action) =>
          action.role == 'node' &&
          action.authored &&
          action.source['resource'] == security.uri.toString() &&
          action.source['pointer'] == '',
    );
    expect(definition.source['range'], [0, securityBefore.length]);
    expect(await source.readAsBytes(), before);
    expect(await security.readAsBytes(), securityBefore);
    project!.close();
    expect(
      () => presentation.resolveSourceAction(definition.index),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'documentation.stale',
        ),
      ),
    );
  });
  test(
    'a source index fails closed on unknown or ambiguous proved coordinates',
    () async {
      final source = await open('3.2.1', true),
          before = await source.readAsBytes();
      for (final fault in ['source', 'display', 'kind', 'ambiguous']) {
        engine.sourceFault = fault;
        await expectLater(
          project!.captureDocumentationPresentation(source.uri.toString()),
          throwsA(
            isA<CoreFailure>().having(
              (error) => error.code,
              'code',
              'documentation.source',
            ),
          ),
        );
        expect(await source.readAsBytes(), before);
      }
      engine.sourceFault = null;
      final presentation = await project!.captureDocumentationPresentation(
        source.uri.toString(),
      );
      expect(presentation.outdated, false);
    },
  );
  test('publication cancellation and an interrupted exchange preserve both complete versions', () async {
    final source = await open('3.2.1', true);
    final first = await project!.prepareDocumentation(
      source.uri.toString(),
      '${temp.path}/output',
    );
    addTearDown(first.close);
    await first.publish();
    final previous = await File('${first.destination}/index.html')
            .readAsBytes(),
        receipt = await first.existing();
    final buffer = await project!.buffer(source.uri.toString());
    project!.store.replace(
      buffer.id,
      buffer.text.replaceFirst('Offline 雪', 'New title'),
    );
    final next = await project!.prepareDocumentation(
      source.uri.toString(),
      first.destination,
    );
    addTearDown(next.close);
    await expectLater(
      next.publish(replaceIdentity: receipt!.identity, cancelled: () => true),
      throwsA(
        isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled'),
      ),
    );
    expect(
      await File('${first.destination}/index.html').readAsBytes(),
      previous,
    );
    OutputDirectoryChanged? interrupted;
    try {
      await next.publish(
        replaceIdentity: receipt.identity,
        afterPublish: () =>
            throw StateError('Deterministic post-exchange failure'),
      );
    } on OutputDirectoryChanged catch (error) {
      interrupted = error;
    }
    expect(interrupted, isNotNull);
    expect(interrupted!.published, true);
    expect(interrupted.recoveryPath, isNotNull);
    expect(
      await File('${interrupted.recoveryPath}/index.html').readAsBytes(),
      previous,
    );
    expect(
      await File('${next.destination}/index.html').readAsString(),
      contains('New title'),
    );
    expect(
      await File('${next.destination}/index.html').readAsString(),
      isNot(contains('Offline 雪</h1>')),
    );
    expect(await source.readAsString(), contains('Offline 雪'));
    final reopened = await AtomicDirectoryWriter.inspect(next.destination);
    expect(reopened.metadata['outputIdentity'], next.identity);
  });
  test('large authored title and description stay complete without duplicating title text into browser chrome', () async {
    final source = File('${temp.path}/large.json'),
        title = 'Title 雪😀${'t' * (1024 * 1024)}',
        description = 'Description 雪😀${'d' * (5 * 1024 * 1024)}';
    await source.writeAsString(
      jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': title, 'version': '1', 'description': description},
        'paths': {},
      }),
    );
    project = await BusyProject.open(source.path, engine);
    final before = await source.readAsBytes(),
        output = await project!.prepareDocumentation(
          source.uri.toString(),
          '${temp.path}/large docs',
        );
    addTearDown(output.close);
    await output.publish();
    final html = await File('${output.destination}/index.html').readAsString();
    expect(html, contains(title));
    expect(html, contains(description));
    expect(title.allMatches(html).length, 1);
    expect(description.allMatches(html).length, 1);
    expect(
      RegExp(
        r'<title>(.*?)</title>',
        dotAll: true,
      ).firstMatch(html)!.group(1)!.length,
      lessThan(260),
    );
    expect(
      html,
      contains(
        'Description preserved as complete plain text within presentation limits.',
      ),
    );
    expect(await source.readAsBytes(), before);
  });
}
