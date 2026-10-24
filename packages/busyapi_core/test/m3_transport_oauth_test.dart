import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'test_support.dart';

PreparedContractRequest _withBody(
  PreparedContractRequest input,
  PreparedRequestBody body,
) => PreparedContractRequest(
  runId: input.runId,
  plan: input.plan,
  environment: input.environment,
  method: input.method,
  uri: input.uri,
  displayUri: input.displayUri,
  headers: input.headers,
  body: body,
  sensitiveHeaders: input.sensitiveHeaders,
  sensitiveQueryNames: input.sensitiveQueryNames,
  connectTimeout: input.connectTimeout,
  overallTimeout: input.overallTimeout,
  inactivityTimeout: input.inactivityTimeout,
  securityAlternative: input.securityAlternative,
  tls: input.tls,
);

void main() {
  late Directory temp;
  late EngineProcess engine;
  BusyProject? project;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-m3-transport-');
    engine = EngineProcess(
      executable: runtimeNode,
      helper: '$repositoryRoot/tools/contract_engine/dist/engine.cjs',
    );
  });

  tearDown(() async {
    project?.close();
    await engine.close();
    await temp.delete(recursive: true);
  });

  Future<OperationRequestPlan> planFor(String path) async {
    final root = File('${temp.path}/openapi.yaml').uri.toString();
    final analysis = await project!.check(root);
    final operation = (analysis['projection']['operations'] as List)
        .whereType<Map>()
        .singleWhere((value) => value['path'] == path);
    return project!.prepareRequest(
      root,
      resource: operation['resource'] as String,
      pointer: operation['pointer'] as String,
      occurrence: operation['occurrence'] as String,
    );
  }

  for (final version in ['3.1.2', '3.2.1']) {
    test('F03 nonempty 205 retains originals and rejects decoded access $version', () async {
      var payload = ascii.encode('bad'), declaredLength = 3, coding = '';
      final requests = <String>[], sockets = <Socket>{};
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
        await server.close();
      });
      server.listen((socket) async {
        sockets.add(socket);
        try {
          final input = <int>[];
          await for (final chunk in socket) {
            input.addAll(chunk);
            final text = ascii.decode(input);
            if (!text.contains('\r\n\r\n')) continue;
            requests.add(text.split('\r\n').first);
            socket.write(
              'HTTP/1.1 205 Reset Content\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: $declaredLength\r\n'
              '${coding.isEmpty ? '' : 'Content-Encoding: $coding\r\n'}'
              'X-Meta: {}\r\nConnection: close\r\n\r\n',
            );
            socket.add(payload);
            await socket.flush();
            await socket.close();
            break;
          }
        } finally {
          sockets.remove(socket);
          socket.destroy();
        }
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: $version
info: {title: Forbidden response content, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /reset:
    get:
      responses:
        '205':
          description: Reset
          headers: {X-Meta: {content: {application/json: {}}}}
          content: {application/json: {}}
''');
      File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
tests: [{name: reset, operation: {method: get, path: /reset}, expect: {status: 205}}]
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/reset');
      addTearDown(plan.close);
      for (final mode in [
        'plain',
        'unsupported-coding',
        'truncated',
        'bounded',
        'empty',
      ]) {
        payload = ascii.encode(mode == 'empty' ? '' : 'bad');
        declaredLength = mode == 'truncated' ? 4 : payload.length;
        coding = mode == 'unsupported-coding' || mode == 'empty' ? 'br' : '';
        final result =
            await ContractRequestExecutor(
              transport: ContractHttpTransport(
                maximumResponseBytes: mode == 'bounded' ? 1 : 1024,
              ),
            ).execute(
              plan,
              OperationRequestDraft(planIdentity: plan.identity),
              resolveSecret: (_) async => null,
            );
        addTearDown(result.close);
        final response = result.response;
        final retained = mode == 'bounded' ? payload.sublist(0, 1) : payload;
        final complete = mode != 'truncated' && mode != 'bounded';
        expect(response.status, 205);
        expect(response.receivedLength, payload.length);
        expect(response.bodyLength, retained.length);
        expect(response.receiptComplete, complete);
        expect(
          response.incompleteReason,
          mode == 'truncated'
              ? 'response-stream-failed'
              : mode == 'bounded'
              ? 'response-size-limit'
              : null,
        );
        expect(await response.bytes(), retained);
        expect(response.bodyIdentity, sha256.convert(retained).toString());
        final original = '${temp.path}/$mode-original.bin';
        await response.export(original);
        expect(await File(original).readAsBytes(), retained);
        expect(response.decodedLength, 0);
        expect(response.displayBytes, isEmpty);
        expect(
          response.decodingComplete,
          mode == 'empty',
          reason:
              'Pinned runtime received ${response.receivedLength} bytes; '
              'retained ${response.bodyLength}, decoded metadata ${response.decodedLength}.',
        );
        final decoded = '${temp.path}/$mode-decoded.bin';
        if (mode == 'empty') {
          expect(response.decodingReason, null);
          expect(await response.decodedBytes(), isEmpty);
          await response.export(decoded, decoded: true);
          expect(await File(decoded).readAsBytes(), isEmpty);
        } else {
          expect(response.decodedBodyFile, null);
          expect(response.decodingReason, 'forbidden-response-content');
          expect(response.exampleEligible, false);
          final unavailable = throwsA(
            isA<CoreFailure>().having(
              (error) => error.code,
              'code',
              'response.decoding',
            ),
          );
          await expectLater(response.decodedBytes(), unavailable);
          await expectLater(
            response.decodedChunks().drain<void>(),
            unavailable,
          );
          await expectLater(
            response.export(decoded, decoded: true),
            unavailable,
          );
          expect(await File(decoded).exists(), false);
          final violation = result.received.findings.singleWhere(
            (f) => f['code'] == 'runtime.response.body.forbidden',
          );
          expect(violation['severity'], 'error');
          expect(violation['location'], 'response-body');
          expect(violation['message'], contains('HTTP 205'));
          expect(
            result.received.findings.any(
              (f) => f['code'] == 'runtime.body.syntax',
            ),
            false,
          );
        }
        expect(result.received.complete, complete);
        expect(result.received.valid, mode == 'empty');
        expect(result.conforming, mode == 'empty');
        expect(
          result.received.coverage['body'],
          mode == 'empty' ? 'not-applicable' : 'forbidden-content',
        );
        final record = ContractRequestRecord.fromResult(
          result,
          recordedAt: DateTime.utc(2026, 10, 22),
        );
        expect(record.conforming, mode == 'empty');
        expect(record.responseBytes, retained.length);
        final directory = Directory(response.ownedDirectory!);
        await result.close();
        expect(await directory.exists(), false);
      }
      // A matching 205 expectation cannot turn the protocol violation into a
      // passing saved case or JUnit result.
      payload = ascii.encode('bad');
      declaredLength = 3;
      coding = '';
      final report = await const ContractTestRunner().run(
        project!,
        File('${temp.path}/openapi.yaml').uri.toString(),
        selectedCases: ['reset'],
        resolveSecret: (_) async => null,
      );
      expect(report.complete, true);
      expect(report.passed, false);
      expect(report.cases.single.status, 'failed');
      expect(
        report.cases.single.findings.any(
          (f) => f['code'] == 'runtime.response.body.forbidden',
        ),
        true,
      );
      expect(report.toJson()['passed'], false);
      expect(CiReports.junit(report), contains('<failure'));
      expect(CiReports.junit(report), isNot(contains('<error')));
      final cli = await Process.run('$testBundle/busyapi', [
        'test',
        temp.path,
        '--case',
        'reset',
        '--json',
        '--junit',
        '${temp.path}/reset.xml',
      ]);
      expect(cli.exitCode, 1, reason: '${cli.stdout} ${cli.stderr}');
      final json = jsonDecode(cli.stdout as String) as Map;
      expect(json['complete'], true);
      expect(json['passed'], false);
      final junit = File('${temp.path}/reset.xml').readAsStringSync();
      expect(junit, contains('<failure'));
      expect(junit, isNot(contains('<error')));
      expect(requests, List.filled(7, 'GET /reset HTTP/1.1'));
    });

    test('F03 residual JSON response-header syntax $version', () async {
      var meta = <String>['{}'], problem = '{}', constrained = '{"id":1}';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.noFolding('X-Meta');
        for (final value in meta) {
          request.response.headers.add('X-Meta', value);
        }
        request.response.headers.set('X-Problem', problem);
        request.response.headers.set('X-Constrained', constrained);
        request.response.statusCode = 204;
        await request.response.close();
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: $version
info: {title: Header syntax, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /headers:
    get:
      responses:
        '204':
          description: Header representations
          headers:
            X-Meta: {content: {application/json: {}}}
            X-Problem: {content: {application/problem+json: {}}}
            X-Constrained: {content: {application/json: {schema: {type: object, required: [id], properties: {id: {type: integer}}}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/headers');
      addTearDown(plan.close);
      Future<ContractRequestResult> send({int limit = 64 * 1024 * 1024}) async {
        final result =
            await ContractRequestExecutor(maximumEvaluationBytes: limit)
                .execute(
                  plan,
                  OperationRequestDraft(planIdentity: plan.identity),
                  resolveSecret: (_) async => null,
                );
        addTearDown(result.close);
        return result;
      }

      for (final specimen in [
        '{"n":9007199254740993,"d":1.0000000000000000001}',
        '42',
        '"a,b"',
        'not json',
        '{} trailing',
        '',
      ]) {
        meta = [specimen];
        problem = specimen;
        final result = await send();
        final valid = !['not json', '{} trailing', ''].contains(specimen);
        expect(
          result.response.headers.where((h) => h.$1 == 'x-meta').single.$2,
          specimen,
        );
        expect(result.received.complete, true, reason: specimen);
        expect(result.received.valid, valid, reason: specimen);
        expect(result.conforming, valid, reason: specimen);
        final syntax = result.received.findings
            .where((f) => f['code'] == 'runtime.body.syntax')
            .toList();
        expect(syntax.length, valid ? 0 : 2);
        if (!valid) {
          expect(
            syntax.map((f) => f['location']),
            containsAll(['X-Meta', 'X-Problem']),
          );
          expect(syntax.every((f) => f['subject'] == 'response-header'), true);
        }
        await result.close();
      }
      meta = ['{}'];
      problem = '{}';
      constrained = '{"id":"wrong"}';
      var result = await send();
      expect(result.received.valid, false);
      expect(
        result.received.findings.any(
          (f) =>
              f['code'] == 'runtime.schema.incompatible' &&
              f['location'] == 'X-Constrained' &&
              f['pointer'] == '/id',
        ),
        true,
      );
      await result.close();
      constrained = '{"id":1}';
      meta = ['1', '2'];
      result = await send();
      expect(
        result.response.headers.where((h) => h.$1 == 'x-meta'),
        hasLength(2),
      );
      expect(result.received.complete, false);
      expect(result.conforming, false);
      expect(
        result.received.findings.any(
          (f) =>
              f['code'] == 'runtime.response.header.unchecked' &&
              f['location'] == 'X-Meta',
        ),
        true,
      );
      await result.close();
      meta = ['"${'x' * 40}"'];
      result = await send(limit: 16);
      expect(result.received.complete, false);
      expect(result.conforming, false);
      expect(
        result.received.findings.any(
          (f) => f['code'] == 'runtime.response.header.limit',
        ),
        true,
      );
      await result.close();
    });

    test('F03 residual no-body metadata and ordinary GET coverage $version', () async {
      var media = 'application/json', coding = 'br', meta = '{"ok":true}';
      var bytes = utf8.encode('{}');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final noBody = request.uri.path != '/get';
        request.response.statusCode = request.uri.path.startsWith('/empty')
            ? int.parse(request.uri.path.substring(6))
            : 200;
        request.response.headers.set('Content-Type', media);
        request.response.headers.set('Content-Encoding', coding);
        request.response.headers.set('X-Meta', meta);
        if (!noBody) request.response.add(bytes);
        await request.response.close();
      });
      final sequence = version == '3.2.1'
          ? 'itemSchema: {type: object, required: [id]}'
          : 'schema: {type: object}';
      String response(int status) =>
          "responses: {'$status': {description: ok, headers: {X-Meta: {content: {application/json: {}}}}, content: {application/json: {schema: {type: object}}, application/jsonl: {$sequence}}}}";
      File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: $version
info: {title: No-body metadata, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /head: {head: {${response(200)}}}
  /empty204: {get: {${response(204)}}}
  /empty205: {get: {${response(205)}}}
  /empty304: {get: {${response(304)}}}
  /get: {get: {${response(200)}}}
''');
      project = await BusyProject.open(temp.path, engine);
      for (final path in ['/head', '/empty204', '/empty205', '/empty304']) {
        final plan = await planFor(path);
        addTearDown(plan.close);
        for (final metadata in [
          ('application/json', 'br'),
          ('application/json; charset=utf-32', 'identity'),
          ('application/json; charset=utf-32', 'gzip'),
          ('application/jsonl; charset=utf-32', 'br'),
          ('application/jsonl', 'identity'),
        ]) {
          (media, coding) = metadata;
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(planIdentity: plan.identity),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(result.response.receiptComplete, true);
          expect(result.response.bodyLength, 0);
          expect(
            result.response.decodingComplete,
            true,
            reason: '$path $metadata ${result.response.decodingReason}',
          );
          expect(result.response.decodingReason, null);
          expect(result.response.decodedLength, 0);
          expect(
            result.received.complete,
            true,
            reason: '$path $metadata ${result.received.findings}',
          );
          expect(result.conforming, true);
          expect(result.received.coverage['body'], 'not-applicable');
          expect(
            result.response.headers.any(
              (h) => h.$1 == 'content-encoding' && h.$2 == coding,
            ),
            true,
          );
          final destination =
              '${temp.path}/no-body-${path.substring(1)}-${coding}-${media.hashCode}.bin';
          await result.response.export(destination);
          expect(await File(destination).readAsBytes(), isEmpty);
          expect(await result.response.decodedBytes(), isEmpty);
          await result.close();
        }
        meta = 'not json';
        final invalidHeader = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(planIdentity: plan.identity),
          resolveSecret: (_) async => null,
        );
        addTearDown(invalidHeader.close);
        expect(invalidHeader.received.complete, true);
        expect(invalidHeader.received.valid, false);
        expect(
          invalidHeader.received.findings.any(
            (f) =>
                f['code'] == 'runtime.body.syntax' && f['location'] == 'X-Meta',
          ),
          true,
        );
        await invalidHeader.close();
        meta = '{"ok":true}';
      }
      final plan = await planFor('/get');
      addTearDown(plan.close);
      for (final mode in [
        'unsupported-coding',
        'empty-unsupported-coding',
        'malformed-coding',
        'unsupported-charset',
        'items',
        'syntax',
        'empty-json',
      ]) {
        media = mode == 'items'
            ? 'application/jsonl'
            : mode == 'unsupported-charset'
            ? 'application/json; charset=utf-32'
            : 'application/json';
        coding = mode.endsWith('unsupported-coding')
            ? 'br'
            : mode == 'malformed-coding'
            ? 'gzip'
            : 'identity';
        bytes = utf8.encode(
          mode.startsWith('empty-')
              ? ''
              : mode == 'syntax'
              ? 'not json'
              : mode == 'malformed-coding'
              ? 'not gzip'
              : '{}',
        );
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(planIdentity: plan.identity),
          resolveSecret: (_) async => null,
        );
        addTearDown(result.close);
        expect(result.conforming, false, reason: mode);
        if (mode.endsWith('unsupported-coding') || mode == 'malformed-coding') {
          expect(
            result.response.decodingReason,
            mode.endsWith('unsupported-coding')
                ? 'unsupported-content-encoding'
                : 'malformed-content-encoding',
          );
          expect(result.received.complete, false);
        }
        if (mode == 'unsupported-charset') {
          expect(result.received.complete, false);
          expect(
            result.received.findings.any(
              (f) => f['code'] == 'runtime.response.charset.unchecked',
            ),
            true,
          );
        }
        if (mode == 'items') {
          expect(result.received.complete, false);
          expect(
            result.received.findings.any(
              (f) =>
                  f['code'] ==
                  (version == '3.2.1'
                      ? 'runtime.response.items.unchecked'
                      : 'runtime.response.body.unchecked'),
            ),
            true,
          );
        }
        if (mode == 'syntax' || mode == 'empty-json') {
          expect(result.received.complete, true);
          expect(result.received.valid, false);
          expect(
            result.received.findings.any(
              (f) => f['code'] == 'runtime.body.syntax',
            ),
            true,
          );
        }
        expect(await result.response.bytes(), bytes);
        await result.close();
      }
    });
  }

  test(
    'F03 schema-free JSON syntax governs outgoing and received conformance',
    () async {
      List<int> bytes = utf8.encode('{}');
      var contentType = 'application/json';
      final sent = <String>[], targets = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        targets.add(request.uri.queryParameters['q']);
        sent.add(
          utf8.decode(
            await request.fold<List<int>>([], (a, b) => a..addAll(b)),
          ),
        );
        request.response.headers.set('Content-Type', contentType);
        request.response.statusCode = request.uri.path == '/empty' ? 204 : 200;
        if (request.method != 'HEAD' && request.uri.path != '/empty')
          request.response.add(bytes);
        await request.response.close();
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Syntax, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /json:
    post:
      parameters: [{in: query, name: q, content: {application/json: {}}}]
      requestBody: {content: {application/json: {}, application/problem+json: {}}}
      responses: {'200': {description: ok, content: {application/json: {}, application/problem+json: {}}}}
  /head: {head: {responses: {'200': {description: ok, content: {application/json: {}}}}}}
  /empty: {get: {responses: {'204': {description: empty, content: {application/json: {}}}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/json');
      addTearDown(plan.close);
      for (final media in ['application/json', 'application/problem+json']) {
        contentType = media;
        for (final specimen in [
          '{"n":9007199254740993}',
          '42',
          '"scalar"',
          'null',
          'not json',
          '{} garbage',
          '',
        ]) {
          bytes = utf8.encode(specimen);
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.raw(mediaType: media, text: specimen),
            ),
            resolveSecret: (_) async => null,
          );
          final valid = !['not json', '{} garbage', ''].contains(specimen);
          expect(result.outgoing.complete, true, reason: specimen);
          expect(result.outgoing.valid, valid, reason: specimen);
          expect(result.received.complete, true, reason: specimen);
          expect(result.received.valid, valid, reason: specimen);
          expect(result.conforming, valid);
          expect(
            sent.last,
            specimen,
            reason: 'Deliberately malformed input remains sendable.',
          );
          await result.close();
        }
      }
      contentType = 'application/json';
      bytes = [0xff];
      var result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(planIdentity: plan.identity),
        resolveSecret: (_) async => null,
      );
      expect(result.received.valid, false);
      expect(
        result.received.findings.any(
          (f) => f['code'] == 'runtime.response.body.encoding',
        ),
        true,
      );
      await result.close();
      bytes = utf8.encode('{"long":"${'x' * 100}"}');
      result = await const ContractRequestExecutor(maximumEvaluationBytes: 16)
          .execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: const RequestBodyDraft.raw(
                mediaType: 'application/json',
                text: '{"long":"long long long"}',
              ),
            ),
            resolveSecret: (_) async => null,
          );
      expect(result.received.complete, false);
      expect(result.outgoing.complete, false);
      expect(result.conforming, false);
      await result.close();
      for (final specimen in ['{"n":9007199254740993}', 'not json', '']) {
        result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: {
              OperationRequestDraft.parameterKey('query', 'q'):
                  RequestValue.text(specimen),
            },
          ),
          resolveSecret: (_) async => null,
        );
        expect(result.outgoing.complete, true);
        expect(result.outgoing.valid, specimen.startsWith('{'));
        expect(targets.last, specimen);
        await result.close();
      }
      for (final path in ['/head', '/empty']) {
        final noBody = await planFor(path);
        addTearDown(noBody.close);
        result = await const ContractRequestExecutor().execute(
          noBody,
          OperationRequestDraft(planIdentity: noBody.identity),
          resolveSecret: (_) async => null,
        );
        expect(result.received.complete, true);
        expect(
          result.received.valid,
          true,
          reason: '$path ${result.received.findings}',
        );
        await result.close();
      }
    },
  );

  test('F05 serialized query ownership detects API-key collisions without rewriting fragments', () async {
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Query ownership, version: '1'}
servers: [{url: http://127.0.0.1:1}]
security: [{key: []}]
components: {securitySchemes: {key: {type: apiKey, in: query, name: api_key}}}
paths:
  /query:
    get:
      parameters: [{in: query, name: api_key, schema: {type: string}}]
      responses: {'200': {description: ok}}
  /whole:
    get:
      parameters: [{in: querystring, name: all, content: {application/x-www-form-urlencoded: {}}}]
      responses: {'200': {description: ok}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {authentication: {alternative: 0, schemes: {key: {secretRef: 123e4567-e89b-42d3-a456-426614174000}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    for (final path in ['/query', '/whole']) {
      final plan = await planFor(path);
      addTearDown(plan.close);
      final key = OperationRequestDraft.parameterKey(
        path == '/query' ? 'query' : 'querystring',
        path == '/query' ? 'api_key' : 'all',
      );
      for (final preview in [false, true]) {
        for (final value in [
          if (path == '/query') const RequestValue.text('demo'),
          const RequestValue.serialized('api_key=demo'),
          const RequestValue.serialized('%61pi%5fkey=demo'),
          const RequestValue.serialized('tag=one&api_key=demo&tag=two'),
        ]) {
          await expectLater(
            const ContractRequestBuilder().build(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                environment: 'local',
                securityAlternative: 0,
                parameters: {key: value},
              ),
              resolveSecret: (_) async => 'synthetic',
              previewOnly: preview,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'request.security.collision',
              ),
            ),
          );
        }
        final input = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'local',
            securityAlternative: 0,
            parameters: {
              key: const RequestValue.serialized(
                'tag=one%2ftwo&tag=three%20four',
              ),
            },
          ),
          resolveSecret: (_) async => 'synthetic',
          previewOnly: preview,
        );
        expect(
          input.uri.query,
          'tag=one%2Ftwo&tag=three%20four&api_key=${preview ? '%5BREDACTED%5D' : 'synthetic'}',
        );
      }
    }
  });

  test('F06 pending OAuth secret lookup settles on cancellation and observes late success or error', () async {
    var exchanges = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      exchanges++;
      await request.drain<void>();
      await request.response.close();
    });
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Owned lookup, version: '1'}
components: {securitySchemes: {oauth: {type: oauth2, flows: {clientCredentials: {tokenUrl: 'http://127.0.0.1:${server.port}/token', scopes: {}}}}}}
paths: {/private: {get: {security: [{oauth: []}], responses: {'200': {description: ok}}}}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {authentication: {alternative: 0, schemes: {oauth: {clientId: desktop, clientAuthentication: basic, clientSecretRef: 123e4567-e89b-42d3-a456-426614174000}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/private');
    addTearDown(plan.close);
    for (final lateError in [false, true]) {
      final entered = Completer<void>(),
          gate = Completer<String?>(),
          token = RunCancellation();
      final pending = const OAuthClient().clientCredentials(
        plan,
        environment: 'local',
        scheme: 'oauth',
        cancellation: token,
        resolveSecret: (_) {
          entered.complete();
          return gate.future;
        },
      );
      final check = expectLater(
        pending,
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      await entered.future;
      token.cancel();
      await check;
      expect(
        gate.isCompleted,
        false,
        reason: 'Authorization must settle before the backend does.',
      );
      if (lateError) {
        gate.completeError(StateError('late backend error'));
      } else {
        gate.complete('synthetic');
      }
      await Future<void>.value();
      expect(exchanges, 0);
    }
  });

  test('F07 OAuth validates scopes before binding and owns every post-bind failure', () async {
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Callback ownership, version: '1'}
components: {securitySchemes: {oauth: {type: oauth2, flows: {authorizationCode: {authorizationUrl: http://127.0.0.1:1/authorize, tokenUrl: http://127.0.0.1:1/token, scopes: {read: Read, write: Write}}}}}}
paths: {/private: {get: {security: [{oauth: [write]}], responses: {'200': {description: ok}}}}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {authentication: {alternative: 0, schemes: {oauth: {clientId: desktop, scopes: [read]}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    var plan = await planFor('/private');
    addTearDown(plan.close);
    final receivers = <_ObservedReceiver>[];
    var launched = 0;
    Future<HttpServer> receiver({bool failPort = false}) async {
      final value = _ObservedReceiver(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        failPort: failPort,
      );
      receivers.add(value);
      return value;
    }

    for (var i = 0; i < 3; i++) {
      await expectLater(
        OAuthClient(bindCallbackReceiver: receiver).authorizationCode(
          plan,
          environment: 'local',
          scheme: 'oauth',
          cancellation: RunCancellation(),
          launchBrowser: (_) async {
            launched++;
          },
        ),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'oauth.scopes.required',
          ),
        ),
      );
    }
    expect(receivers, isEmpty);
    expect(launched, 0);
    final manifest = File('${temp.path}/busyapi.yaml');
    final configuration = manifest.readAsStringSync();
    for (final malformed in ['"read write"', '["bad scope"]']) {
      manifest.writeAsStringSync(
        configuration.replaceFirst('scopes: [read]', 'scopes: $malformed'),
      );
      final malformedPlan = await planFor('/private');
      addTearDown(malformedPlan.close);
      await expectLater(
        OAuthClient(bindCallbackReceiver: receiver).authorizationCode(
          malformedPlan,
          environment: 'local',
          scheme: 'oauth',
          cancellation: RunCancellation(),
          launchBrowser: (_) async {
            launched++;
          },
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'oauth.scopes'),
        ),
      );
      expect(receivers, isEmpty);
      expect(launched, 0);
    }
    manifest.writeAsStringSync(configuration);
    plan = await planFor('/private');
    addTearDown(plan.close);

    for (final failPort in [true, false]) {
      await expectLater(
        OAuthClient(bindCallbackReceiver: () => receiver(failPort: failPort))
            .authorizationCode(
              plan,
              environment: 'local',
              scheme: 'oauth',
              scopes: ['write'],
              cancellation: RunCancellation(),
              launchBrowser: (_) async {
                launched++;
                throw StateError('injected browser failure');
              },
            ),
        throwsA(isA<StateError>()),
      );
      expect(receivers.last.closed, true);
      // A new receiver can reclaim the actual port: no leaked loopback listener.
      final rebound = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        receivers.last.boundPort,
      );
      await rebound.close(force: true);
    }
    expect(launched, 1);
  });

  test('F12 response directory creation failures are classified and cancellation remains authoritative', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('body');
      await request.response.close();
    });
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Storage, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/data: {get: {responses: {'200': {description: ok}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/data');
    addTearDown(plan.close);
    for (final cancel in [false, true]) {
      final token = RunCancellation(), overrides = _ObservedHttp();
      var opened = false;
      final input = await const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(planIdentity: plan.identity),
        resolveSecret: (_) async => null,
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        await expectLater(
          ContractHttpTransport(
            createResponseDirectory: () async {
              if (cancel) token.cancel();
              throw const FileSystemException(
                'injected directory creation failure',
              );
            },
            openResponseStorage: (_) async {
              opened = true;
              throw StateError('unreachable');
            },
          ).send(input, cancellation: token),
          throwsA(
            isA<CoreFailure>()
                .having(
                  (e) => e.code,
                  'code',
                  cancel ? 'cancelled' : 'response.storage',
                )
                .having(
                  (e) => e.message,
                  'message',
                  cancel
                      ? contains('cancelled')
                      : contains('disk space and permissions'),
                ),
          ),
        );
      }, overrides);
      expect(opened, false);
      expect(overrides.clients, hasLength(1));
      expect(
        () => overrides.clients.single.getUrl(Uri.parse('http://127.0.0.1:1')),
        throwsStateError,
      );
    }
  });
  test(
    'TLS configuration names external material without authorizing its read',
    () {
      final configuration = ExecutionConfiguration.parse({
        'id': File('${temp.path}/busyapi.yaml').uri.toString(),
        'text': 'version: 1\nenvironments: {external: {tls: {caFile: ../private/ca.pem}}}\n',
      }, temp.path);
      expect(
        configuration.environments['external']!.tls['caFile'],
        '../private/ca.pem',
      );
    },
  );

  test('TLS approval renews changed selected bytes at capacity, not a seventeenth file', () async {
    const source = '''
openapi: 3.2.1
info: {title: Selected files, version: "1"}
paths: {/secure: {get: {responses: {"204": {description: ok}}}}}
''';
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync(source);
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/secure');
    addTearDown(plan.close);
    final external = await Directory.systemTemp.createTemp(
      'busyapi-tls-capacity-',
    );
    addTearDown(() => external.delete(recursive: true));
    final files = [
      for (var i = 0; i < 17; i++)
        File('${external.path}/selected-$i.pem')..writeAsBytesSync([i, 0, 255]),
    ];
    for (final file in files.take(16)) {
      await project!.approveExecutionFile(file.path);
    }
    files.first.writeAsBytesSync([42, 0, 254]);
    await expectLater(
      plan.readProjectFile(files.first.path),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'access.file.changed'),
      ),
    );
    await project!.approveExecutionFile('${external.path}/./selected-0.pem');
    expect(await plan.readProjectFile(files.first.path), [42, 0, 254]);
    await expectLater(
      project!.approveExecutionFile(files.last.path),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'access.limit')),
    );
    await expectLater(
      plan.readProjectFile(files.last.path),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'access.outside'),
      ),
    );
    for (var i = 1; i < 16; i++) {
      expect(await plan.readProjectFile(files[i].path), [i, 0, 255]);
    }
    expect(contract.readAsStringSync(), source);
  });

  test(
    'TLS approval capacity remains bounded across concurrent selections',
    () async {
      File('${temp.path}/openapi.yaml').writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Capacity, version: "1"}\npaths: {}\n',
      );
      project = await BusyProject.open(temp.path, engine);
      final external = await Directory.systemTemp.createTemp(
        'busyapi-tls-concurrent-',
      );
      addTearDown(() => external.delete(recursive: true));
      final files = [
        for (var i = 0; i < 17; i++)
          File('${external.path}/selected-$i.pem')..writeAsBytesSync([i]),
      ];
      for (final file in files.take(15)) {
        await project!.approveExecutionFile(file.path);
      }
      Future<Object?> approve(File file) async {
        try {
          await project!.approveExecutionFile(file.path);
          return null;
        } on Object catch (error) {
          return error;
        }
      }

      final outcomes = await Future.wait(files.skip(15).map(approve));
      expect(outcomes.where((value) => value == null), hasLength(1));
      expect(outcomes.whereType<CoreFailure>().single.code, 'access.limit');
    },
  );

  test(
    'one overall deadline owns upload, redirect drain, chain and final body',
    () async {
      final seen = <String, int>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final path = request.uri.path;
        seen.update(path, (n) => n + 1, ifAbsent: () => 1);
        try {
          if (path == '/upload')
            return; // Deliberately never consume the upload.
          if (path.startsWith('/chain')) {
            await Future<void>.delayed(const Duration(milliseconds: 90));
            final index = int.parse(path.substring('/chain'.length));
            request.response.statusCode = 302;
            request.response.headers.set('location', '/chain${index + 1}');
            await request.response.close();
            return;
          }
          if (path == '/redirect-stall') {
            request.response.statusCode = 302;
            request.response.headers.set('location', '/never');
          }
          request.response.write('first');
          await request.response
              .flush(); // Neither redirect nor final body ends.
        } on Object {
          /* A deadline closes the owned connection. */
        }
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Deadlines, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /upload: {post: {responses: {"200": {description: ok}}}}
  /redirect-stall: {get: {responses: {"200": {description: ok}}}}
  /chain0: {get: {responses: {"200": {description: ok}}}}
  /final-stall: {get: {responses: {"200": {description: ok}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      for (final path in [
        '/upload',
        '/redirect-stall',
        '/chain0',
        '/final-stall',
      ]) {
        final plan = await planFor(path);
        addTearDown(plan.close);
        for (final explicitCancel in [false, true]) {
          final token = RunCancellation();
          final input = await const ContractRequestBuilder().build(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              overallTimeout: const Duration(milliseconds: 250),
              inactivityTimeout: const Duration(seconds: 2),
            ),
            resolveSecret: (_) async => null,
          );
          var uploadCancelled = false;
          final upload = StreamController<List<int>>(
            onCancel: () {
              uploadCancelled = true;
            },
          );
          final prepared = path == '/upload'
              ? _withBody(input, PreparedRequestBody(1024, () => upload.stream))
              : input;
          final watch = Stopwatch()..start();
          final cancelTimer = explicitCancel
              ? Timer(const Duration(milliseconds: 100), token.cancel)
              : null;
          ContractHttpResponse? response;
          String? failure;
          try {
            response = await const ContractHttpTransport()
                .send(prepared, cancellation: token)
                .timeout(
                  const Duration(milliseconds: 900),
                  onTimeout: () {
                    token.cancel();
                    throw StateError(
                      'transport outlived its overall deadline: '
                      '$path cancel=$explicitCancel '
                      'elapsed=${watch.elapsedMilliseconds}ms seen=$seen',
                    );
                  },
                );
          } on CoreFailure catch (error) {
            failure = error.code;
          } finally {
            cancelTimer?.cancel();
            token.cancel();
            if (path == '/upload') await upload.close();
          }
          expect(
            watch.elapsedMilliseconds,
            lessThan(800),
            reason: '$path cancel=$explicitCancel',
          );
          if (response != null) {
            expect(response.receiptComplete, false);
            expect(
              response.incompleteReason,
              explicitCancel ? 'cancelled' : 'overall-timeout',
            );
            await response.close();
          } else {
            expect(failure, explicitCancel ? 'cancelled' : 'request.timeout');
          }
          if (path == '/upload') expect(uploadCancelled, true);
        }
      }
      expect(seen['/never'], isNull);
      expect(seen['/upload'] ?? 0, lessThanOrEqualTo(2)); // No retry/replay.
    },
  );

  test('form, multipart and binary bodies reach the controlled server as authored bytes', () async {
    final received = <Map<String, Object?>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final bytes = await request.fold<List<int>>(
        [],
        (all, part) => all..addAll(part),
      );
      received.add({
        'path': request.uri.path,
        'contentType': request.headers.value(HttpHeaders.contentTypeHeader),
        'body': bytes,
      });
      request.response.statusCode = 204;
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {baseUrl: http://127.0.0.1:${server.port}}}
''');
    File('${temp.path}/openapi.yaml').writeAsStringSync(_bodyContract);
    final binary = File('${temp.path}/binary.dat')
      ..writeAsBytesSync([0, 1, 2, 255, 128]);
    project = await BusyProject.open(temp.path, engine);
    final builder = const ContractRequestBuilder();
    for (final entry in <(String, RequestBodyDraft)>[
      (
        '/form',
        const RequestBodyDraft.form([
          RequestFormField('name', '雪'),
          RequestFormField('tag', 'a'),
          RequestFormField('tag', 'b'),
        ]),
      ),
      (
        '/multipart',
        RequestBodyDraft.multipart(
          const [RequestFormField('note', 'literal')],
          [MultipartFileValue(name: 'payload', path: binary.path)],
        ),
      ),
      (
        '/binary',
        RequestBodyDraft.binaryFile(
          mediaType: 'application/octet-stream; charset=shift_jis',
          file: binary.path,
        ),
      ),
    ]) {
      final plan = await planFor(entry.$1);
      addTearDown(plan.close);
      final prepared = await builder.build(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          environment: 'local',
          body: entry.$2,
        ),
        resolveSecret: (_) async => null,
      );
      final response = await const ContractHttpTransport().send(prepared);
      await response.close();
    }
    expect(
      utf8.decode(received[0]['body'] as List<int>),
      'name=%E9%9B%AA&tag=a&tag=b',
    );
    final multipartType = received[1]['contentType'] as String;
    expect(multipartType, startsWith('multipart/form-data; boundary=busyapi-'));
    final multipart = received[1]['body'] as List<int>;
    expect(
      utf8.decode(multipart, allowMalformed: true),
      contains('name="note"\r\n\r\nliteral'),
    );
    expect(
      utf8.decode(multipart, allowMalformed: true),
      contains('filename="binary.dat"'),
    );
    expect(_containsBytes(multipart, [0, 1, 2, 255, 128]), true);
    expect(received[2]['body'], [0, 1, 2, 255, 128]);
    expect(
      received[2]['contentType'],
      'application/octet-stream; charset=shift_jis',
      reason: 'A captured file is opaque authored bytes; no UTF-8 text conversion is performed.',
    );
  });

  test('timeouts, cancellation and redirects preserve distinct incomplete outcomes and credentials', () async {
    var leaked = false;
    final foreign = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => foreign.close(force: true));
    foreign.listen((request) async {
      leaked = request.headers.value('X-Api-Key') != null;
      request.response.statusCode = 200;
      await request.response.close();
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      switch (request.uri.path) {
        case '/redirect':
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${foreign.port}/foreign',
          );
          await request.response.close();
        case '/slow':
          request.response.statusCode = 200;
          request.response.write('first');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          request.response.write('late');
          await request.response.close();
        case '/cancel':
          request.response.statusCode = 200;
          request.response.write('started');
          await request.response.flush();
          await Future<void>.delayed(const Duration(seconds: 2));
          await request.response.close();
      }
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  local:
    baseUrl: http://127.0.0.1:${server.port}
    headers: {X-Api-Key: synthetic-secret}
''');
    File('${temp.path}/openapi.yaml').writeAsStringSync(_transportContract);
    project = await BusyProject.open(temp.path, engine);

    final redirectPlan = await planFor('/redirect');
    addTearDown(redirectPlan.close);
    final redirect = await const ContractRequestExecutor().execute(
      redirectPlan,
      OperationRequestDraft(
        planIdentity: redirectPlan.identity,
        environment: 'local',
      ),
      resolveSecret: (_) async => null,
    );
    addTearDown(redirect.close);
    expect(redirect.response.status, 302);
    expect(
      redirect.response.incompleteReason,
      'cross-origin-redirect-not-followed',
    );
    expect(leaked, false);

    final slowPlan = await planFor('/slow');
    addTearDown(slowPlan.close);
    final slow = await const ContractRequestExecutor().execute(
      slowPlan,
      OperationRequestDraft(
        planIdentity: slowPlan.identity,
        environment: 'local',
        inactivityTimeout: const Duration(milliseconds: 100),
      ),
      resolveSecret: (_) async => null,
    );
    addTearDown(slow.close);
    expect(slow.response.receiptComplete, false);
    expect(slow.response.incompleteReason, 'response-inactivity-timeout');
    expect(slow.received.complete, false);

    final cancelPlan = await planFor('/cancel');
    addTearDown(cancelPlan.close);
    final cancellation = RunCancellation();
    final pending = const ContractRequestExecutor().execute(
      cancelPlan,
      OperationRequestDraft(
        planIdentity: cancelPlan.identity,
        environment: 'local',
      ),
      resolveSecret: (_) async => null,
      cancellation: cancellation,
    );
    await Future<void>.delayed(const Duration(milliseconds: 75));
    cancellation.cancel();
    final cancelled = await pending;
    addTearDown(cancelled.close);
    expect(cancelled.response.receiptComplete, false);
    expect(cancelled.response.incompleteReason, 'cancelled');
  });

  test('OAuth authorization code uses PKCE/state and client credentials resolve only their secret', () async {
    final tokenRequests = <Map<String, String>>[];
    final tokenServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => tokenServer.close(force: true));
    tokenServer.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      tokenRequests.add({
        'body': body,
        'authorization':
            request.headers.value(HttpHeaders.authorizationHeader) ?? '',
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"access_token":"synthetic-token","token_type":"Bearer","expires_in":60}',
      );
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  oauth:
    baseUrl: http://127.0.0.1:1
    authentication:
      schemes:
        oauth:
          clientId: desktop-client
          clientSecretRef: 123e4567-e89b-42d3-a456-426614174002
          clientAuthentication: basic
          scopes: [read]
''');
    File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.1.2
info: {title: OAuth, version: "1"}
components:
  securitySchemes:
    oauth:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: http://127.0.0.1:${tokenServer.port}/authorize
          tokenUrl: http://127.0.0.1:${tokenServer.port}/token
          scopes: {read: Read}
        clientCredentials:
          tokenUrl: http://127.0.0.1:${tokenServer.port}/token
          scopes: {read: Read}
paths:
  /private:
    get:
      security: [{oauth: [read]}]
      responses: {"200": {description: ok}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/private');
    addTearDown(plan.close);
    Uri? authorization;
    final callbackCompleted = Completer<void>();
    final authToken = await const OAuthClient().authorizationCode(
      plan,
      environment: 'oauth',
      scheme: 'oauth',
      cancellation: RunCancellation(),
      resolveSecret: (_) async => 'client-secret',
      launchBrowser: (uri) async {
        authorization = uri;
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        unawaited(() async {
          final callback = Uri.parse(uri.queryParameters['redirect_uri']!);
          final client = HttpClient();
          try {
            // The launcher returns immediately, like the desktop portal. Let
            // the receiver subscribe before simulating browser navigation.
            await Future<void>.delayed(const Duration(milliseconds: 10));
            final wrong = await (await client.getUrl(
              callback.replace(
                queryParameters: {'state': 'wrong', 'code': 'wrong-code'},
              ),
            )).close();
            expect(wrong.statusCode, 400);
            await wrong.drain<void>();
            final right = await (await client.getUrl(
              callback.replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'one-use-code',
                },
              ),
            )).close();
            expect(right.statusCode, 200);
            await right.drain<void>();
            callbackCompleted.complete();
          } catch (error, stack) {
            callbackCompleted.completeError(error, stack);
          } finally {
            client.close(force: true);
          }
        }());
      },
    );
    await callbackCompleted.future;
    expect(authToken.accessToken, 'synthetic-token');
    expect(authToken.owner, plan.identity);
    expect(authToken.environment, 'oauth');
    final authorizationBody = Uri.splitQueryString(
      tokenRequests.first['body']!,
    );
    final verifier = authorizationBody['code_verifier']!;
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    expect(challenge, authorization!.queryParameters['code_challenge']);
    expect(authorizationBody['code'], 'one-use-code');

    final resolved = <String>[];
    final clientToken = await const OAuthClient().clientCredentials(
      plan,
      environment: 'oauth',
      scheme: 'oauth',
      cancellation: RunCancellation(),
      resolveSecret: (reference) async {
        resolved.add(reference);
        return 'client-secret';
      },
    );
    expect(clientToken.accessToken, 'synthetic-token');
    expect(resolved, ['123e4567-e89b-42d3-a456-426614174002']);
    expect(tokenRequests.last['authorization'], startsWith('Basic '));
    expect(
      Uri.splitQueryString(tokenRequests.last['body']!)['grant_type'],
      'client_credentials',
    );
  });

  test('custom CA and mutual TLS use selected project material while verification stays enabled', () async {
    final certificates = Directory('${temp.path}/certs')..createSync();
    Future<void> openssl(List<String> arguments) async {
      final result = await Process.run(
        '/usr/bin/openssl',
        arguments,
        workingDirectory: certificates.path,
        environment: const {'PATH': '', 'LC_ALL': 'C.UTF-8'},
        includeParentEnvironment: false,
      );
      if (result.exitCode != 0) {
        fail('openssl ${arguments.first} failed: ${result.stderr}');
      }
    }

    await openssl([
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=BusyAPI Test CA',
      '-keyout',
      'ca.key',
      '-out',
      'ca.crt',
    ]);
    await openssl([
      'req',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=127.0.0.1',
      '-keyout',
      'server.key',
      '-out',
      'server.csr',
    ]);
    File('${certificates.path}/server.ext').writeAsStringSync(
      'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n',
    );
    await openssl([
      'x509',
      '-req',
      '-in',
      'server.csr',
      '-CA',
      'ca.crt',
      '-CAkey',
      'ca.key',
      '-CAcreateserial',
      '-days',
      '1',
      '-extfile',
      'server.ext',
      '-out',
      'server.crt',
    ]);
    await openssl([
      'req',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=BusyAPI Client',
      '-keyout',
      'client.key',
      '-out',
      'client.csr',
    ]);
    File('${certificates.path}/client.ext')
        .writeAsStringSync('extendedKeyUsage=clientAuth\n');
    await openssl([
      'x509',
      '-req',
      '-in',
      'client.csr',
      '-CA',
      'ca.crt',
      '-CAkey',
      'ca.key',
      '-days',
      '1',
      '-extfile',
      'client.ext',
      '-out',
      'client.crt',
    ]);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain('${certificates.path}/server.crt')
      ..usePrivateKey('${certificates.path}/server.key')
      ..setTrustedCertificates('${certificates.path}/ca.crt');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
    );
    addTearDown(() => server.close(force: true));
    final clientSeen = Completer<bool>();
    server.listen((request) async {
      if (!clientSeen.isCompleted)
        clientSeen.complete(request.certificate != null);
      request.response.statusCode = 204;
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  secure:
    baseUrl: https://127.0.0.1:${server.port}
    tls:
      caFile: certs/ca.crt
      clientCertificateFile: certs/client.crt
      clientKeyFile: certs/client.key
''');
    File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.1.2
info: {title: TLS, version: "1"}
paths: {/secure: {get: {responses: {"204": {description: ok}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/secure');
    addTearDown(plan.close);
    final prepared = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(planIdentity: plan.identity, environment: 'secure'),
      resolveSecret: (_) async => null,
    );
    final response = await const ContractHttpTransport().send(prepared);
    addTearDown(response.close);
    expect(response.status, 204);
    expect(await clientSeen.future, true);
    final external = await Directory.systemTemp.createTemp(
      'busyapi-selected-tls-',
    );
    addTearDown(() => external.delete(recursive: true));
    final selected = <String, String>{};
    for (final entry in {
      'caFile': 'ca.crt',
      'clientCertificateFile': 'client.crt',
      'clientKeyFile': 'client.key',
    }.entries) {
      selected[entry.key] = (await File(
        '${certificates.path}/${entry.value}',
      ).copy('${external.path}/${entry.value}')).path;
    }
    final externalDraft = OperationRequestDraft(
      planIdentity: plan.identity,
      environment: 'secure',
      tlsFiles: selected,
    );
    await expectLater(
      const ContractRequestBuilder().build(
        plan,
        externalDraft,
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'access.outside'),
      ),
    );
    for (final file in selected.values) {
      await project!.approveExecutionFile(file);
    }
    final approved = await const ContractRequestBuilder().build(
      plan,
      externalDraft,
      resolveSecret: (_) async => null,
    );
    final externalResponse = await const ContractHttpTransport().send(approved);
    await externalResponse.close();
    expect(externalResponse.status, 204);
    File(selected['caFile']!)
        .writeAsStringSync('replacement must not acquire TLS authority');
    await expectLater(
      const ContractRequestBuilder().build(
        plan,
        externalDraft,
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'access.file.changed'),
      ),
    );
    File(selected['caFile']!).deleteSync();
    Link(selected['caFile']!).createSync('${certificates.path}/ca.crt');
    await expectLater(
      plan.readProjectFile(selected['caFile']!),
      throwsA(isA<CoreFailure>()),
    );
  });

  test(
    'delayed credential completion cannot revive a closed project',
    () async {
      File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  local:
    baseUrl: http://127.0.0.1:1
    authentication:
      alternative: 0
      schemes:
        bearer: {tokenRef: 123e4567-e89b-42d3-a456-426614174003}
''');
      File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.1.2
info: {title: Ownership, version: "1"}
components: {securitySchemes: {bearer: {type: http, scheme: bearer}}}
paths: {/private: {get: {security: [{bearer: []}], responses: {"200": {description: ok}}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/private');
      final secret = Completer<String?>();
      final pending = const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          environment: 'local',
        ),
        resolveSecret: (_) => secret.future,
      );
      project!.close();
      project = null;
      secret.complete('must-not-escape');
      await expectLater(
        pending,
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'request.closed'),
        ),
      );
    },
  );
  test('H12 cancellation transfers preparation ownership and releases each upload once', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {});
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Upload ownership, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/upload: {post: {responses: {'204': {description: ok}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/upload');
    addTearDown(plan.close);
    final draft = OperationRequestDraft(planIdentity: plan.identity);
    final input = await const ContractRequestBuilder().build(
      plan,
      draft,
      resolveSecret: (_) async => null,
    );
    for (final duringPreparation in [true, false]) {
      final acquired = Completer<PreparedContractRequest>(),
          opened = Completer<void>(),
          released = Completer<void>();
      var releases = 0, uploadCancelled = false;
      StreamController<List<int>>? upload;
      final body = PreparedRequestBody(
        1024,
        () {
          opened.complete();
          upload = StreamController<List<int>>(
            onCancel: () {
              uploadCancelled = true;
            },
          );
          return upload!.stream;
        },
        release: () async {
          releases++;
          if (!released.isCompleted) released.complete();
        },
      );
      final token = RunCancellation();
      final pending =
          ContractRequestExecutor(
            builder: _DeferredRequestBuilder(acquired.future),
          ).execute(
            plan,
            draft,
            resolveSecret: (_) async => null,
            cancellation: token,
          );
      if (!duringPreparation) {
        acquired.complete(_withBody(input, body));
        await opened.future;
      }
      token.cancel();
      await expectLater(
        pending,
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      if (duringPreparation) acquired.complete(_withBody(input, body));
      await released.future;
      await body.close();
      expect(releases, 1);
      expect(uploadCancelled, !duringPreparation);
      await upload?.close();
    }
  });

  test('H20 redirects redact reflected credentials and never adopt URI credentials', () async {
    var mode = 'echo', finals = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          mode == 'echo'
              ? '/final?different=fixture-token'
              : 'http://injected:server-password@127.0.0.1:${server.port}/final',
        );
      } else {
        finals++;
        expect(request.uri.queryParameters['different'], 'fixture-token');
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Redirect summaries, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
security: [{access: []}]
components: {securitySchemes: {access: {type: http, scheme: bearer}}}
paths: {/start: {get: {responses: {'204': {description: ok}, '302': {description: redirect}}}}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {authentication: {alternative: 0, schemes: {access: {tokenRef: 123e4567-e89b-42d3-a456-426614174000}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/start');
    addTearDown(plan.close);
    for (final selected in ['echo', 'userinfo']) {
      mode = selected;
      final result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          environment: 'local',
        ),
        resolveSecret: (_) async => 'fixture-token',
      );
      expect(
        result.response.redirects.single,
        isNot(contains('fixture-token')),
      );
      expect(
        result.response.redirects.single,
        isNot(contains('server-password')),
      );
      if (selected == 'userinfo') {
        expect(result.response.status, 302);
        expect(
          result.response.incompleteReason,
          'credential-bearing-redirect-not-followed',
        );
        expect(
          result.response.headers.any(
            (h) => h.$1 == 'location' && h.$2.contains('server-password'),
          ),
          isTrue,
        );
      }
      await result.close();
    }
    expect(finals, 1);
  });

  test(
    'H01 retained entity bytes and bounded decoded inspection are independent',
    () async {
      const json = '{"id":9007199254740993}';
      final encoded = gzip.encode(utf8.encode(json));
      final expansion = gzip.encode(List.filled(4 * 1024 * 1024, 97));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var mode = 'gzip';
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (mode != 'plain')
          request.response.headers.set(
            'content-encoding',
            mode == 'unknown'
                ? 'br'
                : mode == 'double'
                ? 'gzip, identity, gzip'
                : 'gzip',
          );
        request.response.add(
          mode == 'plain'
              ? utf8.encode(json)
              : mode == 'malformed'
              ? [1, 2, 3]
              : mode == 'double'
              ? gzip.encode(encoded)
              : mode == 'expansion'
              ? expansion
              : encoded,
        );
        await request.response.close();
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Decoding, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/data: {get: {responses: {'200': {description: ok, content: {application/json: {schema: {type: object, required: [id], properties: {id: {type: integer}}}}}}}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/data');
      addTearDown(plan.close);
      final draft = OperationRequestDraft(planIdentity: plan.identity);
      for (final selected in [
        'plain',
        'gzip',
        'double',
        'malformed',
        'unknown',
        'limit',
        'expansion',
      ]) {
        mode = selected;
        final result = await ContractRequestExecutor(
          transport: ContractHttpTransport(
            maximumDecodedBytes: selected == 'limit'
                ? 8
                : selected == 'expansion'
                ? 4096
                : 1024,
          ),
        ).execute(plan, draft, resolveSecret: (_) async => null);
        try {
          expect(result.response.receiptComplete, isTrue);
          if (selected == 'plain' ||
              selected == 'gzip' ||
              selected == 'double') {
            expect(result.conforming, isTrue);
            expect(utf8.decode(result.response.displayBytes), json);
            expect(utf8.decode(await result.response.decodedBytes()), json);
          } else {
            expect(result.received.complete, isFalse);
            expect(result.conforming, isFalse);
            expect(
              result.response.decodingReason,
              selected == 'limit' || selected == 'expansion'
                  ? 'decoded-size-limit'
                  : selected == 'unknown'
                  ? 'unsupported-content-encoding'
                  : 'malformed-content-encoding',
            );
          }
          final output = '${temp.path}/$selected.bin';
          await result.response.export(output);
          await expectLater(
            result.response.export(output),
            throwsA(isA<AtomicFileAlreadyExistsException>()),
          );
          if (result.response.decodingComplete) {
            final decoded = '$output.decoded';
            await result.response.export(decoded, decoded: true);
            expect(await File(decoded).readAsString(), json);
          } else {
            await expectLater(
              result.response.export('$output.decoded', decoded: true),
              throwsA(isA<CoreFailure>()),
            );
          }

          expect(
            await File(output).readAsBytes(),
            selected == 'plain'
                ? utf8.encode(json)
                : selected == 'malformed'
                ? [1, 2, 3]
                : selected == 'double'
                ? gzip.encode(encoded)
                : selected == 'expansion'
                ? expansion
                : encoded,
          );
        } finally {
          await result.close();
        }
      }
      mode = 'gzip';
      final flushStarted = Completer<void>(), releaseFlush = Completer<void>();
      final cancel = RunCancellation();
      final prepared = await const ContractRequestBuilder().build(
        plan,
        draft,
        resolveSecret: (_) async => null,
      );
      final pending = ContractHttpTransport(
        openResponseStorage: (file) async => _TestStorage(
          await FileResponseStorage.open(file),
          flushStarted: flushStarted,
          releaseFlush: releaseFlush,
        ),
      ).send(prepared, cancellation: cancel);
      await flushStarted.future;
      cancel.cancel();
      releaseFlush.complete();
      final cancelled = await pending;
      expect(cancelled.receiptComplete, isTrue);
      expect(cancelled.decodingComplete, isFalse);
      expect(cancelled.decodingReason, 'cancelled');
      expect(await cancelled.bytes(), encoded);
      final owned = cancelled.ownedDirectory!;
      final cancelledExport = '${temp.path}/cancelled-export.bin';
      final exportCancellation = RunCancellation();
      await expectLater(
        cancelled.export(
          cancelledExport,
          cancellation: exportCancellation,
          beforePublish: () async => exportCancellation.cancel(),
        ),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      expect(await File(cancelledExport).exists(), isFalse);
      final disposedExport = '${temp.path}/disposed-export.bin';
      await expectLater(
        cancelled.export(disposedExport, beforePublish: cancelled.close),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'response.closed'),
        ),
      );
      expect(await File(disposedExport).exists(), isFalse);
      await cancelled.close();
      expect(await Directory(owned).exists(), isFalse);
    },
  );
  test('U4 charset inspection is truthful without a schema and examples require supported text', () async {
    var charset = 'us-ascii';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const body = '{"message":"雪"}';
    server.listen((request) async {
      request.response.headers.set(
        'content-type',
        'application/json; charset=$charset',
      );
      request.response.add(utf8.encode(body));
      await request.response.close();
    });
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Charset inspection, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/text: {get: {responses: {'200': {description: ok, content: {application/json: {}}}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/text');
    addTearDown(plan.close);
    for (final selected in ['us-ascii', 'utf-16', 'utf-8']) {
      charset = selected;
      final result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(planIdentity: plan.identity),
        resolveSecret: (_) async => null,
      );
      expect(await result.response.bytes(), utf8.encode(body));
      expect(result.response.receiptComplete, isTrue);
      if (selected == 'us-ascii') {
        expect(result.received.valid, isFalse);
        expect(
          result.received.findings.any(
            (f) => f['code'] == 'runtime.response.body.encoding',
          ),
          isTrue,
        );
      } else if (selected == 'utf-16') {
        expect(result.received.complete, isFalse);
      } else {
        expect(result.conforming, isTrue);
      }
      expect(result.response.exampleEligible, selected == 'utf-8');
      await result.close();
    }
  });

  test(
    'H04 content path values preserve the complete request target and suffix',
    () async {
      final targets = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        targets.add(request.uri.toString());
        request.response.statusCode = 204;
        await request.response.close();
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Paths, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /items/{id}/details:
    get:
      parameters: [{name: id, in: path, required: true, content: {text/plain: {schema: {type: string}}}}]
      responses: {'204': {description: ok}}
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/items/{id}/details');
      addTearDown(plan.close);
      for (final value in [
        'a/b',
        'a?b',
        'a#b',
        'a%b',
        'a b',
        '雪',
        '{"id":"a#b"}',
      ]) {
        final input = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: {
              OperationRequestDraft.parameterKey('path', 'id'):
                  RequestValue.text(value),
            },
          ),
          resolveSecret: (_) async => null,
        );
        final response = await const ContractHttpTransport().send(input);
        await response.close();
        expect(targets.last, '/items/${Uri.encodeComponent(value)}/details');
      }
    },
  );

  test(
    'H04 whole-query JSON and form media preserve different encoding layers',
    () async {
      final targets = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        targets.add(request.uri.toString());
        request.response.statusCode = 204;
        await request.response.close();
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Whole query, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /json: {get: {parameters: [{name: filter, in: querystring, content: {application/json: {schema: {}}}}], responses: {'204': {description: ok}}}}
  /form: {get: {parameters: [{name: filter, in: querystring, content: {application/x-www-form-urlencoded: {schema: {}}}}], responses: {'204': {description: ok}}}}
  /unsupported: {get: {parameters: [{name: filter, in: querystring, content: {application/xml: {schema: {}}}}], responses: {'204': {description: ok}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      for (final path in ['/json', '/form', '/unsupported']) {
        final plan = await planFor(path);
        addTearDown(plan.close);
        const data = '{"tag":["one","two"],"note":"a&b#% 雪"}';
        final pending = const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: {
              OperationRequestDraft.parameterKey('querystring', 'filter'):
                  const RequestValue.json(data),
            },
          ),
          resolveSecret: (_) async => null,
        );
        if (path == '/unsupported') {
          await expectLater(pending, throwsA(isA<CoreFailure>()));
        } else {
          final input = await pending;
          final response = await const ContractHttpTransport().send(input);
          await response.close();
          expect(
            targets.last,
            path == '/json'
                ? '/json?${Uri.encodeComponent(data)}'
                : '/form?tag=one&tag=two&note=a%26b%23%25+%E9%9B%AA',
          );
        }
      }
      expect(targets.length, 2);
    },
  );

  test('H08 H09 H10 cookie repetition and parameterized multipart honor captured encoding', () async {
    final bodies = <String>[], cookies = <String?>[], mediaTypes = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      cookies.add(request.headers.value('cookie'));
      mediaTypes.add(request.headers.value('content-type'));
      bodies.add(
        utf8.decode(await request.fold<List<int>>([], (a, b) => a..addAll(b))),
      );
      request.response.statusCode = 204;
      await request.response.close();
    });
    File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Multipart, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /upload:
    post:
      parameters:
        - {name: color, in: cookie, style: cookie, schema: {type: array, items: {type: string}}}
        - {name: options, in: cookie, style: cookie, schema: {type: object}}
        - {name: note, in: cookie, style: form, schema: {type: string}}
      requestBody:
        content:
          'multipart/form-data; charset=utf-8':
            schema: {type: object}
            encoding:
              metadata:
                contentType: application/json
                headers: {Content-Transfer-Encoding: {schema: {type: string}, example: binary}}
      responses: {'204': {description: ok}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/upload');
    addTearDown(plan.close);
    final file = File('${temp.path}/upload.bin')..writeAsStringSync('file-A');
    final prepared = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        parameters: {
          OperationRequestDraft.parameterKey('cookie', 'color'):
              const RequestValue.json('["red","blue"]'),
          OperationRequestDraft.parameterKey('cookie', 'options'):
              const RequestValue.json('{"a":1,"b":"a%20b%2Cc"}'),
          OperationRequestDraft.parameterKey('cookie', 'note'):
              const RequestValue.text('a b,c'),
        },
        body: RequestBodyDraft.multipart(
          [
            const RequestFormField('metadata', '{"id":1}'),
            const RequestFormField('note', 'a&admin=true'),
            const RequestFormField('note', ' a=b%26雪 '),
          ],
          [MultipartFileValue(name: 'attachment', path: file.path)],
          mediaType: 'multipart/form-data; charset=utf-8',
        ),
      ),
      resolveSecret: (_) async => null,
    );
    // The selected file contents become owned bytes during preparation.
    file.writeAsStringSync('file-B');
    final response = await const ContractHttpTransport().send(prepared);
    await response.close();
    expect(
      cookies.single,
      'color=red; color=blue; a=1; b=a%20b%2Cc; note=a%20b%2Cc',
    );
    expect(
      mediaTypes.single,
      startsWith('multipart/form-data; charset=utf-8; boundary='),
    );
    expect(
      bodies.single,
      contains(
        'Content-Type: application/json\r\nContent-Transfer-Encoding: binary\r\n\r\n{"id":1}',
      ),
    );
    expect(bodies.single, contains('a&admin=true'));
    expect(bodies.single, contains(' a=b%26雪 '));
    expect(bodies.single, contains('file-A'));
    expect(bodies.single, isNot(contains('file-B')));
    await expectLater(
      const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          parameters: {
            OperationRequestDraft.parameterKey('cookie', 'color'):
                const RequestValue.json('["red"]'),
            OperationRequestDraft.parameterKey('cookie', 'options'):
                const RequestValue.json('{"color":"collision"}'),
          },
        ),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'request.cookie.duplicate',
        ),
      ),
    );
    final root = File('${temp.path}/openapi.yaml');
    final original = root.readAsStringSync();
    await project!.buffer(root.uri.toString());
    for (final rule in [
      ('charset=iso-8859-1', 'request.charset.unsupported'),
      ('charset=us-ascii', 'request.charset'),
    ]) {
      project!.store.replace(
        root.uri.toString(),
        original.replaceFirst(
          'contentType: application/json',
          "contentType: 'application/json; ${rule.$1}'",
        ),
      );
      final constrained = await planFor('/upload');
      addTearDown(constrained.close);
      await expectLater(
        const ContractRequestBuilder().build(
          constrained,
          OperationRequestDraft(
            planIdentity: constrained.identity,
            body: const RequestBodyDraft.multipart(
              [RequestFormField('metadata', '{"id":"雪"}')],
              [],
              mediaType: 'multipart/form-data; charset=utf-8',
            ),
          ),
          resolveSecret: (_) async => null,
        ),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', rule.$2)),
      );
    }
    project!.store.replace(
      root.uri.toString(),
      original.replaceAll('Content-Transfer-Encoding', 'X-Forbidden'),
    );
    final forbidden = await planFor('/upload');
    addTearDown(forbidden.close);
    await expectLater(
      const ContractRequestBuilder().build(
        forbidden,
        OperationRequestDraft(
          planIdentity: forbidden.identity,
          body: const RequestBodyDraft.multipart(
            [RequestFormField('metadata', '{}')],
            [],
            mediaType: 'multipart/form-data; charset=utf-8',
          ),
        ),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'request.multipart.headers',
        ),
      ),
    );
    project!.store.replace(
      root.uri.toString(),
      original.replaceFirst(
        'contentType: application/json',
        'contentType: multipart/mixed\n                encoding: {nested: {contentType: text/plain}}',
      ),
    );
    final complex = await planFor('/upload');
    addTearDown(complex.close);
    await expectLater(
      const ContractRequestBuilder().build(
        complex,
        OperationRequestDraft(
          planIdentity: complex.identity,
          body: const RequestBodyDraft.multipart(
            [RequestFormField('metadata', 'literal')],
            [],
            mediaType: 'multipart/form-data; charset=utf-8',
          ),
        ),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'request.multipart.encoding',
        ),
      ),
    );
    expect(bodies.length, 1);
  });
  test('H10 parameterized form identity survives generic alternatives and validation', () async {
    final seen = <(String, String)>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      seen.add((
        request.headers.contentType.toString(),
        await utf8.decoder.bind(request).join(),
      ));
      request.response.statusCode = 204;
      await request.response.close();
    });
    for (final generic in [false, true]) {
      File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Form identity, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /form:
    post:
      requestBody:
        content:
          'Application/X-WWW-Form-Urlencoded; charset=utf-8': {schema: {}}
          'application/x-www-form-urlencoded; charset=utf-8': {schema: {type: object, required: [note]}}
${generic ? '          application/x-www-form-urlencoded: {schema: {}}' : ''}
      responses: {'204': {description: ok}}
''');
      project?.close();
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/form');
      final result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: const RequestBodyDraft.form([
            RequestFormField('note', '雪 & value'),
          ], mediaType: 'application/x-www-form-urlencoded; charset=utf-8'),
        ),
        resolveSecret: (_) async => null,
      );
      expect(seen.last, (
        'application/x-www-form-urlencoded; charset=utf-8',
        'note=%E9%9B%AA+%26+value',
      ));
      expect(
        result.request.body!.mediaType,
        'application/x-www-form-urlencoded; charset=utf-8',
      );
      // The selected constrained declaration is acknowledged as unchecked;
      // a generic unconstrained alternative must not conceal it.
      expect(result.outgoing.complete, isFalse);
      expect(
        result.outgoing.findings.any(
          (f) => f['code'] == 'runtime.request.body.unchecked',
        ),
        isTrue,
      );
      await result.close();
      plan.close();
    }
    expect(seen.length, 2);
  });
  test(
    'H14 storage failures are owned and slow writes apply backpressure',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          request.response.add(List.filled(10000, 65));
          await request.response.close();
        } on Object {
          /* Client owns cancellation. */
        }
      });
      File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Storage, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/data: {get: {responses: {'200': {description: ok}}}}}
