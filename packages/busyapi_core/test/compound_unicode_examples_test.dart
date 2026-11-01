import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _render(Object value, String format) =>
    '${format == 'yaml' ? '# Keep MIME ownership and CRLF\r\n' : ''}'
    '${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';

({String type, String wire, Map<String, Object> description}) _media(
  bool nested,
) {
  const leafType = 'text/plain; charset=utf-8';
  const leafSchema = {
    'type': 'string',
    'enum': ['A'],
  };
  const namedSchema = {
    'type': 'object',
    'required': ['label'],
    'properties': {'label': leafSchema},
  };
  const leaf =
      '--Leaf\r\nContent-Disposition: form-data; name="label"\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n\r\nA\r\n--Leaf--\r\n';
  return nested
      ? (
          type: 'multipart/mixed; boundary=Outer',
          wire:
              '--Outer\r\nContent-Type: multipart/form-data; boundary=Leaf\r\n\r\n'
              '$leaf\r\n--Outer--\r\n',
          description: {
            'schema': {'type': 'array', 'minItems': 1, 'items': namedSchema},
            'itemEncoding': {
              'contentType': 'multipart/form-data; boundary=Leaf',
              'encoding': {
                'label': {'contentType': leafType},
              },
            },
          },
        )
      : (
          type: 'multipart/form-data; boundary=Leaf',
          wire: leaf,
          description: {
            'schema': namedSchema,
            'encoding': {
              'label': {'contentType': leafType},
            },
          },
        );
}

Future<({int code, Map report, String error})> _check(String path) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    ['check', path, '--json'],
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  var exited = false;
  final completion = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  try {
    await process.stdin.close();
    final code = await completion.timeout(const Duration(seconds: 60));
    return (
      code: code,
      report: jsonDecode(await output) as Map,
      error: await error,
    );
  } finally {
    if (!exited) {
      process.kill();
      await completion.timeout(const Duration(seconds: 5));
    }
  }
}

List _samples(Map result) =>
    result['categories']['openapi']['schema']['serializedExamples'] as List;

