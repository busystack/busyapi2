import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  late BusyProject project;
  late String root;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-m3-execution-');
    engine = EngineProcess(
      executable: runtimeNode,
      helper: '$repositoryRoot/tools/contract_engine/dist/engine.cjs',
    );
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });

  Future<OperationRequestPlan> prepare() async {
    final analysis = await project.check(root);
    final operation =
        (analysis['projection']['operations'] as List).single as Map;
    return project.prepareRequest(
      root,
      resource: operation['resource'] as String,
      pointer: operation['pointer'] as String,
      occurrence: operation['occurrence'] as String,
    );
  }

  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    test(
      '$version label values and server templates retain wire semantics',
      () async {
        final paths = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          paths.add(request.uri.toString());
          request.response.statusCode = 204;
          await request.response.close();
        });
        final contract = File('${temp.path}/openapi.yaml')
          ..writeAsStringSync('''
openapi: $version
info: {title: Labels, version: "1"}
servers:
  - url: http://127.0.0.1:${server.port}/{version}
    variables: {version: {default: v1/public}}
paths:
  /items/{label}:
    get:
      parameters:
        - {name: label, in: path, required: true, style: label, explode: true, schema: {}}
        - {name: exact, in: query, explode: true, schema: {}}
        - {name: object, in: query, style: deepObject, explode: true, schema: {}}
      responses: {"204": {description: ok}}
''');
        project = await BusyProject.open(temp.path, engine);
        root = contract.uri.toString();
        final plan = await prepare();
        addTearDown(plan.close);
        for (final entry in [
          ('["blue","black"]', '.blue.black'),
          ('{"R":100,"G":200}', '.R=100.G=200'),
          ('["a/b","雪"]', '.a%2Fb.%E9%9B%AA'),
        ]) {
          final input = await const ContractRequestBuilder().build(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              parameters: {
                OperationRequestDraft.parameterKey('path', 'label'):
                    RequestValue.json(entry.$1),
                OperationRequestDraft.parameterKey(
                  'query',
                  'exact',
                ): const RequestValue.json(
                  '[9007199254740993,123456789012345678901234567890,1.0000000000000000001]',
                ),
                OperationRequestDraft.parameterKey(
                  'query',
                  'object',
                ): const RequestValue.json(
                  '{"n":123456789012345678901234567890,"fraction":1.0000000000000000001}',
                ),
              },
            ),
            resolveSecret: (_) async => null,
          );
          expect(
            input.uri.query,
            'exact=9007199254740993&exact=123456789012345678901234567890&exact=1.0000000000000000001&object%5Bn%5D=123456789012345678901234567890&object%5Bfraction%5D=1.0000000000000000001',
          );
          expect(input.uri.path, startsWith('/v1/public/items/'));
          expect(input.uri.toString(), contains('/items/${entry.$2}'));
          final response = await const ContractHttpTransport().send(input);
          await response.close();
          expect(paths.last, '${input.uri.path}?${input.uri.query}');
        }
        for (final bad in [
          'v1#fragment',
          '{unresolved}',
          'v1\r\nInjected: true',
        ]) {
          await expectLater(
            const ContractRequestBuilder().build(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                variables: {'version': bad},
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'request.url'),
            ),
          );
        }
        final buffer = await project.buffer(root);
        project.store.replace(
          root,
          buffer.text.replaceFirst(
            'style: label, explode: true',
            'style: label, explode: false',
          ),
        );
        final unexpanded = await prepare();
        addTearDown(unexpanded.close);
        for (final entry in [
          ('["blue","black"]', '.blue,black'),
          ('{"R":100,"G":200}', '.R,100,G,200'),
        ]) {
          final input = await const ContractRequestBuilder().build(
            unexpanded,
            OperationRequestDraft(
              planIdentity: unexpanded.identity,
              parameters: {
                OperationRequestDraft.parameterKey('path', 'label'):
                    RequestValue.json(entry.$1),
              },
            ),
            resolveSecret: (_) async => null,
          );
          expect(input.uri.path, '/v1/public/items/${entry.$2}');
          final response = await const ContractHttpTransport().send(input);
          await response.close();
          expect(paths.last, input.uri.path);
        }
        project.store.replace(
          root,
          buffer.text.replaceFirst(
            '    variables: {version: {default: v1/public}}\n',
            '',
          ),
        );
        final missingVariable = await prepare();
        addTearDown(missingVariable.close);
        await expectLater(
          const ContractRequestBuilder().build(
            missingVariable,
            OperationRequestDraft(planIdentity: missingVariable.identity),
            resolveSecret: (_) async => null,
          ),
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'request.server.variable',
            ),
          ),
        );
      },
    );
  }

  test('native wire preserves parameter styles, repeats, Unicode and exact JSON bytes', () async {
    final received = Completer<Map<String, Object?>>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = await request.fold<List<int>>(
        [],
        (all, part) => all..addAll(part),
      );
      final headers = <String, List<String>>{};
      request.headers.forEach((name, values) => headers[name] = values);
      received.complete({
        'method': request.method,
        'uri': request.uri.toString(),
        'headers': headers,
        'body': utf8.decode(body),
      });
      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.add('X-Trace', 'ok');
      request.response.write('{"id":9007199254740993,"name":"雪"}');
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots:
  - name: api
    path: openapi.yaml
environments:
  local:
    baseUrl: http://127.0.0.1:${server.port}/v1
    variables: {tenant: north}
''');
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync(r'''
openapi: 3.2.1
info: {title: Wire, version: "1"}
paths:
  /items/{coords}:
    post:
      parameters:
        - {name: coords, in: path, required: true, style: simple, explode: true, schema: {type: object}}
        - {name: tag, in: query, explode: true, schema: {type: array, items: {type: string}}}
        - {name: filter, in: query, style: deepObject, explode: true, schema: {type: object}}
        - {name: X-Mode, in: header, schema: {type: string}}
        - {name: session, in: cookie, schema: {type: string}}
      requestBody:
        required: true
        content:
          application/json:
            schema: {type: object}
      responses:
        "201":
          description: made
          headers:
            X-Trace: {required: true, schema: {type: string}}
          content:
            application/json:
              schema:
                type: object
                required: [id, name]
                properties:
                  id: {type: integer}
                  name: {type: string}
''');
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    final plan = await prepare();
    addTearDown(plan.close);
    final result = await const ContractRequestExecutor().execute(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        environment: 'local',
        parameters: {
          OperationRequestDraft.parameterKey('path', 'coords'):
              const RequestValue.json('{"x":"a/b","y":2}'),
          OperationRequestDraft.parameterKey('query', 'tag'):
              const RequestValue.json('["one","雪"]'),
          OperationRequestDraft.parameterKey('query', 'filter'):
              const RequestValue.json('{"a":"0","b":false}'),
          OperationRequestDraft.parameterKey('header', 'X-Mode'):
              const RequestValue.text('exact'),
          OperationRequestDraft.parameterKey('cookie', 'session'):
              const RequestValue.text('empty-safe'),
        },
        body: const RequestBodyDraft.raw(
          mediaType: 'application/json',
          text: '{"id":9007199254740993,"name":"雪"}',
        ),
      ),
      resolveSecret: (_) async => null,
    );
    addTearDown(result.close);
    final wire = await received.future;
    expect(wire['method'], 'POST');
    expect(wire['uri'], contains('/v1/items/x=a%2Fb,y=2'));
    expect(wire['uri'], contains('tag=one&tag=%E9%9B%AA'));
    expect(wire['uri'], contains('filter%5Ba%5D=0'));
    expect(wire['uri'], contains('filter%5Bb%5D=false'));
    expect((wire['headers'] as Map)['x-mode'], ['exact']);
    expect((wire['headers'] as Map)['cookie'], ['session=empty-safe']);
    expect(wire['body'], '{"id":9007199254740993,"name":"雪"}');
    expect(result.response.status, 201);
    expect(
      await result.response.bytes(),
      utf8.encode('{"id":9007199254740993,"name":"雪"}'),
    );
    expect(result.response.receiptComplete, true);
    expect(result.outgoing.valid, true);
    expect(result.received.valid, true);
    final history = ContractRequestRecord.fromResult(
      result,
      recordedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    ).toJson();
    final historyText = jsonEncode(history);
    expect(historyText, contains('POST'));
    expect(historyText, contains('/items/{coords}'));
    expect(historyText, isNot(contains('/v1/items/')));
    expect(historyText, isNot(contains('x-mode')));
    expect(historyText, isNot(contains(r'"id":9007199254740993')));
    final destination = File('${temp.path}/response-export.bin');
    Object? collision;
    try {
      await result.response.export(
        destination.path,
        beforePublish: () async {
          await destination.writeAsBytes([0, 255, 128, 7], flush: true);
        },
      );
    } on Object catch (error) {
      collision = error;
    }
    expect(destination.readAsBytesSync(), [
      0,
      255,
      128,
      7,
    ], reason: 'Publication must never clobber a late destination');
    expect(collision, isNotNull);
    await expectLater(
      result.response.export(destination.path),
      throwsA(isA<Exception>()),
    );
    final token = RunCancellation()..cancel();
    await expectLater(
      result.response.export('${temp.path}/cancelled.bin', cancellation: token),
      throwsA(isA<CoreFailure>()),
    );
    expect(File('${temp.path}/cancelled.bin').existsSync(), false);
    await result.response.export('${temp.path}/success.bin');
    expect(
      File('${temp.path}/success.bin').readAsBytesSync(),
      await result.response.bytes(),
    );
  });

  test('authorization only resolves selected combined requirement and redacts its URL', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<HttpRequest>();
    final requests = <HttpRequest>[];
    server.listen((request) async {
      requests.add(request);
      if (!received.isCompleted) received.complete(request);
      request.response.statusCode = 204;
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  local:
    baseUrl: http://127.0.0.1:${server.port}
    authentication:
      alternative: 0
      schemes:
        key: {secretRef: 123e4567-e89b-42d3-a456-426614174000}
        bearer: {tokenRef: 123e4567-e89b-42d3-a456-426614174001}
        basic: {username: api-user, passwordRef: 123e4567-e89b-42d3-a456-426614174002}
''');
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync(r'''
openapi: 3.1.2
info: {title: Auth, version: "1"}
components:
  securitySchemes:
    key: {type: apiKey, in: query, name: api_key}
    bearer: {type: http, scheme: bearer}
    basic: {type: http, scheme: basic}
paths:
  /private:
    get:
      security: [{key: [], bearer: []}, {basic: []}, {}]
      responses: {"204": {description: ok}}
''');
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    final plan = await prepare();
    final resolved = <String>[];
    final prepared = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(planIdentity: plan.identity, environment: 'local'),
      resolveSecret: (reference) async {
        resolved.add(reference);
        return reference.endsWith('000')
            ? 'query-secret'
            : reference.endsWith('001')
            ? 'bearer-secret'
            : 'basic-secret';
      },
    );
    expect(resolved, hasLength(2));
    expect(prepared.displayUri, contains('api_key=%5BREDACTED%5D'));
    expect(prepared.displayUri, isNot(contains('query-secret')));
    await const ContractHttpTransport()
        .send(prepared)
        .then((value) => value.close());
    final request = await received.future;
    expect(request.uri.queryParameters['api_key'], 'query-secret');
    expect(request.headers.value('authorization'), 'Bearer bearer-secret');
    final basic = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        environment: 'local',
        securityAlternative: 1,
      ),
      resolveSecret: (reference) async {
        resolved.add(reference);
        return 'basic-secret';
      },
    );
    expect(resolved, hasLength(3));
    expect(
      basic.headers
          .singleWhere((header) => header.$1.toLowerCase() == 'authorization')
          .$2,
      'Basic ${base64.encode(utf8.encode('api-user:basic-secret'))}',
    );
    final anonymous = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        environment: 'local',
        securityAlternative: 2,
      ),
      resolveSecret: (_) async =>
          throw StateError('Anonymous execution must not resolve credentials'),
    );
    final anonymousResponse = await const ContractHttpTransport().send(
      anonymous,
    );
    await anonymousResponse.close();
    expect(requests.last.headers.value('authorization'), isNull);
    expect(requests.last.uri.queryParameters.containsKey('api_key'), false);
    expect(resolved, hasLength(3));
  });

  test('Prism in-memory adapter accepts literal example ref and stops its loopback listener', () async {
    var upstreamRequests = 0;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((request) async {
      upstreamRequests++;
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"\$ref":"upstream","amount":9007199254740993}');
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync(
      'version: 1\nroots: [{name: api, path: openapi.yaml}]\nmock: {proxyTarget: http://127.0.0.1:${upstream.port}}\n',
    );
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync(r'''
openapi: 3.1.2
info: {title: Mock, version: "1"}
paths:
  /things/{id}:
    get:
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
      responses:
        "200":
          description: ok
          content:
            application/json:
              examples:
                literal:
                  value: {$ref: "payload data", amount: 9007199254740993}
''');
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    final plan = await project.prepareMock(root);
    final run = await plan.start(
      nodeExecutable: runtimeNode,
      helper: '$repositoryRoot/tools/contract_engine/dist/mock-server.cjs',
    );
    expect(run.host, '127.0.0.1');
    expect(run.toolVersion, '5.15.11');
    expect(run.upstreamForwarding, false);
    final client = HttpClient();
    final response = await (await client.getUrl(
      run.baseUri.resolve('/things/1'),
    )).close();
    expect(response.statusCode, 200);
    final body = await utf8.decoder.bind(response).join();
    expect(body, contains(r'"$ref":"payload data"'));
    expect(body, contains('9007199254740993'));
    final invalid = await (await client.getUrl(
      run.baseUri.resolve('/things/not-an-integer'),
    )).close();
    expect(invalid.statusCode, anyOf(400, 422));
    expect(
      invalid.headers.value('sl-violations') ??
          await utf8.decoder.bind(invalid).join(),
      isNotEmpty,
    );
    expect(upstreamRequests, 0);
    await run.stop();
    await expectLater(
      client
          .getUrl(run.baseUri.resolve('/things/1'))
          .then((request) => request.close()),
      throwsA(anything),
    );
    final proxy = await plan.start(
      nodeExecutable: runtimeNode,
      helper: '$repositoryRoot/tools/contract_engine/dist/mock-server.cjs',
      proxyTarget: plan.configuredProxyTarget(),
    );
    addTearDown(proxy.stop);
    expect(proxy.upstreamForwarding, true);
    final proxied = await (await client.getUrl(
      proxy.baseUri.resolve('/things/2'),
    )).close();
    expect(proxied.statusCode, 200);
    final proxiedBody = await utf8.decoder.bind(proxied).join();
    expect(proxiedBody, contains('upstream'));
    expect(proxiedBody, contains('9007199254740993'));
    expect(upstreamRequests, 1);
    final rejected = await (await client.getUrl(
      proxy.baseUri.resolve('/things/not-an-integer'),
    )).close();
    expect(rejected.statusCode, anyOf(400, 422));
    await rejected.drain<void>();
    expect(upstreamRequests, 1);
    final changed = '${contract.readAsStringSync()}\n# unsaved mock change\n';
    await project.buffer(root);
    project.store.replace(root, changed, label: 'Mock outdated test');
    expect(proxy.outdated, true);
    await proxy.stop();
    client.close(force: true);
  });

  test('selected declarative cases execute through the shared transport and report untested operations', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final queries = <String?>[];
    server.listen((request) async {
      requests++;
      queries.add(request.uri.queryParameters['required']);
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('X-Test', 'controlled');
      request.response.write('{"ok":true}');
      await request.response.close();
    });
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {baseUrl: http://127.0.0.1:${server.port}}}
tests:
  - name: selected-example
    operation: {method: get, path: /selected}
    environment: local
    parameters: {query: {required: exact}}
    expect:
      status: 200
      mediaType: application/json
      headers: {X-Test: controlled}
''');
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync('''
openapi: 3.1.2
info: {title: Tests, version: "1"}
paths:
  /selected:
    get:
      parameters: [{name: required, in: query, required: true, schema: {type: string}}]
      responses:
        "200":
          description: ok
          headers: {X-Test: {required: true, schema: {type: string}}}
          content: {application/json: {schema: {\$ref: './response.yaml'}}}
  /untested:
    post:
      responses: {"204": {description: untouched}}
''');
    final schema = File('${temp.path}/response.yaml')
      ..writeAsStringSync(
        'type: object\nrequired: [ok]\nproperties: {ok: {type: boolean}}\n',
      );
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    final report = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: const ['selected-example'],
      resolveSecret: (_) async => null,
    );
    expect(report.complete, true);
    expect(report.passed, true);
    expect(requests, 1);
    expect(report.executedOperations, hasLength(1));
    expect(report.untestedOperations, hasLength(1));
    expect(report.toJson()['coverage'], containsPair('exhaustive', false));
    expect(report.toJson()['input'], 'saved-source');
    final manifest = File('${temp.path}/busyapi.yaml');
    await project.buffer(manifest.uri.toString());
    await project.buffer(schema.uri.toString());
    project.store.replace(
      manifest.uri.toString(),
      manifest.readAsStringSync().replaceFirst(
        'required: exact',
        'required: overlay',
      ),
      label: 'Unsaved test values',
    );
    project.store.replace(
      schema.uri.toString(),
      '${schema.readAsStringSync()}\nproperties: {ok: {const: false}}\n'
          .replaceFirst('properties: {ok: {type: boolean}}\n', ''),
      label: 'Unsaved response assertion',
    );
    final captured = await project.captureContractSnapshot(root);
    final working = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: const ['selected-example'],
      resolveSecret: (_) async => null,
      saved: false,
      expectedSourceIdentity: captured.snapshot.sourceIdentity,
    );
    expect(working.complete, true);
    expect(working.passed, false);
    expect(working.toJson()['input'], 'working-buffers');
    expect(working.cases.single.findings, isNotEmpty);
    expect(queries, ['exact', 'overlay']);
    expect(schema.readAsStringSync(), contains('type: boolean'));
    project.store.replace(
      schema.uri.toString(),
      'type: object\n',
      label: 'Changed selection',
    );
    await expectLater(
      const ContractTestRunner().run(
        project,
        root,
        selectedCases: const ['selected-example'],
        resolveSecret: (_) async => null,
        saved: false,
        expectedSourceIdentity: captured.snapshot.sourceIdentity,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (value) => value.code,
          'code',
          'test.snapshot.changed',
        ),
      ),
    );
    expect(requests, 2);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    test('F03 residual header and no-body saved reports $version', () async {
      var header = <String>['not json'];
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        request.response.headers.noFolding('X-Meta');
        for (final value in header) {
          request.response.headers.add('X-Meta', value);
        }
        // Keep the no-body case's headers valid independently of /headers.
        if (request.method == 'HEAD') {
          request.response.headers.set('X-Meta', '{}');
          request.response.headers.set('X-Problem', '{}');
          request.response.headers.set(
            'Content-Type',
            'application/jsonl; charset=utf-32',
          );
          request.response.headers.set('Content-Encoding', 'br');
        } else {
          request.response.headers.set('X-Problem', header.first);
          request.response.headers.contentType = ContentType.json;
          request.response.write('{}');
        }
        await request.response.close();
      });
      final sequence = version == '3.2.1'
          ? 'itemSchema: {type: object, required: [id]}'
          : 'schema: {type: object}';
      String response(String content) =>
          "responses: {'200': {description: ok, headers: {X-Meta: {content: {application/json: {}}}, X-Problem: {content: {application/problem+json: {}}}}, content: {$content}}}";
      final contract = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync('''openapi: $version
info: {title: Header and no-body reports, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /headers: {get: {${response('application/json: {}')}}}
  /head: {head: {${response('application/jsonl: {$sequence}')}}}
''');
      File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
tests:
  - {name: headers, operation: {method: get, path: /headers}, expect: {status: 200}}
  - {name: no-body, operation: {method: head, path: /head}, expect: {status: 200}}
''');
      project = await BusyProject.open(temp.path, engine);
      root = contract.uri.toString();
      for (final mode in ['malformed', 'valid', 'repeated']) {
        header = switch (mode) {
          'malformed' => ['not json'],
          'valid' => ['{"n":9007199254740993,"d":1.0000000000000000001}'],
          _ => ['1', '2'],
        };
        final report = await const ContractTestRunner().run(
          project,
          root,
          selectedCases: ['headers', 'no-body'],
          resolveSecret: (_) async => null,
        );
        final headers = report.cases.singleWhere((c) => c.name == 'headers');
        final noBody = report.cases.singleWhere((c) => c.name == 'no-body');
        expect(noBody.status, 'passed');
        expect(noBody.complete, true);
        expect(report.complete, mode != 'repeated');
        expect(report.passed, mode == 'valid');
        expect(
          headers.status,
          mode == 'valid'
              ? 'passed'
              : mode == 'repeated'
              ? 'incomplete'
              : 'failed',
        );
        if (mode == 'malformed') {
          expect(
            headers.findings.where((f) => f['code'] == 'runtime.body.syntax'),
            hasLength(2),
          );
        }
        if (mode == 'repeated') {
          expect(
            headers.findings.any(
              (f) => f['code'] == 'runtime.response.header.unchecked',
            ),
            true,
          );
        }
        final junit = CiReports.junit(report);
        expect(junit.contains('<failure'), mode == 'malformed');
        expect(junit.contains('<error'), mode == 'repeated');
        expect(report.toJson()['passed'], mode == 'valid');
        final cli = await Process.run('$testBundle/busyapi', [
          'test',
          temp.path,
          '--case',
          'headers',
          '--case',
          'no-body',
          '--json',
          '--junit',
          '${temp.path}/$mode.xml',
        ]);
        expect(
          cli.exitCode,
          mode == 'valid'
              ? 0
              : mode == 'repeated'
              ? 2
              : 1,
          reason: '${cli.stdout} ${cli.stderr}',
        );
        final json = jsonDecode(cli.stdout as String) as Map;
        expect(json['passed'], mode == 'valid');
        expect(json['complete'], mode != 'repeated');
        final cliJunit = File('${temp.path}/$mode.xml').readAsStringSync();
        expect(cliJunit.contains('<failure'), mode == 'malformed');
        expect(cliJunit.contains('<error'), mode == 'repeated');
      }
      // Both the saved runner and built CLI actually execute both selections.
      expect(requests.where((r) => r == 'GET /headers'), hasLength(6));
      expect(requests.where((r) => r == 'HEAD /head'), hasLength(6));
    });
  }

  test('F03 schema-free JSON saved cases and machine/JUnit reports agree with syntax', () async {
    var specimen = 'not json';
    final received = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      received.add(await utf8.decoder.bind(request).join());
      request.response.headers.contentType = ContentType.json;
      request.response.write(specimen);
      await request.response.close();
    });
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync('''openapi: 3.2.1
info: {title: Syntax reports, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/json: {post: {requestBody: {content: {application/json: {}}}, responses: {'200': {description: ok, content: {application/json: {}}}}}}}
''');
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
tests: [{name: syntax, operation: {method: post, path: /json}, body: {mediaType: application/json, value: 'not json'}, expect: {status: 200}}]
''');
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    var report = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: ['syntax'],
      resolveSecret: (_) async => null,
    );
    expect(received.single, 'not json');
    expect(report.complete, true);
    expect(report.passed, false);
    expect(report.cases.single.status, 'failed');
    expect(
      report.cases.single.findings.where(
        (f) => f['code'] == 'runtime.body.syntax',
      ),
      hasLength(2),
    );
    expect(CiReports.junit(report), contains('<failure'));
    expect(report.toJson()['passed'], false);
    final cli = await Process.run('$testBundle/busyapi', [
      'test',
      temp.path,
      '--case',
      'syntax',
      '--json',
      '--junit',
      '${temp.path}/syntax.xml',
    ]);
    expect(cli.exitCode, 1, reason: '${cli.stdout} ${cli.stderr}');
    expect((jsonDecode(cli.stdout as String) as Map)['passed'], false);
    expect(
      File('${temp.path}/syntax.xml').readAsStringSync(),
      contains('<failure'),
    );
    specimen = '42';
    manifest.writeAsStringSync(
      manifest.readAsStringSync().replaceFirst(
        "value: 'not json'",
        'value: 42',
      ),
    );
    report = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: ['syntax'],
      resolveSecret: (_) async => null,
    );
    expect(report.complete, true);
    expect(report.passed, true);
    expect(received.last, '42');
    expect(CiReports.junit(report), isNot(contains('<failure')));
  });
  test('T01 T02 selected cases keep exact typed numbers and reject every malformed selected assertion before sending', () async {
    final received = <String>[], queries = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      queries.add(request.uri.query);
      received.add(
        utf8.decode(await request.fold<List<int>>([], (a, b) => a..addAll(b))),
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync('''
openapi: 3.2.1
info: {title: Cases, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /exact:
    post:
      parameters: [{name: n, in: query, schema: {type: number}}]
      requestBody: {content: {application/json: {schema: {}}}}
      responses: {'200': {description: ok, content: {application/json: {schema: {}}}}}
''');
    final manifest = File('${temp.path}/busyapi.yaml');
    const numbers = [
      '1.0000000000000000001',
      '9007199254740993',
      '123456789012345678901234567890',
      '1e-100',
      '1e100',
    ];
    String configuration(String expectation) =>
        '''
version: 1
roots: [{name: api, path: openapi.yaml}]
tests:
  - name: first
    operation: {method: post, path: /exact}
    parameters: {query: {n: 1.0000000000000000001}}
    body: {mediaType: application/json, value: {numbers: [${numbers.join(',')}]}}
    expect: {status: [200, 201]}
  - name: second
    operation: {method: post, path: /exact}
    expect: $expectation
''';
    manifest.writeAsStringSync(configuration('{status: 200}'));
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    final result = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: ['first'],
      resolveSecret: (_) async => null,
    );
    expect(result.passed, isTrue, reason: jsonEncode(result.toJson()));
    expect(received.single, '{"numbers":[${numbers.join(',')}]}');
    expect(queries.single, 'n=1.0000000000000000001');
    manifest.writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
x-number: &number 1.0000000000000000001
x-query: &query {n: *number}
x-inputs: &inputs {query: *query}
x-numbers: &numbers [${numbers.join(',')}]
x-value: &value {numbers: *numbers}
x-body: &body {mediaType: application/json, value: *value}
tests:
  - name: aliased
    operation: {method: post, path: /exact}
    parameters: *inputs
    body: *body
    expect: {status: 200}
''');
    final aliasResult = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: ['aliased'],
      resolveSecret: (_) async => null,
    );
    expect(aliasResult.passed, true, reason: jsonEncode(aliasResult.toJson()));
    expect(received.last, received.first);
    expect(
      queries.last,
      queries.first,
      reason: 'F04A optional aliased parameter must actually be sent.',
    );
    received.clear();
    queries.clear();
    for (final malformed in [
      '{status: "200"}',
      '{status: [200, "201"]}',
      '{status: []}',
      '{headers: {X-Test: 7}}',
      '{headers: []}',
      '{}',
    ]) {
      manifest.writeAsStringSync(configuration(malformed));
      await expectLater(
        const ContractTestRunner().run(
          project,
          root,
          selectedCases: ['first', 'second'],
          resolveSecret: (_) async => null,
        ),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'test.configuration',
          ),
        ),
      );
      expect(received, isEmpty, reason: malformed);
    }
    for (final malformedInput in [
      '    operation: {method: post, path: /exact, occurrence: 7}',
      '    headers: []',
      '    variables: 7',
      '    parameters: []',
      '    body: []',
    ]) {
      final valid = configuration('{status: 200}');
      manifest.writeAsStringSync(
        valid
            .replaceFirst(
              '  - name: second\n',
              '  - name: second\n$malformedInput\n',
            )
            .replaceFirst(
              '    operation: {method: post, path: /exact}\n    expect: {status: 200}',
              malformedInput.contains('operation:')
                  ? '    expect: {status: 200}'
                  : '    operation: {method: post, path: /exact}\n    expect: {status: 200}',
            ),
      );
      await expectLater(
        const ContractTestRunner().run(
          project,
          root,
          selectedCases: ['first', 'second'],
          resolveSecret: (_) async => null,
        ),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'test.configuration',
          ),
        ),
      );
      expect(received, isEmpty, reason: malformedInput);
    }
    manifest.writeAsStringSync(configuration('{status: "200"}'));
    final invalidCli = await Process.run('$testBundle/busyapi', [
      'test',
      temp.path,
      '--case',
      'first',
      '--case',
      'second',
      '--json',
      '--junit',
      '${temp.path}/invalid.xml',
    ]);
    expect(
      invalidCli.exitCode,
      3,
      reason: '${invalidCli.stdout} ${invalidCli.stderr}',
    );
    expect(
      '${invalidCli.stdout} ${invalidCli.stderr}',
      contains('test.configuration'),
    );
    final failureReport = jsonDecode(invalidCli.stdout as String) as Map;
    expect(failureReport['status'], 'operational-failure');
    expect(failureReport['complete'], false);
    expect(
      File('${temp.path}/invalid.xml').readAsStringSync(),
      contains('<error'),
      reason: 'An invalid selected run must publish an incomplete failure, never a passing JUnit report.',
    );
    expect(received, isEmpty);
    manifest.writeAsStringSync(
      configuration('{status: 200}').replaceFirst(
        '    expect: {status: 200}',
        '    body: {mediaType: application/json, value: ${List.filled(4097, '1').join()}}\n    expect: {status: 200}',
      ),
    );
    await expectLater(
      const ContractTestRunner().run(
        project,
        root,
        selectedCases: ['first', 'second'],
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'limit.schema.numeric',
        ),
      ),
    );
    expect(received, isEmpty);
    manifest.writeAsStringSync(
      configuration('{status: 200}')
          .replaceFirst(
            'tests:',
            "x-too-large: &tooLarge ${'1' * 4097}\nx-query: &query {n: *tooLarge}\ntests:",
          )
          .replaceFirst(
            '    expect: {status: 200}',
            '    parameters: {query: *query}\n    expect: {status: 200}',
          ),
    );
    await expectLater(
      const ContractTestRunner().run(
        project,
        root,
        selectedCases: ['first', 'second'],
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'limit.schema.numeric',
        ),
      ),
    );
    expect(
      received,
      isEmpty,
      reason: 'F04A aliased bounds must fail the whole selection before the first request.',
    );
  });
  test('H05 sequential constraints stay incomplete in core history saved cases CLI JSON and JUnit', () async {
    var body = '{"id":1}\n';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.set('content-type', 'application/jsonl');
      request.response.headers.set('x-sequence', '{}');
      request.response.write(body);
      await request.response.close();
    });
    final contract = File('${temp.path}/openapi.yaml')
      ..writeAsStringSync('''
openapi: 3.2.1
info: {title: Sequences, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths:
  /items:
    post:
      parameters: [{name: stream, in: query, content: {application/jsonl: {schema: {type: array}, itemSchema: {type: object, required: [id]}}}}]
      requestBody: {content: {application/jsonl: {itemSchema: {type: object, required: [id], properties: {id: {type: integer}}}}}}
      responses: {'200': {description: ok, headers: {X-Sequence: {content: {application/jsonl: {itemSchema: {type: object, required: [id]}}}}}, content: {application/jsonl: {itemSchema: {type: object, required: [id], properties: {id: {type: integer}}}}}}}
''');
    File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
