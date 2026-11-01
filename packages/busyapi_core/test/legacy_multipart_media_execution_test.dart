import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.0', '3.0.1', '3.0.2', '3.0.3', '3.0.4']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format named binary media does not need a format hint', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-legacy-part-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final seen = <List<int>>[];
        String? contentType;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          expect((request.method, request.uri.toString()), ('POST', '/file'));
          expect(request.headers.value('host'), '127.0.0.1:${server.port}');
          contentType = request.headers.value('content-type');
          final bytes = await request.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          seen.add(bytes);
          request.response.headers.set(
            'content-type',
            request.headers.value('content-type')!,
          );
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        final media = {
          'schema': {
            'type': 'object',
            'required': ['metadata'],
            'properties': {
              'metadata': {
                'type': 'object',
                'properties': {
                  'id': {
                    'type': 'integer',
                    'enum': ['EXACT'],
                  },
                },
              },
              'file': {'type': 'string', 'maxLength': 4},
            },
          },
          'encoding': {
            'metadata': {'contentType': 'application/json'},
            'file': {'contentType': 'application/octet-stream'},
          },
        };
        final source =
            (format == 'yaml' ? '# Preserve original 雪\r\n' : '') +
            jsonEncode({
              'openapi': version,
              'info': {'title': 'Original', 'version': 'api-version'},
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              'paths': {
                '/file': {
                  'post': {
                    'requestBody': {
                      'required': true,
                      'content': {'multipart/form-data': media},
                    },
                    'responses': {
                      '200': {
                        'description': 'Echo',
                        'content': {'multipart/form-data': media},
                      },
                    },
                  },
                },
              },
            }).replaceAll('"EXACT"', '9007199254740993.00');
        final root = File('${directory.path}/api.$format');
        await root.writeAsString(source);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final plan = await project.prepareRequest(
          root.uri.toString(),
          resource: root.uri.toString(),
          pointer: '/paths/~1file/post',
        );
        addTearDown(plan.close);
        const bytes = [0, 255, 128, 0];
        final file = File('${directory.path}/opaque.bin');
        await file.writeAsBytes(bytes);
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipartValue(
              json: '{"metadata":{"id":9007199254740993}}',
              files: [MultipartFileValue(name: 'file', path: file.path)],
            ),
          ),
          resolveSecret: (_) async => throw StateError('No credentials'),
        );
        try {
          expect(seen, hasLength(1));
          final parsed = ContentType.parse(contentType!);
          expect(parsed.mimeType, 'multipart/form-data');
          final boundary = parsed.parameters['boundary']!;
          expect(seen.single, [
            ...utf8.encode(
              '--$boundary\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n{"id":9007199254740993}\r\n--$boundary\r\nContent-Disposition: form-data; name="file"; filename="opaque.bin"\r\nContent-Type: application/octet-stream\r\n\r\n',
            ),
            ...bytes,
            ...utf8.encode('\r\n--$boundary--\r\n'),
          ]);
          expect(
            result.outgoing.complete,
            isTrue,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.outgoing.valid,
            isTrue,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.received.complete,
            isTrue,
            reason: '${result.received.findings}',
          );
          expect(
            result.received.valid,
            isTrue,
            reason: '${result.received.findings}',
          );
          expect(await result.response.decodedBytes(), seen.single);
          expect(await file.readAsBytes(), bytes);
          expect(await root.readAsBytes(), utf8.encode(source));
        } finally {
          await result.close();
        }
      });
    }
  }
}
