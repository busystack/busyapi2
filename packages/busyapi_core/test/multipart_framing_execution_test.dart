import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format multipart preparation and raw framing retain wire ownership',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-framing-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final seen = <(String, String, String, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.contentType.toString(),
              bytes,
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          final legacy = version == '2.0';
          final value = <String, Object?>{
            if (legacy) 'swagger': version else 'openapi': version,
            'info': {'title': 'Keep 雪', 'version': 'unchanged'},
            if (legacy) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': ['multipart/form-data'],
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            'paths': {
              '/parts': {
                'post': {
                  if (legacy)
                    'parameters': [
                      {
                        'in': 'formData',
                        'name': 'value',
                        'type': 'string',
                        'allowEmptyValue': true,
                      },
                    ]
                  else
                    'requestBody': {
                      'content': {
                        'multipart/form-data': {
                          'schema': {
                            'type': 'object',
                            'properties': {
                              'value': {'type': 'string'},
                            },
                          },
                        },
                      },
                    },
                  'responses': {
                    '204': {'description': 'Keep response'},
                  },
                },
              },
            },
          };
          final original = format == 'json'
              ? '${const JsonEncoder.withIndent('  ').convert(value)}\n'
              : '''# Keep exact YAML layout and 雪\r
${legacy ? "swagger: '2.0'\r\nhost: 127.0.0.1:${server.port}\r\nschemes: [http]\r\nconsumes: [multipart/form-data]" : "openapi: $version\r\nservers: [{url: 'http://127.0.0.1:${server.port}'}]"}\r
info: {title: Keep 雪, version: unchanged}\r
paths:\r
  /parts:\r
    post:\r
${legacy ? "      parameters: [{in: formData, name: value, type: string, allowEmptyValue: true}]" : "      requestBody:\r\n        content:\r\n          multipart/form-data:\r\n            schema: {type: object, properties: {value: {type: string}}}"}\r
      responses: {'204': {description: Keep response}}\r
''';
          final file = File('${directory.path}/api.$format');
          await file.writeAsString(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final checked = await project.check(file.uri.toString());
          expect(checked['complete'], isTrue, reason: '$checked');
          final operation =
              (checked['projection']['operations'] as List).single as Map;
          final plan = await project.prepareRequest(
            file.uri.toString(),
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          var dispatched = 0;
          Future<ContractRequestResult> send(
            RequestBodyDraft body, {
            RunCancellation? cancellation,
          }) async {
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(planIdentity: plan.identity, body: body),
              resolveSecret: (_) async => null,
              cancellation: cancellation,
              onRequestDispatched: () => dispatched++,
            );
            addTearDown(result.close);
            return result;
          }

          await expectLater(
            send(const RequestBodyDraft.multipart([], [])),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'request.multipart.empty',
              ),
            ),
          );
          expect(dispatched, 0);
          expect(seen, isEmpty);
          final positive = await send(
            const RequestBodyDraft.multipart([
              RequestFormField('value', ''),
            ], []),
          );
          expect(positive.outgoing.complete, isTrue);
          expect(
            positive.outgoing.valid,
            isTrue,
            reason: '${positive.outgoing.findings}',
          );
          expect(positive.received.valid, isTrue);
          final first = seen.single;
          final boundary = ContentType.parse(first.$3).parameters['boundary']!;
          expect(first.$1, 'POST');
          expect(first.$2, '/parts');
          expect(
            first.$4,
            utf8.encode(
              '--$boundary\r\nContent-Disposition: form-data; name="value"\r\n${legacy ? '' : 'Content-Type: text/plain\r\n'}\r\n\r\n--$boundary--\r\n',
            ),
          );
          for (final wire in [
            '--Fixture--\r\n',
            '--Fixture\r\nContent-Disposition: form-data; name="value"\r\n\r\nbefore\r\n--Fixture-is-data\r\nafter\r\n--Fixture--\r\n',
          ]) {
            final result = await send(
              RequestBodyDraft.raw(
                text: wire,
                mediaType: 'multipart/form-data; boundary=Fixture',
              ),
            );
            expect(result.outgoing.complete, isTrue);
            expect(result.outgoing.valid, isFalse);
            expect(
              result.outgoing.findings.any(
                (finding) => finding['code'] == 'runtime.body.syntax',
              ),
              isTrue,
              reason: '${result.outgoing.findings}',
            );
            expect(result.received.valid, isTrue);
            expect(seen.last.$4, utf8.encode(wire));
          }
          final cancellation = RunCancellation()..cancel();
          await expectLater(
            send(
              const RequestBodyDraft.multipart([], []),
              cancellation: cancellation,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'cancelled',
              ),
            ),
          );
          expect(dispatched, 3);
          expect(seen, hasLength(3));
          expect(await file.readAsString(), original);
          expect((await project.buffer(file.uri.toString())).text, original);
        },
      );
    }
  }
}
