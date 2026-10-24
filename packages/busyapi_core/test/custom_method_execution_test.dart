import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format custom methods retain actual wire identity and response content',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-custom-method-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final listener = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final sockets = <Socket>{};
          addTearDown(() async {
            for (final socket in sockets.toList()) {
              socket.destroy();
            }
            await listener.close();
          });
          const body =
              '{"message":"雪😀 BUSYAPI payload","number":9007199254740993.00}';
          final requests = <({String line, String headers, List<int> body})>[];
          listener.listen((socket) async {
            sockets.add(socket);
            try {
              final bytes = <int>[];
              await for (final chunk in socket) {
                bytes.addAll(chunk);
                expect(bytes.length, lessThan(32 * 1024));
                final header = latin1.decode(bytes);
                final end = header.indexOf('\r\n\r\n');
                if (end < 0) continue;
                final headers = header.substring(0, end);
                final length = int.parse(
                  RegExp(
                    r'^content-length:\s*(\d+)',
                    caseSensitive: false,
                    multiLine: true,
                  ).firstMatch(headers)!.group(1)!,
                );
                if (bytes.length < end + 4 + length) continue;
                requests.add((
                  line: headers.split('\r\n').first,
                  headers: headers,
                  body: bytes.sublist(end + 4, end + 4 + length),
                ));
                final response = utf8.encode(body);
                socket.add(
                  ascii.encode(
                    'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${response.length}\r\nConnection: close\r\n\r\n',
                  ),
                );
                socket.add(response);
                await socket.flush();
                await socket.close();
                break;
              }
            } finally {
              sockets.remove(socket);
              socket.destroy();
            }
          });
          const methods = [
            'PURGE',
            'purge',
            'Purge',
            'head',
            'get',
            'trace',
            'connect',
            'query',
            'MiXeD!',
          ];
          final operation = {
            'parameters': [
              {
                'name': 'id',
                'in': 'path',
                'required': true,
                'schema': {'type': 'string'},
              },
              {
                'name': 'q',
                'in': 'query',
                'schema': {'type': 'string'},
              },
            ],
            'requestBody': {
              'required': true,
              'content': {
                'application/json': {
                  'schema': {
                    'type': 'object',
                    'required': ['message', 'number'],
                  },
                },
              },
            },
            'responses': {
              '200': {
                'description': 'Exact response',
                'content': {
                  'application/json': {
                    'schema': {
                      'type': 'object',
                      'required': ['message', 'number'],
                    },
                  },
                },
              },
            },
          };
          final json = jsonEncode({
            'openapi': version,
            'info': {'title': 'Exact custom methods', 'version': '1'},
            'servers': [
              {'url': 'http://127.0.0.1:${listener.port}/v1'},
            ],
            'paths': {
              '/method/{id}': {
                'additionalOperations': {
                  for (final method in methods) method: operation,
                },
              },
            },
            'x-exact': '@exact',
          }).replaceFirst('"@exact"', '9007199254740993.00');
          final original = format == 'yaml'
              ? '# Preserve 雪\r\n$json\r\n'
              : json;
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(), checked = await project.check(root);
          expect(checked['complete'], true, reason: '$checked');
          expect(
            checked['findings'].where(
              (dynamic finding) => finding['severity'] == 'error',
            ),
            isEmpty,
          );
          for (final method in methods) {
            final operation = (checked['projection']['operations'] as List)
                .whereType<Map>()
                .singleWhere((value) => value['method'] == method);
            final plan = await project.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            addTearDown(plan.close);
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                parameters: {
                  OperationRequestDraft.parameterKey('path', 'id'):
                      const RequestValue.text('a/b'),
                  OperationRequestDraft.parameterKey('query', 'q'):
                      const RequestValue.text('snow space'),
                },
                headers: const [
                  RequestHeaderValue('X-Unchanged', 'BUSYAPI header'),
                ],
                body: RequestBodyDraft.raw(
                  mediaType: 'application/json',
                  text: body,
                ),
              ),
              resolveSecret: (_) async => null,
            );
            addTearDown(result.close);
            expect(
              result.conforming,
              true,
              reason:
                  '$method ${result.outgoing.findings} ${result.received.findings}',
            );
            expect(
              requests.last.line,
              '$method /v1/method/a%2Fb?q=snow%20space HTTP/1.1',
            );
            expect(
              requests.last.headers,
              contains('X-Unchanged: BUSYAPI header'),
            );
            expect(requests.last.body, utf8.encode(body));
            expect(result.request.method, method);
            expect(
              await File(result.response.bodyFile).readAsBytes(),
              utf8.encode(body),
            );
            expect(await result.response.decodedBytes(), utf8.encode(body));
          }
          expect(requests, hasLength(methods.length));
          expect(file.readAsStringSync(), original);
        },
      );
    }
  }
}
