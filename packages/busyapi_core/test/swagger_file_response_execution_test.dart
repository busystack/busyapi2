import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

bool hasLocatedForbiddenContent(Object? value, String resource) {
  if (value is Map) {
    if (value['code'] == 'runtime.response.body.forbidden' &&
        value['source'] is Map &&
        (value['source'] as Map)['resource'] == resource) {
      return true;
    }
    return value.values.any(
      (entry) => hasLocatedForbiddenContent(entry, resource),
    );
  }
  return value is List &&
      value.any((entry) => hasLocatedForbiddenContent(entry, resource));
}

void main() {
  const cliTypes = [
    'application/json',
    'application/x-www-form-urlencoded',
    'multipart/form-data; boundary=Fixture',
  ];
  for (final format in ['yaml', 'json']) {
    for (final cliType in <String?>[null, ...cliTypes]) {
      test(
        'Swagger $format file response checks retain actual bytes and reference ownership (${cliType ?? 'Core'})',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-swagger-file-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final bytes = <int>[0, 255, 128];
          var responseBytes = bytes;
          String? responseType = 'application/json';
          final seen = <List<int>>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            expect((request.method, request.uri.toString()), ('POST', '/file'));
            expect(request.headers.value('host'), '127.0.0.1:${server.port}');
            expect(
              request.headers.contentType.toString(),
              'application/octet-stream',
            );
            seen.add(
              await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              ),
            );
            if (responseType != null) {
              request.response.headers.set('content-type', responseType);
            } else {
              request.response.headers.removeAll(HttpHeaders.contentTypeHeader);
            }
            request.response.contentLength = responseBytes.length;
            request.response.add(responseBytes);
            await request.response.close();
          });
          String sourceFor(Map<String, Object?>? schema) {
            final value = {
              'swagger': '2.0',
              'info': {'title': 'Original', 'version': '3.2.1'},
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': ['application/octet-stream'],
              'produces': [responseType ?? 'application/json'],
              'paths': {
                '/file': {
                  'post': {
                    'parameters': [
                      {
                        'name': 'payload',
                        'in': 'body',
                        'required': true,
                        'schema': <String, Object?>{},
                      },
                    ],
                    'responses': {
                      '200': {r'$ref': '#/responses/File'},
                    },
                  },
                },
              },
              'responses': {
                'File': {
                  'description': 'File bytes',
                  if (schema != null) 'schema': schema,
                },
                'Bytes': {
                  'description': 'Reusable file schema',
                  'schema': {'type': 'file'},
                },
              },
              'definitions': {
                'Text': {'type': 'string'},
              },
            };
            // JSON is also valid YAML. A comment and CRLF exercise retained YAML source.
            return (format == 'yaml' ? '# Keep 雪 and CRLF\r\n' : '') +
                jsonEncode(value);
          }

          final file = File('${directory.path}/api.$format');
          final external = File('${directory.path}/response-file.$format');
          final externalSource = format == 'yaml'
              ? '# Retain the external file schema\r\ntype: file\r\n'
              : '{"type":"file"}\r\n';
          await external.writeAsString(externalSource);
          final bufferedFile = File('${directory.path}/buffer-file.$format');
          const bufferedDiskSource = '{"type":"string"}\r\n';
          await bufferedFile.writeAsString(bufferedDiskSource);
          final original = sourceFor({r'$ref': './response-file.$format'});
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final sharedBuffer = await project.buffer(
            bufferedFile.uri.toString(),
          );
          project.store.replace(sharedBuffer.id, externalSource);
          final buffer = await project.buffer(file.uri.toString());
          final upload = File('${directory.path}/body.bin');
          await upload.writeAsBytes(bytes);
          if (cliType == null) {
            for (final type in [
              'application/json',
              'application/xml',
              'application/octet-stream',
              'application/x-www-form-urlencoded',
              'multipart/form-data; boundary=Fixture',
              null,
            ]) {
              responseType = type;
              for (final schema in <Map<String, Object?>?>[
                if (type != null) {'type': 'file'},
                if (type != null) {r'$ref': '#/responses/Bytes/schema'},
                if (type != null) {r'$ref': './response-file.$format'},
                if (type != null) {r'$ref': './buffer-file.$format'},
                null,
              ]) {
                project.store.replace(
                  buffer.id,
                  sourceFor(schema).replaceFirst('Original', 'Unsaved'),
                );
                final plan = await project.prepareRequest(
                  buffer.id,
                  resource: buffer.id,
                  pointer: '/paths/~1file/post',
                );
                try {
                  for (final received in [bytes, <int>[]]) {
                    responseBytes = received;
                    final before = seen.length;
                    final result = await const ContractRequestExecutor()
                        .execute(
                          plan,
                          OperationRequestDraft(
                            planIdentity: plan.identity,
                            body: RequestBodyDraft.binaryFile(
                              mediaType: 'application/octet-stream',
                              file: upload.path,
                            ),
                          ),
                          resolveSecret: (_) async =>
                              throw StateError('No credentials'),
                        );
                    try {
                      expect(seen, hasLength(before + 1));
                      expect(seen.last, bytes);
                      expect(
                        result.outgoing.complete,
                        isTrue,
                        reason: '${result.outgoing.findings}',
                      );
                      expect(result.outgoing.valid, isTrue);
                      expect(
                        result.received.complete,
                        isTrue,
                        reason: '${result.received.findings}',
                      );
                      expect(
                        result.received.valid,
                        schema != null || received.isEmpty,
                      );
                      if (type == null) {
                        expect(
                          result.response.headers.where(
                            (header) =>
                                header.$1.toLowerCase() == 'content-type',
                          ),
                          isEmpty,
                        );
                      }
                      expect(
                        result.received.coverage['body'],
                        schema == null
                            ? 'no-response-content'
                            : type == 'application/json'
                            ? 'selected-json-body'
                            : 'selected-media-body',
                      );
                      if (schema == null && received.isNotEmpty) {
                        expect(
                          result.received.findings.any(
                            (finding) =>
                                finding['code'] ==
                                'runtime.response.body.forbidden',
                          ),
                          isTrue,
                        );
                      }
                      expect(
                        await File(result.response.bodyFile).readAsBytes(),
                        received,
                      );
                      expect(await result.response.decodedBytes(), received);
                    } finally {
                      await result.close();
                    }
                  }
                } finally {
                  plan.close();
                }
              }
            }
          }
          if (cliType != null) {
            final manifest = File('${directory.path}/busyapi.yaml');
            var cliIndex = 0;
            for (final type in [cliType]) {
              responseType = type;
              for (final fileResponse in [true, false]) {
                final cliFile = File(
                  '${directory.path}/cli-${cliIndex++}.$format',
                );
                final cliSource = sourceFor(
                  fileResponse ? {r'$ref': './response-file.$format'} : null,
                );
                await cliFile.writeAsString(cliSource);
                await manifest.writeAsString(
                  jsonEncode({
                    'version': 1,
                    'roots': [
                      {'name': 'api', 'path': cliFile.uri.pathSegments.last},
                    ],
                    'tests': [
                      {
                        'name': 'file',
                        'operation': {'method': 'post', 'path': '/file'},
                        'body': {
                          'mediaType': 'application/octet-stream',
                          'value': 'binary\u0000雪',
                        },
                        'expect': {'status': 200},
                      },
                    ],
                  }),
                );
                for (final received in [bytes, if (!fileResponse) <int>[]]) {
                  responseBytes = received;
                  final before = seen.length;
                  final cli = await Process.run(
                    '$testBundle/busyapi',
                    ['test', directory.path, '--case', 'file', '--json'],
                    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
                    includeParentEnvironment: false,
                  );
                  final passed = fileResponse || received.isEmpty;
                  expect(
                    cli.exitCode,
                    passed ? 0 : 1,
                    reason: '${cli.stdout}\n${cli.stderr}',
                  );
                  final report = jsonDecode(cli.stdout as String) as Map;
                  expect(report['complete'], isTrue, reason: '${cli.stdout}');
                  expect(report['passed'], passed);
                  if (!passed)
                    expect(
                      hasLocatedForbiddenContent(
                        report,
                        cliFile.uri.toString(),
                      ),
                      isTrue,
                      reason: '${cli.stdout}',
                    );
                  expect(seen, hasLength(before + 1));
                  expect(seen.last, utf8.encode('binary\u0000雪'));
                  expect(await cliFile.readAsString(), cliSource);
                }
              }
            }
          }
          expect(seen, hasLength(cliType == null ? 52 : 3));
          expect(await file.readAsBytes(), utf8.encode(original));
          expect(await external.readAsBytes(), utf8.encode(externalSource));
          expect(
            await bufferedFile.readAsBytes(),
            utf8.encode(bufferedDiskSource),
          );
          expect(await upload.readAsBytes(), bytes);
        },
      );
    }
  }
}
