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
  '3.1.0',
  '3.1.1',
  '3.1.2',
  '3.2.0',
  '3.2.1',
];

String _render(Object value, String format) =>
    '${format == 'yaml' ? '# Keep branch examples and CRLF\r\n' : ''}'
    '${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';

void main() {
  for (final version in _versions) {
    for (final format in ['yaml', 'json']) {
      final modern = version.startsWith('3.1') || version.startsWith('3.2');
      for (final conditional in [false, if (modern) true]) {
        test(
          '$version $format ${conditional ? 'conditional' : 'oneOf'} referenced candidates use unsaved bytes and whole-schema checks',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-branch-input-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final seen = <List<int>>[];
            server.listen((request) async {
              expect(request.method, 'POST');
              expect(request.uri.toString(), '/v1/data');
              expect(request.headers.contentType!.mimeType, 'application/json');
              seen.add(
                await request.fold<List<int>>(
                  [],
                  (all, chunk) => all..addAll(chunk),
                ),
              );
              request.response.statusCode = 204;
              await request.response.close();
            });
            Map<String, Object> branch(String kind, String label) {
              final value = {
                'kind': kind,
                'label': label,
                'n': 'EXACT',
                'flag': false,
                'empty': '',
                r'$ref': 'literal.json',
              };
              return {
                'type': 'object',
                'properties': {
                  'kind': {
                    'enum': [kind],
                  },
                },
                if (modern) 'examples': [value] else 'example': value,
              };
            }

            final root = _render({
              'openapi': version,
              'info': {
                'title': 'Whole-schema candidates',
                'version': 'business',
              },
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}/v1'},
              ],
              'paths': {
                '/data': {
                  'post': {
                    'requestBody': {
                      'required': true,
                      'content': {
                        'application/json': {
                          'schema': {
                            'type': 'object',
                            'required': [
                              'kind',
                              'label',
                              'n',
                              'flag',
                              'empty',
                              r'$ref',
                            ],
                            'properties': {
                              'label': {'type': 'string', 'minLength': 3},
                              'n': {
                                'type': 'integer',
                                'enum': ['EXACT'],
                              },
                            },
                            if (conditional) ...{
                              'if': {
                                'properties': {
                                  'kind': {
                                    'enum': ['Good'],
                                  },
                                },
                                'required': ['kind'],
                              },
                              'then': {
                                r'$ref':
                                    'shared.$format#/components/schemas/Good~1~0',
                              },
                              'else': {
                                r'$ref':
                                    'shared.$format#/components/schemas/Bad',
                              },
                              'dependentSchemas': {
                                'n': {
                                  r'$ref':
                                      'shared.$format#/components/schemas/Good~1~0',
                                },
                              },
                            } else
                              'oneOf': [
                                {
                                  r'$ref':
                                      'shared.$format#/components/schemas/Good~1~0',
                                },
                                {
                                  r'$ref':
                                      'shared.$format#/components/schemas/Bad',
                                },
                              ],
                          },
                        },
                      },
                    },
                    'responses': {
                      '204': {'description': 'None'},
                    },
                  },
                },
              },
            }, format);
            final shared = _render({
              'openapi': version,
              'info': {'title': 'Defining candidates', 'version': 'business'},
              'paths': <String, Object?>{},
              'components': {
                'schemas': {
                  'Good/~': branch('Good', 'Saved'),
                  'Bad': branch('Bad', 'x'),
                },
              },
            }, format);
            final file = File('${directory.path}/api.$format');
            final sharedFile = File('${directory.path}/shared.$format');
            await file.writeAsBytes([239, 187, 191, ...utf8.encode(root)]);
            await sharedFile.writeAsString(shared);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final rootBuffer = await project.buffer(file.uri.toString());
            final buffer = await project.buffer(sharedFile.uri.toString());
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst('"Saved"', '"Unsaved 雪😀"'),
            );
            Future<OperationRequestPlan> plan({bool saved = false}) =>
                project.prepareRequest(
                  file.uri.toString(),
                  resource: file.uri.toString(),
                  pointer: '/paths/~1data/post',
                  saved: saved,
                );
            final captured = await plan();
            addTearDown(captured.close);
            expect(
              (captured.result['representationRevisions']
                  as Map)['schemaExamples'],
              '2',
            );
            final media =
                ((captured.result['requestBody'] as Map)['content'] as List)
                        .single
                    as Map;
            expect(media['schemaExamples'], {'complete': true, 'issues': []});
            final choices = (media['examples'] as List).cast<Map>();
            expect(choices, hasLength(2));
            final expected = [
              r'{"kind":"Good","label":"Unsaved 雪😀","n":9007199254740993.00,"flag":false,"empty":"","$ref":"literal.json"}',
              r'{"kind":"Bad","label":"x","n":9007199254740993.00,"flag":false,"empty":"","$ref":"literal.json"}',
            ];
            expect(choices.map((choice) => choice['raw']), expected);
            for (var index = 0; index < choices.length; index++) {
              final choice = choices[index];
              expect(choice['origin'], 'schema');
              expect(choice['schemaApplicability'], 'not-evaluated');
              expect(choice['source']['resource'], buffer.id);
              expect(choice['source']['generation'], buffer.generation);
              final keyword = conditional
                  ? (index == 0 ? 'then' : 'else')
                  : 'oneOf';
              expect(
                choice['name'],
                '$keyword${conditional ? '' : '[$index]'} · ${modern ? 'examples[0]' : 'example'}',
              );
              final context = (choice['schemaContext'] as List).single as Map;
              expect(context['keyword'], keyword);
              expect(context['selector'], conditional ? null : '$index');
              expect(context['source']['resource'], rootBuffer.id);
              expect(
                context['source']['pointer'],
                endsWith('/$keyword${conditional ? '' : '/$index'}'),
              );
              final draft = OperationRequestDraft(
                planIdentity: captured.identity,
                body: RequestBodyDraft.raw(
                  mediaType: 'application/json',
                  text: choice['raw'] as String,
                ),
              );
              // Manual negative requests remain dispatchable; selecting an authored
              // branch candidate must not turn it into a whole-schema success.
              final result = await const ContractRequestExecutor().execute(
                captured,
                draft,
                resolveSecret: (_) async => null,
              );
              try {
                expect(seen[index], utf8.encode(expected[index]));
                expect(
                  result.outgoing.complete,
                  true,
                  reason: '${result.outgoing.findings}',
                );
                expect(
                  result.outgoing.valid,
                  index == 0,
                  reason: '${result.outgoing.findings}',
                );
                expect(result.received.complete, true);
                expect(result.received.valid, true);
              } finally {
                await result.close();
              }
            }
            final saved = await plan(saved: true);
            addTearDown(saved.close);
            final savedMedia =
                ((saved.result['requestBody'] as Map)['content'] as List).single
                    as Map;
            expect(
              (savedMedia['examples'] as List).first['raw'],
              expected.first.replaceFirst('Unsaved 雪😀', 'Saved'),
            );
            await project.save(rootBuffer);
            expect(await file.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(root),
            ]);
            expect(await sharedFile.readAsString(), shared);
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst('Unsaved 雪😀', 'Revised'),
            );
            expect(
              captured.ensureCurrentPreparation,
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'request.draft.stale',
                ),
              ),
            );
            final current = await plan();
            addTearDown(current.close);
            expect(current.identity, isNot(captured.identity));
            final currentMedia =
                ((current.result['requestBody'] as Map)['content'] as List)
                        .single
                    as Map;
            expect(
              (currentMedia['examples'] as List).first['raw'],
              contains('Revised'),
            );
            await expectLater(
              project.prepareRequest(
                file.uri.toString(),
                resource: file.uri.toString(),
                pointer: '/paths/~1data/post',
                cancelled: () => true,
              ),
              throwsA(
                isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
              ),
            );
            expect(seen, hasLength(2));
            expect(await sharedFile.readAsString(), shared);
          },
        );
      }
    }
  }
}
