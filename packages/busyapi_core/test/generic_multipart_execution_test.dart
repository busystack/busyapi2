import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _data =
    '{"flag":false,"metadata":{"id":9007199254740993.00},"note":"café 東京"}';

String _wire(String boundary, {bool rounded = false}) =>
    '--$boundary\r\nContent-Disposition: form-data; name="flag"\r\n'
    'Content-Type: text/plain\r\n\r\nfalse\r\n'
    '--$boundary\r\nContent-Disposition: form-data; name="metadata"\r\n'
    'Content-Type: application/json\r\n\r\n'
    '{"id":${rounded ? '9007199254740992' : '9007199254740993.00'}}\r\n'
    '--$boundary\r\nContent-Disposition: form-data; name="note"\r\n'
    'Content-Type: text/plain; charset=utf-8\r\n\r\ncafé 東京\r\n'
    '--$boundary--\r\n';

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format named generic multipart reaches actual HTTP and independent CLI',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-generic-multipart-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final seen = <(String, String, String, String, List<int>)>[];
          var roundResponse = false;
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            final type = request.headers.contentType.toString();
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('host')!,
              type,
              bytes,
            ));
            request.response.headers.set('content-type', type);
            request.response.add(
              roundResponse
                  ? utf8.encode(
                      utf8
                          .decode(bytes)
                          .replaceAll(
                            '9007199254740993.00',
                            '9007199254740992',
                          ),
                    )
                  : bytes,
            );
            await request.response.close();
          });
          final media = {
            'schema': {
              'type': 'object',
              'required': ['flag', 'metadata', 'note'],
              'properties': {
                'flag': {
                  'type': 'boolean',
                  'enum': [false],
                },
                'metadata': {r'$ref': 'model.yaml#/Item'},
                'note': {
                  'type': 'string',
                  'enum': ['café 東京'],
                },
              },
            },
            'encoding': {
              'flag': {'contentType': 'text/plain'},
              'metadata': {'contentType': 'application/json'},
              'note': {'contentType': 'text/plain; charset=utf-8'},
            },
          };
          final operation = {
            'requestBody': {
              'required': true,
              'content': {'multipart/mixed': media},
            },
            'responses': {
              '200': {
                'description': 'Echo',
                'content': {'multipart/mixed': media},
              },
            },
          };
          final source = format == 'json'
              ? jsonEncode({
                  'openapi': version,
                  'info': {'title': 'Original', 'version': 'api-version'},
                  'servers': [
                    {'url': 'http://127.0.0.1:${server.port}'},
                  ],
                  'paths': {
                    '/parts': {'post': operation},
                  },
                })
              : '\ufeff# Preserve source 雪\r\nopenapi: $version\r\n'
                    'info: {title: Original, version: api-version}\r\n'
                    'servers: [{url: "http://127.0.0.1:${server.port}"}]\r\n'
                    'paths:\r\n  /parts:\r\n    post: ${jsonEncode(operation)}\r\n';
          const shared =
              '# Keep aliases and exact values\r\nItem: &item\r\n'
              '  type: object\r\n  required: [id]\r\n'
              '  properties:\r\n    id: {type: integer, enum: [9007199254740993.00]}\r\nMirror: *item\r\n';
          final file = File('${directory.path}/api.$format');
          await file.writeAsString(source);
          final model = File('${directory.path}/model.yaml');
          await model.writeAsString(shared);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Original', 'Unsaved'),
          );
          final plan = await project.prepareRequest(
            buffer.id,
            resource: buffer.id,
            pointer: '/paths/~1parts/post',
          );
          addTearDown(plan.close);
          expect(
            plan.formBindingForMedia('multipart/mixed'),
            RequestFormBinding.namedMultipart,
          );
          for (final (typed, rounded, roundedResponse, mediaType) in [
            (true, false, false, 'multipart/mixed'),
            (true, false, false, 'multipart/mixed; charset=utf-8'),
            (false, false, false, 'multipart/mixed'),
            (false, true, false, 'multipart/mixed'),
            (true, false, true, 'multipart/mixed'),
          ]) {
            roundResponse = roundedResponse;
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                body: typed
                    ? RequestBodyDraft.multipartValue(
                        json: _data,
                        mediaType: mediaType,
                      )
                    : RequestBodyDraft.raw(
                        mediaType: 'multipart/mixed; boundary=Fixture',
                        text: _wire('Fixture', rounded: rounded),
                      ),
              ),
              resolveSecret: (_) async => throw StateError('No credentials'),
            );
            try {
              expect(
                result.outgoing.complete,
                isTrue,
                reason: '${result.outgoing.findings}',
              );
              expect(
                result.received.complete,
                isTrue,
                reason: '${result.received.findings}',
              );
              expect(result.outgoing.valid, !rounded);
              expect(result.received.valid, !rounded && !roundedResponse);
              expect(result.conforming, !rounded && !roundedResponse);
              final actual = seen.last;
              expect(
                (actual.$1, actual.$2, actual.$3),
                ('POST', '/parts', '127.0.0.1:${server.port}'),
              );
              final type = ContentType.parse(actual.$4);
              expect(type.mimeType, 'multipart/mixed');
              final boundary = type.parameters['boundary']!;
              expect(actual.$5, utf8.encode(_wire(boundary, rounded: rounded)));
              final response = utf8.encode(
                _wire(boundary, rounded: rounded || roundedResponse),
              );
              expect(
                await File(result.response.bodyFile).readAsBytes(),
                response,
              );
              expect(await result.response.decodedBytes(), response);
            } finally {
              await result.close();
            }
          }
          roundResponse = false;
          final manifest = File('${directory.path}/busyapi.yaml');
          await manifest.writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                {
                  'name': 'typed exact',
                  'operation': {'method': 'post', 'path': '/parts'},
                  'body': {
                    'mediaType': 'multipart/mixed',
                    'value': {
                      'flag': false,
                      'metadata': {'id': 'EXACT'},
                      'note': 'café 東京',
                    },
                  },
                  'expect': {'status': 200},
                },
                {
                  'name': 'rounded',
                  'operation': {'method': 'post', 'path': '/parts'},
                  'body': {
                    'mediaType': 'multipart/mixed; boundary=Fixture',
                    'value': _wire('Fixture', rounded: true),
                  },
                  'expect': {'status': 200},
                },
              ],
            }).replaceAll('"EXACT"', '9007199254740993.00'),
          );
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'test',
              directory.path,
              '--case',
              'typed exact',
              '--case',
              'rounded',
              '--json',
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 1, reason: '${cli.stdout}\n${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['complete'], isTrue, reason: '${cli.stdout}');
          expect((report['cases'] as List).map((value) => value['passed']), [
            true,
            false,
          ]);
          expect(seen.length, 7);
          for (final (index, request) in seen.skip(5).indexed) {
            final boundary = ContentType.parse(request.$4)
                .parameters['boundary']!;
            expect(
              request.$5,
              utf8.encode(_wire(boundary, rounded: index == 1)),
            );
          }
          final cancellation = RunCancellation()..cancel();
          final draft = OperationRequestDraft(
            planIdentity: plan.identity,
            body: const RequestBodyDraft.multipartValue(
              json: _data,
              mediaType: 'multipart/mixed',
            ),
          );
          await expectLater(
            const ContractRequestExecutor().execute(
              plan,
              draft,
              resolveSecret: (_) async => null,
              cancellation: cancellation,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (value) => value.code,
                'code',
                'cancelled',
              ),
            ),
          );
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Unsaved', 'Stale'),
          );
          await expectLater(
            const ContractRequestExecutor().execute(
              plan,
              draft,
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (value) => value.code,
                'code',
                'request.draft.stale',
              ),
            ),
          );
          expect(seen.length, 7);
          expect(await file.readAsBytes(), utf8.encode(source));
          expect(await model.readAsBytes(), utf8.encode(shared));
        },
      );
    }
  }
}
