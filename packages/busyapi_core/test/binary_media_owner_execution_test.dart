import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in [
    '3.0.0',
    '3.0.1',
    '3.0.2',
    '3.0.3',
    '3.0.4',
    '3.1.0',
    '3.1.1',
    '3.1.2',
    '3.2.0',
    '3.2.1',
  ]) {
    for (final format in ['yaml', 'json']) {
      test('$version $format actual binary media owns optional schema evaluation', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-byte-owner-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
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
          final bytes = await request.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          seen.add(bytes);
          request.response.headers.set(
            'content-type',
            'application/octet-stream',
          );
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        String sourceFor(Map<String, Object?>? schema) {
          final media = {if (schema != null) 'schema': schema};
          final operation = {
            'requestBody': {
              'required': true,
              'content': {'application/octet-stream': media},
            },
            'responses': {
              '200': {
                'description': 'Echo',
                'content': {'application/octet-stream': media},
              },
            },
          };
          return format == 'json'
              ? jsonEncode({
                  'openapi': version,
                  'info': {'title': 'Original', 'version': '3.2.1'},
                  'servers': [
                    {'url': 'http://127.0.0.1:${server.port}'},
                  ],
                  'paths': {
                    '/file': {'post': operation},
                  },
                })
              : '# Preserve 雪 and CRLF\r\nopenapi: $version\r\ninfo: {title: Original, version: "3.2.1"}\r\n'
                    'servers: [{url: "http://127.0.0.1:${server.port}"}]\r\npaths:\r\n  /file:\r\n    post: ${jsonEncode(operation)}\r\n';
        }

        final file = File('${directory.path}/api.$format');
        final original = sourceFor(null);
        await file.writeAsString(original);
        final upload = File('${directory.path}/body.bin');
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(file.uri.toString());
        final legacy = version.startsWith('3.0.');
        final schemas = <Map<String, Object?>?>[
          null,
          {},
          legacy
              ? {'format': 'binary'}
              : {
                  'not': {'type': 'null'},
                },
          legacy
              ? {'type': 'string', 'maxLength': 2}
              : {'type': 'string', 'format': 'binary'},
        ];
        for (var index = 0; index < schemas.length; index++) {
          project.store.replace(
            buffer.id,
            sourceFor(schemas[index]).replaceFirst('Original', 'Unsaved'),
          );
          final plan = await project.prepareRequest(
            buffer.id,
            resource: buffer.id,
            pointer: '/paths/~1file/post',
          );
          try {
            for (final bytes in [
              <int>[0, 255, 128],
              if (index == 0) <int>[],
            ]) {
              await upload.writeAsBytes(bytes);
              final before = seen.length;
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.binaryFile(
                    mediaType: 'application/octet-stream',
                    file: upload.path,
                  ),
                ),
                resolveSecret: (_) async => throw StateError('No credentials'),
              );
              try {
                expect(seen, hasLength(before + 1));
                expect(seen.last, bytes);
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
                expect(result.outgoing.valid, index != 3);
                expect(result.received.valid, index != 3);
                expect(result.outgoing.coverage['body'], 'selected-media-body');
                expect(result.received.coverage['body'], 'selected-media-body');
                expect(
                  await File(result.response.bodyFile).readAsBytes(),
                  bytes,
                );
                expect(await result.response.decodedBytes(), bytes);
                expect(await upload.readAsBytes(), bytes);
              } finally {
                await result.close();
              }
            }
          } finally {
            plan.close();
          }
        }
        const cliText = 'binary\u0000雪';
        final manifest = File('${directory.path}/busyapi.yaml');
        await manifest.writeAsString(
          jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'tests': [
              {
                'name': 'bytes',
                'operation': {'method': 'post', 'path': '/file'},
                'body': {
                  'mediaType': 'application/octet-stream',
                  'value': cliText,
                },
                'expect': {'status': 200},
              },
            ],
          }),
        );
        final before = seen.length;
        final cli = await Process.run(
          '$testBundle/busyapi',
          ['test', directory.path, '--case', 'bytes', '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
        final report = jsonDecode(cli.stdout as String) as Map;
        expect(report['complete'], isTrue, reason: '${cli.stdout}');
        expect(report['passed'], isTrue);
        expect(seen, hasLength(before + 1));
        expect(seen.last, utf8.encode(cliText));
        expect(await file.readAsBytes(), utf8.encode(original));
      });
    }
  }
}