''');
      project = await BusyProject.open(temp.path, engine);
      final plan = await planFor('/data');
      addTearDown(plan.close);
      for (final failure in ['open', 'write', 'flush', 'close']) {
        String? capturedDirectory;
        final transport = ContractHttpTransport(
          openResponseStorage: (file) async {
            capturedDirectory = file.parent.path;
            if (failure == 'open')
              throw const FileSystemException('injected open failure');
            return _TestStorage(
              await FileResponseStorage.open(file),
              failure: failure,
            );
          },
        );
        final input = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(planIdentity: plan.identity),
          resolveSecret: (_) async => null,
        );
        await expectLater(
          transport.send(input),
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'response.storage',
            ),
          ),
        );
        expect(
          await Directory(capturedDirectory!).exists(),
          isFalse,
          reason: failure,
        );
      }
      final started = Completer<void>(), release = Completer<void>();
      late _TestStorage storage;
      final transport = ContractHttpTransport(
        openResponseStorage: (file) async => storage = _TestStorage(
          await FileResponseStorage.open(file),
          started: started,
          release: release,
        ),
      );
      final input = await const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(planIdentity: plan.identity),
        resolveSecret: (_) async => null,
      );
      final cancel = RunCancellation(),
          pending = transport.send(input, cancellation: cancel);
      await started.future;
      expect(storage.writes, 1);
      cancel.cancel();
      release.complete();
      final response = await pending;
      expect(response.receiptComplete, isFalse);
      expect(response.incompleteReason, 'cancelled');
      expect(response.exampleEligible, isFalse);
      final partial = '${temp.path}/partial.bin';
      await response.export(partial);
      expect(await File(partial).readAsBytes(), await response.bytes());
      expect(await File(partial).length(), response.bodyLength);
      await response.close();
    },
  );

  test('U1 preview shares exact destination resolution without secrets TLS files or upload capture', () async {
    const ref = '123e4567-e89b-42d3-a456-426614174000';
    File('${temp.path}/openapi.yaml').writeAsStringSync('''openapi: 3.2.1
