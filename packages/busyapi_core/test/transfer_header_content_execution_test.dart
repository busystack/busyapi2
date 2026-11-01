import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final composed in [false, true]) {
        test(
          '$version $format typed conversion $composed Header content controls actual form-data transfer bytes',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-transfer-content-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final seen = <(String, String, String, String, List<int>)>[];
            server.listen((request) async {
              seen.add((
                request.method,
                request.uri.toString(),
                request.headers.value('host')!,
                request.headers.contentType.toString(),
                await request.fold<List<int>>(
                  [],
                  (all, bytes) => all..addAll(bytes),
                ),
              ));
              request.response.statusCode = 204;
              await request.response.close();
            });
            final operation = {
              'requestBody': {
                'required': true,
                'content': {
                  'multipart/form-data': {
                    'schema': {
                      'type': 'object',
                      'required': ['value'],
                      'properties': {
                        'value': composed
                            ? {
                                'oneOf': [
                                  {'type': 'string'},
                                  {'type': 'boolean'},
                                ],
                                'not': {'type': 'string'},
                              }
                            : {
                                'type': 'boolean',
                                'enum': [false],
                              },
                      },
                    },
                    'encoding': {
                      'value': {
                        'contentType': 'text/plain',
                        'headers': {
                          'Content-Transfer-Encoding': {
                            'required': true,
                            'content': {
                              'text/plain': {
                                'schema': {
                                  'type': 'string',
                                  'enum': ['base64'],
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
              'responses': {
                '204': {'description': 'Empty'},
              },
            };
            final source = format == 'json'
                ? jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Keep 雪', 'version': 'unrelated'},
                    'servers': [
                      {'url': 'http://127.0.0.1:${server.port}'},
                    ],
                    'paths': {
                      '/parts': {'post': operation},
                    },
                  })
                : '\ufeff# Keep CRLF and native family\r\nopenapi: $version\r\ninfo: {title: Keep 雪, version: unrelated}\r\nservers: [{url: "http://127.0.0.1:${server.port}"}]\r\npaths:\r\n  /parts:\r\n    post: ${jsonEncode(operation)}\r\n';
            final file = File('${directory.path}/api.$format');
            await file.writeAsString(source);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final buffer = await project.buffer(file.uri.toString());
            final plan = await project.prepareRequest(
              buffer.id,
              resource: buffer.id,
              pointer: '/paths/~1parts/post',
            );
            addTearDown(plan.close);
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                body: const RequestBodyDraft.multipartValue(
                  json: '{"value":false}',
                ),
              ),
              resolveSecret: (_) async => null,
            );
            try {
              expect(
                result.outgoing.complete,
                isTrue,
                reason: '${result.outgoing.findings}',
              );
              expect(
                result.conforming,
                isTrue,
                reason: '${result.outgoing.findings}',
              );
              final actual = seen.single,
                  boundary = ContentType.parse(seen.single.$4)
                      .parameters['boundary']!;
              expect(
                (actual.$1, actual.$2, actual.$3),
                ('POST', '/parts', '127.0.0.1:${server.port}'),
              );
              expect(
                actual.$5,
                utf8.encode(
                  '--$boundary\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\nZmFsc2U=\r\n--$boundary--\r\n',
                ),
              );
            } finally {
              await result.close();
            }
            final changed = buffer.text.replaceFirst(
              '"enum":["base64"]',
              '"enum":["x-unknown-cte"]',
            );
            expect(changed, isNot(buffer.text));
            project.store.replace(buffer.id, changed);
            final unsupported = await project.prepareRequest(
              buffer.id,
              resource: buffer.id,
              pointer: '/paths/~1parts/post',
            );
            addTearDown(unsupported.close);
            await expectLater(
              const ContractRequestBuilder().build(
                unsupported,
                OperationRequestDraft(
                  planIdentity: unsupported.identity,
                  body: const RequestBodyDraft.multipartValue(
                    json: '{"value":false}',
                  ),
                ),
                resolveSecret: (_) async => null,
              ),
              throwsA(
                isA<CoreFailure>().having(
                  (value) => value.code,
                  'code',
                  'request.multipart.encoding.unsupported',
                ),
              ),
            );
            expect(seen.length, 1);
            expect(await file.readAsBytes(), utf8.encode(source));
          },
        );
      }
    }
  }
}