void main() {
  for (final version in ['3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final nested in [false, true]) {
        test(
          '$version $format nested=$nested MIME eligibility uses captured buffers while actual bytes remain valid',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-compound-unicode-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final seen = <List<int>>[];
            final media = _media(nested);
            server.listen((request) async {
              expect(request.method, 'POST');
              expect(request.uri.toString(), '/v1/data');
              expect(request.headers.value('content-type'), media.type);
              seen.add(
                await request.fold<List<int>>(
                  [],
                  (all, chunk) => all..addAll(chunk),
                ),
              );
              request.response.statusCode = 204;
              await request.response.close();
            });
            final root = File('${temp.path}/api.$format'),
                body = File('${temp.path}/body.$format'),
                examples = File('${temp.path}/examples.$format');
            final source = _render({
              'openapi': version,
              'info': {'title': 'Original MIME root', 'version': 'business'},
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}/v1'},
              ],
              'paths': {
                '/data': {
                  'post': {
                    'requestBody': {
                      r'$ref':
                          'body.$format#/components/requestBodies/Body~1~0',
                    },
                    'responses': {
                      '204': {'description': 'None'},
                    },
                  },
                },
              },
              'x-kept': {
                'n': 'EXACT',
                'flag': false,
                'zero': 0,
                'empty': '',
                'text': '雪😀',
              },
            }, format);
            final bodySource = _render({
              'openapi': '3.2.1',
              'info': {'title': 'Defining body', 'version': 'business'},
              'paths': <String, Object?>{},
              'components': {
                'requestBodies': {
                  'Body/~': {
                    'required': true,
                    'content': {
                      media.type: {
                        ...media.description,
                        'examples': {
                          'Native': {
                            r'$ref':
                                'examples.$format#/components/examples/Value~1~0',
                          },
                        },
                      },
                    },
                  },
                },
              },
            }, format);
            final exampleSource = _render({
              'openapi': '3.2.1',
              'info': {'title': 'Defining example', 'version': 'business'},
              'paths': <String, Object?>{},
              'components': {
                'examples': {
                  'Value/~': {'serializedValue': media.wire},
                },
              },
            }, format);
            await root.writeAsBytes([239, 187, 191, ...utf8.encode(source)]);
            await body.writeAsString(bodySource);
            await examples.writeAsString(exampleSource);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(root.path, engine);
            addTearDown(project.close);
            final rootBuffer = await project.buffer(root.uri.toString());
            final original = await project.check(rootBuffer.id);
            expect(original['complete'], true, reason: jsonEncode(original));
            expect(_samples(original), hasLength(1));
            expect(_samples(original).single['valid'], true);
            expect(
              original['categories']['openapi']['schema']['producerVersion'],
              '1.18.0+46',
            );
            final bodyBuffer = await project.buffer(body.uri.toString()),
                exampleBuffer = await project.buffer(examples.uri.toString());
            project.store.replace(
              bodyBuffer.id,
              bodyBuffer.text.replaceAll('charset=utf-8', 'charset=iso-8859-1'),
            );
            project.store.replace(
              exampleBuffer.id,
              exampleBuffer.text.replaceAll(
                'charset=utf-8',
                'charset=iso-8859-1',
              ),
            );
            final current = await project.check(rootBuffer.id);
            expect(current['complete'], false, reason: jsonEncode(current));
            final sample = _samples(current).single;
            expect(sample['complete'], false);
            expect(sample['valid'], false);
            expect(sample['resource'], exampleBuffer.id);
            expect(
              sample['pointer'],
              '/components/examples/Value~1~0/serializedValue',
            );
            final finding = (current['findings'] as List)
                .cast<Map>()
                .singleWhere(
                  (f) => f['code'] == 'example.serialization.incomplete',
                );
            expect(finding['resource'], exampleBuffer.id);
            expect(finding['pointer'], sample['pointer']);
            final range = finding['range'] as List;
            expect(
              exampleBuffer.text.substring(range[0] as int, range[1] as int),
              contains('charset=iso-8859-1'),
            );
            expect(
              (finding['details'] as List).cast<Map>().any(
                (d) => d['detailCode'] == 'runtime.media.unicode.unsupported',
              ),
              true,
            );
            final saved = await project.check(rootBuffer.id, saved: true);
            expect(saved['complete'], true, reason: jsonEncode(saved));
            expect(_samples(saved).single['valid'], true);
            final limitedPlan = await project.prepareRequest(
              rootBuffer.id,
              resource: rootBuffer.id,
              pointer: '/paths/~1data/post',
            );
            addTearDown(limitedPlan.close);
            final wire = media.wire.replaceAll(
              'charset=utf-8',
              'charset=iso-8859-1',
            );
            Future<void> execute(
              OperationRequestPlan plan,
              bool complete,
            ) async {
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(mediaType: media.type, text: wire),
                ),
                resolveSecret: (_) async => null,
              );
              try {
                expect(seen.last, utf8.encode(wire));
                expect(
                  result.outgoing.complete,
                  complete,
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
            }

            await execute(limitedPlan, false);
            final ineligibleSource = exampleBuffer.text;
            // The contract's example limitation remains incomplete. Removing
            // that witness changes no schema or MIME bytes for this wire check.
            project.store.replace(
              exampleBuffer.id,
              _render({
                'openapi': '3.2.1',
                'info': {'title': 'Defining example', 'version': 'business'},
                'paths': <String, Object?>{},
                'components': {
                  'examples': {
                    'Value/~': {'summary': 'No serialized witness'},
                  },
                },
              }, format),
            );
            expect((await project.check(rootBuffer.id))['complete'], true);
            final plan = await project.prepareRequest(
              rootBuffer.id,
              resource: rootBuffer.id,
              pointer: '/paths/~1data/post',
            );
            addTearDown(plan.close);
            await execute(plan, true);
            project.store.replace(exampleBuffer.id, ineligibleSource);
            final cli = await _check(root.path);
            expect(cli.code, 0, reason: cli.error);
            expect(cli.report['complete'], true);
            final copy = await Directory('${temp.path}/cli').create();
            final cliRoot = File('${copy.path}/api.$format');
            await cliRoot.writeAsString(source);
            await File('${copy.path}/body.$format')
                .writeAsString(bodyBuffer.text);
            await File('${copy.path}/examples.$format')
                .writeAsString(exampleBuffer.text);
            final limited = await _check(cliRoot.path);
            expect(
              limited.code,
              2,
              reason: '${limited.report}\n${limited.error}',
            );
            expect(limited.report['complete'], false);
            final reports =
                (limited.report['categories'] as List)
                        .single['results']['openapi']['schema']['serializedExamples']
                    as List;
            expect(reports.single['complete'], false);
            expect(reports.single['valid'], false);
            await project.save(rootBuffer);
            expect(await root.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(source),
            ]);
            expect(await body.readAsString(), bodySource);
            expect(await examples.readAsString(), exampleSource);
            project.store.replace(
              exampleBuffer.id,
              exampleBuffer.text.replaceFirst(
                '"Defining example"',
                '"New revision"',
              ),
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
            await expectLater(
              project.check(rootBuffer.id, cancelled: () => true),
              throwsA(
                isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
              ),
            );
            expect(seen, hasLength(2));
          },
        );
      }
    }
  }
}
