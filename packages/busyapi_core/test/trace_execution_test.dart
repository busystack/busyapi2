import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _TraceWire {
  _TraceWire(this.server) {
    server.listen((socket) async {
      connections++;
      sockets.add(socket);
      try {
        final bytes = <int>[];
        await for (final chunk in socket) {
          bytes.addAll(chunk);
          if (bytes.length > 32768) throw StateError('Fixture wire bound');
          final text = latin1.decode(bytes), end = text.indexOf('\r\n\r\n');
          if (end < 0) continue;
          final headers = text.substring(0, end);
          final length = int.parse(
            RegExp(
                  r'^content-length:\s*(\d+)',
                  caseSensitive: false,
                  multiLine: true,
                ).firstMatch(headers)?.group(1) ??
                '0',
          );
          if (bytes.length < end + 4 + length) continue;
          requests.add((
            headers: headers,
            body: bytes.sublist(end + 4, end + 4 + length),
          ));
          const response = '{"value":9007199254740993}';
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${response.length}\r\nConnection: close\r\n\r\n$response',
            ),
          );
          await socket.flush();
          await socket.close();
          break;
        }
      } finally {
        sockets.remove(socket);
        socket.destroy();
      }
    });
  }
  final ServerSocket server;
  final sockets = <Socket>{};
  final requests = <({String headers, List<int> body})>[];
  int connections = 0;
  Future<void> close() async {
    for (final socket in sockets.toList()) socket.destroy();
    await server.close();
  }
}

