import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory directory;
  late EngineProcess engine;
  BusyProject? project;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('busyapi-wire-repair-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    project?.close();
    project = null;
    await engine.close();
    await directory.delete(recursive: true);
  });

  Future<OperationRequestPlan> prepare(
    Map<String, Object?> document, {
    Map<String, Object?> configuration = const {},
    String? retrieval,
    String path = '/pets',
    String? method,
  }) async {
    final file = File('${directory.path}/openapi.json');
    file.writeAsStringSync(jsonEncode(document));
    File('${directory.path}/busyapi.yaml').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'roots': [
          {'name': 'api', 'path': 'openapi.json'},
        ],
        if (retrieval != null) 'resourceMappings': {retrieval: 'openapi.json'},
        ...configuration,
      }),
    );
    project = await BusyProject.open(directory.path, engine);
    final checked = await project!.check(file.uri.toString());
    final operation = (checked['projection']['operations'] as List)
        .whereType<Map>()
        .singleWhere(
          (value) =>
              value['path'] == path &&
              (method == null || value['method'] == method),
        );
    final plan = await project!.prepareRequest(
      file.uri.toString(),
      resource: operation['resource'] as String,
      pointer: operation['pointer'] as String,
      occurrence: operation['occurrence'] as String,
    );
    addTearDown(plan.close);
    return plan;
  }

  Map<String, Object?> contract(
    String version, {
    Object? servers,
    Map<String, Object?>? operation,
    Map<String, Object?> extra = const {},
  }) => {
    'openapi': version,
    'info': {'title': 'Synthetic wire checks', 'version': '1'},
    if (servers != null) 'servers': servers,
    'paths': {
      '/pets': {
        'get':
            operation ??
            {
              'responses': {
                '200': {'description': 'ok'},
              },
            },
      },
    },
    ...extra,
  };

  for (final version in ['3.1.2', '3.2.1']) {
    for (final remote in [false, true]) {
      test(
        '$version OAuth relative endpoints use the API server (remote=$remote)',
        () async {
          final intended = <String>[], unintended = <String>[];
          final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final docs = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => api.close(force: true));
          addTearDown(() => docs.close(force: true));
          void listen(HttpServer server, List<String> requests) =>
              server.listen((request) async {
                requests.add(request.uri.toString());
                await request.drain<void>();
                request.response.headers.contentType = ContentType.json;
                request.response.write(
                  '{"token_type":"Bearer","access_token":"synthetic-token"}',
                );
                await request.response.close();
              });
          listen(api, intended);
          listen(docs, unintended);
          final plan = await prepare(
            contract(
              version,
              servers: [
                {'url': 'http://127.0.0.1:${api.port}/v1/'},
              ],
              operation: {
                'security': [
                  {'oauth': <String>[]},
                ],
                'responses': {
                  '200': {'description': 'ok'},
                },
              },
              extra: {
                if (version == '3.2.1')
                  r'$self': 'https://identity.example.test/description',
                'components': {
                  'securitySchemes': {
                    'oauth': {
                      'type': 'oauth2',
                      'flows': {
                        'clientCredentials': {
                          'tokenUrl': 'oauth/token',
                          'scopes': <String, String>{},
                        },
                      },
                    },
                  },
                },
              },
            ),
            retrieval: remote
                ? 'http://127.0.0.1:${docs.port}/openapi.json'
                : null,
            configuration: {
              'environments': {
                'oauth': {
                  'authentication': {
                    'schemes': {
                      'oauth': {
                        'clientId': 'synthetic-client',
                        'clientSecretRef':
                            '123e4567-e89b-42d3-a456-426614174002',
                      },
                    },
                  },
                },
              },
            },
          );
          final token = await const OAuthClient().clientCredentials(
            plan,
            environment: 'oauth',
            scheme: 'oauth',
            resolveSecret: (_) async => 'synthetic-secret',
            cancellation: RunCancellation(),
          );
          expect(token.accessToken, 'synthetic-token');
          expect(intended, ['/v1/oauth/token']);
          expect(
            unintended,
            isEmpty,
            reason: 'Description origin must receive no credentials',
          );
        },
      );
    }
  }

  test(
    'OAuth Basic form encodes each credential exactly once on the wire',
    () async {
      final captured = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        captured.add(
          utf8.decode(
            base64.decode(request.headers.value('authorization')!.substring(6)),
          ),
        );
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"token_type":"Bearer","access_token":"synthetic-token"}',
        );
        await request.response.close();
      });
      final plan = await prepare(
        contract(
          '3.2.1',
          operation: {
            'security': [
              {'oauth': <String>[]},
            ],
            'responses': {
              '200': {'description': 'ok'},
            },
          },
          extra: {
            'components': {
              'securitySchemes': {
                'oauth': {
                  'type': 'oauth2',
                  'flows': {
                    'clientCredentials': {
                      'tokenUrl': 'http://127.0.0.1:${server.port}/token',
                      'scopes': <String, String>{},
                    },
                  },
                },
              },
            },
          },
        ),
        configuration: {
          'environments': {
            'oauth': {
              'authentication': {
                'schemes': {
                  'oauth': {
                    'clientId': 'client:alpha',
                    'clientSecretRef': '123e4567-e89b-42d3-a456-426614174002',
                  },
                },
              },
            },
          },
        },
      );
      await const OAuthClient().clientCredentials(
        plan,
        environment: 'oauth',
        scheme: 'oauth',
        resolveSecret: (_) async => 'secret+ space',
        cancellation: RunCancellation(),
      );
      expect(captured, ['client%3Aalpha:secret%2B+space']);
    },
  );
  for (final version in ['3.1.2', '3.2.1']) {
    for (final reversed in [false, true]) {
      test(
        '$version most specific content wins (reversed=$reversed)',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            await request.drain<void>();
            request.response.headers.contentType = ContentType.json;
            request.response.write('"bad"');
            await request.response.close();
          });
          final entries = <String, Object?>{
            '*/*': {'schema': true},
            'application/*': {
              'schema': {'type': 'string'},
            },
            'application/json': {
              'schema': {'type': 'integer'},
            },
          };
          final content = Map<String, Object?>.fromEntries(
            reversed ? entries.entries.toList().reversed : entries.entries,
          );
          final plan = await prepare(
            contract(
              version,
              servers: [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              operation: {
                'requestBody': {'content': content},
                'responses': {
                  '200': {'description': 'ok', 'content': content},
                },
              },
            ),
          );
          expect(
            (plan.result['responses'] as List).single['content'].map(
              (v) => v['mediaType'],
            ),
            content.keys,
          );
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: const RequestBodyDraft.raw(
                mediaType: 'application/json',
                text: '"bad"',
              ),
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(result.outgoing.complete, true);
          expect(result.outgoing.valid, false);
          expect(result.received.complete, true);
          expect(result.received.valid, false);
          expect(result.conforming, false);
          final review = await plan.planResponseExample(
            '"reviewed"',
            status: 200,
            headers: result.response.headers,
            receiptComplete: true,
            redacted: true,
          );
          expect(
            review.result['to']['pointer'],
            endsWith('/content/application~1json/example'),
          );
          await project!.applyRefactoring(review);
          final edited = jsonDecode(
            (await project!.buffer(plan.snapshot.root)).text,
          ) as Map;
          final authored =
              edited['paths']['/pets']['get']['responses']['200']['content']
                  as Map;
          expect(authored['application/json']['example'], 'reviewed');
          expect(authored['*/*'].containsKey('example'), false);
          expect(authored.keys, content.keys);
        },
      );
    }
    test(
      '$version constrained text response reports its schema violation and cannot pass a case',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.text;
          request.response.write('BAD');
          await request.response.close();
        });
        final plan = await prepare(
          contract(
            version,
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            operation: {
              'responses': {
                '200': {
                  'description': 'ok',
                  'content': {
                    'text/plain': {
                      'schema': {'type': 'string', 'pattern': r'^OK$'},
                    },
                  },
                },
              },
            },
          ),
          configuration: {
            'tests': [
              {
                'name': 'text',
                'operation': {'method': 'GET', 'path': '/pets'},
              },
            ],
          },
        );
        final report = await const ContractTestRunner().run(
          project!,
          plan.snapshot.root,
          selectedCases: ['text'],
          resolveSecret: (_) async => null,
        );
        expect(report.complete, true);
        expect(report.passed, false);
        expect(report.cases.single.complete, true);
        expect(report.cases.single.passed, false);
        expect(report.toJson()['status'], 'failed');
        expect(
          report.cases.single.findings.any(
            (f) => f['code'] == 'runtime.schema.incompatible',
          ),
          true,
        );
      },
    );
    test('$version empty root servers have the usable default', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final targets = <String>[];
      server.listen((request) async {
        targets.add(request.uri.toString());
        request.response.statusCode = 204;
        await request.response.close();
      });
      final plan = await prepare(
        contract(version, servers: []),
        retrieval: 'http://127.0.0.1:${server.port}/descriptions/api.json',
      );
      final built = await const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(planIdentity: plan.identity),
        resolveSecret: (_) async => null,
      );
      expect(built.uri.toString(), 'http://127.0.0.1:${server.port}/pets');
      final response = await const ContractHttpTransport().send(built);
      addTearDown(response.close);
      expect(targets, ['/pets']);
    });
    test(
      '$version non-exploded query encodes data before structural commas',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final targets = <String>[];
        server.listen((socket) async {
          final bytes = <int>[];
          await for (final chunk in socket) {
            bytes.addAll(chunk);
            final text = ascii.decode(bytes);
            if (!text.contains('\r\n\r\n')) continue;
            // Inspect the request-target bytes before any HTTP URI parsing.
            targets.add(text.split('\r\n').first.split(' ')[1]);
            socket.write(
              'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
            );
            await socket.flush();
            await socket.close();
            break;
          }
        });
        final plan = await prepare(
          contract(
            version,
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            operation: {
              'parameters': [
                {
                  'name': 'id',
                  'in': 'query',
                  'style': 'form',
                  'explode': false,
                  'schema': {},
                },
                {
                  'name': 'reserved',
                  'in': 'query',
                  'allowReserved': true,
                  'schema': {'type': 'string'},
                },
              ],
              'responses': {
                '204': {'description': 'ok'},
              },
            },
          ),
        );
        for (final sample in [
          ('["a,b","c"]', 'id=a%2Cb,c'),
          (
            '{"a,b":"雪 &?#=","empty":""}',
            'id=a%2Cb,%E9%9B%AA%20%26%3F%23%3D,empty,',
          ),
          ('["",""]', 'id=,'),
        ]) {
          final built = await const ContractRequestBuilder().build(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: {
                OperationRequestDraft.parameterKey('query', 'id'):
                    RequestValue.json(sample.$1),
              },
            ),
            resolveSecret: (_) async => null,
          );
          final response = await const ContractHttpTransport().send(built);
          await response.close();
          expect(targets.last, '/pets?${sample.$2}');
        }
        const reserved = 'a&injected=1#frag?x/雪';
        final built = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: {
              OperationRequestDraft.parameterKey('query', 'reserved'):
                  const RequestValue.text(reserved),
            },
          ),
          resolveSecret: (_) async => null,
        );
        final response = await const ContractHttpTransport().send(built);
        await response.close();
        expect(
          targets.last,
          '/pets?reserved=a%26injected%3D1%23frag?x/%E9%9B%AA',
        );
        expect(Uri.parse(targets.last).hasFragment, false);
        expect(Uri.parse(targets.last).queryParameters, {'reserved': reserved});
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final reverse in [false, true]) {
      test(
        'F04 $version exact mock bytes follow Prism selection reverse=$reverse',
        () async {
          Map<String, Object?> response(String label) => {
            'description': label,
            'content': {
              'application/json': {
                'examples': {
                  'named': {
                    'value': {r'$ref': label, 'amount': 9007199254740993},
                  },
                },
              },
            },
          };
          Map<String, Object?> operation(
            String label, {
            bool template = false,
          }) => {
            if (template)
              'parameters': [
                {
                  'name': 'id',
                  'in': 'path',
                  'required': true,
                  'schema': {'type': 'string'},
                },
              ],
            'responses': reverse
                ? {
                    '200': response('$label-exact'),
                    '2XX': response('$label-range'),
                    'default': response('$label-default'),
                  }
                : {
                    '2XX': response('$label-range'),
                    '200': response('$label-exact'),
                    'default': response('$label-default'),
                  },
          };
          final paths = <String, Object?>{
            '/pets/{id}': {'get': operation('template', template: true)},
            '/pets/special': {'get': operation('concrete')},
          };
          final plan = await prepare(
            contract(
              version,
              extra: {
                'paths': Map.fromEntries(
                  reverse ? paths.entries.toList().reversed : paths.entries,
                ),
              },
            ),
            path: '/pets/special',
          );
          final mockPlan = await project!.prepareMock(plan.snapshot.root);
          addTearDown(mockPlan.close);
          final run = await mockPlan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(run.stop);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          for (final sample in [
            ('/pets/special', 200, 'concrete-exact'),
            ('/pets/other', 200, 'template-exact'),
            ('/pets/special', 201, 'concrete-range'),
            ('/pets/special', 404, 'concrete-default'),
          ]) {
            final request = await client.getUrl(run.baseUri.resolve(sample.$1));
            request.headers.set('prefer', 'code=${sample.$2}, example=named');
            final response = await request.close();
            final text = await utf8.decoder.bind(response).join();
            expect(response.statusCode, sample.$2, reason: text);
            expect(text, contains('"\u0024ref":"${sample.$3}"'));
            expect(text, contains('9007199254740993'));
            expect(response.headers.value('sl-violations'), isNull);
          }
          await run.stop();
          expect(await run.exitCode, 0);
        },
      );
    }
    test(
      'F05 $version response headers follow declared representations',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final wire = <String, String>{
          'X-Limit': '9007199254740993',
          'X-Flag': 'true',
          'X-String': '42',
          'X-Array': '1,2',
          'X-Object': 'a=1,b=true',
          'X-Json': '{"n":9007199254740993}',
        };
        server.listen((request) async {
          for (final header in wire.entries) {
            request.response.headers.set(header.key, header.value);
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write('{}');
          await request.response.close();
        });
        final plan = await prepare(
          contract(
            version,
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            operation: {
              'responses': {
                '200': {
                  'description': 'ok',
                  'headers': {
                    'X-Limit': {
                      'schema': {r'$ref': '#/components/schemas/Exact'},
                    },
                    'X-Flag': {
                      'schema': {
                        'allOf': [
                          {'type': 'boolean'},
                        ],
                      },
                    },
                    'X-String': {
                      'schema': {'type': 'string', 'const': '42'},
                    },
                    'X-Array': {
                      'schema': {
                        'type': 'array',
                        'items': {'type': 'integer'},
                      },
                    },
                    'X-Object': {
                      'style': 'simple',
                      'explode': true,
                      'schema': {
                        'type': 'object',
                        'properties': {
                          'a': {'type': 'integer'},
                          'b': {'type': 'boolean'},
                        },
                        'required': ['a', 'b'],
                      },
                    },
                    'X-Json': {
                      'content': {
                        'application/json': {
                          'schema': {
                            'type': 'object',
                            'properties': {
                              'n': {
                                'type': 'integer',
                                'const': 9007199254740993,
                              },
                            },
                          },
                        },
                      },
                    },
                    'Content-Type': {'schema': false},
                  },
                  'content': {
                    'application/json': {
                      'schema': {'type': 'object'},
                    },
                  },
                },
              },
            },
            extra: {
              'components': {
                'schemas': {
                  'Exact': {'type': 'integer', 'const': 9007199254740993},
                },
              },
            },
          ),
        );
        Future<ContractRequestResult> execute() =>
            const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(planIdentity: plan.identity),
              resolveSecret: (_) async => null,
            );
        final valid = await execute();
        addTearDown(valid.close);
        expect(valid.received.complete, true);
        expect(
          valid.received.valid,
          true,
          reason: '${valid.received.findings}',
        );
        wire['X-Limit'] = 'not-an-integer';
        wire['X-Json'] = '{"n":"bad"}';
        final invalid = await execute();
        addTearDown(invalid.close);
        expect(invalid.received.complete, true);
        expect(invalid.received.valid, false);
        expect(
          invalid.received.findings.any((f) => f['location'] == 'X-Json'),
          true,
        );
      },
    );
  }
  test(
    'F07 exact custom identity never authorizes a rewritten wire method',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final lines = <String>[];
      listener.listen((socket) async {
        final bytes = <int>[];
        await for (final chunk in socket) {
          bytes.addAll(chunk);
          if (ascii.decode(bytes).contains('\r\n\r\n')) {
            lines.add(ascii.decode(bytes).split('\r\n').first);
            socket.write(
              'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
            );
            await socket.flush();
            await socket.close();
            break;
          }
        }
      });
      final operation = {
        'responses': {
          '204': {'description': 'ok'},
        },
      };
      final plan = await prepare(
        contract(
          '3.2.1',
          servers: [
            {'url': 'http://127.0.0.1:${listener.port}'},
          ],
          extra: {
            'paths': {
              '/pets': {
                'get': operation,
                'post': operation,
                'query': operation,
                'additionalOperations': {
                  'purge': operation,
                  'PURGE': operation,
                },
              },
            },
          },
        ),
        method: 'purge',
        configuration: {
          'tests': [
            {
              'name': 'lower',
              'operation': {'method': 'purge', 'path': '/pets'},
            },
            {
              'name': 'upper',
              'operation': {'method': 'PURGE', 'path': '/pets'},
            },
          ],
        },
      );
      final built = await const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(planIdentity: plan.identity),
        resolveSecret: (_) async => null,
      );

      expect(built.method, 'purge');
      await expectLater(
        const ContractHttpTransport().send(built),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'unsupported transport',
            'request.method.unsupported',
          ),
        ),
      );
      expect(lines, isEmpty);
      final checked = await project!.check(plan.snapshot.root);
      final operations = (checked['projection']['operations'] as List)
          .whereType<Map>()
          .toList();
      expect(
        operations
            .where((o) => o['customMethod'] == true)
            .map((o) => o['method']),
        ['purge', 'PURGE'],
      );
      final found = await project!.semanticSearch().run(
        'pets',
        category: 'operations',
      );
      expect(found.complete, true);
      expect(found.matches.map((value) => value['label']), [
        'GET · /pets',
        'POST · /pets',
        'QUERY · /pets',
        'purge · /pets',
        'PURGE · /pets',
      ]);
      for (final method in ['get', 'post', 'query', 'PURGE']) {
        final operation = operations.singleWhere((o) => o['method'] == method);
        final selected = await project!.prepareRequest(
          plan.snapshot.root,
          resource: operation['resource'] as String,
          pointer: operation['pointer'] as String,
          occurrence: operation['occurrence'] as String,
        );
        addTearDown(selected.close);
        final control = await const ContractRequestBuilder().build(
          selected,
          OperationRequestDraft(planIdentity: selected.identity),
          resolveSecret: (_) async => null,
        );
        final response = await const ContractHttpTransport().send(control);
        await response.close();
        expect(lines.last, '${method.toUpperCase()} /pets HTTP/1.1');
      }
      final report = await const ContractTestRunner().run(
        project!,
        plan.snapshot.root,
        selectedCases: ['lower', 'upper'],
        resolveSecret: (_) async => null,
      );
      expect(report.complete, false);
      expect(report.cases.first.operation, 'purge /pets');
      expect(report.cases.first.complete, false);
      expect(report.cases.first.operationalFailure, false);
      expect(report.cases.last.operation, 'PURGE /pets');
      expect(report.cases.last.passed, true);
      expect(lines, [
        'GET /pets HTTP/1.1',
        'POST /pets HTTP/1.1',
        'QUERY /pets HTTP/1.1',
        'PURGE /pets HTTP/1.1',
        'PURGE /pets HTTP/1.1',
      ]);
    },
  );
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'F16 $version explicit no-auth must not revive an environment alternative',
      () async {
        final requests = <String?>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          requests.add(request.headers.value('authorization'));
          expect(await utf8.decoder.bind(request).join(), 'retained body');
          expect(request.uri.queryParameters['name'], 'retained parameter');
          expect(request.headers.value('x-retained'), 'retained header');
          request.response.statusCode = 204;
          await request.response.close();
        });
        final plan = await prepare(
          contract(
            version,
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            operation: {
              'security': [],
              'parameters': [
                {
                  'name': 'name',
                  'in': 'query',
                  'schema': {'type': 'string'},
                },
              ],
              'requestBody': {
                'content': {
                  'text/plain': {'schema': true},
                },
              },
              'responses': {
                '204': {'description': 'ok'},
              },
            },
            extra: {
              'security': [
                {'old': <String>[]},
              ],
              'components': {
                'securitySchemes': {
                  'old': {'type': 'http', 'scheme': 'bearer'},
                },
              },
            },
          ),
          configuration: {
            'environments': {
              'selected': {
                'authentication': {
                  'alternative': 0,
                  'schemes': {
                    'old': {'tokenRef': '123e4567-e89b-42d3-a456-426614174002'},
                  },
                },
              },
            },
          },
        );
        var secrets = 0;
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'selected',
            parameters: {
              OperationRequestDraft.parameterKey('query', 'name'):
                  const RequestValue.text('retained parameter'),
            },
            headers: [
              const RequestHeaderValue('X-Retained', 'retained header'),
            ],
            body: const RequestBodyDraft.raw(
              mediaType: 'text/plain',
              text: 'retained body',
            ),
          ),
          resolveSecret: (_) async {
            secrets++;
            return 'must-not-be-attached';
          },
        );
        addTearDown(result.close);
        expect(secrets, 0);
        expect(requests, [null]);
        expect(result.request.securityAlternative, isNull);
        expect(result.conforming, true);
      },
    );
  }
  for (final scenario in [
    'root-selection',
    'path',
    'operation',
    'variables',
    'override',
    'file-base',
    'retrieval-base',
  ]) {
    test('F01 effective OAuth server uses $scenario and relative authorization', () async {
      final requests = <String>[];
      final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => api.close(force: true));
      api.listen((request) async {
        requests.add(request.uri.path);
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"token_type":"Bearer","access_token":"synthetic","refresh_token":"retained-only"}',
        );
        await request.response.close();
      });
      final origin = 'http://127.0.0.1:${api.port}';
      final expected = scenario == 'file-base' ? '/' : '/$scenario/';
      final server = scenario == 'variables'
          ? {
              'url': '$origin/{version}/',
              'variables': {
                'version': {'default': 'default'},
              },
            }
          : scenario == 'retrieval-base'
          ? {'url': '../retrieval-base/'}
          : {
              'url':
                  '$origin${scenario == 'file-base' ? '/file-base' : expected}',
            };
      final operation = <String, Object?>{
        if (scenario == 'operation') 'servers': [server],
        'security': [
          {'oauth': <String>[]},
        ],
        'responses': {
          '200': {'description': 'ok'},
        },
      };
      final document = contract(
        '3.2.1',
        servers: scenario == 'root-selection'
            ? [
                {'url': 'http://127.0.0.1:1/wrong/'},
                server,
              ]
            : [
                scenario == 'path' ||
                        scenario == 'operation' ||
                        scenario == 'override'
                    ? {'url': 'http://127.0.0.1:1/wrong/'}
                    : server,
              ],
        extra: {
          r'$self': 'https://identity.example.test/ignored-api-base',
          'paths': {
            '/pets': {
              if (scenario == 'path') 'servers': [server],
              'get': operation,
            },
          },
          'components': {
            'securitySchemes': {
              'oauth': {
                'type': 'oauth2',
                'flows': {
                  'clientCredentials': {
                    'tokenUrl': 'oauth/token',
                    'scopes': <String, String>{},
                  },
                  'authorizationCode': {
                    'authorizationUrl': 'oauth/authorize',
                    'tokenUrl': 'oauth/token',
                    'scopes': <String, String>{},
                  },
                },
              },
            },
          },
        },
      );
      final plan = await prepare(
        document,
        retrieval: scenario == 'retrieval-base'
            ? '$origin/descriptions/openapi.json'
            : null,
        configuration: {
          'environments': {
            'selected': {
              if (scenario == 'variables')
                'variables': {'version': 'variables'},
              if (scenario == 'override') 'baseUrl': '$origin/override/',
              'authentication': {
                'schemes': {
                  'oauth': {
                    'clientId': 'synthetic',
                    'clientSecretRef': '123e4567-e89b-42d3-a456-426614174002',
                  },
                },
              },
            },
          },
        },
      );
      final draft = OperationRequestDraft(
        planIdentity: plan.identity,
        environment: 'selected',
        server: scenario == 'root-selection' ? 1 : 0,
      );
      final token = await const OAuthClient().clientCredentials(
        plan,
        environment: 'selected',
        scheme: 'oauth',
        draft: draft,
        resolveSecret: (_) async => 'synthetic',
        cancellation: RunCancellation(),
      );
      expect(token.refreshToken, 'retained-only');
      expect(requests, ['${expected}oauth/token']);
      final callback = Completer<void>();
      final authorization = await const OAuthClient().authorizationCode(
        plan,
        environment: 'selected',
        scheme: 'oauth',
        draft: draft,
        resolveSecret: (_) async => 'synthetic',
        cancellation: RunCancellation(),
        launchBrowser: (uri) async {
          expect(uri.origin, origin);
          expect(uri.path, '${expected}oauth/authorize');
          unawaited(() async {
            final client = HttpClient();
            try {
              await (await (await client.getUrl(uri)).close()).drain<void>();
              final target = Uri.parse(uri.queryParameters['redirect_uri']!)
                  .replace(
                    queryParameters: {
                      'state': uri.queryParameters['state']!,
                      'code': 'synthetic-code',
                    },
                  );
              await (await (await client.getUrl(target)).close()).drain<void>();
              callback.complete();
            } catch (error, stack) {
              callback.completeError(error, stack);
            } finally {
              client.close(force: true);
            }
          }());
        },
      );
      await callback.future;
      expect(authorization.accessToken, 'synthetic');
      expect(requests, [
        '${expected}oauth/token',
        '${expected}oauth/authorize',
        '${expected}oauth/token',
      ]);
    });
  }
  for (final retirement in ['close', 'cancel', 'edit']) {
    test(
      'F01 no OAuth credentials leave after delayed secret $retirement',
      () async {
        var connections = 0;
        final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => endpoint.close(force: true));
        endpoint.listen((request) async {
          connections++;
          request.response.write(
            '{"token_type":"Bearer","access_token":"unexpected"}',
          );
          await request.response.close();
        });
        final plan = await prepare(
          contract(
            '3.2.1',
            operation: {
              'security': [
                {'oauth': <String>[]},
              ],
              'responses': {
                '200': {'description': 'ok'},
              },
            },
            extra: {
              'components': {
                'securitySchemes': {
                  'oauth': {
                    'type': 'oauth2',
                    'flows': {
                      'clientCredentials': {
                        'tokenUrl': 'http://127.0.0.1:${endpoint.port}/token',
                        'scopes': <String, String>{},
                      },
                    },
                  },
                },
              },
            },
          ),
          configuration: {
            'environments': {
              'selected': {
                'authentication': {
                  'schemes': {
                    'oauth': {
                      'clientId': 'synthetic',
                      'clientSecretRef': '123e4567-e89b-42d3-a456-426614174002',
                    },
                  },
                },
              },
            },
          },
        );
        final entered = Completer<void>(),
            release = Completer<String?>(),
            cancellation = RunCancellation();
        final issued = const OAuthClient().clientCredentials(
          plan,
          environment: 'selected',
          scheme: 'oauth',
          cancellation: cancellation,
          resolveSecret: (_) {
            entered.complete();
            return release.future;
          },
        );
        final assertion = expectLater(issued, throwsA(isA<CoreFailure>()));
        await entered.future;
        if (retirement == 'close') plan.close();
        if (retirement == 'cancel') cancellation.cancel();
        if (retirement == 'edit') {
          final buffer = await project!.buffer(plan.snapshot.root);
          project!.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Synthetic wire checks', 'New input'),
          );
        }
        release.complete('synthetic-must-not-leave');
        await assertion;
        expect(connections, 0);
      },
    );
  }
  for (final sample in [
    ('plain', 'ordinary', 'plain:ordinary'),
    ('a%20b', '%', 'a%2520b:%25'),
    ('client雪', 'secrét😀', 'client%E9%9B%AA:secr%C3%A9t%F0%9F%98%80'),
    ('id', '', 'id:'),
    ('a+b', ' x ', 'a%2Bb:+x+'),
  ]) {
    test('F09 OAuth Basic prescribed encoding ${sample.$3}', () async {
      final captured = <String>[];
      final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => endpoint.close(force: true));
      endpoint.listen((request) async {
        captured.add(
          utf8.decode(
            base64.decode(request.headers.value('authorization')!.substring(6)),
          ),
        );
        await request.drain<void>();
        request.response.write(
          '{"token_type":"Bearer","access_token":"synthetic"}',
        );
        await request.response.close();
      });
      final plan = await prepare(
        contract(
          '3.1.2',
          operation: {
            'security': [
              {'oauth': <String>[]},
            ],
            'responses': {
              '200': {'description': 'ok'},
            },
          },
          extra: {
            'components': {
              'securitySchemes': {
                'oauth': {
                  'type': 'oauth2',
                  'flows': {
                    'clientCredentials': {
                      'tokenUrl': 'http://127.0.0.1:${endpoint.port}/token',
                      'scopes': <String, String>{},
                    },
                  },
                },
              },
            },
          },
        ),
        configuration: {
          'environments': {
            'selected': {
              'authentication': {
                'schemes': {
                  'oauth': {
                    'clientId': sample.$1,
                    'clientSecretRef': '123e4567-e89b-42d3-a456-426614174002',
                  },
                },
              },
            },
          },
        },
      );
      await const OAuthClient().clientCredentials(
        plan,
        environment: 'selected',
        scheme: 'oauth',
        cancellation: RunCancellation(),
        resolveSecret: (_) async => sample.$2,
      );
      expect(captured, [sample.$3]);
      final split = captured.single.indexOf(':');
      expect(
        Uri.decodeQueryComponent(captured.single.substring(0, split)),
        sample.$1,
      );
      expect(
        Uri.decodeQueryComponent(captured.single.substring(split + 1)),
        sample.$2,
      );
    });
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final represented in [true, false]) {
      test(
        'F03 $version CLI and JUnit distinguish known text violations from unknown media: $represented',
        () async {
          final mediaType = represented
              ? 'text/plain'
              : 'application/x-undefined';
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            await request.drain<void>();
            request.response.headers.set('content-type', mediaType);
            request.response.write('BAD');
            await request.response.close();
          });
          await prepare(
            contract(
              version,
              servers: [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              operation: {
                'responses': {
                  '200': {
                    'description': 'ok',
                    'content': {
                      mediaType: {
                        'schema': {'type': 'string', 'pattern': r'^OK$'},
                      },
                    },
                  },
                },
              },
            ),
            configuration: {
              'tests': [
                {
                  'name': 'selected',
                  'operation': {'method': 'GET', 'path': '/pets'},
                },
              ],
            },
          );
          final junit = '${directory.path}/report.xml';
          final result = await Process.run(
            '$testBundle/busyapi',
            [
              'test',
              directory.path,
              '--case',
              'selected',
              '--json',
              '--junit',
              junit,
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            result.exitCode,
            represented ? 1 : 2,
            reason: '${result.stderr}\n${result.stdout}',
          );
          final machine = jsonDecode(result.stdout as String) as Map;
          expect(machine['complete'], represented);
          expect(machine['passed'], false);
          expect(machine['cases'].single['passed'], false);
          final xml = await File(junit).readAsString();
          expect(
            xml,
            contains(
              represented
                  ? 'tests="1" failures="1" errors="0"'
                  : 'tests="1" failures="0" errors="1"',
            ),
          );
          expect(xml, contains('name="complete" value="$represented"'));
          expect(xml, contains(represented ? '<failure' : '<error'));
        },
      );
    }
    test(
      'F03 $version representation and input limits retain honest request coverage',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final sizes = <int>[];
        server.listen((request) async {
          sizes.add(
            (await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            )).length,
          );
          request.response.statusCode = 204;
          await request.response.close();
        });
        final plan = await prepare(
          contract(
            version,
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            operation: {
              'requestBody': {
                'content': {
                  for (final type in [
                    'application/json',
                    'application/x-www-form-urlencoded',
                    'multipart/form-data',
                  ])
                    type: {
                      'schema': {'type': 'object'},
                    },
                },
              },
              'responses': {
                '204': {'description': 'ok'},
              },
            },
          ),
        );
        final bodies = <RequestBodyDraft>[
          const RequestBodyDraft.raw(
            mediaType: 'application/json',
            text: '{"a":1}',
          ),
          const RequestBodyDraft.raw(
            mediaType: 'application/json',
            text: '{"a":"large"}',
          ),
          const RequestBodyDraft.form([RequestFormField('a', '1')]),
          const RequestBodyDraft.multipart([RequestFormField('a', '1')], []),
        ];
        for (var i = 0; i < bodies.length; i++) {
          final result =
              await const ContractRequestExecutor(maximumEvaluationBytes: 8)
                  .execute(
                    plan,
                    OperationRequestDraft(
                      planIdentity: plan.identity,
                      body: bodies[i],
                    ),
                    resolveSecret: (_) async => null,
                  );
          addTearDown(result.close);
          expect(result.outgoing.complete, i == 0);
          expect(result.conforming, i == 0);
          final record = ContractRequestRecord.fromResult(
            result,
            recordedAt: DateTime.utc(2026),
          );
          expect(record.conformanceComplete, i == 0);
          expect(record.toJson()['conformance'], {
            'complete': i == 0,
            'conforming': i == 0,
          });
        }
        expect(sizes, everyElement(greaterThan(0)));
      },
    );
    for (final schema in [
      true,
      <String, Object?>{},
      {'description': 'No instance constraint'},
    ]) {
      test(
        'F03 $version unconstrained plain content remains complete: $schema',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            await request.drain<void>();
            request.response.headers.contentType = ContentType.text;
            request.response.write('BAD');
            await request.response.close();
          });
          final plan = await prepare(
            contract(
              version,
              servers: [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              operation: {
                'requestBody': {
                  'content': {
                    'text/plain': {'schema': schema},
                  },
                },
                'responses': {
                  '200': {
                    'description': 'ok',
                    'content': {
                      'text/plain': {'schema': schema},
                    },
                  },
                },
              },
            ),
          );
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: const RequestBodyDraft.raw(
                mediaType: 'text/plain',
                text: 'BAD',
              ),
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(result.conforming, true);
        },
      );
    }
  }
  test('F02 parameters retain value case and select the specific authored destination', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var media = 'application/json;profile=Case', body = '"value"';
    final sent = <String>[];
    server.listen((request) async {
      sent.add(request.headers.value('content-type') ?? '');
      await request.drain<void>();
      request.response.headers.set('content-type', media);
      request.response.write(body);
      await request.response.close();
    });
    final content = {
      '*/*': {'schema': true},
      'application/*': {
        'schema': {'type': 'number'},
      },
      'application/json': {
        'schema': {'type': 'integer'},
      },
      'application/json;profile=Case': {
        'schema': {'type': 'string'},
      },
      'application/json;profile=case': {
        'schema': {'type': 'boolean'},
      },
      'application/json;charset=UTF-8;profile=Case': {'schema': false},
    };
    final plan = await prepare(
      contract(
        '3.2.1',
        servers: [
          {'url': 'http://127.0.0.1:${server.port}'},
        ],
        operation: {
          'requestBody': {'content': content},
          'responses': {
            '200': {'description': 'ok', 'content': content},
          },
        },
      ),
    );
    for (final sample in [
      ('Application/JSON;Profile="Case"', '"value"', true),
      ('application/json;profile=case', 'false', true),
      ('application/json;profile=CASE', '"value"', false),
      ('application/json;CHARSET=utf-8;profile=Case', '"value"', false),
      ('text/plain', '"value"', true),
    ]) {
      media = sample.$1;
      body = sample.$2;
      final result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: RequestBodyDraft.raw(mediaType: media, text: body),
        ),
        resolveSecret: (_) async => null,
      );
      addTearDown(result.close);
      expect(result.outgoing.valid, sample.$3, reason: media);
      expect(result.received.valid, sample.$3, reason: media);
      expect(sent.last, media);
    }
    media = 'application/json;profile=Case';
    body = '"reviewed"';
    final result = await const ContractRequestExecutor().execute(
      plan,
      OperationRequestDraft(planIdentity: plan.identity),
      resolveSecret: (_) async => null,
    );
    addTearDown(result.close);
    final review = await plan.planResponseExample(
      body,
      status: 200,
      headers: result.response.headers,
      receiptComplete: true,
      redacted: true,
    );
    expect(
      review.result['to']['pointer'],
      endsWith('/content/application~1json;profile=Case/example'),
    );
    await project!.applyRefactoring(review);
    final edited =
        jsonDecode((await project!.buffer(plan.snapshot.root)).text) as Map;
    final authored =
        edited['paths']['/pets']['get']['responses']['200']['content'] as Map;
    expect(authored['application/json;profile=Case']['example'], 'reviewed');
    expect(authored['application/json'].containsKey('example'), false);
    expect(authored.keys, content.keys);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'F05 $version ambiguous and repeated header representations remain honest',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var values = <String>['1', '2'];
        var name = 'X-Value';
        server.listen((request) async {
          request.response.headers.noFolding(name);
          for (final value in values) {
            request.response.headers.add(name, value);
          }
          request.response.statusCode = 204;
          await request.response.close();
        });
        // One plan per operation keeps every case tied to its actual declaration.
        final cases =
            <(String, Map<String, Object?>, List<String>, bool, bool)>[
              (
                'array',
                {
                  'schema': {
                    'type': 'array',
                    'items': {'type': 'integer'},
                  },
                },
                ['1', '2'],
                true,
                true,
              ),
              (
                'object',
                {
                  'schema': {
                    'type': 'object',
                    'properties': {
                      'a': {'type': 'integer'},
                      'b': {'type': 'string'},
                    },
                  },
                },
                ['a,1,b,42'],
                true,
                true,
              ),
              (
                'invalid',
                {
                  'schema': {'type': 'boolean'},
                },
                ['not-a-boolean'],
                true,
                false,
              ),
              (
                'untyped',
                {
                  'schema': {'pattern': '^OK'},
                },
                ['BAD'],
                false,
                true,
              ),
              (
                'union',
                {
                  'schema': {
                    'type': ['integer', 'string'],
                  },
                },
                ['42'],
                false,
                true,
              ),
              (
                'repeated-scalar',
                {
                  'schema': {'type': 'string'},
                },
                ['a', 'b'],
                false,
                true,
              ),
              (
                'unknown-content',
                {
                  'content': {
                    'application/cbor': {
                      'schema': {'type': 'object'},
                    },
                  },
                },
                ['opaque'],
                false,
                true,
              ),
            ];
        final paths = <String, Object?>{
          for (final item in cases)
            '/${item.$1}': {
              'get': {
                'responses': {
                  '204': {
                    'description': 'ok',
                    'headers': {'X-Value': item.$2},
                  },
                },
              },
            },
        };
        paths['/cookies'] = {
          'get': {
            'responses': {
              '204': {
                'description': 'ok',
                'headers': {
                  'Set-Cookie': {
                    'explode': true,
                    'schema': {
                      'type': 'object',
                      'properties': {
                        'lang': {
                          'type': 'string',
                          'const':
                              'en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT',
                        },
                        'foo': {'type': 'string', 'const': 'bar'},
                      },
                      'required': ['lang', 'foo'],
                    },
                  },
                },
              },
            },
          },
        };
        final first = await prepare(
          contract(
            version,
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            extra: {'paths': paths},
          ),
          path: '/array',
        );
        final checked = await project!.check(first.snapshot.root);
        final operations = (checked['projection']['operations'] as List)
            .whereType<Map>();
        for (final sample in [
          ...cases,
          (
            'cookies',
            <String, Object?>{},
            ['lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT', 'foo=bar'],
            version == '3.2.1',
            true,
          ),
        ]) {
          name = sample.$1 == 'cookies' ? 'Set-Cookie' : 'X-Value';
          values = sample.$3;
          final operation = operations.singleWhere(
            (o) => o['path'] == '/${sample.$1}',
          );
          final plan = await project!.prepareRequest(
            first.snapshot.root,
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(planIdentity: plan.identity),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(result.received.complete, sample.$4, reason: sample.$1);
          expect(
            result.received.valid,
            sample.$5,
            reason: '${sample.$1}: ${result.received.findings}',
          );
          if (sample.$1 == 'cookies')
            expect(
              result.response.headers
                  .where((h) => h.$1.toLowerCase() == 'set-cookie')
                  .map((h) => h.$2),
              values,
            );
        }
      },
    );
  }
  for (final schema in [true, <String, Object?>{}]) {
    test(
      'F03 unconstrained schemas still require JSON syntax: $schema',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          request.response.headers.set('content-type', 'application/json');
          request.response.headers.set('X-Json', 'BAD');
          request.response.write('BAD');
          await request.response.close();
        });
        final plan = await prepare(
          contract(
            '3.2.1',
            servers: [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            operation: {
              'requestBody': {
                'content': {
                  'application/json': {'schema': schema},
                },
              },
              'responses': {
                '200': {
                  'description': 'ok',
                  'headers': {
                    'X-Json': {
                      'content': {
                        'application/json': {'schema': schema},
                      },
                    },
                  },
                  'content': {
                    'application/json': {'schema': schema},
                  },
                },
              },
            },
          ),
        );
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: const RequestBodyDraft.raw(
              mediaType: 'application/json',
              text: 'BAD',
            ),
          ),
          resolveSecret: (_) async => null,
        );
        addTearDown(result.close);
        expect(result.outgoing.complete, true);
        expect(result.outgoing.valid, false);
        expect(result.received.complete, true);
        expect(result.received.valid, false);
        expect(
          result.received.findings.any(
            (finding) => finding['location'] == 'X-Json',
          ),
          true,
        );
        expect(result.conforming, false);
      },
    );
  }

  for (final version in ['3.1.2', '3.2.1']) {
    for (final empty in [false, true]) {
      test(
        'F06 local root default uses an explicit environment $version empty=$empty',
        () async {
          final requests = <String>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            requests.add(request.uri.toString());
            request.response.statusCode = 204;
            await request.response.close();
          });
          final plan = await prepare(
            contract(
              version,
              servers: empty ? [] : null,
              operation: {
                'responses': {
                  '204': {'description': 'ok'},
                },
              },
            ),
            configuration: {
              'environments': {
                'local': {'baseUrl': 'http://127.0.0.1:${server.port}'},
              },
            },
          );
          const builder = ContractRequestBuilder();
          await expectLater(
            builder.build(
              plan,
              OperationRequestDraft(planIdentity: plan.identity),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'request.server.relative',
              ),
            ),
          );
          await expectLater(
            builder.build(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                environment: 'local',
                server: 99,
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'request.server',
              ),
            ),
          );
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              environment: 'local',
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(result.conforming, true);
          expect(
            result.request.uri.toString(),
            'http://127.0.0.1:${server.port}/pets',
          );
          expect(requests, ['/pets']);
        },
      );
    }
  }
}
