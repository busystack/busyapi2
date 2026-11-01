import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final multipart in [false, true]) {
        test(
          '$version $format multipart=$multipart preserves selected media and actual bytes',
          () async {
            final temporary = await Directory.systemTemp.createTemp(
              'busyapi-media-identity-',
            );
            addTearDown(() => temporary.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final seen = <(String, String, String, String, List<int>)>[];
            server.listen((request) async {
              seen.add((
                request.method,
                request.uri.toString(),
                request.headers.value('host')!,
                request.headers.contentType.toString(),
                await request.fold<List<int>>(
                  [],
                  (all, chunk) => all..addAll(chunk),
                ),
              ));
              request.response.statusCode = 204;
              await request.response.close();
            });
            final legacy = version == '2.0';
            final selected = multipart
                ? 'multipart/form-data'
                : 'application/x-www-form-urlencoded; charset=utf-8';
            final other = multipart
                ? 'Multipart/Form-Data'
                : 'Application/X-WWW-Form-Urlencoded; charset=utf-8';
            const good = '雪 & value';
            final schema = {
              'type': 'object',
              'required': ['note'],
              'properties': {
                'note': {
                  'type': 'string',
                  'enum': [good],
                },
                'payload': {
                  'type': 'object',
                  'properties': {
                    'n': {
                      'type': 'integer',
                      'enum': ['EXACT'],
                    },
                    'flag': {'type': 'boolean'},
                    'zero': {'type': 'integer'},
                    'nil': <String, Object?>{},
                    r'$ref': {'type': 'string'},
                  },
                },
              },
            };
            final shared = File('${temporary.path}/shared.json');
            final sharedText = jsonEncode({'Body': schema})
                .replaceFirst('"EXACT"', '9007199254740993.00');
            await shared.writeAsString(sharedText);
            final document = {
              if (legacy) ...{
                'swagger': version,
                'host': '127.0.0.1:${server.port}',
                'basePath': '/v1',
                'schemes': ['http'],
                'consumes': [other, selected],
                'parameters': {
                  'Note': {
                    'name': 'note',
                    'in': 'formData',
                    'type': 'string',
                    'required': true,
                    'enum': [good],
                  },
                },
              } else ...{
                'openapi': version,
                'servers': [
                  {'url': 'http://127.0.0.1:${server.port}/v1'},
                ],
              },
              'info': {'title': 'Form identity', 'version': 'unrelated'},
              'paths': {
                '/form': {
                  'post': {
                    if (legacy)
                      'parameters': [
                        {r'$ref': '#/parameters/Note'},
                      ]
                    else
                      'requestBody': {
                        'content': {
                          other: {
                            'schema': {
                              'type': 'object',
                              'properties': {
                                'note': {'type': 'integer'},
                                'payload': {'type': 'string'},
                              },
                            },
                          },
                          selected: {
                            'schema': {r'$ref': 'shared.json#/Body'},
                          },
                          if (!multipart)
                            'application/x-www-form-urlencoded': {
                              'schema': <String, Object?>{},
                            },
                        },
                      },
                    'responses': {
                      '204': {'description': 'No payload'},
                    },
                  },
                },
              },
            };
            final file = File('${temporary.path}/api document.$format');
            final original =
                '${format == 'yaml' ? '# Retain declaration ownership\r\n' : ''}${jsonEncode(document)}\r\n';
            await file.writeAsString(original);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final buffer = await project.buffer(file.uri.toString());
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst('Form identity', 'Unsaved identity'),
            );
            final analysis = await project.check(project.roots.single.id);
            final operations = analysis['projection']['operations'] as List;
            final operation = operations.single as Map;
            final plan = await project.prepareRequest(
              project.roots.single.id,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            addTearDown(plan.close);
            const payload =
                r'{"n":9007199254740993.00,"flag":false,"zero":0,"nil":null,"$ref":"./literal payload.json#/data"}';
            for (final valid in [true, false]) {
              final note = valid ? good : 'bad';
              final json =
                  '{"note":${jsonEncode(note)}${legacy ? '' : ',"payload":$payload'}}';
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: multipart
                      ? RequestBodyDraft.multipartValue(
                          json: json,
                          mediaType: selected,
                        )
                      : RequestBodyDraft.formValue(
                          json: json,
                          mediaType: selected,
                        ),
                ),
                resolveSecret: (_) async => null,
              );
              addTearDown(result.close);
              expect(
                result.outgoing.complete,
                true,
                reason: '${result.outgoing.findings}',
              );
              expect(
                result.outgoing.valid,
                valid,
                reason: '${result.outgoing.findings}',
              );
              expect(
                result.received.complete,
                true,
                reason: '${result.received.findings}',
              );
              expect(
                result.received.valid,
                true,
                reason: '${result.received.findings}',
              );
              final request = seen.last;
              expect(
                (request.$1, request.$2, request.$3),
                ('POST', '/v1/form', '127.0.0.1:${server.port}'),
              );
              final wire = utf8.decode(request.$5);
              if (multipart) {
                final type = ContentType.parse(request.$4);
                expect(type.mimeType, selected);
                final boundary = type.parameters['boundary'];
                expect(boundary, isNotEmpty);
                expect(wire, startsWith('--$boundary\r\n'));
                expect(wire, endsWith('--$boundary--\r\n'));
                expect(wire, contains('name="note"'));
                expect(wire, contains('\r\n\r\n$note\r\n'));
                if (!legacy) {
                  expect(
                    wire.toLowerCase(),
                    contains('content-type: application/json'),
                  );
                  expect(wire, contains('\r\n\r\n$payload\r\n'));
                }
              } else {
                expect(request.$4, selected);
                final values = Uri.splitQueryString(wire);
                expect(values['note'], note);
                if (!legacy) expect(values['payload'], payload);
              }
            }
            expect(seen.length, 2);
            expect(await file.readAsString(), original);
            expect(await shared.readAsString(), sharedText);
            expect(buffer.text, contains('Unsaved identity'));
          },
        );
      }
    }
  }
}
