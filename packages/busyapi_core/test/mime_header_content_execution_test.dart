import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _header =
    '{"id":9007199254740993.00,"flag":false,"empty":"","\$ref":"literal"}';
String _wire({bool rounded = false}) =>
    '--Fixture\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\nX-Meta: ${rounded ? _header.replaceFirst('9007199254740993.00', '9007199254740992') : _header}\r\n\r\nvalue\r\n--Fixture--\r\n';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format MIME Header content uses captured external schemas on HTTP and CLI',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-mime-header-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <(String, String, String, String, List<int>)>[];
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('host')!,
              request.headers.contentType.toString(),
              bytes,
            ));
            request.response.headers.set(
              'content-type',
              'multipart/mixed; boundary=Fixture',
            );
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
            await request.response.close();
          });
          final ordered = version.startsWith('3.2.');
          final encoding = {
            'contentType': 'text/plain',
            'headers': {
              'X-Meta': {r'$ref': './headers.$format#/Meta'},
            },
          };
          final media = {
            'schema': ordered
                ? {
                    'type': 'array',
                    'items': {'type': 'string'},
                  }
                : {
                    'type': 'object',
                    'required': ['value'],
                    'properties': {
                      'value': {'type': 'string'},
                    },
                  },
            if (ordered)
              'itemEncoding': encoding
            else
              'encoding': {'value': encoding},
          };
          final content = {'multipart/mixed': media};
          final value = {
            'openapi': version,
            'info': {'title': 'Keep 雪', 'version': 'unchanged'},
            'servers': [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            'paths': {
              '/parts': {
                'post': {
                  'requestBody': {'content': content},
                  'responses': {
                    '200': {'description': 'Echo', 'content': content},
                  },
                },
              },
            },
          };
          final source = format == 'json'
              ? '${jsonEncode(value)}\r\n'
              : '''# Preserve original YAML and 雪\r
openapi: $version\r
info: {title: Keep 雪, version: unchanged}\r
servers: [{url: 'http://127.0.0.1:${server.port}'}]\r
paths:\r
  /parts:\r
    post:\r
      requestBody: {content: ${jsonEncode(content)}}\r
      responses: {'200': {description: Echo, content: ${jsonEncode(content)}}}\r
''';
          final meta = {
            'Meta': {
              'required': true,
              'content': {
                'application/json': {
                  'schema': {
                    'type': 'object',
                    'required': ['id', 'flag', 'empty', r'$ref'],
                    'properties': {
                      'id': {
                        'type': 'integer',
                        'enum': ['EXACT'],
                      },
                      'flag': {
                        'type': 'boolean',
                        'enum': [false],
                      },
                      'empty': {'type': 'string', 'maxLength': 0},
                      r'$ref': {
                        'type': 'string',
                        'enum': ['literal'],
                      },
                    },
                    'additionalProperties': false,
                  },
                },
              },
            },
            'x-literal': {r'$ref': 'not-a-reference'},
          };
          final sharedSource =
              (format == 'json'
                      ? '${jsonEncode(meta)}\r\n'
                      : '# Keep shared YAML\r\nMeta: ${jsonEncode(meta['Meta'])}\r\nx-literal: {\$ref: not-a-reference}\r\n')
                  .replaceAll('"EXACT"', '9007199254740993.00');
          final file = File('${directory.path}/api.$format'),
              shared = File('${directory.path}/headers.$format');
          await file.writeAsString(source);
          await shared.writeAsString(sharedSource);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(shared.uri.toString());
          Future<ContractRequestResult> send(String wire) async {
            final plan = await project.prepareRequest(
              file.uri.toString(),
              resource: file.uri.toString(),
              pointer: '/paths/~1parts/post',
            );
            try {
              return await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(
                    mediaType: 'multipart/mixed; boundary=Fixture',
                    text: wire,
                  ),
                ),
                resolveSecret: (_) async => null,
              );
            } finally {
              plan.close();
            }
          }

          for (final rounded in [false, true]) {
            final wire = _wire(rounded: rounded),
                result = await send(_wire(rounded: rounded));
            try {
              expect(
                result.outgoing.complete,
                isTrue,
                reason: '${result.outgoing.findings}',
              );
              expect(result.outgoing.valid, !rounded);
              expect(
                result.received.complete,
                isTrue,
                reason: '${result.received.findings}',
              );
              expect(result.received.valid, !rounded || !ordered);
              expect(
                (seen.last.$1, seen.last.$2, seen.last.$3, seen.last.$4),
                (
                  'POST',
                  '/parts',
                  '127.0.0.1:${server.port}',
                  'multipart/mixed; boundary=Fixture',
                ),
              );
              expect(seen.last.$5, utf8.encode(wire));
              expect(await result.response.decodedBytes(), utf8.encode(wire));
              expect(
                await File(result.response.bodyFile).readAsBytes(),
                utf8.encode(wire),
              );
            } finally {
              await result.close();
            }
          }
          project.store.replace(
            buffer.id,
            sharedSource.replaceFirst('"enum":[false]', '"enum":[true]'),
          );
          expect(buffer.text, isNot(sharedSource));
          final changed = await send(_wire());
          try {
            expect(
              changed.outgoing.complete,
              isTrue,
              reason: '${changed.outgoing.findings}',
            );
            expect(changed.outgoing.valid, isFalse);
            expect(
              changed.outgoing.findings.any(
                (finding) =>
                    finding['schema'] is Map &&
                    (finding['schema'] as Map)['resource'] ==
                        shared.uri.toString() &&
                    (finding['schema'] as Map)['pointer'] ==
                        '/Meta/content/application~1json/schema',
              ),
              isTrue,
              reason: '${changed.outgoing.findings}',
            );
          } finally {
            await changed.close();
          }
          final manifest = File('${directory.path}/busyapi.yaml');
          await manifest.writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                for (final rounded in [false, true])
                  {
                    'name': rounded ? 'rounded' : 'exact',
                    'operation': {'method': 'post', 'path': '/parts'},
                    'body': {
                      'mediaType': 'multipart/mixed; boundary=Fixture',
                      'value': _wire(rounded: rounded),
                    },
                    'expect': {'status': 200},
                  },
              ],
            }),
          );
          for (final rounded in [false, true]) {
            final before = seen.length;
            final cli = await Process.run(
              '$testBundle/busyapi',
              [
                'test',
                directory.path,
                '--case',
                rounded ? 'rounded' : 'exact',
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              cli.exitCode,
              rounded ? 1 : 0,
              reason: '${cli.stdout}\n${cli.stderr}',
            );
            final report = jsonDecode(cli.stdout as String) as Map;
            expect(report['complete'], isTrue, reason: '${cli.stdout}');
            expect(report['passed'], !rounded);
            expect(seen, hasLength(before + 1));
            expect(seen.last.$5, utf8.encode(_wire(rounded: rounded)));
          }
          expect(await file.readAsString(), source);
          expect(await shared.readAsString(), sharedSource);
          expect(
            buffer.text,
            sharedSource.replaceFirst('"enum":[false]', '"enum":[true]'),
          );
        },
      );
    }
  }
}
