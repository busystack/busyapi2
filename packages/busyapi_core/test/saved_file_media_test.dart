import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _exact = '9007199254740993.00';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format saved file media overrides shared choices with exact HTTP bytes',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-saved-file-types-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
                (bytes, next) => bytes..addAll(next),
              ),
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          final swagger = version == '2.0';
          final names = ['asset', swagger ? 'other' : 'asset'];
          final payloads = [
            [0, 255, 65],
            [0, 128, 66],
          ];
          final files = [
            for (final name in ['one.bin', 'two.bin'])
              File('${directory.path}/$name'),
          ];
          for (var index = 0; index < files.length; index++)
            await files[index].writeAsBytes(payloads[index]);
          final properties = {
            'n': {
              'type': 'integer',
              'enum': ['EXACT'],
            },
            'zero': {
              'type': 'integer',
              'enum': [0],
            },
            'flag': {
              'type': 'boolean',
              'enum': [false],
            },
          };
          final document = {
            if (swagger) ...{
              'swagger': version,
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': ['multipart/form-data'],
            } else ...{
              'openapi': version,
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            },
            'info': {'title': 'Keep 雪', 'version': 'unrelated'},
            'paths': {
              '/files': {
                'post': {
                  if (swagger)
                    'parameters': [
                      for (final entry in properties.entries)
                        {
                          'name': entry.key,
                          'in': 'formData',
                          'required': true,
                          ...entry.value,
                        },
                      for (final name in names)
                        {
                          'name': name,
                          'in': 'formData',
                          'required': true,
                          'type': 'file',
                        },
                    ]
                  else
                    'requestBody': {
                      'content': {
                        'multipart/form-data': {
                          'schema': {
                            'type': 'object',
                            'required': [...properties.keys, 'asset'],
                            'properties': {
                              ...properties,
                              'asset': {
                                'type': 'array',
                                'minItems': 2,
                                'maxItems': 2,
                                'items': version.startsWith('3.0.')
                                    ? {
                                        'type': 'string',
                                        'format': 'binary',
                                        'minLength': 3,
                                        'maxLength': 3,
                                      }
                                    : <String, Object?>{},
                              },
                            },
                          },
                          'encoding': {
                            for (final name in properties.keys)
                              name: {'contentType': 'application/json'},
                            'asset': {'contentType': 'image/*'},
                          },
                        },
                      },
                    },
                  'responses': {
                    '204': {'description': 'No body'},
                  },
                },
              },
            },
          };
          final text =
              (format == 'json'
                      ? jsonEncode(document)
                      : '# Keep CRLF\r\n${document.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n')
                  .replaceAll('"EXACT"', _exact);
          final api = File('${directory.path}/api.$format'),
              source = [0xef, 0xbb, 0xbf, ...utf8.encode(text)];
          await api.writeAsBytes(source);
          final manifest = File('${directory.path}/busyapi.yaml');
          await manifest.writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': api.uri.pathSegments.last},
              ],
              'tests': [
                for (final valid in [true, false])
                  {
                    'name': valid ? 'selected' : 'invalid',
                    'operation': {'method': 'post', 'path': '/files'},
                    'body': {
                      'mediaType': 'multipart/form-data',
                      'value': {'n': 'EXACT', 'zero': 0, 'flag': false},
                      'partMediaTypes': {'asset': 'image/gif'},
                      'files': [
                        for (var index = 0; index < files.length; index++)
                          {
                            'name': names[index],
                            'path': files[index].uri.pathSegments.last,
                            'mediaType': !valid && index == 0
                                ? 'text/plain'
                                : index == 0
                                ? 'image/png'
                                : 'image/jpeg',
                          },
                      ],
                    },
                    'expect': {'status': 204},
                  },
              ],
            }).replaceAll('"EXACT"', _exact),
          );
          final manifestText = await manifest.readAsString();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(directory.path, engine);
          addTearDown(project.close);
          final report = await const ContractTestRunner().run(
            project,
            api.uri.toString(),
            selectedCases: ['selected'],
            resolveSecret: (_) async => null,
          );
          expect(report.complete, isTrue, reason: '${report.toJson()}');
          expect(report.passed, isTrue, reason: '${report.toJson()}');
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', directory.path, '--case', 'selected', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          final cliReport = jsonDecode(cli.stdout as String) as Map;
          expect(cliReport['complete'], isTrue);
          expect(cliReport['passed'], isTrue, reason: '${cli.stdout}');
          expect(seen, hasLength(2));
          for (final request in seen) {
            final boundary = ContentType.parse(request.$4)
                .parameters['boundary']!;
            expect(request.$1, 'POST');
            expect(request.$2, '/files');
            expect(request.$3, '127.0.0.1:${server.port}');
            expect(request.$5, [
              for (final entry in {
                'n': _exact,
                'zero': '0',
                'flag': 'false',
              }.entries)
                ...utf8.encode(
                  '--$boundary\r\nContent-Disposition: form-data; name="${entry.key}"\r\n${swagger ? '' : 'Content-Type: application/json\r\n'}\r\n${entry.value}\r\n',
                ),
              for (var index = 0; index < files.length; index++) ...[
                ...utf8.encode(
                  '--$boundary\r\nContent-Disposition: form-data; name="${names[index]}"; filename="${files[index].uri.pathSegments.last}"\r\nContent-Type: ${index == 0 ? 'image/png' : 'image/jpeg'}\r\n\r\n',
                ),
                ...payloads[index],
                13,
                10,
              ],
              ...utf8.encode('--$boundary--\r\n'),
            ]);
          }
          if (!swagger) {
            final invalid = await const ContractTestRunner().run(
              project,
              api.uri.toString(),
              selectedCases: ['invalid'],
              resolveSecret: (_) async => null,
            );
            expect(invalid.complete, isTrue);
            expect(invalid.passed, isFalse);
            expect(invalid.cases.single.dispatched, isFalse);
            expect(invalid.cases.single.operationalFailure, isTrue);
            expect(
              jsonEncode(invalid.toJson()),
              contains('request.form.content-type'),
            );
            expect(seen, hasLength(2));
          }
          expect(await api.readAsBytes(), source);
          expect(await manifest.readAsString(), manifestText);
          for (var index = 0; index < files.length; index++)
            expect(await files[index].readAsBytes(), payloads[index]);
        },
      );
    }
  }
}
