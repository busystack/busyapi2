import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _mediaType = 'multipart/form-data; boundary=Wire';
String _wire(String charset, [String value = 'café']) =>
    '--Wire\r\nContent-Disposition: form-data; name="label"\r\n'
    'Content-Type: text/plain; charset=$charset\r\n\r\n$value\r\n--Wire--\r\n';
List<int> _bytes(String charset) => charset == 'utf-8'
    ? utf8.encode(_wire(charset))
    : latin1.encode(_wire(charset));

String _source(String version, String format, int port, String charset) {
  final schema = {
    'type': 'object',
    'required': ['label'],
    'properties': {
      'label': {
        'type': 'string',
        'enum': ['café'],
      },
    },
  };
  final content = {
    'schema': schema,
    'encoding': {
      'label': {'contentType': 'text/plain; charset=$charset'},
    },
    'examples': {
      'Value': {'value': _wire(charset)},
    },
  };
  final swagger = version == '2.0';
  final value = {
    if (swagger) ...{
      'swagger': version,
      'host': '127.0.0.1:$port',
      'basePath': '/v1',
      'schemes': ['http'],
      'consumes': [_mediaType],
      'produces': ['application/json'],
    } else ...{
      'openapi': version,
      'servers': [
        {'url': 'http://127.0.0.1:$port/v1'},
      ],
    },
    'info': {'title': 'Original MIME 雪😀', 'version': 'business'},
    'paths': {
      '/upload': {
        'post': {
          if (swagger)
            'parameters': [
              {
                'name': 'label',
                'in': 'formData',
                'type': 'string',
                'required': true,
                'enum': ['café'],
              },
            ]
          else
            'requestBody': {
              'required': true,
              'content': {_mediaType: content},
            },
          'responses': {
            '200': {
              'description': 'Reply',
              if (swagger)
                'schema': {'type': 'object'}
              else
                'content': {
                  'application/json': {
                    'schema': {'type': 'object'},
                  },
                },
            },
          },
        },
      },
      '/reply': {
        'get': {
          if (swagger) 'produces': [_mediaType],
          'responses': {
            '200': {
              'description': 'MIME reply',
              if (swagger) ...{
                'schema': schema,
                'examples': {_mediaType: _wire(charset)},
              } else
                'content': {_mediaType: content},
            },
          },
        },
      },
    },
    'x-number': 'EXACT',
    'x-literal': {
      r'$ref': 'literal.json',
      'false': false,
      'null': null,
      'zero': 0,
      'empty': '',
    },
  };
  final source = format == 'yaml'
      ? '# Keep MIME source and CRLF\r\n${value.entries.map((entry) => '${jsonEncode(entry.key)}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n'
      : '${jsonEncode(value)}\r\n';
  return source.replaceFirst('"EXACT"', '9007199254740993.00');
}

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final charset in ['utf-8', 'iso-8859-1']) {
        test(
          '$version $format $charset MIME byte conformance and captured workflows',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-mime-text-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final seen =
                <
                  ({
                    String method,
                    String uri,
                    String? media,
                    int length,
                    List<int> bytes,
                  })
                >[];
            server.listen((request) async {
              final bytes = await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              );
              seen.add((
                method: request.method,
                uri: request.uri.toString(),
                media: request.headers.value('content-type'),
                length: request.contentLength,
                bytes: bytes,
              ));
              request.response.headers.contentType = ContentType.json;
              request.response.write('{}');
              await request.response.close();
            });
            final file = File('${directory.path}/api.$format'),
                manifest = File('${directory.path}/busyapi.yaml');
            final original = _source(version, format, server.port, charset);
            await file.writeAsString(original);
            final configuration = jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                {
                  'name': 'mime',
                  'operation': {'method': 'post', 'path': '/upload'},
                  'body': {'mediaType': _mediaType, 'value': _wire(charset)},
                  'expect': {'status': 200, 'mediaType': 'application/json'},
                },
              ],
            });
            await manifest.writeAsString(configuration);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = project.roots.single.id,
                buffer = await project.buffer(root);
            final checked = await project.check(root);
            expect(checked['complete'], true, reason: jsonEncode(checked));
            final plan = await project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1upload/post',
            );
            addTearDown(plan.close);
            Future<ContractRequestResult> execute(
              OperationRequestPlan selected,
              String text, {
              RunCancellation? cancellation,
            }) => const ContractRequestExecutor().execute(
              selected,
              OperationRequestDraft(
                planIdentity: selected.identity,
                body: RequestBodyDraft.raw(mediaType: _mediaType, text: text),
              ),
              resolveSecret: (_) async => null,
              cancellation: cancellation,
            );
            final result = await execute(plan, _wire(charset));
            try {
              expect(
                result.outgoing.complete,
                true,
                reason: '${result.outgoing.findings}',
              );
              expect(
                result.outgoing.valid,
                true,
                reason: '${result.outgoing.findings}',
              );
              expect(result.received.complete, true);
              expect(result.received.valid, true);
            } finally {
              await result.close();
            }
            expect(seen.single.method, 'POST');
            expect(seen.single.uri, '/v1/upload');
            expect(seen.single.media, _mediaType);
            expect(seen.single.length, _bytes(charset).length);
            expect(seen.single.bytes, _bytes(charset));
            expect(buffer.text, original);
            expect(await file.readAsString(), original);
            if (charset == 'utf-8') return;

            final count = seen.length;
            final cancellation = RunCancellation()..cancel();
            await expectLater(
              execute(plan, _wire(charset), cancellation: cancellation),
              throwsA(
                isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
              ),
            );
            await expectLater(
              execute(plan, _wire(charset, '雪')),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'runtime.media.charset',
                ),
              ),
            );
            expect(seen, hasLength(count));
            final invalid = await execute(plan, 'deliberately invalid MIME');
            try {
              expect(invalid.outgoing.valid, false);
              expect(
                invalid.outgoing.findings.any(
                  (finding) =>
                      finding['code'] == 'runtime.form.syntax' &&
                      finding['version'] == 1 &&
                      finding['category'] == 'runtime' &&
                      finding['producer'] == 'busyapi-runtime',
                ),
                true,
              );
              expect(seen.last.bytes, utf8.encode('deliberately invalid MIME'));
            } finally {
              await invalid.close();
            }

            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', directory.path, '--case', 'mime', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
            final report = jsonDecode(cli.stdout as String) as Map;
            expect(report['complete'], true);
            expect(report['passed'], true);
            expect((report['cases'] as List).single['dispatched'], true);
            expect(seen.last.method, 'POST');
            expect(seen.last.uri, '/v1/upload');
            expect(seen.last.media, _mediaType);
            expect(seen.last.length, _bytes(charset).length);
            expect(seen.last.bytes, _bytes(charset));

            final mockPlan = await project.prepareMock(root);
            addTearDown(mockPlan.close);
            final mock = await mockPlan.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            try {
              final client = HttpClient();
              try {
                final request = await client.getUrl(
                  mock.baseUri.resolve('/reply'),
                );
                request.headers.set('accept', _mediaType);
                final reply = await request.close();
                final bytes = await reply.fold<List<int>>(
                  [],
                  (all, chunk) => all..addAll(chunk),
                );
                expect(reply.statusCode, 200);
                expect(reply.headers.value('content-type'), _mediaType);
                expect(
                  reply.headers.value('busyapi-response-validation-complete'),
                  'true',
                );
                expect(reply.contentLength, _bytes(charset).length);
                expect(bytes, _bytes(charset));
              } finally {
                client.close(force: true);
              }
            } finally {
              await mock.stop();
            }

            project.store.replace(
              root,
              original.replaceAll('iso-8859-1', 'utf-8'),
            );
            expect(
              plan.ensureCurrentPreparation,
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'request.draft.stale',
                ),
              ),
            );
            final heldCount = seen.length;
            await expectLater(
              execute(plan, _wire(charset)),
              throwsA(isA<CoreFailure>()),
            );
            expect(seen, hasLength(heldCount));
            final live = await project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1upload/post',
            );
            addTearDown(live.close);
            final unsaved = await execute(live, _wire('utf-8'));
            try {
              expect(unsaved.outgoing.complete, true);
              expect(unsaved.outgoing.valid, true);
            } finally {
              await unsaved.close();
            }
            expect(seen.last.bytes, _bytes('utf-8'));
            expect(await file.readAsString(), original);
            expect(await manifest.readAsString(), configuration);
            project.store.undo();
            expect(buffer.text, original);
            project.store.redo();
            final changed = original.replaceAll('iso-8859-1', 'utf-8');
            expect(buffer.text, changed);
            await project.save(buffer);
            expect(await file.readAsString(), changed);
          },
        );
      }
    }
  }
}
