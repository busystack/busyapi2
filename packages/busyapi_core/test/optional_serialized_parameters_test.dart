import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

Future<ProcessResult> _cli(List<String> args) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    args,
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
    return ProcessResult(process.pid, code, await output, await error);
  } finally {
    if (!exited) {
      process.kill();
      await completion.timeout(const Duration(seconds: 5));
    }
  }
}

List<dynamic> _examples(Map<String, dynamic> result) =>
    result['categories']['openapi']['schema']['serializedExamples'] as List;

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final mode in InitializationMode.values) {
        test(
          '$version $format ${mode.name} optional examples retain Source, Design, HTTP and CLI meaning',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-optional-example-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final seen = <(String, String, String?, List<int>)>[];
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            server.listen((request) async {
              final body = await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              );
              seen.add((
                request.method,
                request.uri.toString(),
                request.headers.value('cookie'),
                body,
              ));
              request.response.statusCode = 204;
              await request.response.close();
            });
            final directory = '${temp.path}/contract';
            final path = await Initializer.create(
              destination: directory,
              title: 'Omission 雪😀',
              apiVersion: 'business',
              openapi: version,
              format: format,
              mode: mode,
            );
            final file = File(path),
                shared = File('$directory/examples.$format');
            final document = {
              'openapi': version,
              'info': {'title': 'Omission 雪😀', 'version': 'business'},
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              'paths': {
                '/items': {
                  'get': {
                    'operationId': 'readItems',
                    'parameters': [
                      {
                        'name': 'ids',
                        'in': 'query',
                        'required': false,
                        'style': 'form',
                        'explode': true,
                        'schema': {
                          'type': 'array',
                          'items': {'type': 'integer'},
                          'maxItems': 0,
                        },
                        'examples': {
                          'Empty': {r'$ref': 'examples.$format#/Array'},
                        },
                      },
                      {
                        'name': 'values',
                        'in': 'cookie',
                        'style': 'form',
                        'explode': true,
                        'schema': {'type': 'object', 'maxProperties': 0},
                        'examples': {
                          'Empty': {r'$ref': 'examples.$format#/Object'},
                        },
                      },
                    ],
                    'responses': {
                      '204': {'description': 'No content'},
                    },
                  },
                },
              },
              'x-literal': {
                'serializedValue': '',
                'value': 'EXACT',
                'flag': false,
              },
            };
            final source =
                '${format == 'yaml' ? '# Keep outside the edit\r\n' : ''}${jsonEncode(document)}\r\n'
                    .replaceAll('"EXACT"', '9007199254740993.00');
            final sharedText = format == 'json'
                ? '${jsonEncode({
                    'Array': {'dataValue': [], 'serializedValue': ''},
                    'Object': {'dataValue': <String, Object?>{}, 'serializedValue': ''},
                  })}\r\n'
                : "# Keep shared alias\r\nAnchor: &empty {dataValue: [], serializedValue: ''}\r\nArray: *empty\r\nObject: {dataValue: {}, serializedValue: ''}\r\n";
            final originalBytes = [239, 187, 191, ...utf8.encode(source)];
            await file.writeAsBytes(originalBytes);
            await shared.writeAsString(sharedText);
            String? configuration;
            if (mode == InitializationMode.project) {
              configuration = jsonEncode({
                'version': 1,
                'roots': [
                  {'name': 'api', 'path': 'openapi.$format'},
                ],
                'tests': [
                  {
                    'name': 'empty-parameters',
                    'operation': {'method': 'get', 'path': '/items'},
                    'parameters': {
                      'query': {'ids': []},
                      'cookie': {'values': <String, Object?>{}},
                    },
                    'expect': {'status': 204},
                  },
                ],
              });
              await File('$directory/busyapi.yaml')
                  .writeAsString(configuration);
            }
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(
              mode == InitializationMode.project ? directory : path,
              engine,
            );
            addTearDown(project.close);
            final root = file.uri.toString(),
                buffer = await project.buffer(root);
            Future<Map<String, dynamic>> check(bool optional) async {
              final result = await project.check(root);
              expect(result['complete'], true, reason: jsonEncode(result));
              final examples = _examples(result);
              expect(examples, hasLength(2));
              final query = examples.singleWhere(
                (entry) =>
                    (entry['parameter']['pointer'] as String).endsWith('/0'),
              );
              final cookie = examples.singleWhere(
                (entry) =>
                    (entry['parameter']['pointer'] as String).endsWith('/1'),
              );
              expect(query['complete'], true);
              expect(query['valid'], optional);
              expect(query['omission'], optional ? 'empty-collection' : null);
              expect(cookie['complete'], true);
              expect(cookie['valid'], true);
              expect(cookie['omission'], 'empty-collection');
              expect(query['resource'], shared.uri.toString());
              expect(
                query['pointer'],
                format == 'json'
                    ? '/Array/serializedValue'
                    : '/Anchor/serializedValue',
              );
              if (!optional) {
                final finding = (result['findings'] as List).singleWhere(
                  (entry) =>
                      entry['code'] == 'example.serialization.incompatible',
                );
                expect(finding['resource'], shared.uri.toString());
                expect(finding['pointer'], query['pointer']);
                final sourceBuffer = await project.buffer(
                  shared.uri.toString(),
                );
                final range = List<int>.from(finding['range'] as List);
                expect(
                  sourceBuffer.text.substring(range[0], range[1]),
                  format == 'json' ? '""' : "''",
                );
              }
              return result;
            }

            final initial = await check(true);
            await project.save(buffer);
            expect(await file.readAsBytes(), originalBytes);
            final cli = await _cli(['check', path, '--json']);
            expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
            final output = jsonDecode(cli.stdout as String) as Map;
            expect(
              output['categories']
                  .single['results']['openapi']['schema']['serializedExamples'],
              _examples(initial),
            );
            final plan = await project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1items/get',
            );
            addTearDown(plan.close);
            final draft = OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: {
                OperationRequestDraft.parameterKey('query', 'ids'):
                    const RequestValue.json('[]'),
                OperationRequestDraft.parameterKey('cookie', 'values'):
                    const RequestValue.json('{}'),
              },
            );
            final sent = await const ContractRequestExecutor().execute(
              plan,
              draft,
              resolveSecret: (_) async => null,
            );
            try {
              expect(sent.response.status, 204);
              expect(
                sent.conforming,
                true,
                reason: '${sent.outgoing.toJson()} ${sent.received.toJson()}',
              );
              expect(await sent.response.bytes(), isEmpty);
            } finally {
              await sent.close();
            }
            expect(seen, hasLength(1));
            expect(seen.single.$1, 'GET');
            expect(seen.single.$2, '/items');
            expect(seen.single.$3, isNull);
            expect(seen.single.$4, isEmpty);
            const pointer = '/paths/~1items/get/parameters/0';
            final inspected = await project.inspectObject(root, root, pointer),
                range = List<int>.from(inspected['range'] as List);
            await project.proposeAndApply(
              root,
              PropertySession(
                root: root,
                buffer: root,
                generation: buffer.generation,
                pointer: pointer,
                range: range,
                expected: buffer.text.substring(range[0], range[1]),
              ),
              [
                {'kind': 'set', 'pointer': '$pointer/required', 'value': true},
              ],
            );
            final requiredSource = source.replaceFirst(
              '"required":false',
              '"required":true',
            );
            expect(buffer.text, requiredSource);
            await check(false);
            expect(plan.outdated, true);
            expect(
              plan.ensureCurrentPreparation,
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'request.draft.stale',
                ),
              ),
            );
            expect(await file.readAsBytes(), originalBytes);
            project.store.undo();
            expect(buffer.text, source);
            await check(true);
            project.store.redo();
            expect(buffer.text, requiredSource);
            await check(false);
            project.store.undo();
            await check(true);
            final replacement = sharedText.replaceFirst(
              format == 'json' ? '"serializedValue":""' : "serializedValue: ''",
              format == 'json'
                  ? '"serializedValue":"other=0"'
                  : "serializedValue: 'other=0'",
            );
            final sharedBuffer = await project.buffer(shared.uri.toString());
            project.store.replace(sharedBuffer.id, replacement);
            final edited = await project.check(root);
            expect(edited['unsaved'], true);
            expect(
              _examples(edited).where((entry) => entry['valid'] == false),
              hasLength(1),
            );
            final saved = await project.check(root, saved: true);
            expect(saved['complete'], true);
            expect(
              _examples(saved).every((entry) => entry['valid'] == true),
              true,
            );
            project.store.undo();
            expect(sharedBuffer.text, sharedText);
            await check(true);
            final mockPlan = await project.prepareMock(root);
            addTearDown(mockPlan.close);
            final mock = await mockPlan.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            addTearDown(mock.stop);
            final client = HttpClient();
            addTearDown(() => client.close(force: true));
            for (final (suffix, status) in [
              ('/items', 204),
              ('/items?ids=1', 422),
            ]) {
              final request = await client.getUrl(mock.baseUri.resolve(suffix)),
                  response = await request.close();
              expect(response.statusCode, status);
              await response.drain<void>();
            }
            if (configuration != null) {
              final tested = await _cli([
                'test',
                directory,
                '--case',
                'empty-parameters',
                '--json',
              ]);
              expect(
                tested.exitCode,
                0,
                reason: '${tested.stdout}\n${tested.stderr}',
              );
              expect(
                (jsonDecode(tested.stdout as String) as Map)['complete'],
                true,
              );
              expect(seen, hasLength(2));
              expect(seen.last.$2, '/items');
              expect(seen.last.$3, isNull);
              expect(seen.last.$4, isEmpty);
            }
            await project.save(buffer);
            await project.save(sharedBuffer);
            expect(await file.readAsBytes(), originalBytes);
            expect(await shared.readAsString(), sharedText);
            expect(
              File('$directory/busyapi.yaml').existsSync(),
              mode == InitializationMode.project,
            );
            if (configuration != null)
              expect(
                await File('$directory/busyapi.yaml').readAsString(),
                configuration,
              );
            final reopened = await BusyProject.open(path, engine);
            addTearDown(reopened.close);
            expect((await reopened.check(root))['complete'], true);
            expect(
              _examples(await reopened.check(root))
                  .every((entry) => entry['omission'] == 'empty-collection'),
              true,
            );
          },
        );
      }
    }
  }
}