void main() {
  for (final version in ['3.0.4', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format compiled CLI preserves TRACE preflight and byte behavior',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-trace-cli-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final wire = _TraceWire(
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          );
          addTearDown(wire.close);
          final original = jsonEncode({
            'openapi': version,
            'info': {'title': 'TRACE CLI', 'version': '1'},
            'servers': [
              {'url': 'http://127.0.0.1:${wire.server.port}'},
            ],
            'paths': {
              '/trace': {
                'trace': {
                  'requestBody': {
                    'content': {
                      'text/plain': {
                        'schema': {'type': 'string'},
                      },
                    },
                  },
                  'responses': {
                    '200': {
                      'description': 'Observed',
                      'content': {
                        'application/json': {
                          'schema': {
                            'type': 'object',
                            'required': ['value'],
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          });
          final file = File('${temp.path}/api.$format')
            ..writeAsStringSync(original);
          final config = jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'tests': [
              {
                'name': 'bare',
                'operation': {'method': 'TRACE', 'path': '/trace'},
                'expect': {'status': 200},
              },
              {
                'name': 'body',
                'operation': {'method': 'TRACE', 'path': '/trace'},
                'body': {'mediaType': 'text/plain', 'value': 'TRACE content'},
              },
              {
                'name': 'credentials',
                'operation': {'method': 'TRACE', 'path': '/trace'},
                'headers': {'Authorization': 'fixture-credential'},
              },
            ],
          });
          final manifest = File('${temp.path}/busyapi.yaml')
            ..writeAsStringSync(config);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          for (final name in ['body', 'credentials', 'bare']) {
            final before = wire.connections;
            final core = await const ContractTestRunner().run(
              project,
              file.uri.toString(),
              selectedCases: [name],
              resolveSecret: (_) async => null,
            );
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', name, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            final report = jsonDecode(cli.stdout as String) as Map;
            final result = (report['cases'] as List).single as Map;
            expect(report['complete'], true);
            expect(result['passed'], name == 'bare');
            expect(result['dispatched'], name == 'bare');
            expect(core.cases.single.passed, name == 'bare');
            expect(core.cases.single.dispatched, name == 'bare');
            expect(
              cli.exitCode,
              name == 'bare' ? 0 : 1,
              reason: '${cli.stdout}\n${cli.stderr}',
            );
            if (name == 'bare') {
              expect(wire.connections, before + 2);
              expect(
                wire.requests.last.headers,
                startsWith('TRACE /trace HTTP/1.1\r\n'),
              );
              expect(wire.requests.last.body, isEmpty);
            } else {
              expect(wire.connections, before);
              final code =
                  'request.trace.${name == 'body' ? 'content' : 'credentials'}';
              final finding = (result['findings'] as List).single as Map;
              expect(finding['code'], code);
              expect(finding['resource'], file.uri.toString());
              expect(finding['pointer'], '/paths/~1trace/trace');
              expect(core.cases.single.findings.single['code'], code);
              expect(report['executedOperations'], isEmpty);
              expect(cli.stdout, isNot(contains('fixture-credential')));
            }
          }
          expect(await file.readAsString(), original);
          expect(await manifest.readAsString(), config);
        },
      );
    }
  }
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final mode in [
        'bare',
        'body',
        'authorization',
        'proxy',
        'cookie',
        'security',
      ]) {
        test(
          '$version $format TRACE $mode obeys HTTP content and credential rules before connecting',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-trace-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final wire = _TraceWire(
              await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
            );
            addTearDown(wire.close);
            final operation = {
              'requestBody': {
                'content': {
                  'text/plain': {
                    'schema': {'type': 'string'},
                  },
                  'application/json': {'schema': <String, Object?>{}},
                },
              },
              if (mode == 'security')
                'security': [
                  {'Access': <String>[]},
                ],
              'responses': {
                '200': {
                  'description': 'Observed',
                  'content': {
                    'application/json': {
                      'schema': {
                        'type': 'object',
                        'required': ['value'],
                        'properties': {
                          'value': {'type': 'integer', 'minimum': '@exact'},
                        },
                      },
                    },
                  },
                },
              },
            };
            final json = jsonEncode({
              'openapi': version,
              'info': {'title': 'TRACE', 'version': '1'},
              'servers': [
                {'url': 'http://127.0.0.1:${wire.server.port}'},
              ],
              'paths': {
                '/trace': {
                  'trace': operation,
                  'post': operation,
                  if (version.startsWith('3.2.'))
                    'additionalOperations': {'trace': operation},
                },
              },
              if (mode == 'security')
                'components': {
                  'securitySchemes': {
                    'Access': {
                      'type': 'apiKey',
                      'in': 'query',
                      'name': 'credential',
                    },
                  },
                },
            }).replaceAll('"@exact"', '9007199254740993.00');
            final original = format == 'yaml'
                ? '# Preserve 雪\r\n$json\r\n'
                : json;
            final file = File('${temp.path}/api.$format')
              ..writeAsStringSync(original);
            if (mode == 'security')
              File('${temp.path}/busyapi.yaml').writeAsStringSync(
                jsonEncode({
                  'version': 1,
                  'roots': [
                    {'name': 'api', 'path': 'api.$format'},
                  ],
                  'environments': {
                    'selected': {
                      'authentication': {
                        'schemes': {
                          'Access': {
                            'secretRef': '11111111-1111-4111-8111-111111111111',
                          },
                        },
                      },
                    },
                  },
                }),
              );
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = file.uri.toString();
            await project.buffer(root);
            final plan = await project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1trace/trace',
            );
            addTearDown(plan.close);
            var secrets = 0;
            Future<ContractRequestResult> send(
              String pointer, {
              RequestBodyDraft? body,
            }) async {
              final selected = pointer == plan.operation['source']['pointer']
                  ? plan
                  : await project.prepareRequest(
                      root,
                      resource: root,
                      pointer: pointer,
                    );
              if (!identical(selected, plan)) addTearDown(selected.close);
              final result = await const ContractRequestExecutor().execute(
                selected,
                OperationRequestDraft(
                  planIdentity: selected.identity,
                  environment: mode == 'security' ? 'selected' : null,
                  securityAlternative: mode == 'security' ? 0 : null,
                  headers: switch (mode) {
                    'authorization' => const [
                      RequestHeaderValue('aUtHoRiZaTiOn', 'fixture-credential'),
                    ],
                    'proxy' => const [
                      RequestHeaderValue(
                        'Proxy-Authorization',
                        'fixture-credential',
                      ),
                    ],
                    'cookie' => const [
                      RequestHeaderValue(
                        'Cookie',
                        'session=fixture-credential',
                      ),
                    ],
                    _ => const [RequestHeaderValue('Max-Forwards', '0')],
                  },
                  body:
                      body ??
                      (mode == 'body'
                          ? RequestBodyDraft.raw(
                              mediaType: 'text/plain',
                              text: '雪\u0000TRACE',
                            )
                          : const RequestBodyDraft.none()),
                ),
                resolveSecret: (_) async {
                  secrets++;
                  return 'fixture-credential';
                },
              );
              addTearDown(result.close);
              return result;
            }

            if (mode == 'bare') {
              final result = await send('/paths/~1trace/trace');
              expect(result.conforming, true);
              expect(
                wire.requests.single.headers,
                startsWith('TRACE /trace HTTP/1.1\r\n'),
              );
              expect(
                wire.requests.single.headers.toLowerCase(),
                contains('max-forwards: 0'),
              );
              expect(wire.requests.single.body, isEmpty);
              expect(
                utf8.decode(await result.response.bytes()),
                '{"value":9007199254740993}',
              );
              final empty = await send(
                '/paths/~1trace/trace',
                body: const RequestBodyDraft.raw(
                  mediaType: 'text/plain',
                  text: '',
                ),
              );
              expect(empty.conforming, true);
              expect(wire.requests, hasLength(2));
              expect(wire.requests.last.body, isEmpty);
              final prepared = await const ContractRequestBuilder().build(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              var opened = false;
              for (final unsafe in ['body', 'header', 'query']) {
                final guarded = PreparedContractRequest(
                  runId: prepared.runId,
                  plan: prepared.plan,
                  environment: prepared.environment,
                  method: prepared.method,
                  uri: unsafe == 'query'
                      ? prepared.uri.replace(
                          queryParameters: {'credential': 'fixture-credential'},
                        )
                      : prepared.uri,
                  displayUri: prepared.displayUri,
                  headers: unsafe == 'header'
                      ? const [('X-Credential', 'fixture-credential')]
                      : prepared.headers,
                  body: unsafe == 'body'
                      ? PreparedRequestBody(1, () {
                          opened = true;
                          return Stream.value(const [0]);
                        })
                      : null,
                  sensitiveHeaders: unsafe == 'header'
                      ? const {'x-credential'}
                      : prepared.sensitiveHeaders,
                  sensitiveQueryNames: unsafe == 'query'
                      ? const {'credential'}
                      : prepared.sensitiveQueryNames,
                  connectTimeout: prepared.connectTimeout,
                  overallTimeout: prepared.overallTimeout,
                  inactivityTimeout: prepared.inactivityTimeout,
                  securityAlternative: prepared.securityAlternative,
                  tls: prepared.tls,
                );
                await expectLater(
                  const ContractHttpTransport().send(guarded),
                  throwsA(
                    isA<CoreFailure>()
                        .having(
                          (failure) => failure.code,
                          'code',
                          unsafe == 'body'
                              ? 'request.trace.content'
                              : 'request.trace.credentials',
                        )
                        .having(
                          (failure) => failure.source?.resource,
                          'source resource',
                          root,
                        )
                        .having(
                          (failure) => failure.source?.pointer,
                          'source pointer',
                          '/paths/~1trace/trace',
                        ),
                  ),
                );
                await guarded.body?.close();
              }
              expect(
                opened,
                false,
                reason: 'No prohibited body stream may be opened',
              );
              expect(
                wire.connections,
                2,
                reason: 'Final transport refusal must precede a connection',
              );
            } else {
              final code = mode == 'body'
                  ? 'request.trace.content'
                  : 'request.trace.credentials';
              await expectLater(
                const ContractRequestBuilder().build(
                  plan,
                  OperationRequestDraft(
                    planIdentity: plan.identity,
                    environment: mode == 'security' ? 'selected' : null,
                    securityAlternative: mode == 'security' ? 0 : null,
                    headers: switch (mode) {
                      'authorization' => const [
                        RequestHeaderValue(
                          'Authorization',
                          'fixture-credential',
                        ),
                      ],
                      'proxy' => const [
                        RequestHeaderValue(
                          'Proxy-Authorization',
                          'fixture-credential',
                        ),
                      ],
                      'cookie' => const [
                        RequestHeaderValue(
                          'Cookie',
                          'session=fixture-credential',
                        ),
                      ],
                      _ => const [],
                    },
                    body: mode == 'body'
                        ? const RequestBodyDraft.raw(
                            mediaType: 'text/plain',
                            text: 'preview content',
                          )
                        : const RequestBodyDraft.none(),
                  ),
                  previewOnly: true,
                  resolveSecret: (_) async => throw StateError(
                    'A preview must not acquire credentials',
                  ),
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'preview refusal',
                    code,
                  ),
                ),
              );
              await expectLater(
                send('/paths/~1trace/trace'),
                throwsA(
                  isA<CoreFailure>()
                      .having((failure) => failure.code, 'code', code)
                      .having(
                        (failure) => failure.source?.resource,
                        'source resource',
                        root,
                      )
                      .having(
                        (failure) => failure.source?.pointer,
                        'source pointer',
                        '/paths/~1trace/trace',
                      ),
                ),
              );
              expect(
                wire.connections,
                0,
                reason: 'TRACE refusal must precede TCP connection',
              );
              expect(
                secrets,
                0,
                reason: 'A forbidden TRACE credential must not be acquired',
              );
              if (mode == 'body') {
                for (final text in ['0', 'false', 'null']) {
                  await expectLater(
                    send(
                      '/paths/~1trace/trace',
                      body: RequestBodyDraft.raw(
                        mediaType: 'application/json',
                        text: text,
                      ),
                    ),
                    throwsA(
                      isA<CoreFailure>().having(
                        (failure) => failure.code,
                        'code',
                        'request.trace.content',
                      ),
                    ),
                  );
                }
                expect(
                  wire.connections,
                  0,
                  reason:
                      'False, null and zero still have nonempty HTTP content',
                );
              }
              final control = await send('/paths/~1trace/post');
              expect(
                control.conforming,
                true,
                reason:
                    '${control.outgoing.findings} ${control.received.findings}',
              );
              expect(
                wire.requests.single.headers,
                startsWith(
                  'POST /trace${mode == 'security' ? '?credential=fixture-credential' : ''} HTTP/1.1\r\n',
                ),
              );
              if (mode == 'body')
                expect(utf8.decode(wire.requests.single.body), '雪\u0000TRACE');
              if (version.startsWith('3.2.')) {
                final custom = await send(
                  '/paths/~1trace/additionalOperations/trace',
                );
                expect(custom.conforming, true);
                expect(wire.requests.last.headers, startsWith('trace /trace'));
              }
            }
            expect(await file.readAsString(), original);
            expect(project.store.get(root).text, original);
          },
        );
      }
    }
  }
}