info: {title: Preview, version: '1'}
servers: [{url: https://authored.example.test}]
security: [{key: []}]
components: {securitySchemes: {key: {type: apiKey, in: query, name: credential}}}
paths: {/upload: {post: {requestBody: {content: {application/octet-stream: {schema: {}}}}, responses: {'204': {description: ok}}}}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  local:
    baseUrl: 'https://preview.example.test/\${prefix}'
    variables: {prefix: v1}
    authentication: {alternative: 0, schemes: {key: {secretRef: $ref}}}
    tls: {caFile: missing-ca.pem}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/upload');
    addTearDown(plan.close);
    var reads = 0;
    final prepared = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        environment: 'local',
        body: const RequestBodyDraft.binaryFile(
          mediaType: 'application/octet-stream',
          file: '/does-not-exist',
        ),
      ),
      resolveSecret: (_) async {
        reads++;
        throw StateError('preview must not resolve a secret');
      },
      previewOnly: true,
    );
    expect(reads, 0);
    expect(
      prepared.displayUri,
      'https://preview.example.test/v1/upload?credential=%5BREDACTED%5D',
    );
    expect(prepared.body!.length, 0);
    expect(prepared.tls.ca, isNull);
    await prepared.body!.close();
  });

  test('U6 held upload capture rejects mutation and cancellation without reopening a replacement', () async {
    final access = await ProjectAccess.open(temp.path);
    addTearDown(access.close);
    final source = File('${temp.path}/selected.bin');
    final captured = File('${temp.path}/captured.bin');
    final original = List<int>.generate(192 * 1024, (i) => i % 251);
    for (final mode in [
      'replace',
      'grow',
      'truncate',
      'mutate',
      'remove',
      'directory',
      'cancel',
    ]) {
      if (await FileSystemEntity.type(source.path) ==
          FileSystemEntityType.directory) {
        await Directory(source.path).delete();
      }
      source.writeAsBytesSync(original);
      var observed = false;
      final cancellation = RunCancellation();
      final result = access.captureUpload(
        source.path,
        captured,
        maximumBytes: 1024 * 1024,
        checkCurrent: () {
          if (!observed) {
            observed = true;
            switch (mode) {
              case 'replace':
                final replacement = File('${temp.path}/replacement.bin')
                  ..writeAsBytesSync(List.filled(original.length, 42));
                replacement.renameSync(source.path);
              case 'grow':
                source.writeAsBytesSync([1], mode: FileMode.append);
              case 'truncate':
                source.writeAsBytesSync([1]);
              case 'mutate':
                source.writeAsBytesSync(List.filled(original.length, 42));
              case 'remove':
                source.deleteSync();
              case 'directory':
                source.deleteSync();
                Directory(source.path).createSync();
              case 'cancel':
                cancellation.cancel();
            }
          }
          cancellation.throwIfCancelled();
        },
      );
      if (['replace', 'remove', 'directory'].contains(mode)) {
        expect(await result, original.length);
        expect(
          await captured.readAsBytes(),
          original,
          reason: 'Held descriptor retains selected file for $mode',
        );
      } else {
        await expectLater(
          result,
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              mode == 'cancel' ? 'cancelled' : 'request.file.changed',
            ),
          ),
        );
      }
      if (await captured.exists()) await captured.delete();
    }
    await expectLater(
      access.captureUpload(source.path, captured, maximumBytes: 1024),
      throwsA(isA<CoreFailure>()),
    );
  });

  test('H16 H17 token types and absolute exchange deadline cannot become usable tokens', () async {
    var mode = 'missing', exchanges = 0;
    final requestedScopes = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      exchanges++;
      requestedScopes.add(
        Uri.splitQueryString(await utf8.decoder.bind(request).join())['scope'],
      );
      request.response.headers.contentType = ContentType.json;
      try {
        if (mode == 'drip') {
          request.response.write('{"access_token":"');
          await request.response.flush();
          for (var i = 0; i < 40; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            request.response.write('a');
            await request.response.flush();
          }
          request.response.write('","token_type":"Bearer"}');
        } else
          request.response.write(
            jsonEncode({
              'access_token': 'synthetic-token',
              if (mode != 'missing') 'token_type': mode,
              'expires_in': 0,
            }),
          );
        await request.response.close();
      } on Object {
        /* Owned deadline closes the peer. */
      }
    });
    File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Tokens, version: "1"}
