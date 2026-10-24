import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _multipart(String amount) => [
  for (final (name, value) in [('amount', amount), ('flag', 'false')])
    '--raw-form-boundary\r\nContent-Disposition: form-data; name="$name"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n$value\r\n',
  '--raw-form-boundary--\r\n',
].join();

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['json', 'yaml']) {
      test(
        '$version $format raw form request and response checks use captured wire data',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-raw-form-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <(String, String, String, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
            request.response.headers.set(
              'content-type',
              request.headers.contentType.toString(),
            );
            request.response.add(bytes);
            await request.response.close();
          });
          final legacy = version == '2.0';
          final properties = {
            'amount': {
              'type': 'integer',
              'enum': ['EXACT_VALUE'],
            },
            'flag': {
              'type': 'boolean',
              'enum': [false],
            },
          };
          final schema = {
            'type': 'object',
            'required': ['amount', 'flag'],
            'properties': properties,
            'additionalProperties': false,
          };
          final content = {
            for (final type in [
              'application/x-www-form-urlencoded',
              'multipart/form-data',
            ])
              type: {'schema': schema},
          };
          final document = {
            if (legacy) 'swagger': version else 'openapi': version,
            'info': {'title': 'Original', 'version': 'api-version'},
            if (legacy) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': content.keys.toList(),
              'produces': content.keys.toList(),
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            'paths': {
              '/form': {
                'post': {
                  if (legacy)
                    'parameters': [
                      for (final entry in properties.entries)
                        {
                          'name': entry.key,
                          'in': 'formData',
                          'required': true,
                          ...entry.value,
                        },
                    ]
                  else
                    'requestBody': {'required': true, 'content': content},
                  'responses': {
                    '200': {
                      'description': 'Echo',
                      if (legacy) 'schema': schema else 'content': content,
                    },
                  },
                },
              },
            },
            'x-number': 'EXACT_VALUE',
          };
          final json = jsonEncode(document)
              .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
          final original = format == 'yaml'
              ? '# Keep source 雪\r\n$json\r\n'
              : json;
          final file = File('${temp.path}/api.$format');
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
            original.replaceFirst('Original', 'Unsaved'),
          );
          final plan = await project.prepareRequest(
            buffer.id,
            resource: buffer.id,
            pointer: '/paths/~1form/post',
          );
          addTearDown(plan.close);
          for (final multipart in [false, true]) {
            final media = multipart
                ? 'multipart/form-data; boundary=raw-form-boundary'
                : 'application/x-www-form-urlencoded';
            for (final amount in ['9007199254740993', '9007199254740992']) {
              final text = multipart
                  ? _multipart(amount)
                  : 'amount=$amount&flag=false';
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(mediaType: media, text: text),
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
                result.received.complete,
                true,
                reason: '${result.received.findings}',
              );
              expect(result.outgoing.valid, amount == '9007199254740993');
              expect(result.received.valid, amount == '9007199254740993');
              expect(result.outgoing.coverage['body'], 'selected-media-body');
              expect(result.received.coverage['body'], 'selected-media-body');
              expect((seen.last.$1, seen.last.$2), ('POST', '/form'));
              expect(seen.last.$3, media);
              expect(seen.last.$4, utf8.encode(text));
              expect(await result.response.decodedBytes(), utf8.encode(text));
            }
          }
          if (format == 'json') {
            final cases = [
              for (final multipart in [false, true])
                for (final valid in [true, false])
                  {
                    'name': '$multipart-$valid',
                    'operation': {'method': 'post', 'path': '/form'},
                    'body': {
                      'mediaType': multipart
                          ? 'multipart/form-data; boundary=raw-form-boundary'
                          : 'application/x-www-form-urlencoded',
                      'value': multipart
                          ? _multipart(
                              valid ? '9007199254740993' : '9007199254740992',
                            )
                          : 'amount=${valid ? '9007199254740993' : '9007199254740992'}&flag=false',
                    },
                    'expect': {'status': 200},
                  },
            ];
            await File('${temp.path}/busyapi.yaml').writeAsString(
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
                temp.path,
                for (final c in cases) ...['--case', c['name'] as String],
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 1, reason: '${cli.stdout}\n${cli.stderr}');
            final report = jsonDecode(cli.stdout as String) as Map;
            expect(report['complete'], true, reason: '${cli.stdout}');
            expect((report['cases'] as List).map((c) => c['passed']), [
              true,
              false,
              true,
              false,
            ]);
            for (final (index, value) in cases.indexed) {
              final body = value['body'] as Map;
              final actual = seen[4 + index];
              expect((actual.$1, actual.$2), ('POST', '/form'));
              expect(actual.$3, body['mediaType']);
              expect(actual.$4, utf8.encode(body['value'] as String));
            }
          }
          expect(await file.readAsString(), original);
          expect(buffer.text, original.replaceFirst('Original', 'Unsaved'));
        },
      );
    }
  }
}
