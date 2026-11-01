import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format GET body rules govern actual requests and documentation',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-method-body-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <(String, String?, List<int>)>[];
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            seen.add((
              request.method,
              request.headers.value('content-type'),
              bytes,
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          final legacy = version == '2.0', ignored = version.startsWith('3.0.');
          final value = {
            legacy ? 'swagger' : 'openapi': version,
            'info': {'title': 'Method body 雪', 'version': 'api-version'},
            if (legacy) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': ['application/json'],
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            'paths': {
              '/payload': {
                'get': {
                  if (legacy)
                    'parameters': [
                      {
                        'in': 'body',
                        'name': 'payload',
                        'required': true,
                        'schema': {'type': 'string'},
                      },
                    ]
                  else
                    'requestBody': {
                      'required': true,
                      'content': {
                        'application/json': {
                          'schema': {'type': 'string'},
                          'example': '雪',
                        },
                      },
                    },
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
            'x-number': 'EXACT_VALUE',
          };
          final encoded = jsonEncode(value)
              .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
          final original = format == 'yaml'
              ? '# Original declaration\r\n$encoded\r\n'
              : encoded;
          final source = File('${temp.path}/api.$format');
          await source.writeAsString(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(source.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(source.uri.toString());
          final checked = await project.check(source.uri.toString());
          expect(checked['complete'], true);
          final operation =
              (checked['projection']['operations'] as List).single as Map;
          Future<OperationRequestPlan> plan() => project.prepareRequest(
            source.uri.toString(),
            resource: source.uri.toString(),
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          final captured = await plan();
          addTearDown(captured.close);
          expect(captured.ignoredRequestBody != null, ignored);
          expect(captured.result['requestBody'] != null, !ignored);
          if (ignored) {
            expect(captured.ignoredRequestBody!.method, 'GET');
            expect(
              captured.ignoredRequestBody!.source.pointer,
              '/paths/~1payload/get/requestBody',
            );
            final absent = await const ContractRequestExecutor().execute(
              captured,
              OperationRequestDraft(planIdentity: captured.identity),
              resolveSecret: (_) async => null,
            );
            addTearDown(absent.close);
            expect(absent.outgoing.complete, true);
            expect(absent.received.complete, true);
            expect(seen.single.$1, 'GET');
            expect(seen.single.$2, isNull);
            expect(seen.single.$3, isEmpty);
          } else {
            await expectLater(
              const ContractRequestBuilder().build(
                captured,
                OperationRequestDraft(planIdentity: captured.identity),
                resolveSecret: (_) async => null,
              ),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'request.body.required',
                ),
              ),
            );
            expect(seen, isEmpty);
          }
          // An explicitly entered body is still a user-owned transport input;
          // an ignored declaration must neither force nor validate that input.
          final sent = await const ContractRequestExecutor().execute(
            captured,
            OperationRequestDraft(
              planIdentity: captured.identity,
              body: const RequestBodyDraft.raw(
                mediaType: 'application/json',
                text: '"雪"',
              ),
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(sent.close);
          expect(sent.outgoing.complete, true);
          expect(sent.received.complete, true);
          expect(seen.last.$1, 'GET');
          expect(seen.last.$2, 'application/json');
          expect(seen.last.$3, utf8.encode('"雪"'));
          if (version == '3.0.4' || version == '3.1.2') {
            final docs = await project.prepareDocumentation(
              source.uri.toString(),
              '${temp.path}/docs',
              saved: false,
            );
            addTearDown(docs.close);
            await docs.publish();
            final html = await File('${temp.path}/docs/index.html')
                .readAsString();
            expect(
              html.contains(
                'OpenAPI 3.0 consumers ignore this GET request-body declaration',
              ),
              ignored,
            );
            expect(html, contains('requestBody'));
          }
          expect(buffer.text, original);
          expect(await source.readAsString(), original);
          if (version == '3.0.4' && format == 'yaml') {
            project.store.replace(
              source.uri.toString(),
              original.replaceFirst('3.0.4', '3.1.2'),
            );
            final changed = await plan();
            addTearDown(changed.close);
            expect(captured.outdated, true);
            expect(changed.ignoredRequestBody, isNull);
            expect(changed.result['requestBody'], isA<Map>());
            await expectLater(
              const ContractRequestBuilder().build(
                changed,
                OperationRequestDraft(planIdentity: changed.identity),
                resolveSecret: (_) async => null,
              ),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'request.body.required',
                ),
              ),
            );
            expect(await source.readAsString(), original);
          }
        },
      );
    }
  }
}