components: {securitySchemes: {oauth: {type: oauth2, flows: {clientCredentials: {tokenUrl: 'http://127.0.0.1:${server.port}/token', scopes: {read: Read}}}}}}
paths:
  /data: {get: {security: [{oauth: [read]}, {}], responses: {'204': {description: ok}}}}
  /write: {get: {security: [{oauth: [write]}], responses: {'204': {description: ok}}}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {authentication: {alternative: 0, schemes: {oauth: {clientId: synthetic, clientAuthentication: none, scopes: [read]}}}}}
''');
    project = await BusyProject.open(temp.path, engine);
    final plan = await planFor('/data');
    addTearDown(plan.close);
    for (final variant in ['missing', 'MAC', 'bearer', 'BEARER', 'drip']) {
      mode = variant;
      final pending =
          const OAuthClient(tokenExchangeTimeout: Duration(milliseconds: 180))
              .clientCredentials(
                plan,
                environment: 'local',
                scheme: 'oauth',
                draft: OperationRequestDraft(
                  planIdentity: plan.identity,
                  environment: 'local',
                  securityAlternative: 0,
                ),
                resolveSecret: (_) async => null,
                cancellation: RunCancellation(),
              );
      if (variant == 'bearer' || variant == 'BEARER') {
        final token = await pending;
        expect(token.tokenType, 'Bearer');
        expect(token.expired, isTrue);
        expect(token.scope, ['read']);
      } else
        await expectLater(
          pending,
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              variant == 'drip' ? 'oauth.exchange.timeout' : 'oauth.token.type',
            ),
          ),
        );
    }
    expect(exchanges, 5);
    expect(requestedScopes, everyElement('read'));
    final writePlan = await planFor('/write');
    addTearDown(writePlan.close);
    await expectLater(
      const OAuthClient().clientCredentials(
        writePlan,
        environment: 'local',
        scheme: 'oauth',
        cancellation: RunCancellation(),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'oauth.scopes.required',
        ),
      ),
    );
    for (final alternative in [1, 20]) {
      await expectLater(
        const OAuthClient().clientCredentials(
          plan,
          environment: 'local',
          scheme: 'oauth',
          draft: OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'local',
            securityAlternative: alternative,
          ),
          cancellation: RunCancellation(),
          resolveSecret: (_) async => null,
        ),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'oauth.scopes.selection',
          ),
        ),
      );
    }
    expect(
      exchanges,
      5,
      reason: 'Scope mismatches must fail before token exchange.',
    );
  });
}

bool _containsBytes(List<int> source, List<int> needle) {
  for (var index = 0; index <= source.length - needle.length; index++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (source[index + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

const _bodyContract = '''
openapi: 3.2.1
info: {title: Bodies, version: "1"}
paths:
  /form:
    post:
      requestBody: {required: true, content: {application/x-www-form-urlencoded: {schema: {type: object}}}}
      responses: {"204": {description: ok}}
  /multipart:
    post:
      requestBody: {required: true, content: {multipart/form-data: {schema: {type: object}}}}
      responses: {"204": {description: ok}}
  /binary:
    post:
      requestBody: {required: true, content: {application/octet-stream: {schema: {type: string, contentMediaType: application/octet-stream}}}}
      responses: {"204": {description: ok}}