tests: [{name: finite, operation: {method: post, path: /items}, body: {mediaType: application/jsonl, value: '{"id":1}'}, expect: {status: 200}}]
''');
    project = await BusyProject.open(temp.path, engine);
    root = contract.uri.toString();
    final plan = await prepare();
    addTearDown(plan.close);
    final parameterOnly = await const ContractRequestExecutor().execute(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        parameters: {
          OperationRequestDraft.parameterKey('query', 'stream'):
              const RequestValue.text('{}\n'),
        },
      ),
      resolveSecret: (_) async => null,
    );
    expect(parameterOnly.outgoing.complete, false);
    expect(
      parameterOnly.received.findings.any(
        (f) => f['code'] == 'runtime.response.header.items.unchecked',
      ),
      true,
    );
    expect(
      parameterOnly.outgoing.valid,
      true,
      reason: 'An unsupported sequential codec must not fabricate a typed schema mismatch.',
    );
    expect(
      parameterOnly.outgoing.findings.any(
        (f) => f['code'] == 'runtime.request.parameter.items.unchecked',
      ),
      true,
    );
    await parameterOnly.close();
    for (final specimen in [
      '{"id":1}\n',
      '{"id":"wrong"}\n',
      '{}\n',
      '{broken}\n',
    ]) {
      body = specimen;
      final result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: const RequestBodyDraft.raw(
            mediaType: 'application/jsonl',
            text: '{"id":1}',
          ),
        ),
        resolveSecret: (_) async => null,
      );
      expect(result.outgoing.complete, isFalse);
      expect(result.received.complete, isFalse);
      expect(result.conforming, isFalse);
      expect(
        ContractRequestRecord.fromResult(
          result,
          recordedAt: DateTime.now(),
        ).conformanceComplete,
        isFalse,
      );
      await result.close();
    }
    final report = await const ContractTestRunner().run(
      project,
      root,
      selectedCases: ['finite'],
      resolveSecret: (_) async => null,
    );
    expect(report.passed, isFalse);
    expect(report.cases.single.status, 'incomplete');
    expect(CiReports.junit(report), contains('<error'));
    final cli = await Process.run('$testBundle/busyapi', [
      'test',
      temp.path,
      '--case',
      'finite',
      '--json',
      '--junit',
      '${temp.path}/sequence.xml',
    ]);
    expect(cli.exitCode, 2, reason: '${cli.stdout} ${cli.stderr}');
    expect((jsonDecode(cli.stdout as String) as Map)['passed'], isFalse);
    expect(
      File('${temp.path}/sequence.xml').readAsStringSync(),
      contains('<error'),
    );
  });
}
