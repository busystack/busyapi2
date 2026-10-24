import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';
import 'redirect_redaction_child.dart' as long_redirect;

void main() {
  late Directory temp;
  late EngineProcess engine;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'busyapi-transport-integrity-',
    );
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    await engine.close();
    await temp.delete(recursive: true);
  });
  Future<OperationRequestPlan> planFor(
    BusyProject project,
    String method,
    String path,
  ) async {
    final root = project.roots.single.id;
    final checked = await project.check(root, schemaEvaluation: false);
    final op =
        ((checked['projection'] as Map? ?? checked)['operations'] as List)
            .whereType<Map>()
            .singleWhere((o) => o['path'] == path && o['method'] == method);
    return project.prepareRequest(
      root,
      resource: op['resource'] as String,
      pointer: op['pointer'] as String,
      occurrence: op['occurrence'] as String,
    );
  }

  test(
    'R10 gzip URL import preserves root and dependency BOM CRLF bytes',
    () async {
      final root = utf8.encode(
        '\uFEFFopenapi: 3.2.1\r\ninfo: {title: 雪, version: "1"}\r\npaths: {}\r\ncomponents: {schemas: {A: {\$ref: "./model.yaml"}}}\r\n',
      );
      final dependency = utf8.encode(
        '\uFEFFtype: integer\r\nconst: 9007199254740993\r\n',
      );
      final headers = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        headers.add(r.headers.value('accept-encoding') ?? '');
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add([
          ...gzip.encode([]),
          ...gzip.encode(r.uri.path == '/api.yaml' ? root : dependency),
        ]);
        await r.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final plan = await ProjectImporter(engine).prepare(
        kind: ProjectImportKind.url,
        source: '$base/api.yaml',
        destination: '${temp.path}/import',
        approvedUrls: {'$base/model.yaml'},
      );
      addTearDown(plan.close);
      expect(plan.complete, true);
      await plan.publish();
      expect(
        await File('${plan.destination}/openapi.yaml').readAsBytes(),
        root,
      );
      expect(
        await Directory('${plan.destination}/resources')
            .listSync()
            .whereType<File>()
            .single
            .readAsBytes(),
        dependency,
      );
      expect(headers, hasLength(2));
      final available = await ProjectImporter(engine).prepare(
        kind: ProjectImportKind.url,
        source: '$base/api.yaml',
        destination: '${temp.path}/available',
      );
      addTearDown(available.close);
      expect(available.complete, false);
      await available.publish();
      expect(
        await File('${available.destination}/openapi.yaml').readAsBytes(),
        root,
      );
    },
  );
  test('R10 gzip acquisition rejects corrupt truncated and decoded overflow with bounded controls', () async {
    var mode = 'plain';
    final bytes = utf8.encode(
      'openapi: 3.1.2\r\ninfo: {title: Test, version: "1"}\r\npaths: {}\r\n',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      if (mode != 'plain')
        r.response.headers.set(
          'content-encoding',
          mode == 'unsupported'
              ? 'br'
              : mode == 'nested'
              ? 'gzip, gzip'
              : 'gzip',
        );
      final encoded = gzip.encode(bytes);
      r.response.add(switch (mode) {
        'plain' => bytes,
        'corrupt' => [1, 2, 3],
        'truncated' => encoded.sublist(0, encoded.length ~/ 2),
        'missing-trailer' => encoded.sublist(0, encoded.length - 8),
        'crc' => [
          ...encoded.sublist(0, encoded.length - 8),
          encoded[encoded.length - 8] ^ 1,
          ...encoded.sublist(encoded.length - 7),
        ],
        'encoded-overflow' => [...encoded, ...List.filled(2000, 0)],
        'nested' => gzip.encode(encoded),
        'concatenated' => [
          ...gzip.encode(bytes.sublist(0, 20)),
          ...gzip.encode(bytes.sublist(20)),
        ],
        'overflow' => gzip.encode(List.filled(20000, 97)),
        _ => encoded,
      });
      await r.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/api.yaml');
    for (final selected in [
      'plain',
      'gzip',
      'nested',
      'concatenated',
      'corrupt',
      'truncated',
      'missing-trailer',
      'crc',
      'encoded-overflow',
      'overflow',
      'unsupported',
    ]) {
      mode = selected;
      final call = const ContractHttpTransport().acquireResource(
        uri,
        approved: (_) => true,
        maximumBytes: 1024,
      );
      if (['plain', 'gzip', 'nested', 'concatenated'].contains(selected)) {
        expect((await call).$2, bytes);
      } else {
        await expectLater(call, throwsA(isA<CoreFailure>()));
      }
    }
  });
  test(
    'R11 HEAD redirects retain wire method and consistent conformance',
    () async {
      final methods = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        methods.add(r.method);
        if (r.uri.path != '/target') {
          r.response.statusCode = r.uri.path == '/chain'
              ? 303
              : int.parse(r.uri.path.substring(1));
          r.response.headers.set(
            'location',
            r.uri.path == '/chain' ? '/307' : '/target',
          );
        } else {
          r.response.headers.set('content-type', 'application/json');
          r.response.write('{}');
        }
        await r.response.close();
      });
      await File('${temp.path}/openapi.json').writeAsString(
        jsonEncode({
          'openapi': '3.2.1',
          'info': {'title': 'Redirect', 'version': '1'},
          'servers': [
            {'url': 'http://127.0.0.1:${server.port}'},
          ],
          'paths': {
            for (final code in [301, 302, 303, 307, 308, 'chain'])
              '/$code': {
                for (final method in ['head', 'get'])
                  method: {
                    'responses': {
                      '200': {
                        'description': 'ok',
                        'content': {'application/json': {}},
                      },
                    },
                  },
              },
          },
        }),
      );
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      for (final code in [303, 301, 302, 307, 308, 'chain'])
        for (final method in ['head', 'get']) {
          final plan = await planFor(project, method, '/$code');
          addTearDown(plan.close);
          final input = await const ContractRequestBuilder().build(
            plan,
            OperationRequestDraft(planIdentity: plan.identity),
            resolveSecret: (_) async => null,
          );
          final response = await const ContractHttpTransport().send(input);
          addTearDown(response.close);
          expect(methods.sublist(methods.length - 2), [
            method.toUpperCase(),
            method.toUpperCase(),
          ]);
          final checked = await const ContractRequestExecutor()
              .validateResponse(plan, response, input.runId);
          expect(
            checked.findings.where(
              (f) => f['code'] == 'runtime.response.body.forbidden',
            ),
            isEmpty,
          );
          expect(response.receivedLength, method == 'head' ? 0 : 2);
        }
    },
  );
  test('R14 authored and environment base query API-key collisions precede any HTTP request', () async {
    var received = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      received++;
      await r.response.close();
    });
    for (final environmentBase in [false, true])
      for (final name in ['api_key', '%61pi%5Fkey']) {
        final base =
            'http://127.0.0.1:${server.port}/base?$name=old&tag=one%2ftwo&tag=three+four';
        await File('${temp.path}/openapi.yaml').writeAsString('''openapi: 3.2.1
info: {title: Query, version: "1"}
servers: [{url: '${environmentBase ? 'http://example.invalid' : base}'}]
security: [{key: []}]
components: {securitySchemes: {key: {type: apiKey, in: query, name: api_key}}}
paths:
  /pets:
    get:
      responses: {'200': {description: ok}}
''');
        await File('${temp.path}/busyapi.yaml').writeAsString('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {${environmentBase ? "baseUrl: '$base', " : ''}authentication: {alternative: 0, schemes: {key: {secretRef: 123e4567-e89b-42d3-a456-426614174000}}}}}
''');
        final project = await BusyProject.open(temp.path, engine);
        try {
          final plan = await planFor(project, 'get', '/pets');
          addTearDown(plan.close);
          final draft = OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'local',
            securityAlternative: 0,
          );
          for (final preview in [true, false]) {
            await expectLater(
              const ContractRequestBuilder().build(
                plan,
                draft,
                resolveSecret: (_) async => 'new',
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
            if (!preview)
              await expectLater(
                const ContractRequestExecutor().execute(
                  plan,
                  draft,
                  resolveSecret: (_) async => 'new',
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (e) => e.code,
                    'code',
                    'request.security.collision',
                  ),
                ),
              );
            expect(draft.securityAlternative, 0);
            expect(draft.environment, 'local');
          }
        } finally {
          project.close();
        }
      }
    expect(received, 0);
  });

  test('R14-B API-key checks preserve unrelated opaque base-query values', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      r.response.statusCode = 303;
      r.response.headers.set(
        'location',
        'http://other.invalid/new?reflected=new',
      );
      await r.response.close();
    });
    for (final location in ['header', 'query'])
      for (final opaque in ['%E9', '%C3%A9']) {
        final base =
            'http://127.0.0.1:${server.port}/base?opaque=$opaque&tag=one%2Ftwo';
        await File('${temp.path}/openapi.yaml').writeAsString('''openapi: 3.2.1
info: {title: Query, version: "1"}
servers: [{url: '$base'}]
security: [{key: []}]
components: {securitySchemes: {key: {type: apiKey, in: $location, name: api_key}}}
paths: {"/pets": {get: {responses: {'200': {description: ok}}}}}
''');
        await File('${temp.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots: [{name: api, path: openapi.yaml}]\nenvironments: {local: {authentication: {alternative: 0, schemes: {key: {secretRef: 123e4567-e89b-42d3-a456-426614174000}}}}}\n',
        );
        final project = await BusyProject.open(temp.path, engine);
        try {
          final plan = await planFor(project, 'get', '/pets');
          addTearDown(plan.close);
          final draft = OperationRequestDraft(
            planIdentity: plan.identity,
            securityAlternative: 0,
            environment: 'local',
          );
          for (final preview in [true, false]) {
            final request = await const ContractRequestBuilder().build(
              plan,
              draft,
              resolveSecret: (_) async => 'new',
              previewOnly: preview,
            );
            expect(
              request.uri.query,
              startsWith('opaque=$opaque&tag=one%2Ftwo'),
            );
            expect(draft.securityAlternative, 0);
            if (!preview) {
              final response = await const ContractHttpTransport().send(
                request,
              );
              addTearDown(response.close);
              expect(response.status, 303);
              expect(response.redirects.single, isNot(contains('=new')));
            }
          }
        } finally {
          project.close();
        }
      }
  });
  for (final location in ['header', 'query']) {
    test(
      'R14-E $location credentials retain redirects through the accepted size limit in the VM',
      () => long_redirect.verifyLongRedirects(location),
    );
    test(
      'R14-E $location credentials retain redirects through the accepted size limit in AOT',
      () async {
        final result = await Process.run(
          '$testBundle/redirect-redaction-child',
          [location],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          result.stdout,
          contains('R14-E $location long redirect controls passed'),
        );
      },
    );
    test('R14-D redirect summaries redact mixed URI spellings of $location keys', () async {
      var destinationRequests = 0;
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => destination.close(force: true));
      destination.listen((request) async {
        destinationRequests++;
        request.response.statusCode = 204;
        await request.response.close();
      });
      var reflected = '';
      final queries = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        queries.add(request.uri.query);
        request.response.statusCode = 302;
        request.response.headers.set('location', reflected);
        await request.response.close();
      });
      await File('${temp.path}/openapi.yaml').writeAsString('''openapi: 3.2.1
info: {title: Redirect redaction, version: "1"}
servers: [{url: 'http://127.0.0.1:${server.port}/base?opaque=%E9&tag=one%2Ftwo'}]
security: [{key: []}]
components: {securitySchemes: {key: {type: apiKey, in: $location, name: api_key}}}
paths: {"/pets": {get: {responses: {'302': {description: redirect}}}}}
''');
      await File('${temp.path}/busyapi.yaml').writeAsString(
        'version: 1\nroots: [{name: api, path: openapi.yaml}]\nenvironments: {local: {authentication: {alternative: 0, schemes: {key: {secretRef: 123e4567-e89b-42d3-a456-426614174000}}}}}\n',
      );
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      final plan = await planFor(project, 'get', '/pets');
      addTearDown(plan.close);
      const secret = 'BUSYAPI_TEST_ONLY/plus+equals=end';
      const percentSecret = 'PERCENT_TEST_ONLY%2B/path+end';
      final spaceSecret = location == 'query'
          ? 'SPACE_TEST_ONLY é/+'
          : 'SPACE_TEST_ONLY x/+';
      final cases = [
        (secret, secret),
        (secret, Uri.encodeComponent(secret)),
        (secret, 'BUSYAPI_TEST_ONLY/plus%2Bequals%3Dend'),
        (secret, 'BUSYAPI_TEST_ONLY%2fplus%2bequals=end'),
        (secret, 'B%55SYAPI_TEST_ONLY/plus%2Bequals%3Dend'),
        (
          spaceSecret,
          'SPACE_TEST_ONLY+${location == 'query' ? '%c3%a9' : 'x'}/%2B',
        ),
        (spaceSecret, Uri.encodeQueryComponent(spaceSecret)),
        (spaceSecret, Uri.encodeComponent(spaceSecret)),
        (percentSecret, 'PERCENT_TEST_ONLY%252B/path%2Bend'),
      ];
      for (final (selected, spelling) in cases) {
        reflected =
            'http://127.0.0.1:${destination.port}/target?reflected=before${spelling}after&again=$spelling&opaque=%E9&tag=one%2Ftwo';
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'local',
            securityAlternative: 0,
          ),
          resolveSecret: (_) async => selected,
        );
        try {
          expect(result.response.status, 302);
          expect(
            result.response.incompleteReason,
            'cross-origin-redirect-not-followed',
          );
          expect(
            result.response.redirects.single,
            'http://127.0.0.1:${destination.port}/target?reflected=before[REDACTED]after&again=[REDACTED]&opaque=%E9&tag=one%2Ftwo',
            reason: spelling,
          );
          expect(
            result.response.headers,
            contains(('location', reflected)),
            reason: 'The intentionally inspectable original header is retained',
          );
        } finally {
          await result.close();
        }
      }
      expect(destinationRequests, 0);
      expect(queries, hasLength(cases.length));
      expect(
        queries.every((q) => q.startsWith('opaque=%E9&tag=one%2Ftwo')),
        true,
      );
    });
  }
  test('R10 cancellation owns the acquired gzip connection', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    });
    server.listen((request) async {
      entered.complete();
      await release.future;
      try {
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(gzip.encode([1]));
        await request.response.close();
      } on Object {
        /* The cancelled connection is already closed. */
      }
    });
    final cancellation = RunCancellation();
    final pending = const ContractHttpTransport().acquireResource(
      Uri.parse('http://127.0.0.1:${server.port}/root.yaml'),
      approved: (_) => true,
      cancellation: cancellation,
    );
    final stopped = expectLater(
      pending,
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    await entered.future;
    cancellation.cancel();
    await stopped;
    release.complete();
  });

  test('R10-B R10-C received gzip supports block kinds optional headers and empty concatenated members', () async {
    final bytes = List.generate(10000, (i) => (i * i + i ~/ 7) % 251);
    bytes.setRange(1022, 1025, [31, 139, 8]);
    final stored = ZLibEncoder(gzip: true, level: 0).convert(bytes);
    final fixed = ZLibEncoder(
      gzip: true,
      strategy: ZLibOption.strategyFixed,
    ).convert(bytes);
    final dynamic = gzip.encode(bytes);
    expect((stored[10] >> 1) & 3, 0);
    expect((fixed[10] >> 1) & 3, 1);
    expect((dynamic[10] >> 1) & 3, 2);
    final header = [
      31,
      139,
      8,
      31,
      ...dynamic.sublist(4, 10),
      2,
      0,
      99,
      88,
      ...utf8.encode('api.yaml'),
      0,
      ...utf8.encode('comment'),
      0,
    ];
    int crc(List<int> value) {
      var crc = 0xffffffff;
      for (final byte in value) {
        crc ^= byte;
        for (var bit = 0; bit < 8; bit++) {
          crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
        }
      }
      return (crc ^ 0xffffffff) & 0xffffffff;
    }

    final checksum = crc(header);
    final optional = [
      ...header,
      checksum & 255,
      (checksum >> 8) & 255,
      ...dynamic.sublist(10),
    ];
    var selected = stored;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      r.response.headers.set('content-encoding', 'gzip');
      r.response.add(selected);
      await r.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/bytes');
    final empty = gzip.encode([]);
    final pad = (1023 - stored.length - 2) % 1024;
    final aligned = [
      31,
      139,
      8,
      4,
      ...stored.sublist(4, 10),
      pad & 255,
      pad >> 8,
      ...List.filled(pad, 0),
      ...stored.sublist(10),
    ];
    expect(aligned.length % 1024, 1023);
    for (final (vector, expected) in [
      (stored, bytes),
      (fixed, bytes),
      (dynamic, bytes),
      (optional, bytes),
      ([...stored, ...fixed, ...optional], [...bytes, ...bytes, ...bytes]),
      ([...empty, ...dynamic], bytes),
      ([...stored, ...empty, ...optional], [...bytes, ...bytes]),
      (empty, <int>[]),
      ([...aligned, ...empty, ...dynamic], [...bytes, ...bytes]),
    ]) {
      selected = vector;
      expect(
        (await const ContractHttpTransport().acquireResource(
          uri,
          approved: (_) => true,
        )).$2,
        expected,
      );
    }
    for (final cut in {
      0,
      1,
      3,
      9,
      10,
      11,
      12,
      13,
      14,
      20,
      24,
      header.length,
      header.length + 1,
      optional.length - 8,
      optional.length - 1,
    }) {
      selected = optional.sublist(0, cut);
      await expectLater(
        const ContractHttpTransport().acquireResource(
          uri,
          approved: (_) => true,
        ),
        throwsA(isA<CoreFailure>()),
        reason: 'incomplete optional gzip at $cut',
      );
    }
    selected = zlib.encode(bytes);
    await expectLater(
      const ContractHttpTransport().acquireResource(uri, approved: (_) => true),
      throwsA(isA<CoreFailure>()),
    );
  });
  for (final importing in [true, false])
    test(
      'R10-B incomplete gzip extra header cannot complete ${importing ? 'import' : 'response export'}',
      () async {
        final contract = utf8.encode(
          'openapi: 3.2.1\ninfo: {title: Import, version: "1"}\npaths: {}\n',
        );
        final json = utf8.encode('{"ok":true}');
        List<int> encoded() => [
          ...gzip.encode(importing ? contract : json),
          31,
          139,
          8,
          4,
          0,
          0,
          0,
          0,
          0,
          3,
          10,
          0,
        ];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          r.response.headers.set('content-encoding', 'gzip');
          r.response.headers.set(
            'content-type',
            importing ? 'application/yaml' : 'application/json',
          );
          r.response.add(encoded());
          await r.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        if (importing) {
          await expectLater(
            ProjectImporter(engine).prepare(
              kind: ProjectImportKind.url,
              source: '$base/api.yaml',
              destination: '${temp.path}/incomplete',
            ),
            throwsA(isA<CoreFailure>()),
          );
          expect(await Directory('${temp.path}/incomplete').exists(), false);
          return;
        }
        await File('${temp.path}/openapi.yaml').writeAsString(
          'openapi: 3.2.1\ninfo: {title: Response, version: "1"}\nservers: [{url: "$base"}]\npaths: {"/json": {get: {responses: {"200": {description: ok, content: {application/json: {schema: {type: object}}}}}}}}\n',
        );
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final plan = await planFor(project, 'get', '/json');
        addTearDown(plan.close);
        final request = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(planIdentity: plan.identity),
          resolveSecret: (_) async => null,
        );
        final response = await const ContractHttpTransport().send(request);
        addTearDown(response.close);
        expect(await File(response.bodyFile).readAsBytes(), encoded());
        expect(response.decodingComplete, false);
        await expectLater(
          response.export('${temp.path}/bad-decoded', decoded: true),
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'response.decoding',
            ),
          ),
        );
        expect(await File('${temp.path}/bad-decoded').exists(), false);
        await response.export('${temp.path}/original');
        expect(await File('${temp.path}/original').readAsBytes(), encoded());
        await expectLater(response.decodedBytes(), throwsA(isA<CoreFailure>()));
        final checked = await const ContractRequestExecutor().validateResponse(
          plan,
          response,
          request.runId,
        );
        expect(
          checked.findings.where(
            (f) => f['code'] == 'runtime.response.decoding',
          ),
          isNotEmpty,
        );
      },
    );
  test('R10-A truncated response gzip cannot claim complete decoded content', () async {
    const json = '{"n":9007199254740993.00}';
    final encoded = gzip.encode(utf8.encode(json));
    var truncated = true;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.set('content-type', 'application/json');
      request.response.headers.set('content-encoding', 'gzip');
      request.response.add(
        truncated
            ? encoded.sublist(0, encoded.length - 8)
            : [...gzip.encode([]), ...encoded],
      );
      await request.response.close();
    });
    await File('${temp.path}/openapi.yaml').writeAsString(
      'openapi: 3.1.2\ninfo: {title: Receipt, version: "1"}\nservers: [{url: "http://127.0.0.1:${server.port}"}]\npaths: {"/json": {get: {responses: {"200": {description: ok, content: {application/json: {schema: {type: object}}}}}}}}\n',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final plan = await planFor(project, 'get', '/json');
    addTearDown(plan.close);
    final input = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(planIdentity: plan.identity),
      resolveSecret: (_) async => null,
    );
    final bad = await const ContractHttpTransport().send(input);
    addTearDown(bad.close);
    expect(
      await File(bad.bodyFile).readAsBytes(),
      encoded.sublist(0, encoded.length - 8),
    );
    expect(bad.decodingComplete, false);
    await expectLater(bad.decodedBytes(), throwsA(isA<CoreFailure>()));
    final checked = await const ContractRequestExecutor().validateResponse(
      plan,
      bad,
      input.runId,
    );
    expect(
      checked.findings.where((f) => f['code'] == 'runtime.response.decoding'),
      isNotEmpty,
    );
    truncated = false;
    final good = await const ContractHttpTransport().send(input);
    addTearDown(good.close);
    expect(good.decodingComplete, true);
    expect(utf8.decode(await good.decodedBytes()), json);
    await good.export('${temp.path}/good-decoded', decoded: true);
    expect(await File('${temp.path}/good-decoded').readAsString(), json);
  });
}