''';

const _transportContract = '''
openapi: 3.1.2
info: {title: Transport, version: "1"}
paths:
  /redirect:
    get:
      responses: {"302": {description: elsewhere}}
  /slow:
    get:
      responses: {"200": {description: slow, content: {text/plain: {schema: {type: string}}}}}
  /cancel:
    get:
      responses: {"200": {description: cancel, content: {text/plain: {schema: {type: string}}}}}
''';

class _TestStorage implements ResponseStorage {
  _TestStorage(
    this.delegate, {
    this.failure,
    this.started,
    this.release,
    this.flushStarted,
    this.releaseFlush,
  });
  final ResponseStorage delegate;
  final String? failure;
  final Completer<void>? started, release, flushStarted, releaseFlush;
  int writes = 0;
  bool closed = false;
  @override
  Future<void> write(List<int> bytes) async {
    writes++;
    if (started?.isCompleted == false) started!.complete();
    await release?.future;
    if (failure == 'write') throw const FileSystemException('injected write');
    await delegate.write(bytes);
  }

  @override
  Future<void> flush() async {
    if (flushStarted?.isCompleted == false) flushStarted!.complete();
    await releaseFlush?.future;
    if (failure == 'flush') throw const FileSystemException('injected flush');
    await delegate.flush();
  }

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      await delegate.close();
    }
    if (failure == 'close') throw const FileSystemException('injected close');
  }
}

class _DeferredRequestBuilder extends ContractRequestBuilder {
  _DeferredRequestBuilder(this.prepared);
  final Future<PreparedContractRequest> prepared;
  @override
  Future<PreparedContractRequest> build(
    OperationRequestPlan plan,
    OperationRequestDraft draft, {
    required SecretResolver resolveSecret,
    bool previewOnly = false,
    RunCancellation? cancellation,
  }) => prepared;
}

class _ObservedReceiver implements HttpServer {
  _ObservedReceiver(this.inner, {this.failPort = false})
    : boundPort = inner.port;
  final HttpServer inner;
  final int boundPort;
  final bool failPort;
  bool closed = false;
  @override
  int get port {
    if (failPort) throw StateError('injected URI preparation failure');
    return inner.port;
  }

  @override
  Future<HttpServer> close({bool force = false}) async {
    closed = true;
    await inner.close(force: force);
    return inner;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedHttp extends HttpOverrides {
  final clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    clients.add(client);
    return client;
  }
}
