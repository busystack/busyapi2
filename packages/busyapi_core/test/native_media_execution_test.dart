import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

Future<
  ({
    BusyProject project,
    OperationRequestPlan plan,
    File source,
    String original,
  })
>
openMedia(
  Directory temp,
  HttpServer server,
  String version,
  String format,
  Map<String, Object?> media, {
  Map<String, Object?> headers = const {},
  Map<String, Object?> schemas = const {},
}) async {
  final legacy = version == '2.0';
  final operation = <String, Object?>{
    if (legacy)
      'parameters': [
        {'in': 'body', 'name': 'payload', 'schema': media['schema']},
      ]
    else
      'requestBody': {
        'content': {'text/plain': media},
      },
    'responses': {
      '200': {
        'description': 'ok',
        if (legacy)
          'schema': media['schema']
        else
          'content': {'text/plain': media},
        if (headers.isNotEmpty) 'headers': headers,
      },
    },
  };
  final value = {
    legacy ? 'swagger' : 'openapi': version,
    'info': {'title': 'Native media', 'version': 'api-version'},
    if (legacy) ...{
      'host': '127.0.0.1:${server.port}',
      'basePath': '/v1',
      'schemes': ['http'],
      'consumes': ['text/plain'],
      'produces': ['text/plain'],
      'definitions': schemas,
    } else ...{
      'servers': [
        {'url': 'http://127.0.0.1:${server.port}/v1'},
      ],
      'components': {'schemas': schemas},
    },
    'paths': {
      '/data': {'post': operation},
    },
    'x-exact': 'EXACT_VALUE',
  };
  // Flow JSON within block YAML keeps this fixture's exact numeric tokens in
  // both formats, including the numeric extension unrelated to the edit/run.
  final encoded = jsonEncode(value)
      .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
  final original = format == 'json' ? encoded : '# Keep 雪😀\r\n${encoded}\r\n';
  final source = File('${temp.path}/api.$format');
  await source.writeAsString(original);
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  addTearDown(engine.close);
  final project = await BusyProject.open(source.path, engine);
  addTearDown(project.close);
  await project.buffer(source.uri.toString());
  final checked = await project.check(source.uri.toString());
  expect(checked['complete'], true, reason: '$checked');
  expect(
    (checked['findings'] as List).whereType<Map>().where(
      (f) => f['severity'] == 'error',
    ),
    isEmpty,
  );
  final operationLocation = (checked['projection']['operations'] as List)
      .whereType<Map>()
      .single;
  final plan = await project.prepareRequest(
    source.uri.toString(),
    resource: operationLocation['resource'] as String,
    pointer: operationLocation['pointer'] as String,
    occurrence: operationLocation['occurrence'] as String,
  );
  addTearDown(plan.close);
  return (project: project, plan: plan, source: source, original: original);
}

