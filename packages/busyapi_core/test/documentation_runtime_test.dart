import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_support.dart';

class _OutputFaultEngine extends EngineProcess {
  _OutputFaultEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) {
    if ([
      'deriveBundle',
      'referenceDocument',
      'referenceDisplay',
    ].contains(method)) {
      throw CoreFailure('engine.exit', 'Injected output worker failure');
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  late Directory temp;
  late EngineProcess engine;
  BusyProject? project;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-redoc-core-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    project?.close();
    project = null;
    await engine.close();
    await temp.delete(recursive: true);
  });

  test('Swagger retains native Reference and explicitly rejects Redoc vendor conversion', () async {
    final root = File('${temp.path}/swagger.yaml');
    await root.writeAsString(
      'swagger: "2.0"\ninfo: {title: Native, version: "1"}\npaths: {}\n',
    );
    final original = await root.readAsBytes();
    project = await BusyProject.open(root.path, engine);
    final presentation = (await project!.captureDocumentationPresentation(
      root.uri.toString(),
    )).toJson();
    final redoc = await DocumentationRuntime.forEngine(engine);
    await expectLater(
      redoc.page(
        presentation,
        labels: defaultDocumentationLabels,
        native: true,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'documentation.renderer.version',
        ),
      ),
    );
    final swagger = await DocumentationRuntime.forEngine(
      engine,
      preset: 'swagger',
    );
    expect(
      (await swagger.page(
        presentation,
        labels: defaultDocumentationLabels,
        native: true,
      )).keys,
      contains('swagger.js'),
    );
    final output = await project!.prepareDocumentation(
      root.uri.toString(),
      '${temp.path}/native',
    );
    addTearDown(output.close);
    await output.publish();
    expect(
      await File('${output.destination}/index.html').readAsString(),
      contains('OpenAPI 2.0'),
    );
    expect(await root.readAsBytes(), original);
  });

  test('1-MiB located documentation fits the bounded entry without dropping graph or source actions', () async {
    final root = File('${temp.path}/large.json');
    await root.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'openapi': '3.2.1',
        'info': {'title': 'Representative documentation', 'version': '1'},
        'paths': {
          for (var i = 0; i < 1300; i++)
            '/items/$i': {
              'get': {
                'summary': 'Get representative item $i',
                'description': 'Representative text ' * 10,
                'responses': {
                  '200': {
                    'description': 'OK',
                    'content': {
                      'application/json': {
                        'schema': {
                          'type': 'object',
                          'properties': {
                            'name': {'type': 'string'},
                          },
                        },
                        'example': {'name': 'fixture'},
                      },
                    },
                  },
                },
              },
            },
        },
      }),
    );
    final before = await root.readAsBytes();
    expect(before.length, greaterThan(1024 * 1024));
    project = await BusyProject.open(root.path, engine);
    final presentation = (await project!.captureDocumentationPresentation(
      root.uri.toString(),
    )).toJson();
    for (final preset in ['redoc', 'swagger']) {
      final runtime = await DocumentationRuntime.forEngine(
        engine,
        preset: preset,
      );
      final files = await runtime.page(
        presentation,
        labels: defaultDocumentationLabels,
        native: true,
      );
      final html = utf8.decode(files['index.html']!);
      expect(
        files['index.html']!.length,
        inInclusiveRange(16 * 1024 * 1024 + 1, 32 * 1024 * 1024),
      );
      final marker = '<script id="busyapi-snapshot" type="application/json">';
      final start = html.indexOf(marker) + marker.length;
      final decoded = jsonDecode(
        html.substring(start, html.indexOf('</script>', start)),
      );
      expect(decoded['projection'], presentation['projection']);
      expect(decoded['sourceActions'], presentation['sourceActions']);
      expect(decoded['text'], presentation['text']);
      await expectLater(
        runtime.page(
          {...presentation, 'text': 'x' * (32 * 1024 * 1024)},
          labels: defaultDocumentationLabels,
          native: true,
        ),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'limit.documentation.output',
          ),
        ),
      );
    }
    expect(await root.readAsBytes(), before);
  }, timeout: Timeout(Duration(minutes: 2)));

  for (final preset in ['redoc', 'swagger']) {
    for (final version in ['3.1.2', '3.2.1']) {
      for (final json in [false, true]) {
        test('shared $preset export $version json=$json preserves source and CLI output', () async {
          final root = File('${temp.path}/root.${json ? 'json' : 'yaml'}'),
              fragment = File('${temp.path}/model.json'),
              callbacks = File('${temp.path}/callbacks.json');
          final operation = {
            'summary': 'Operation sentinel 雪😀',
            'callbacks': {
              'Received': {
                r'$ref': 'callbacks.json#/Shared',
                'summary': 'Captured callback owner',
              },
            },
            'responses': {
              '200': {
                'description': 'OK',
                'content': {
                  'application/json': {
                    'schema': {r'$ref': 'model.json#/Named'},
                    'example': {'n': 'EXACT', r'$ref': 'payload data'},
                  },
                },
              },
              '204': {'description': 'Bodyless sentinel'},
            },
          };
          final source =
              '${json ? '' : '# original YAML 雪😀\r\n'}${jsonEncode({
                'openapi': version,
                'info': {'title': 'Local reference', 'version': '1'},
                'paths': {
                  '/items': {
                    'get': operation,
                    if (version.startsWith('3.2')) 'additionalOperations': {
                        'COPY': {...operation, 'summary': 'COPY sentinel'},
                      },
                  },
                },
              }).replaceAll('"EXACT"', '900719925474099312345678901')}\r\n';
          const schema =
              '{"Named":{"type":["object","null"],"description":"External schema sentinel","properties":{"n":{"type":"integer"},"a/b":false},"x-data":{"\$ref":"literal extension"}}}';
          await root.writeAsString('\ufeff$source');
          await fragment.writeAsString(schema);
          final callbackPath = <String, Object?>{
            'post': {
              'summary': 'Core callback POST sentinel',
              'responses': {
                '204': {'description': 'Bodyless callback'},
              },
            },
            if (version.startsWith('3.2.')) ...{
              'query': {
                'summary': 'Core callback QUERY sentinel',
                'responses': {
                  '204': {'description': 'Bodyless QUERY'},
                },
              },
              'additionalOperations': {
                'COPY': {
                  'summary': 'Core callback COPY sentinel',
                  'responses': {
                    '200': {
                      'description': 'Callback data',
                      'content': {
                        'application/json': {
                          'schema': true,
                          'examples': {
                            'Captured': {
                              'dataValue': {
                                r'$ref': 'literal nested callback payload',
                                'number': 'EXACT_CALLBACK',
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          };
          final callbackSource = jsonEncode({
            'Shared': {r'{$request.body#/callbackUrl}': callbackPath},
            'x-preserved': {r'$ref': 'literal callback extension'},
          }).replaceAll('"EXACT_CALLBACK"', '900719925474099312345678901.00');
          await callbacks.writeAsString(callbackSource);
          final before = await root.readAsBytes();
          project = await BusyProject.open(root.path, engine);
          final owner = await project!.buffer(root.uri.toString());
          // Same saved bytes with different buffer generations must not change
          // a portable output when compared with the fresh packaged CLI.
          project!.store.replace(owner.id, '$source ');
          project!.store.replace(owner.id, source);
          final output = await project!.prepareDocumentation(
            owner.id,
            '${temp.path}/site 雪',
            preset: preset,
          );
          addTearDown(output.close);
          expect(output.unsaved, false);
          expect(output.metadata['root'], './${root.uri.pathSegments.last}');
          expect(output.metadata['preset'], preset);
          await output.publish();
          final directory = Directory(output.destination),
              html = await File('${directory.path}/index.html').readAsString(),
              notices = await File('${directory.path}/THIRD_PARTY_NOTICES.txt')
                  .readAsString(),
              inventory = jsonDecode(
                await File('${directory.path}/third-party.json').readAsString(),
              ),
              provenance = await File('${directory.path}/provenance.json')
                  .readAsString();
          expect(html, contains('900719925474099312345678901'));
          expect(html, contains('payload data'));
          expect(html, contains('External schema sentinel'));
          expect(html, contains('Core callback POST sentinel'));
          if (version.startsWith('3.2.')) {
            expect(html, contains('Core callback COPY sentinel'));
            expect(html, contains('900719925474099312345678901.00'));
            expect(html, contains('literal nested callback payload'));
          }
          expect(html, isNot(contains('<script src="http')));
          expect(
            notices,
            contains(
              preset == 'redoc'
                  ? '(c) Copyright 2025 Redocly Inc, all rights reserved.'
                  : 'Copyright 2020-2021 SmartBear Software Inc.',
            ),
          );
          expect(
            notices,
            contains('Permission is hereby granted, free of charge'),
          );
          expect(
            inventory['packages'],
            hasLength(preset == 'redoc' ? 52 : 118),
          );
          expect(
            notices,
            contains(
              'regenerator-runtime -- Copyright (c) 2014-present, Facebook, Inc. -- license (MIT)',
            ),
          );
          final dompurify = (inventory['packages'] as List).singleWhere(
            (record) => record['name'] == 'dompurify',
          );
          expect(dompurify['embeddedSources'][0]['license'], 'MIT');
          expect(provenance, isNot(contains(temp.path)));
          expect(await root.readAsBytes(), before);
          expect(await fragment.readAsString(), schema);
          expect(await callbacks.readAsString(), callbackSource);
          final result = await Process.run(
            '$testBundle/busyapi',
            [
              'build-docs',
              root.path,
              '--preset',
              preset,
              '--output',
              '${temp.path}/cli 雪',
              '--json',
            ],
            environment: {
              'PATH': '/nonexistent',
              'NODE_OPTIONS': '--must-not-be-used',
            },
            includeParentEnvironment: false,
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stderr}\n${result.stdout}',
          );
          expect(result.stderr, isEmpty);
          final record = jsonDecode(result.stdout as String);
          expect(record['preset'], preset);
          for (final entry
              in await directory
                  .list()
                  .where((entry) => entry is File)
                  .cast<File>()
                  .toList()) {
            final peer = File('${temp.path}/cli 雪/${p.basename(entry.path)}');
            expect(
              await peer.readAsBytes(),
              await entry.readAsBytes(),
              reason: p.basename(entry.path),
            );
          }
          expect(await root.readAsBytes(), before);
          expect(await callbacks.readAsString(), callbackSource);
        });
      }
    }
  }

  for (final preset in ['redoc', 'swagger']) {
    test(
      '$preset native page binds the owner snapshot and escapes inert authored script text',
      () async {
        final root = File('${temp.path}/root.json');
        await root.writeAsString(
          jsonEncode({
            'openapi': '3.2.1',
            'info': {
              'title': '</script><script>mustNotExecute()</script>',
              'version': '1',
            },
            'paths': <String, Object>{},
          }),
        );
        project = await BusyProject.open(root.path, engine);
        final presentation = await project!.captureDocumentationPresentation(
              root.uri.toString(),
            ),
            runtime = await DocumentationRuntime.forEngine(
              engine,
              preset: preset,
            ),
            files = await runtime.page(
              presentation.toJson(),
              labels: defaultDocumentationLabels,
              native: true,
            ),
            html = utf8.decode(files['index.html']!);
        expect(html, isNot(contains('</script><script>mustNotExecute()')));
        expect(html, contains(r'\u003c/script>'));
        final start =
                html.indexOf(
                  '<script id="busyapi-snapshot" type="application/json">',
                ) +
                '<script id="busyapi-snapshot" type="application/json">'.length,
            end = html.indexOf('</script>', start),
            input = jsonDecode(html.substring(start, end));
        expect(input['snapshot'], presentation.snapshot.identity);
        expect(input['text'], presentation.text);
        expect(input['sourceActions'], isNotEmpty);
        expect(
          files.keys,
          unorderedEquals([
            'index.html',
            '$preset.js',
            'bootstrap.js',
            if (preset == 'swagger') 'swagger.css',
          ]),
        );
        expect(files['$preset.js'], isA<List<int>>());
        expect(() => files['$preset.js']![0] = 0, throwsUnsupportedError);
      },
    );

    for (final problem in ['missing', 'modified', 'notice', 'symlink']) {
      test(
        '$preset $problem installed assets fail explicitly without using a project or network loader',
        () async {
          final directory = await Directory('${temp.path}/assets').create();
          final installed = Directory(
            '$testBundle/share/busyapi/documentation/$preset',
          );
          for (final entry
              in await installed
                  .list()
                  .where((entry) => entry is File)
                  .cast<File>()
                  .toList()) {
            await entry.copy('${directory.path}/${p.basename(entry.path)}');
          }
          final script = File('${directory.path}/$preset.js'),
              notice = File('${directory.path}/THIRD_PARTY_NOTICES.txt');
          if (problem == 'missing') await script.delete();
          if (problem == 'modified') await script.writeAsString('changed code');
          if (problem == 'notice') await notice.delete();
          if (problem == 'symlink') {
            await script.delete();
            await Link(script.path).create('${installed.path}/$preset.js');
          }
          await expectLater(
            DocumentationRuntime.loadInstalled(directory.path, preset: preset),
            throwsA(
              isA<DocumentationAssetsFailure>()
                  .having((e) => e.code, 'code', 'documentation.assets')
                  .having(
                    (e) => e.component,
                    'component',
                    problem == 'notice'
                        ? 'THIRD_PARTY_NOTICES.txt'
                        : '$preset.js',
                  ),
            ),
          );
        },
      );
    }
  }

  for (final kind in ['bundle', 'native-reference', 'redoc', 'swagger']) {
    test(
      '$kind execution failure retains the actual checked root and source evidence without producing output',
      () async {
        await engine.close();
        engine = _OutputFaultEngine();
        final root = File('${temp.path}/root.json');
        const source =
            '{"openapi":"3.2.1","info":{"title":"Checked source","version":"1"},"paths":{}}';
        await root.writeAsString(source);
        project = await BusyProject.open(root.path, engine);
        Object? failed;
        try {
          if (kind == 'bundle') {
            await project!.prepareBundle(
              root.uri.toString(),
              '${temp.path}/output',
            );
          } else {
            await project!.prepareDocumentation(
              root.uri.toString(),
              '${temp.path}/output',
              preset: kind,
            );
          }
        } on Object catch (error) {
          failed = error;
        }
        expect(failed, isA<OutputAnalysisFailure>());
        final error = failed as OutputAnalysisFailure;
        expect(error.code, 'engine.exit');
        expect(outputFailureExitCode(error), 3);
        expect(
          error.analysis['complete'],
          true,
          reason:
              'Source check and output execution have independent completeness',
        );
        expect(
          (error.analysis['checkedRoots'] as List).single,
          root.uri.toString(),
        );
        expect(error.analysis['sourceSnapshot'], isA<String>());
        expect(await Directory('${temp.path}/output').exists(), false);
        expect(await root.readAsString(), source);
      },
    );
  }

  for (final preset in ['redoc', 'swagger']) {
    test(
      'relocated CLI with missing $preset assets reports the selected named root, never another alias or empty success',
      () async {
        final bundle = await Directory('${temp.path}/bare application 雪')
                .create(),
            helper = await Directory('${bundle.path}/libexec/busyapi')
                .create(recursive: true),
            root = File('${temp.path}/root.json');
        await copyExecutableFixture(runtimeNode, '${helper.path}/node');
        await File(runtimeHelper).copy('${helper.path}/engine.cjs');
        await copyExecutableFixture(
          '$testBundle/busyapi',
          '${bundle.path}/busyapi',
        );
        const source =
            '{"openapi":"3.2.1","info":{"title":"Missing assets","version":"1"},"paths":{}}';
        await root.writeAsString(source);
        final manifest = File('${temp.path}/busyapi.yaml');
        const manifestSource =
            'version: 1\nroots:\n  - name: first\n    path: root.json\n  - name: second\n    path: root.json\n';
        await manifest.writeAsString(manifestSource);
        final result = await Process.run(
          '${bundle.path}/busyapi',
          [
            'build-docs',
            temp.path,
            '--root',
            'second',
            '--preset',
            preset,
            '--output',
            '${temp.path}/output',
            '--json',
          ],
          environment: {'PATH': '/nonexistent'},
          includeParentEnvironment: false,
        );
        expect(
          result.exitCode,
          3,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final record = jsonDecode(result.stdout as String);
        expect(record['complete'], false);
        expect(record['status'], 'operational-failure');
        expect(record['error']['code'], 'documentation.assets');
        expect(record['error']['message'], contains('assets.json'));
        expect(record['error']['message'], contains(preset));
        expect((record['checkedRoots'] as List).single['name'], 'second');
        expect(
          (record['checkedRoots'] as List).single['resource'],
          root.uri.toString(),
        );
        expect(await Directory('${temp.path}/output').exists(), false);
        expect(await root.readAsString(), source);
        expect(await manifest.readAsString(), manifestSource);
      },
    );
  }
}
