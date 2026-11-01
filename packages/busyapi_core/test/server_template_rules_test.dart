import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _body =
    '{"amount":9007199254740993.00,"text":"雪😀","flag":false,"nil":null,"zero":0}';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format Unicode Server URLs preserve actual HTTP, outputs and source history',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-server-literals-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final requests = <(String, String, String?, List<int>)>[];
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, next) => all..addAll(next),
            );
            requests.add((
              request.method,
              request.uri.toString(),
              request.headers.value('X-Control'),
              bytes,
            ));
            request.response.headers.contentType = ContentType.json;
            request.response.add(utf8.encode(_body));
            await request.response.close();
          });
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          for (final character in [
            '\u00a0',
            '\ufeff',
            '\u2028',
            if (version != '3.2.1') '%{hex}',
          ]) {
            final template = character == '%{hex}';
            final url = 'http://127.0.0.1:${server.port}/base${character}part';
            final schema = {
              'type': 'object',
              'required': ['amount', 'text', 'flag', 'nil', 'zero'],
              'properties': {
                'amount': {
                  'type': 'integer',
                  'enum': ['EXACT'],
                },
                'text': {'type': 'string'},
                'flag': {
                  'type': 'boolean',
                  'enum': [false],
                },
                'nil': version == '3.0.4'
                    ? {'type': 'string', 'nullable': true}
                    : {
                        'type': ['string', 'null'],
                      },
                'zero': {
                  'type': 'integer',
                  'enum': [0],
                },
              },
            };
            final value = {
              'openapi': version,
              'info': {'title': 'Original', 'version': 'api-version'},
              'servers': [
                {
                  'url': url,
                  if (template)
                    'variables': {
                      'hex': {
                        'default': '20',
                        'enum': ['20'],
                      },
                    },
                },
              ],
              'paths': {
                '/items': {
                  'post': {
                    'parameters': [
                      {
                        'name': 'X-Control',
                        'in': 'header',
                        'required': true,
                        'schema': {'type': 'string'},
                      },
                    ],
                    'requestBody': {
                      'required': true,
                      'content': {
                        'application/json': {
                          'schema': {r'$ref': '#/components/schemas/Value'},
                        },
                      },
                    },
                    'responses': {
                      '200': {
                        'description': 'Echo',
                        'content': {
                          'application/json': {
                            'schema': {r'$ref': '#/components/schemas/Value'},
                          },
                        },
                      },
                    },
                  },
                },
              },
              'components': {
                'schemas': {'Value': schema},
              },
              'x-exact': 'EXACT',
            };
            final original =
                '${format == 'yaml' ? '# Keep literals 雪\r\n' : ''}${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
            final file = File('${temp.path}/api.$format');
            await file.writeAsString(original);
            final project = await BusyProject.open(file.path, engine);
            try {
              final root = file.uri.toString(),
                  buffer = await project.buffer(root);
              project.store.replace(
                root,
                original.replaceFirst('Original', 'Unsaved'),
              );
              final unsaved = buffer.text;
              expect((await project.check(root))['status'], 'complete');
              final plan = await project.prepareRequest(
                root,
                resource: root,
                pointer: '/paths/~1items/post',
              );
              try {
                final result = await const ContractRequestExecutor().execute(
                  plan,
                  OperationRequestDraft(
                    planIdentity: plan.identity,
                    parameters: {
                      OperationRequestDraft.parameterKey('header', 'X-Control'):
                          const RequestValue.text('synthetic'),
                    },
                    body: const RequestBodyDraft.raw(
                      mediaType: 'application/json',
                      text: _body,
                    ),
                  ),
                  resolveSecret: (_) async => null,
                );
                try {
                  expect(
                    result.conforming,
                    true,
                    reason:
                        '${result.outgoing.findings}\n${result.received.findings}',
                  );
                  expect(await result.response.bytes(), utf8.encode(_body));
                } finally {
                  await result.close();
                }
              } finally {
                plan.close();
              }
              final request = requests.last;
              expect(request.$1, 'POST');
              expect(
                request.$2,
                '/base${template ? '%20' : Uri.encodeComponent(character)}part/items',
              );
              expect(request.$3, 'synthetic');
              expect(request.$4, utf8.encode(_body));
              final bundle = await project.prepareBundle(
                root,
                '${temp.path}/bundle',
              );
              try {
                final bundled = jsonDecode(
                  bundle.result['output']['text'] as String,
                ) as Map;
                expect(bundled['openapi'], version);
                expect(
                  bundled['servers'][0]['url'],
                  template ? url : Uri.parse(url).toString(),
                );
                expect(
                  bundle.result['output']['text'],
                  contains('9007199254740993.00'),
                );
              } finally {
                bundle.close();
              }
              final documentation = await project.prepareDocumentation(
                root,
                '${temp.path}/docs',
                preset: 'native-reference',
              );
              documentation.close();
              final moved = File('${temp.path}/moved/api.$format');
              await Directory('${temp.path}/moved').create();
              final move = await project.planFileMove(root, moved.path);
              await project.applyRefactoring(move);
              expect(buffer.text, unsaved);
              expect(await file.readAsString(), original);
              expect(moved.existsSync(), false);
              project.store.undo();
              expect(buffer.id, root);
              expect(buffer.text, unsaved);
              project.store.redo();
              final publication = await PublicationStore(
                '${temp.path}/state/publications',
              ).save(project, [buffer]);
              expect(publication.complete, true);
              expect(publication.published, hasLength(1));
              expect(await moved.readAsString(), unsaved);
              expect(file.existsSync(), false);
              project.close();
              final reopened = await BusyProject.open(moved.path, engine);
              try {
                expect(
                  (await reopened.check(moved.uri.toString()))['status'],
                  'complete',
                );
              } finally {
                reopened.close();
              }
              // Keep the next iteration's source and destination independent.
              await moved.delete();
              await moved.parent.delete();
            } finally {
              project.close();
            }
          }
          expect(requests, hasLength(version == '3.2.1' ? 3 : 4));
        },
      );
    }
  }
  for (final version in ['3.0.4', '3.1.2']) {
    for (final format in ['yaml', 'json']) {
      for (final invalid in [
        'https://api.example.invalid/{unfinished',
        'https://api.example.invalid/{version}/bad space',
        r'https://api.example.invalid/{version}/bad\path',
        'https://api.example.invalid/{version}/bad%zz',
      ]) {
        final code = invalid.endsWith('{unfinished')
            ? 'server.url.template-delimiters'
            : 'server.url.template-literal';
        test(
          '$version $format $invalid native Server URL repair is localized, undoable and refuses invalid migration',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-server-delimiters-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final file = File('${temp.path}/api.$format');
            final original =
                '${format == 'yaml' ? '# Keep delimiter comment\r\n' : ''}{"openapi":"$version","info":{"title":"Original","version":"1"},"servers":[{"url":${jsonEncode(invalid)}}],"paths":{},"x-exact":9007199254740993.00}\r\n';
            await file.writeAsString(original);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = file.uri.toString(),
                buffer = await project.buffer(root);
            expect((await project.check(root))['status'], 'invalid');
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['check', file.path, '--json'],
              environment: {'PATH': ''},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 1);
            expect(
              (jsonDecode(cli.stdout as String) as Map)['findings'],
              contains(isA<Map>().having((f) => f['code'], 'code', code)),
            );
            final destination = '${temp.path}/refused-migration';
            await expectLater(
              project.prepareMigration(
                root,
                destination,
                targetVersion: '3.2.1',
              ),
              throwsA(
                isA<OutputAnalysisFailure>().having(
                  (e) => e.code,
                  'code',
                  'migration.contract',
                ),
              ),
            );
            expect(await Directory(destination).exists(), false);
            final refused = await Process.run(
              '$testBundle/busyapi',
              [
                'migrate',
                file.path,
                '--target',
                '3.2.1',
                '--output',
                destination,
                '--json',
              ],
              environment: {'PATH': ''},
              includeParentEnvironment: false,
            );
            expect(
              refused.exitCode,
              1,
              reason: '${refused.stdout} ${refused.stderr}',
            );
            expect(
              (jsonDecode(refused.stdout as String) as Map)['status'],
              'invalid',
            );
            expect(await Directory(destination).exists(), false);
            final page = await project.inspectObject(root, root, '/servers/0'),
                range = List<int>.from(page['range'] as List);
            const repaired = 'https://api.example.invalid/ready';
            await project.proposeAndApply(
              root,
              PropertySession(
                root: root,
                buffer: root,
                generation: buffer.generation,
                pointer: '/servers/0',
                range: range,
                expected: buffer.text.substring(range[0], range[1]),
              ),
              [
                {'kind': 'set', 'pointer': '/servers/0/url', 'value': repaired},
              ],
            );
            final changed = original.replaceFirst(
              jsonEncode(invalid),
              jsonEncode(repaired),
            );
            expect(buffer.text, changed);
            expect((await project.check(root))['status'], 'complete');
            project.store.undo();
            expect(buffer.text, original);
            expect((await project.check(root))['status'], 'invalid');
            project.store.redo();
            await project.save(buffer);
            final saved = await file.readAsBytes();
            await project.save(buffer);
            expect(await file.readAsBytes(), saved);
            expect(await file.readAsString(), changed);
          },
        );
      }
    }
  }
}
