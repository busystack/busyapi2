import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _RequestGate extends EngineProcess {
  _RequestGate(this.method)
    : super(executable: runtimeNode, helper: runtimeHelper);
  final String method;
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = false;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (armed && method == this.method) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['json', 'yaml']) {
      test('$version $format referenced form parameter and header content', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-form-content-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <Uri>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          seen.add(request.uri);
          await request.drain<void>();
          request.response.headers.set(
            'x-form',
            request.uri.queryParameters['payload']!,
          );
          await request.response.close();
        });
        final schema = File('${temp.path}/schema.json');
        const schemaText =
            '{"type":"object","required":["amount","flag"],"properties":{"amount":{"type":"integer","enum":[9007199254740993.00]},"flag":{"type":"boolean","enum":[false]}},"additionalProperties":false}';
        await schema.writeAsString(schemaText);
        final media = {
          'schema': {r'$ref': './schema.json'},
          // Encoding applies only to request-body content, not this context.
          'encoding': {
            'amount': {
              'contentType': 'application/json',
              'style': 'form',
              'explode': false,
            },
          },
        };
        final shared = File('${temp.path}/shared.json');
        final sharedText = jsonEncode({
          'parameter': {
            'name': 'payload',
            'in': 'query',
            'required': true,
            'content': {'application/x-www-form-urlencoded': media},
          },
          'header': {
            'required': true,
            'content': {'application/x-www-form-urlencoded': media},
          },
        });
        await shared.writeAsString(sharedText);
        final source = File('${temp.path}/api.$format');
        final json = jsonEncode({
          'openapi': version,
          'info': {'title': 'Shared form content', 'version': '1'},
          'servers': [
            {'url': 'http://127.0.0.1:${server.port}'},
          ],
          'paths': {
            '/form': {
              'get': {
                'parameters': [
                  {r'$ref': './shared.json#/parameter'},
                ],
                'responses': {
                  '200': {
                    'description': 'Empty',
                    'headers': {
                      'x-form': {r'$ref': './shared.json#/header'},
                    },
                  },
                },
              },
            },
          },
        });
        final original = format == 'yaml'
            ? '# Preserve source 雪\r\n$json\r\n'
            : json;
        await source.writeAsString(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(source.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(source.uri.toString());
        final plan = await project.prepareRequest(
          buffer.id,
          resource: buffer.id,
          pointer: '/paths/~1form/get',
        );
        addTearDown(plan.close);
        for (final amount in ['9007199254740993', '9007199254740992']) {
          final value = 'amount=$amount&flag=false';
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: {
                OperationRequestDraft.parameterKey('query', 'payload'):
                    RequestValue.text(value),
              },
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(
            result.outgoing.complete,
            true,
            reason: '${result.outgoing.toJson()}',
          );
          expect(
            result.received.complete,
            true,
            reason: '${result.received.toJson()}',
          );
          expect(result.outgoing.valid, amount == '9007199254740993');
          expect(result.received.valid, amount == '9007199254740993');
          expect(
            seen.last.toString(),
            '/form?payload=${Uri.encodeQueryComponent(value)}',
          );
          expect(seen.last.queryParameters['payload'], value);
          expect(await result.response.decodedBytes(), isEmpty);
          if (amount == '9007199254740992') {
            expect(
              result.received.findings.any(
                (f) =>
                    f['schema'] is Map &&
                    (f['schema'] as Map)['resource'] == shared.uri.toString() &&
                    (f['schema'] as Map)['pointer'] ==
                        '/header/content/application~1x-www-form-urlencoded/schema' &&
                    (((f['schema'] as Map)['range'] as List).last as int) >
                        (((f['schema'] as Map)['range'] as List).first as int),
              ),
              true,
            );
          }
        }
        expect(await source.readAsString(), original);
        expect(await shared.readAsString(), sharedText);
        expect(await schema.readAsString(), schemaText);
        expect(buffer.text, original);
        final draft = OperationRequestDraft(
          planIdentity: plan.identity,
          parameters: {
            OperationRequestDraft.parameterKey('query', 'payload'):
                const RequestValue.text('amount=9007199254740993&flag=false'),
          },
        );
        final count = seen.length;
        await expectLater(
          const ContractRequestExecutor().execute(
            plan,
            draft,
            resolveSecret: (_) async => null,
            cancellation: RunCancellation()..cancel(),
          ),
          throwsA(
            isA<CoreFailure>().having((f) => f.code, 'code', 'cancelled'),
          ),
        );
        final changed = original.replaceFirst(
          version,
          version == '3.0.4' ? '3.1.2' : '3.0.4',
        );
        project.store.replace(buffer.id, changed);
        await expectLater(
          const ContractRequestExecutor().execute(
            plan,
            draft,
            resolveSecret: (_) async => null,
          ),
          throwsA(
            isA<CoreFailure>().having(
              (f) => f.code,
              'code',
              'request.draft.stale',
            ),
          ),
        );
        expect(seen.length, count);
        expect(await source.readAsString(), original);
        expect(buffer.text, changed);
      });
    }
  }
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final phase in ['requestParameterValues', 'evaluateSchemas']) {
      test(
        '$version Source declaration changes during $phase prevent raw dispatch',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-request-capture-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var requests = 0, dispatched = 0;
          server.listen((request) async {
            requests++;
            await request.drain<void>();
            await request.response.close();
          });
          final legacy = version == '2.0';
          final source = File('${temp.path}/api.json');
          final original = jsonEncode({
            legacy ? 'swagger' : 'openapi': version,
            'info': {'title': 'Original', 'version': '1'},
            if (legacy) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': ['application/json'],
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            'paths': {
              '/data': {
                'post': {
                  'parameters': [
                    {
                      'name': 'n',
                      'in': 'query',
                      if (legacy)
                        'type': 'integer'
                      else
                        'schema': {'type': 'integer'},
                    },
                  ],
                  if (!legacy)
                    'requestBody': {
                      'content': {
                        'application/json': {
                          'schema': {'type': 'integer'},
                        },
                      },
                    },
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
          });
          await source.writeAsString(original);
          final engine = _RequestGate(phase);
          addTearDown(engine.close);
          addTearDown(() {
            if (!engine.release.isCompleted) engine.release.complete();
          });
          final project = await BusyProject.open(source.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(source.uri.toString());
          final plan = await project.prepareRequest(
            buffer.id,
            resource: buffer.id,
            pointer: '/paths/~1data/post',
          );
          addTearDown(plan.close);
          engine.armed = true;
          final checked = expectLater(
            const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                parameters: {
                  OperationRequestDraft.parameterKey('query', 'n'):
                      const RequestValue.json('0'),
                },
                body: const RequestBodyDraft.raw(
                  mediaType: 'application/json',
                  text: '0',
                ),
              ),
              resolveSecret: (_) async => null,
              onRequestDispatched: () => dispatched++,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (f) => f.code,
                'code',
                'request.draft.stale',
              ),
            ),
          );
          await engine.entered.future.timeout(const Duration(seconds: 10));
          final changed = legacy
              ? original.replaceFirst('"swagger":"2.0"', '"openapi":"3.0.4"')
              : original.replaceFirst(
                  version,
                  version == '3.0.4' ? '3.1.2' : '3.0.4',
                );
          project.store.replace(buffer.id, changed);
          engine.release.complete();
          await checked;
          expect((requests, dispatched), (0, 0));
          expect(await source.readAsString(), original);
          expect(buffer.text, changed);
          expect((await plan.inspectJson('0'))['pretty'], '0');
        },
      );
    }
  }
}
