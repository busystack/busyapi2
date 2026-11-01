import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _media = 'application/x-www-form-urlencoded';
const _wire = 'id=9007199254740993&flag=false&empty=&text=%E9%9B%AA';
const _xml = '<item><id>9007199254740993</id></item>';

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final reusable in version == '3.2.1' ? [false, true] : [false]) {
        test(
          '$version $format literal media keeps bytes and captured meaning reusable=$reusable',
          () async {
            final legacy = version == '2.0';
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-literal-media-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final seen = <(String, String, String?, List<int>)>[];
            server.listen((request) async {
              final body = await request.fold<List<int>>(
                [],
                (all, part) => all..addAll(part),
              );
              seen.add((
                request.method,
                request.uri.toString(),
                request.headers.value('content-type'),
                body,
              ));
              request.response.headers.set('content-type', _media);
              request.response.write(_wire);
              await request.response.close();
            });
            final schema = {
              'type': 'object',
              'required': ['id', 'flag', 'empty', 'text'],
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
                'text': {
                  'type': 'string',
                  'enum': ['雪'],
                },
              },
            };
            var selectedMedia = _media;
            Map<String, Object?> document() {
              final example = selectedMedia == _media ? _wire : _xml;
              final mediaValue = {
                'schema': schema,
                'examples': {
                  'Literal': {'value': example},
                },
              };
              final content = {
                selectedMedia: reusable
                    ? {r'$ref': '#/components/mediaTypes/Shared'}
                    : mediaValue,
              };
              return {
                if (legacy) 'swagger': version else 'openapi': version,
                'info': {'title': 'Keep 雪', 'version': 'api-version'},
                if (reusable)
                  'components': {
                    'mediaTypes': {'Shared': mediaValue},
                  },
                if (legacy) ...{
                  'host': '127.0.0.1:${server.port}',
                  'basePath': '/v1',
                  'schemes': ['http'],
                  'produces': [selectedMedia],
                } else
                  'servers': [
                    {'url': 'http://127.0.0.1:${server.port}/v1'},
                  ],
                'paths': {
                  '/items': {
                    'post': {
                      if (!legacy) 'requestBody': {'content': content},
                      'responses': {
                        '200': legacy
                            ? {
                                'description': 'Read',
                                'schema': schema,
                                'examples': {selectedMedia: example},
                              }
                            : {'description': 'Read', 'content': content},
                      },
                    },
                  },
                },
              };
            }

            String render() =>
                '${format == 'yaml' ? '# Keep literal media and 雪\r\n' : ''}${jsonEncode(document()).replaceAll('"EXACT"', '9007199254740993')}\r\n';
            final original = render(),
                file = File('${directory.path}/api.$format');
            final originalBytes = [239, 187, 191, ...utf8.encode(original)];
            await file.writeAsBytes(originalBytes);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final buffer = await project.buffer(file.uri.toString());
            final checked = await project.check(buffer.id);
            expect(checked['complete'], true, reason: jsonEncode(checked));
            expect(
              (checked['findings'] as List).where(
                (f) => f['severity'] == 'error',
              ),
              isEmpty,
            );
            final proofs =
                checked['categories']['openapi']['schema']['serializedExamples']
                    as List;
            expect(proofs, hasLength(legacy ? 1 : 2));
            expect(
              proofs.every((p) => p['complete'] == true && p['valid'] == true),
              true,
            );
            expect(
              proofs.every(
                (p) => p['field'] == (legacy ? 'swagger-response' : 'value'),
              ),
              true,
            );
            final operation = (checked['projection']['operations'] as List)
                .whereType<Map>()
                .single;
            final plan = await project.prepareRequest(
              buffer.id,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            try {
              final media =
                  (legacy
                          ? plan.result['responses'][0]['content']
                          : plan.result['requestBody']['content'])
                      as List;
              final example = media.single['example'];
              expect(example['representation'], 'serialized');
              expect(example['raw'], _wire);
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: legacy
                      ? const RequestBodyDraft.none()
                      : RequestBodyDraft.raw(
                          mediaType: _media,
                          text: example['raw'] as String,
                        ),
                ),
                resolveSecret: (_) async =>
                    throw StateError('No credentials expected'),
              );
              try {
                expect(
                  result.outgoing.complete,
                  true,
                  reason: '${result.outgoing.findings}',
                );
                expect(
                  result.received.complete,
                  true,
                  reason: '${result.received.findings}',
                );
                expect(result.conforming, true);
                expect(await result.response.bytes(), utf8.encode(_wire));
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
            expect(seen, hasLength(1));
            expect(seen.single.$1, 'POST');
            expect(seen.single.$2, '/v1/items');
            expect(seen.single.$4, legacy ? <int>[] : utf8.encode(_wire));
            if (!legacy) expect(seen.single.$3, _media);
            expect(await file.readAsBytes(), originalBytes);
            selectedMedia = 'application/xml';
            final changed = render();
            project.store.replace(buffer.id, changed);
            final working = await project.check(buffer.id);
            expect(working['complete'], false);
            expect(
              (working['findings'] as List).any(
                (f) => f['code'] == 'example.serialization.incomplete',
              ),
              true,
            );
            expect(
              (working['findings'] as List).any(
                (f) => f['code'] == 'example.schema.incompatible',
              ),
              false,
            );
            expect(
              (await project.check(buffer.id, saved: true))['complete'],
              true,
            );
            expect(await file.readAsBytes(), originalBytes);
            project.store.undo();
            expect(buffer.bytes(), originalBytes);
            project.store.redo();
            await project.save(buffer);
            final cli = await Process.run('$testBundle/busyapi', [
              'check',
              file.path,
              '--json',
            ]);
            expect(cli.exitCode, 2, reason: '${cli.stdout}\n${cli.stderr}');
            expect(jsonDecode(cli.stdout as String)['status'], 'incomplete');
            final reopened = await BusyProject.open(file.path, engine);
            try {
              expect(
                (await reopened.check(file.uri.toString()))['complete'],
                false,
              );
            } finally {
              reopened.close();
            }
            expect(await file.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(changed),
            ]);
            expect(
              await File('${directory.path}/busyapi.yaml').exists(),
              false,
            );
          },
        );
      }
    }
  }
}