void main() {
  for (final version in ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format text body evaluation uses actual UTF-8 request and response bytes',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-native-text-',
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
            request.response.headers.contentType = ContentType(
              'text',
              'plain',
              charset: 'utf-8',
            );
            request.response.add(bytes);
            await request.response.close();
          });
          final fixture = await openMedia(
            temp,
            server,
            version,
            format,
            {
              'schema': {
                r'$ref': version == '2.0'
                    ? '#/definitions/Value'
                    : '#/components/schemas/Value',
              },
            },
            schemas: {
              'Value': {
                'type': 'string',
                'maxLength': 2,
                'pattern': r'^(雪😀)?$',
              },
            },
          );
          for (final text in ['雪😀', '', 'bad']) {
            final result = await const ContractRequestExecutor().execute(
              fixture.plan,
              OperationRequestDraft(
                planIdentity: fixture.plan.identity,
                body: RequestBodyDraft.raw(mediaType: 'text/plain', text: text),
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
            expect(result.outgoing.valid, text != 'bad');
            expect(result.received.valid, text != 'bad');
            expect(result.outgoing.coverage['body'], 'selected-media-body');
            expect(result.received.coverage['body'], 'selected-media-body');
            expect(
              (seen.last.$1, seen.last.$2, seen.last.$3),
              (
                'POST',
                '/v1/data',
                text == '雪😀' ? 'text/plain; charset=utf-8' : 'text/plain',
              ),
            );
            expect(seen.last.$4, utf8.encode(text));
            expect(await result.response.decodedBytes(), utf8.encode(text));
            if (text == 'bad') {
              expect(
                result.received.findings.any(
                  (f) =>
                      f['code'] == 'runtime.schema.incompatible' &&
                      (f['schema'] as Map)['resource'] ==
                          fixture.source.uri.toString(),
                ),
                true,
              );
            }
          }
          expect(await fixture.source.readAsString(), fixture.original);
          expect(
            fixture.project.store.get(fixture.source.uri.toString()).text,
            fixture.original,
          );
        },
      );
    }
  }
  for (final version in ['3.0.0', '3.0.4']) {
    test(
      '$version binary file bytes and response enforce native octet bounds through a referenced schema',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-native-binary-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <List<int>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final bytes = await request.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          seen.add(bytes);
          request.response.headers.contentType = ContentType.binary;
          request.response.add(bytes);
          await request.response.close();
        });
        final source = File('${temp.path}/api.yaml');
        final original =
            '''# Native binary source
openapi: $version
info: {title: Binary, version: api-version}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /data:
    post:
      requestBody: {content: {application/octet-stream: {schema: {\$ref: 'binary.yaml#/Value'}}}}
      responses: {'200': {description: ok, content: {application/octet-stream: {schema: {\$ref: 'binary.yaml#/Value'}}}}}
''';
        await source.writeAsString(original);
        final shared = File('${temp.path}/binary.yaml');
        const sharedText =
            '# Shared original\nValue: {type: string, format: binary, minLength: 2, maxLength: 4}\n';
        await shared.writeAsString(sharedText);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(source.path, engine);
        addTearDown(project.close);
        final plan = await project.prepareRequest(
          source.uri.toString(),
          resource: source.uri.toString(),
          pointer: '/paths/~1data/post',
        );
        addTearDown(plan.close);
        final upload = File('${temp.path}/upload.bin');
        for (final bytes in [
          [0, 255, 254, 10],
          [255],
          [0, 1, 2, 3, 4],
        ]) {
          await upload.writeAsBytes(bytes);
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.binaryFile(
                mediaType: 'application/octet-stream',
                file: upload.path,
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
            result.received.complete,
            true,
            reason: '${result.received.findings}',
          );
          expect(result.outgoing.valid, bytes.length == 4);
          expect(result.received.valid, bytes.length == 4);
          expect(result.outgoing.coverage['body'], 'selected-media-body');
          expect(result.received.coverage['body'], 'selected-media-body');
          expect(seen.last, bytes);
          expect(await result.response.decodedBytes(), bytes);
        }
        expect(await source.readAsString(), original);
        expect(await shared.readAsString(), sharedText);
      },
    );
  }
  for (final mediaType in [
    'application/jsonl',
    'application/json-seq',
    'text/event-stream',
  ]) {
    test(
      '3.2 $mediaType checks the whole finite body and each item on actual HTTP',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-native-sequence-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          seen.add(body);
          request.response.headers.set('content-type', mediaType);
          request.response.add(utf8.encode(body));
          await request.response.close();
        });
        final event = mediaType == 'text/event-stream';
        final item = event
            ? '{type: object, required: [data], properties: {data: {type: string, pattern: "^雪"}, retry: {type: integer, minimum: 9007199254740993}}}'
            : '{type: object, required: [id], properties: {id: {type: integer, minimum: 9007199254740993}}}';
        final source = File('${temp.path}/api.yaml');
        final original =
            '''openapi: 3.2.1
info: {title: Sequences, version: api-version}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /data:
    post:
      requestBody: {content: {$mediaType: {schema: {type: array, minItems: 2, maxItems: 2}, itemSchema: {\$ref: '#/components/schemas/Item'}}}}
      responses: {'200': {description: ok, content: {$mediaType: {schema: {type: array, minItems: 2, maxItems: 2}, itemSchema: {\$ref: '#/components/schemas/Item'}}}}}
components: {schemas: {Item: $item}}
''';
        await source.writeAsString(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(source.path, engine);
        addTearDown(project.close);
        final plan = await project.prepareRequest(
          source.uri.toString(),
          resource: source.uri.toString(),
          pointer: '/paths/~1data/post',
        );
        addTearDown(plan.close);
        String record(String value) => event
            ? 'data: $value\nretry: 9007199254740993\n\n'
            : mediaType == 'application/jsonl'
            ? '$value\n'
            : '\x1e$value\n';
        final first = record(event ? '雪😀' : '{"id":9007199254740993}');
        for (final tail in [
          record(event ? '雪' : '{"id":9007199254740994}'),
          record(event ? 'bad' : '{"id":9007199254740992}'),
          '',
        ]) {
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.raw(
                mediaType: mediaType,
                text: first + tail,
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
            result.received.complete,
            true,
            reason: '${result.received.findings}',
          );
          final valid =
              tail.isNotEmpty &&
              !tail.contains('bad') &&
              !tail.contains('9007199254740992');
          expect(result.outgoing.valid, valid);
          expect(result.received.valid, valid);
          expect(seen.last, first + tail);
          expect(
            await result.response.decodedBytes(),
            utf8.encode(first + tail),
          );
        }
        expect(await source.readAsString(), original);
      },
    );
  }
  test(
    '3.2 SSE captured bytes remove one BOM and preserve parsed event defaults',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-sse-framing-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <List<int>>[];
      server.listen((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        seen.add(bytes);
        request.response.headers.set(
          'content-type',
          'text/event-stream; charset=iso-8859-1',
        );
        request.response.add(bytes);
        await request.response.close();
      });
      final source = File('${temp.path}/api.yaml');
      final original =
          '''openapi: 3.2.1
info: {title: SSE framing, version: api-version}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /data:
    post:
      requestBody: {content: {text/event-stream: {\$ref: '#/components/mediaTypes/Event'}}}
      responses: {'200': {description: ok, content: {text/event-stream: {\$ref: '#/components/mediaTypes/Event'}}}}
components:
  mediaTypes:
    Event:
      schema: {type: array, maxItems: 1}
      itemSchema: {type: object, required: [data], properties: {data: {type: string, maxLength: 0}, event: {enum: [message]}}}
''';
      await source.writeAsString(original);
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(source.path, engine);
      addTearDown(project.close);
      final plan = await project.prepareRequest(
        source.uri.toString(),
        resource: source.uri.toString(),
        pointer: '/paths/~1data/post',
      );
      addTearDown(plan.close);
      final upload = File('${temp.path}/events.bin');
      final specimens = [
        utf8.encode('\ufeff\ufeffdata: hidden\n\n'),
        utf8.encode('event:\ndata:\n\n'),
        [...ascii.encode('data: '), 255, 10, 10],
      ];
      for (var index = 0; index < specimens.length; index++) {
        final bytes = specimens[index];
        await upload.writeAsBytes(bytes);
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.binaryFile(
              mediaType: 'text/event-stream',
              file: upload.path,
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
          result.received.complete,
          true,
          reason: '${result.received.findings}',
        );
        expect(result.outgoing.valid, index != 2);
        expect(result.received.valid, index != 2);
        expect(seen.last, bytes);
        expect(await result.response.decodedBytes(), bytes);
      }
      expect(await source.readAsString(), original);
    },
  );
  test('repeated response media parameters remain source-located unsupported evaluation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-media-parameters-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.set(
        'content-type',
        'text/plain; profile=a; profile=b',
      );
      request.response.write('x');
      await request.response.close();
    });
    final fixture = await openMedia(temp, server, '3.0.4', 'yaml', {
      'schema': {'type': 'string'},
    });
    final result = await const ContractRequestExecutor().execute(
      fixture.plan,
      OperationRequestDraft(
        planIdentity: fixture.plan.identity,
        body: const RequestBodyDraft.raw(mediaType: 'text/plain', text: 'x'),
      ),
      resolveSecret: (_) async => null,
    );
    addTearDown(result.close);
    expect(result.outgoing.complete, true);
    expect(result.received.complete, false);
    expect(result.received.valid, true);
    expect(result.conforming, false);
    final finding = result.received.findings.singleWhere(
      (f) => f['code'] == 'runtime.response.body.unchecked',
    );
    expect(finding['kind'], 'unsupported');
    expect(
      (finding['schema'] as Map)['resource'],
      fixture.source.uri.toString(),
    );
    expect(await fixture.source.readAsString(), fixture.original);
  });
}
