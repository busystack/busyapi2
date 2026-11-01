import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory directory;
  late EngineProcess engine;
  BusyProject? project;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('busyapi-followup-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    project?.close();
    project = null;
    await engine.close();
    await directory.delete(recursive: true);
  });

  Future<OperationRequestPlan> prepare(
    String version,
    Map<String, Object?> operation, {
    int? port,
    List<Map<String, Object?>> tests = const [],
  }) async {
    final file = File('${directory.path}/openapi.json');
    file.writeAsStringSync(
      jsonEncode({
        'openapi': version,
        'info': {'title': 'Synthetic follow-up checks', 'version': '1'},
        if (port != null)
          'servers': [
            {'url': 'http://127.0.0.1:$port'},
          ],
        'paths': {
          '/pets': {'get': operation},
        },
      }),
    );
    File('${directory.path}/busyapi.yaml').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'roots': [
          {'name': 'api', 'path': 'openapi.json'},
        ],
        if (tests.isNotEmpty) 'tests': tests,
      }),
    );
    project = await BusyProject.open(directory.path, engine);
    final checked = await project!.check(file.uri.toString());
    final op = (checked['projection']['operations'] as List).single as Map;
    final plan = await project!.prepareRequest(
      file.uri.toString(),
      resource: op['resource'] as String,
      pointer: op['pointer'] as String,
      occurrence: op['occurrence'] as String,
    );
    addTearDown(plan.close);
    return plan;
  }

  for (final version in ['3.1.2', '3.2.1']) {
    for (final media in ['application/json', 'application/json;profile=Case']) {
      test(
        'R01 $version exact mock bytes retain media declaration $media',
        () async {
          final plan = await prepare(version, {
            'responses': {
              '200': {
                'description': 'ok',
                'content': {
                  media: {
                    'example': {'amount': 9007199254740993, r'$ref': 'literal'},
                  },
                  if (media.contains(';'))
                    'application/json;profile=Other': {
                      'example': {'amount': 9007199254740995, r'$ref': 'other'},
                    },
                },
              },
            },
          });
          final mock = await project!.prepareMock(plan.snapshot.root);
          addTearDown(mock.close);
          final run = await mock.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(run.stop);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          for (final accept in [
            null,
            media,
            if (media.contains(';')) 'application/json;profile=Other',
          ]) {
            final request = await client.getUrl(run.baseUri.resolve('/pets'));
            if (accept != null) request.headers.set('accept', accept);
            final response = await request.close();
            final bytes = await response.fold<List<int>>(
              [],
              (all, next) => all..addAll(next),
            );
            final text = utf8.decode(bytes);
            expect(response.statusCode, 200, reason: text);
            expect(response.headers.value('content-type'), accept ?? media);
            expect(
              text,
              accept == 'application/json;profile=Other'
                  ? '{"amount":9007199254740995,"\u0024ref":"other"}'
                  : '{"amount":9007199254740993,"\u0024ref":"literal"}',
            );
            expect(response.headers.value('sl-violations'), isNull);
          }
          await run.stop();
          expect(await run.exitCode, 0);
        },
      );
    }

    for (final collision in [false, true]) {
      test('R02 $version default numeric example identity collision=$collision', () async {
        final values = <String, Map<String, Object?>>{
          // Keep this textual order: JavaScript enumerates these keys as 1, 2.
          '2': {if (!collision) 'selected': 'two', 'amount': 9007199254740993},
          '1': {if (!collision) 'selected': 'one', 'amount': 9007199254740992},
          'default': {'amount': 9007199254740995},
        };
        final plan = await prepare(version, {
          'responses': {
            '200': {
              'description': 'ok',
              'content': {
                'application/json': {
                  'examples': {
                    for (final entry in values.entries)
                      entry.key: {'value': entry.value},
                  },
                },
              },
            },
          },
        });
        final mock = await project!.prepareMock(plan.snapshot.root);
        addTearDown(mock.close);
        final run = await mock.start(
          nodeExecutable: runtimeNode,
          helper: '$testBundle/libexec/busyapi/mock-server.cjs',
        );
        addTearDown(run.stop);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        for (final key in [null, '1', '2', 'default']) {
          final request = await client.getUrl(run.baseUri.resolve('/pets'));
          if (key != null) request.headers.set('prefer', 'example=$key');
          final response = await request.close();
          final text = await utf8.decoder.bind(response).join();
          expect(response.statusCode, 200, reason: text);
          expect(text, jsonEncode(values[key ?? '1']));
          expect(response.headers.value('sl-violations'), isNull);
        }
        await run.stop();
        expect(await run.exitCode, 0);
      });
      test('R02 $version invalid request uses negotiated example collision=$collision', () async {
        final values = <String, Map<String, Object?>>{
          'first': {
            if (!collision) 'marker': 'first',
            'amount': 9007199254740992,
          },
          'other': {
            if (!collision) 'marker': 'other',
            'amount': 9007199254740993,
          },
        };
        Map<String, Object?> response() => {
          'description': 'Example response',
          'content': {
            'application/json': {
              'examples': {
                for (final entry in values.entries)
                  entry.key: {'value': entry.value},
              },
            },
          },
        };
        final plan = await prepare(version, {
          'parameters': [
            {
              'name': 'id',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': {'200': response(), '422': response()},
        });
        final checked = await project!.check(plan.snapshot.root);
        expect(checked['complete'], true);
        expect(checked['findings'], isEmpty);
        final mock = await project!.prepareMock(plan.snapshot.root);
        addTearDown(mock.close);
        final run = await mock.start(
          nodeExecutable: runtimeNode,
          helper: '$testBundle/libexec/busyapi/mock-server.cjs',
        );
        addTearDown(run.stop);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        for (final header in [false, true]) {
          for (final sample in [
            ('/pets?id=ok', 'other', null, 200, 'other'),
            ('/pets', null, null, 422, 'first'),
            ('/pets', 'other', null, 422, 'first'),
            ('/pets', 'other', 422, 422, 'other'),
            // An explicit non-error code still suppresses the preference.
            ('/pets', 'other', 200, 422, 'first'),
            // Prism honors any expected error code, even when its chosen
            // response is the earlier 422 declaration, rather than 400.
            ('/pets', 'other', 400, 422, 'other'),
          ]) {
            final controls = [
              if (sample.$2 != null)
                '${header ? 'example' : '__example'}=${sample.$2}',
              if (sample.$3 != null)
                '${header ? 'code' : '__code'}=${sample.$3}',
            ];
            final route = header || controls.isEmpty
                ? sample.$1
                : '${sample.$1}${sample.$1.contains('?') ? '&' : '?'}${controls.join('&')}';
            final request = await client.getUrl(run.baseUri.resolve(route));
            if (header && controls.isNotEmpty)
              request.headers.set('prefer', controls.join(', '));
            final result = await request.close();
            final bytes = await result.fold<List<int>>(
              [],
              (all, next) => all..addAll(next),
            );
            final context =
                '$route Prefer=${header ? controls : []}: ${utf8.decode(bytes)}';
            expect(result.statusCode, sample.$4, reason: context);
            expect(
              bytes,
              utf8.encode(jsonEncode(values[sample.$5])),
              reason: context,
            );
            expect(result.headers.value('content-type'), 'application/json');
            final violations = result.headers.value('sl-violations');
            if (sample.$4 == 422) {
              expect(violations, isNotNull, reason: context);
              expect(
                (jsonDecode(violations!) as List).any(
                  (v) =>
                      (v['location'] as List).first == 'request' &&
                      v['severity'] == 'Error',
                ),
                true,
              );
            } else {
              expect(violations, isNull);
            }
          }
        }
        await run.stop();
        expect(await run.exitCode, 0);
      });
    }

    for (final cases in [false, true]) {
      test(
        'R03 $version malformed media ${cases ? 'does not abort selected cases' : 'remains inspectable'}',
        () async {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(server.close);
          var requests = 0;
          server.listen((socket) async {
            final bytes = <int>[];
            await for (final next in socket) {
              bytes.addAll(next);
              if (!ascii.decode(bytes).contains('\r\n\r\n')) continue;
              final media = requests++ == 0
                  ? 'application/json;profile="'
                  : 'application/json';
              socket.write(
                'HTTP/1.1 200 OK\r\nContent-Type: $media\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}',
              );
              await socket.flush();
              await socket.close();
              break;
            }
          });
          final plan = await prepare(
            version,
            {
              'responses': {
                '200': {
                  'description': 'ok',
                  'content': {
                    'application/json': {
                      'schema': {'type': 'object'},
                    },
                  },
                },
              },
            },
            port: server.port,
            tests: [
              for (final name in ['malformed', 'valid'])
                {
                  'name': name,
                  'operation': {'method': 'GET', 'path': '/pets'},
                },
            ],
          );
          if (cases) {
            final report = await const ContractTestRunner().run(
              project!,
              plan.snapshot.root,
              selectedCases: ['malformed', 'valid'],
              resolveSecret: (_) async => null,
            );
            expect(requests, 2);
            expect(report.cases.map((c) => c.name), ['malformed', 'valid']);
            expect(report.cases.map((c) => c.passed), [false, true]);
            expect(report.passed, false);
            expect(report.complete, true);
            expect(report.toJson()['status'], 'failed');
            requests = 0;
            final junit = '${directory.path}/report.xml';
            final cli = await Process.run(
              '$testBundle/busyapi',
              [
                'test',
                directory.path,
                '--case',
                'malformed',
                '--case',
                'valid',
                '--junit',
                junit,
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 1, reason: '${cli.stderr}\n${cli.stdout}');
            final machine = jsonDecode(cli.stdout as String) as Map;
            expect(machine['status'], 'failed');
            expect((machine['cases'] as List).map((c) => c['name']), [
              'malformed',
              'valid',
            ]);
            expect((machine['cases'] as List).map((c) => c['passed']), [
              false,
              true,
            ]);
            expect(requests, 2);
            final xml = await File(junit).readAsString();
            expect(xml, contains('tests="2" failures="1" errors="0"'));
            expect(xml, contains('name="malformed"'));
            expect(xml, contains('name="valid"'));
            return;
          }
          // The request path retains the response for inspection after validation.
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(planIdentity: plan.identity),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(await result.response.bytes(), utf8.encode('{}'));
          expect(
            result.response.headers
                .where((h) => h.$1.toLowerCase() == 'content-type')
                .single
                .$2,
            'application/json;profile="',
          );
          expect(result.received.valid, false);
          expect(result.conforming, false);
          expect(
            result.received.findings.any(
              (f) => f['code'] == 'runtime.response.media-type',
            ),
            true,
          );
          await expectLater(
            plan.planResponseExample(
              '{}',
              status: 200,
              headers: result.response.headers,
              receiptComplete: true,
              redacted: true,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (f) => f.code,
                'code',
                'example.destination',
              ),
            ),
          );
        },
      );
    }

    test(
      'R03 $version malformed authored and outgoing media fail structurally',
      () async {
        final plan = await prepare(version, {
          'requestBody': {
            'content': {
              'application/json;profile="': {'schema': {}},
              'application/json': {'schema': {}},
              'multipart/form-data': {'schema': {}},
            },
          },
          'responses': {
            '200': {'description': 'ok'},
          },
        }, port: 1);
        Future<PreparedContractRequest> build(RequestBodyDraft body) =>
            const ContractRequestBuilder().build(
              plan,
              OperationRequestDraft(planIdentity: plan.identity, body: body),
              resolveSecret: (_) async => null,
            );
        // A malformed authored candidate must not prevent a valid later match.
        final valid = await build(
          const RequestBodyDraft.raw(mediaType: 'application/json', text: '{}'),
        );
        expect(valid.body!.mediaType, 'application/json');
        await expectLater(
          build(
            const RequestBodyDraft.raw(
              mediaType: 'application/json;profile="',
              text: '{}',
            ),
          ),
          throwsA(
            isA<CoreFailure>().having(
              (f) => f.code,
              'code',
              'request.body.media-type',
            ),
          ),
        );
        await expectLater(
          build(
            const RequestBodyDraft.multipart([], [
              MultipartFileValue(
                name: 'part',
                path: 'must-not-be-opened',
                mediaType: 'application/json;profile="',
              ),
            ]),
          ),
          throwsA(
            isA<CoreFailure>().having(
              (f) => f.code,
              'code',
              'request.media-type',
            ),
          ),
        );
      },
    );

    test(
      'R04 $version reserved query expansion preserves only valid percent triples on wire',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final targets = <String>[];
        server.listen((socket) async {
          final bytes = <int>[];
          await for (final next in socket) {
            bytes.addAll(next);
            final text = ascii.decode(bytes);
            if (!text.contains('\r\n\r\n')) continue;
            targets.add(text.split('\r\n').first.split(' ')[1]);
            socket.write(
              'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
            );
            await socket.flush();
            await socket.close();
            break;
          }
        });
        final plan = await prepare(version, {
          'parameters': [
            for (final reserved in [false, true])
              {
                'name': reserved ? 'reserved' : 'regular',
                'in': 'query',
                'allowReserved': reserved,
                'schema': {'type': 'string'},
              },
          ],
          'responses': {
            '204': {'description': 'ok'},
          },
        }, port: server.port);
        for (final sample in [
          (true, 'x%2By', 'x%2By'),
          (false, 'x%2By', 'x%252By'),
          (true, 'x%y', 'x%25y'),
          (true, 'x%', 'x%25'),
          (true, 'x%2', 'x%252'),
          (true, '%2b%252B', '%2B%252B'),
          (true, '%26%3D%23&=#', '%26%3D%23%26%3D%23'),
          (true, '雪%2B+', '%E9%9B%AA%2B+'),
        ]) {
          final name = sample.$1 ? 'reserved' : 'regular';
          final request = await const ContractRequestBuilder().build(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: {
                OperationRequestDraft.parameterKey('query', name):
                    RequestValue.text(sample.$2),
              },
            ),
            resolveSecret: (_) async => null,
          );
          final response = await const ContractHttpTransport().send(request);
          await response.close();
          expect(targets.last, '/pets?$name=${sample.$3}', reason: sample.$2);
          expect(Uri.parse(targets.last).hasFragment, false);
          expect(Uri.parse(targets.last).queryParameters.keys, [name]);
        }
      },
    );
  }
}
