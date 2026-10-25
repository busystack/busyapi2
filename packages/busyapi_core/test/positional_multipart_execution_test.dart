import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _media = 'multipart/mixed; boundary=Fixture';

String _wire(String value, bool nested) {
  final first =
      '--Fixture\r\nContent-Type: application/json\r\n\r\n'
      '{"id":$value}\r\n';
  final second = nested
      ? 'Content-Type: multipart/mixed; boundary=Inner\r\n\r\n'
            '--Inner\r\nContent-Type: text/plain\r\n\r\nfalse\r\n'
            '--Inner\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n'
            'café 東京\r\n--Inner--\r\n'
      : 'Content-Type: text/plain; charset=utf-8\r\n\r\n';
  return '$first--Fixture\r\n$second\r\n--Fixture--\r\n';
}

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['json', 'yaml']) {
      for (final nested in [false, true]) {
        test(
          '$version $format ${nested ? 'nested' : 'ordered'} multipart uses actual HTTP bytes and installed CLI',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-positional-multipart-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final seen = <(String, String, String, List<int>)>[];
            var roundResponse = false;
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
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
              request.response.headers.set('content-type', _media);
              request.response.add(
                roundResponse
                    ? utf8.encode(_wire('9007199254740992', nested))
                    : bytes,
              );
              await request.response.close();
            });
            final item = nested
                ? {
                    'type': 'array',
                    'minItems': 2,
                    'maxItems': 2,
                    'prefixItems': [
                      {'type': 'boolean', 'const': false},
                      {'type': 'string', 'const': 'café 東京'},
                    ],
                    'items': false,
                  }
                : {'type': 'string', 'maxLength': 0};
            final media = {
              'schema': {
                'type': 'array',
                'minItems': 2,
                'maxItems': 2,
                'prefixItems': [
                  {r'$ref': 'part.yaml#/Part'},
                  item,
                ],
                'items': false,
              },
              'prefixEncoding': [
                {'contentType': 'application/json'},
                if (nested)
                  {
                    'contentType': 'multipart/mixed',
                    'itemEncoding': {'contentType': 'text/plain'},
                  }
                else
                  {'contentType': 'text/plain; charset=utf-8'},
              ],
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
                : '\ufeff# Keep source and Unicode 雪\r\n'
                      'openapi: $version\r\n'
                      'info: {title: Original, version: api-version}\r\n'
                      'servers: [{url: "http://127.0.0.1:${server.port}"}]\r\n'
                      'paths:\r\n  /parts:\r\n    post: ${jsonEncode(operation)}\r\n';
            const shared =
                '# Keep exact model and alias ownership\r\n'
                'Part: &part\r\n  type: object\r\n  contentEncoding: base64\r\n  required: [id]\r\n'
                '  properties:\r\n    id: {type: integer, enum: [9007199254740993.00]}\r\n'
                '  additionalProperties: false\r\nMirror: *part\r\n';
            final file = File('${directory.path}/api.$format');
            await file.writeAsString(source);
            final model = File('${directory.path}/part.yaml');
            await model.writeAsString(shared);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final buffer = await project.buffer(file.uri.toString());
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst('Original', 'Unsaved'),
            );
            final checked = await project.check(buffer.id);
            expect(checked['complete'], isTrue);
            expect(
              (checked['findings'] as List).where(
                (f) => f['severity'] == 'error',
              ),
              isEmpty,
            );
            final plan = await project.prepareRequest(
              buffer.id,
              resource: buffer.id,
              pointer: '/paths/~1parts/post',
            );
            addTearDown(plan.close);
            final originalBytes = await file.readAsBytes();
            for (final (value, responseRounded) in [
              ('9007199254740993.00', false),
              ('9007199254740992', false),
              ('9007199254740993.00', true),
            ]) {
              roundResponse = responseRounded;
              final wire = _wire(value, nested);
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(mediaType: _media, text: wire),
                ),
                resolveSecret: (_) async => throw StateError('No credentials'),
              );
              try {
                final validInput = value == '9007199254740993.00';
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
                expect(result.outgoing.valid, validInput);
                expect(result.received.valid, validInput && !responseRounded);
                expect(result.conforming, validInput && !responseRounded);
                expect((seen.last.$1, seen.last.$2), ('POST', '/parts'));
                expect(seen.last.$3, _media);
                expect(seen.last.$4, utf8.encode(wire));
                final response = responseRounded
                    ? utf8.encode(_wire('9007199254740992', nested))
                    : utf8.encode(wire);
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
            final cases = [
              for (final valid in [true, false])
                {
                  'name': valid ? 'exact' : 'rounded',
                  'operation': {'method': 'post', 'path': '/parts'},
                  'body': {
                    'mediaType': _media,
                    'value': _wire(
                      valid ? '9007199254740993.00' : '9007199254740992',
                      nested,
                    ),
                  },
                  'expect': {'status': 200},
                },
            ];
            await File('${directory.path}/busyapi.yaml').writeAsString(
              jsonEncode({
                'version': 1,
                'roots': [
                  {'name': 'api', 'path': 'api.$format'},
                ],
                'tests': cases,
              }),
            );
            final cli = await Process.run(
              '$testBundle/busyapi',
              [
                'test',
                directory.path,
                '--case',
                'exact',
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
            expect((report['cases'] as List).map((c) => c['passed']), [
              true,
              false,
            ]);
            expect(seen.length, 5);
            for (final (index, value) in cases.indexed) {
              expect(
                (seen[index + 3].$1, seen[index + 3].$2),
                ('POST', '/parts'),
              );
              expect(seen[index + 3].$3, _media);
              expect(
                seen[index + 3].$4,
                utf8.encode((value['body'] as Map)['value'] as String),
              );
            }
            final cancellation = RunCancellation()..cancel();
            final draft = OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.raw(
                mediaType: _media,
                text: _wire('9007199254740993.00', nested),
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
                isA<CoreFailure>().having((f) => f.code, 'code', 'cancelled'),
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
                  (f) => f.code,
                  'code',
                  'request.draft.stale',
                ),
              ),
            );
            expect(seen.length, 5);
            expect(await file.readAsBytes(), originalBytes);
            expect(await model.readAsString(), shared);
            expect(buffer.text, contains('Stale'));
          },
        );
      }
    }
  }
}
