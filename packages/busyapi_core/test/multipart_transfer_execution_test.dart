import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _large = '900719925474099312345678901234567890';
const _media = 'multipart/form-data';

Future<(BusyProject, OperationRequestPlan, File)> _fixture(
  Directory temp,
  EngineProcess engine,
  String version,
  String format,
  int port, {
  String codec = 'base64',
  String? encodedEnum,
  bool nested = false,
  String? encodedContentType,
}) async {
  final encoded = version.startsWith('3.0.')
      ? {'type': 'string', 'format': 'byte'}
      : {
          'type': ['string', 'null'],
          'contentEncoding': codec,
        };
  final properties = {
    'encoded': {
      ...encoded,
      if (encodedEnum != null) 'enum': [encodedEnum],
    },
    'blank': encoded,
    'values': {'type': 'array', 'items': encoded},
    'nullable': version.startsWith('3.0.')
        ? {...encoded, 'nullable': true}
        : encoded,
    'data': {
      'type': 'object',
      'properties': {
        'v': {'type': 'integer'},
      },
    },
    'text': {'type': 'string'},
    'long': encoded,
    'file': encoded,
  };
  final shared =
      '# A referenced native form; execution must not rewrite it.\nForm:\n  type: object\n  properties:\n${properties.entries.map((entry) => '    ${entry.key}: ${jsonEncode(entry.value)}\n').join()}Transfer:\n  \$ref: "#/ActualTransfer"\nActualTransfer:\n  schema: {type: string, enum: [$codec]}\n';
  await File('${temp.path}/shared.yaml').writeAsString(shared);
  final encoding = {
    'encoded': {
      'headers': {
        'Content-Transfer-Encoding': {r'$ref': 'shared.yaml#/Transfer'},
      },
    },
    'data': {
      'contentType': 'application/json',
      'headers': {
        'Content-Transfer-Encoding': {r'$ref': 'shared.yaml#/Transfer'},
      },
    },
    'text': {
      'headers': {
        'Content-Transfer-Encoding': {r'$ref': 'shared.yaml#/Transfer'},
      },
    },
  };
  if (nested)
    encoding['data'] = {
      'contentType': 'multipart/mixed',
      'encoding': {
        'v': {'contentType': 'text/plain'},
      },
    };
  if (encodedContentType != null) {
    encoding['encoded'] = {
      ...encoding['encoded']!,
      'contentType': encodedContentType,
    };
    encoding['file'] = {'contentType': encodedContentType};
  }
  final declaration = {
    'schema': {r'$ref': 'shared.yaml#/Form'},
    'encoding': encoding,
  };
  final root = File('${temp.path}/api.$format');
  final source = format == 'json'
      ? jsonEncode({
          'openapi': version,
          'info': {'title': 'Transfer', 'version': 'api-version'},
          'servers': [
            {'url': 'http://127.0.0.1:$port/api'},
          ],
          'paths': {
            '/upload': {
              'post': {
                'requestBody': {
                  'content': {_media: declaration},
                },
                'responses': {
                  '204': {'description': 'ok'},
                },
              },
            },
          },
        })
      : '''# Native transfer fixture with comments
openapi: $version
info: {title: Transfer, version: api-version}
servers: [{url: 'http://127.0.0.1:$port/api'}]
paths:
  /upload:
    post:
      requestBody:
        content:
          multipart/form-data:
            schema: {\$ref: 'shared.yaml#/Form'}
            encoding: ${jsonEncode(encoding)}
      responses: {'204': {description: ok}}
''';
  await root.writeAsString(source);
  final project = await BusyProject.open(root.path, engine);
  final analysis = await project.check(root.uri.toString());
  expect(analysis['complete'], isTrue, reason: '$analysis');
  final operation =
      (analysis['projection']['operations'] as List).single as Map;
  final plan = await project.prepareRequest(
    root.uri.toString(),
    resource: operation['resource'] as String,
    pointer: operation['pointer'] as String,
    occurrence: operation['occurrence'] as String,
  );
  return (project, plan, root);
}

String _fold64(String value) => [
  for (var index = 0; index < value.length; index += 76)
    value.substring(
      index,
      index + 76 > value.length ? value.length : index + 76,
    ),
].join('\r\n');

void main() {
  test('established multipart limitation codes retain typed incompleteness and source locations in core and CLI', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-mime-unsupported-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      await request.response.close();
    });
    final (project, plan, root) = await _fixture(
      temp,
      engine,
      '3.2.1',
      'json',
      server.port,
      nested: true,
    );
    addTearDown(project.close);
    addTearDown(plan.close);
    final source = await root.readAsString();
    final direct = const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        body: const RequestBodyDraft.multipartValue(json: '{"data":{"v":0}}'),
      ),
      resolveSecret: (_) async => null,
    );
    await expectLater(
      direct,
      throwsA(
        isA<CoreFailure>()
            .having(
              (failure) => failure.code,
              'code',
              'request.multipart.encoding',
            )
            .having(
              (failure) => failure.kind,
              'kind',
              CoreFailureKind.unsupported,
            )
            .having(
              (failure) => failure.source?.resource,
              'source',
              root.uri.toString(),
            ),
      ),
    );
    final manifest = File('${temp.path}/busyapi.yaml');
    final config = jsonEncode({
      'version': 1,
      'roots': [
        {'name': 'api', 'path': 'api.json'},
      ],
      'tests': [
        {
          'name': 'nested',
          'operation': {'method': 'post', 'path': '/upload'},
          'body': {
            'mediaType': _media,
            'value': {
              'data': {'v': 0},
            },
          },
        },
      ],
    });
    await manifest.writeAsString(config);
    final configured = await BusyProject.open(temp.path, engine);
    addTearDown(configured.close);
    final report = await const ContractTestRunner().run(
      configured,
      root.uri.toString(),
      selectedCases: ['nested'],
      resolveSecret: (_) async => null,
    );
    expect(report.complete, isFalse);
    expect(report.cases.single.status, 'incomplete');
    expect(report.cases.single.operationalFailure, isFalse);
    expect(report.cases.single.dispatched, isFalse);
    expect(report.executedOperations, isEmpty);
    final finding = report.cases.single.findings.single;
    expect(finding['code'], 'request.multipart.encoding');
    expect(finding['resource'], root.uri.toString());
    expect(finding['pointer'], endsWith('/encoding/data'));
    final range = (finding['range'] as List).cast<int>();
    expect(source.substring(range[0], range[1]), contains('multipart/mixed'));
    final cli = await Process.run(
      '$testBundle/busyapi',
      ['test', temp.path, '--case', 'nested', '--json'],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(cli.exitCode, 2, reason: '${cli.stdout}\n${cli.stderr}');
    final json = jsonDecode(cli.stdout as String) as Map;
    expect(json['status'], 'incomplete');
    expect(json['cases'][0]['operationalFailure'], isFalse);
    expect(json['cases'][0]['dispatched'], isFalse);
    expect(json['cases'][0]['findings'][0]['resource'], root.uri.toString());
    expect(requests, 0);
    expect(await root.readAsString(), source);
    expect(await manifest.readAsString(), config);
  });

  test('captured multipart file encoding cancels and rejects stale input before HTTP, releasing private captures', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-mime-file-owner-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      await request.response.close();
    });
    final (project, plan, root) = await _fixture(
      temp,
      engine,
      '3.0.4',
      'yaml',
      server.port,
    );
    addTearDown(project.close);
    addTearDown(plan.close);
    final original = await root.readAsBytes();
    final buffer = await project.buffer(root.uri.toString());
    final file = File('${temp.path}/raw.bin');
    final fileBytes = List.filled(2 * 1024 * 1024, 255);
    await file.writeAsBytes(fileBytes);
    for (final stale in [false, true]) {
      final cancellation = RunCancellation(), seen = Completer<String>();
      final watch = Directory.systemTemp
          .watch(events: FileSystemEvent.create)
          .listen((event) {
            if (event.isDirectory &&
                event.path.split('/').last.startsWith('busyapi-multipart-') &&
                !seen.isCompleted) {
              seen.complete(event.path);
              if (stale) {
                project.store.replace(
                  buffer.id,
                  buffer.text.replaceFirst('title: Transfer', 'title: Changed'),
                );
              } else
                cancellation.cancel();
            }
          });
      try {
        await expectLater(
          const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.multipart([], [
                MultipartFileValue(name: 'file', path: file.path),
              ]),
            ),
            resolveSecret: (_) async => null,
            cancellation: cancellation,
          ),
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'code',
              stale ? 'request.draft.stale' : 'cancelled',
            ),
          ),
        );
        final directory = await seen.future.timeout(const Duration(seconds: 5));
        // Executor cancellation may return while its late preparation is being
        // released. Await the observed private resource's bounded retirement.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (await Directory(directory).exists() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(await Directory(directory).exists(), isFalse);
        expect(requests, 0);
        expect(await root.readAsBytes(), original);
        expect(await file.readAsBytes(), fileBytes);
      } finally {
        await watch.cancel();
      }
    }
  });

  test('multipart codecs keep bit groups and MIME line framing across captured file read boundaries', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-mime-chunks-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String>[];
    server.listen((request) async {
      seen.add(await utf8.decoder.bind(request).join());
      request.response.statusCode = 204;
      await request.response.close();
    });
    for (final codec in ['base32', 'quoted-printable', '7bit']) {
      final fixture = Directory('${temp.path}/$codec');
      await fixture.create();
      final (project, plan, _) = await _fixture(
        fixture,
        engine,
        '3.2.1',
        'yaml',
        server.port,
        codec: codec,
      );
      try {
        final file = File('${fixture.path}/raw.bin');
        final raw = codec == 'base32'
            ? utf8.encode('fooba' * 14000)
            : codec == 'quoted-printable'
            ? List.filled(70000, 255)
            : [
                ...utf8.encode(('a' * 998 + '\r\n') * 65),
                ...utf8.encode('a' * 535 + '\r\ntail'),
              ];
        await file.writeAsBytes(raw);
        final request = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipart([], [
              MultipartFileValue(name: 'file', path: file.path),
            ]),
          ),
          resolveSecret: (_) async => null,
        );
        try {
          final response = await const ContractHttpTransport().send(request);
          await response.close();
          final body = seen.last,
              start = body.indexOf('\r\n\r\n') + 4,
              content = body.substring(start, body.lastIndexOf('\r\n--'));
          if (codec == 'base32')
            expect(content, 'MZXW6YTB' * 14000);
          else if (codec == 'quoted-printable') {
            expect(
              content.split('\r\n').every((line) => line.length <= 76),
              isTrue,
            );
            expect(content.replaceAll('=\r\n', ''), '=FF' * 70000);
          } else
            expect(content, utf8.decode(raw));
          expect(utf8.encode(body).length, request.body!.length);
        } finally {
          await request.body!.close();
        }
      } finally {
        plan.close();
        project.close();
      }
    }
  });

  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format native multipart applies implicit and referenced encodings to actual bytes and exact schema instances',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-mime-wire-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final seen = <(String, String, String, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('content-type')!,
              await request.fold<List<int>>([], (a, b) => a..addAll(b)),
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          final (project, plan, root) = await _fixture(
            temp,
            engine,
            version,
            format,
            server.port,
          );
          addTearDown(project.close);
          addTearDown(plan.close);
          final before = await root.readAsBytes(),
              sharedBefore = await File('${temp.path}/shared.yaml')
                  .readAsBytes();
          final raw = List.generate(220, (index) => index % 256),
              encoded = base64.encode(raw);
          final data =
              '{"encoded":"Zg==","blank":"","values":["Zm9v","YmFy"],"nullable":null,"data":{"v":$_large},"text":"雪+&","long":"$encoded"}';
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.multipartValue(json: data),
            ),
            resolveSecret: (_) async => null,
          );
          expect(
            result.outgoing.complete,
            isTrue,
            reason: '${result.outgoing.toJson()}',
          );
          expect(
            result.outgoing.valid,
            isTrue,
            reason: '${result.outgoing.toJson()}',
          );
          expect(result.response.status, 204);
          final request = seen.single,
              boundary = ContentType.parse(request.$3).parameters['boundary']!;
          String part(
            String name,
            String content, {
            String type = 'application/octet-stream',
            bool transfer = true,
          }) =>
              '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\nContent-Type: $type\r\n${transfer ? 'Content-Transfer-Encoding: base64\r\n' : ''}\r\n$content\r\n';
          final expected =
              part('encoded', 'Zg==') +
              part('blank', '') +
              part('values', 'Zm9v') +
              part('values', 'YmFy') +
              part('nullable', 'null', transfer: false) +
              part(
                'data',
                base64.encode(utf8.encode('{"v":$_large}')),
                type: 'application/json',
              ) +
              part(
                'text',
                base64.encode(utf8.encode('雪+&')),
                type: 'text/plain',
              ) +
              part('long', _fold64(encoded)) +
              '--$boundary--\r\n';
          expect(request.$1, 'POST');
          expect(request.$2, '/api/upload');
          expect(request.$4, utf8.encode(expected));
          expect(result.request.body!.formInstance, contains('"v":$_large'));
          await result.close();
          final manifest = File('${temp.path}/busyapi.yaml');
          final configuration =
              '{"version":1,"roots":[{"name":"api","path":"api.$format"}],"tests":[{"name":"transfer","operation":{"method":"post","path":"/upload"},"body":{"mediaType":"$_media","value":$data},"expect":{"status":204}}]}';
          await manifest.writeAsString(configuration);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'transfer', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], isTrue);
          final cliBoundary = ContentType.parse(seen.last.$3)
              .parameters['boundary']!;
          expect(
            utf8.decode(seen.last.$4).replaceAll(cliBoundary, boundary),
            expected,
          );
          expect(await manifest.readAsString(), configuration);

          final upload = File('${temp.path}/upload.bin');
          // Cross both the base64 grouping and filesystem read boundaries.
          final fileBytes = List.generate(65539, (index) => index % 256);
          await upload.writeAsBytes(fileBytes);
          final prepared = await const ContractRequestBuilder().build(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.multipartValue(
                json: '{"data":{"v":$_large}}',
                files: [MultipartFileValue(name: 'file', path: upload.path)],
              ),
            ),
            resolveSecret: (_) async => null,
          );
          expect(
            prepared.body!.formInstance,
            contains(base64.encode(fileBytes)),
          );
          expect(prepared.body!.formInstance, contains('"v":$_large'));
          await upload.writeAsBytes([99, 98, 97]);
          final outgoing = await const ContractRequestExecutor()
              .validateOutgoing(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.multipartValue(
                    json: '{"data":{"v":$_large}}',
                    files: [
                      MultipartFileValue(name: 'file', path: upload.path),
                    ],
                  ),
                ),
                prepared.runId,
                preparedBody: prepared.body,
              );
          expect(outgoing.complete, isTrue, reason: '${outgoing.toJson()}');
          expect(outgoing.valid, isTrue);
          final response = await const ContractHttpTransport().send(prepared);
          await response.close();
          final fileRequest = utf8.decode(seen.last.$4);
          expect(
            fileRequest,
            contains(
              'filename="upload.bin"\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n${_fold64(base64.encode(fileBytes))}\r\n',
            ),
          );
          expect(seen.last.$4.length, prepared.body!.length);
          await prepared.body!.close();
          expect(await root.readAsBytes(), before);
          expect(
            await File('${temp.path}/shared.yaml').readAsBytes(),
            sharedBefore,
          );
        },
      );
    }

  for (final (codec, input, wire, raw) in [
    ('base64', 'Zg== ', 'Zg==', utf8.encode('f')),
    ('base64url', '-_8=', '-_8=', [251, 255]),
    ('base16', '00ff', '00FF', [0, 255]),
    ('base32', 'MZXW6===', 'MZXW6===', utf8.encode('foo')),
    ('base32', 'mzxw6===', 'MZXW6===', utf8.encode('foo')),
    ('base32hex', 'CPNMU===', 'CPNMU===', utf8.encode('foo')),
    ('base32hex', 'cpnmu===', 'CPNMU===', utf8.encode('foo')),
    ('quoted-printable', '=00=FF=0D=0A', '=00=FF=0D=0A', [0, 255, 13, 10]),
    ('quoted-printable', 'a=3D', '=61=3D', utf8.encode('a=')),
    ('7bit', 'ascii\r\ntext', 'ascii\r\ntext', utf8.encode('ascii\r\ntext')),
    ('8bit', '雪', '雪', utf8.encode('雪')),
    ('identity', '雪', '雪', utf8.encode('雪')),
    ('binary', '雪', '雪', utf8.encode('雪')),
  ])
    test(
      'native multipart $codec (${input.length}:${input.codeUnitAt(0)}) encoded data and raw files have matching decoded bytes',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-mime-codec-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final seen = <List<int>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          expect(request.method, 'POST');
          expect(request.uri.path, '/api/upload');
          seen.add(await request.fold<List<int>>([], (a, b) => a..addAll(b)));
          request.response.statusCode = 204;
          await request.response.close();
        });
        final (project, plan, _) = await _fixture(
          temp,
          engine,
          '3.2.1',
          'yaml',
          server.port,
          codec: codec,
          encodedEnum: input,
        );
        addTearDown(project.close);
        addTearDown(plan.close);
        final prepared = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipartValue(
              json: jsonEncode({'encoded': input}),
            ),
          ),
          resolveSecret: (_) async => null,
        );
        addTearDown(() => prepared.body!.close());
        final bytes = await prepared.body!.open().fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        expect(
          utf8.decode(bytes),
          contains('Content-Transfer-Encoding: $codec\r\n\r\n$input\r\n'),
        );
        expect(bytes.length, prepared.body!.length);
        final checked = await const ContractRequestExecutor().validateOutgoing(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipartValue(
              json: jsonEncode({'encoded': input}),
            ),
          ),
          prepared.runId,
          preparedBody: prepared.body,
        );
        expect(checked.complete, isTrue, reason: '${checked.toJson()}');
        expect(checked.valid, isTrue);
        final response = await const ContractHttpTransport().send(prepared);
        await response.close();
        expect(seen.single, bytes);
        final file = File('${temp.path}/raw.bin');
        await file.writeAsBytes(raw);
        final fileRequest = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipart([], [
              MultipartFileValue(name: 'file', path: file.path),
            ]),
          ),
          resolveSecret: (_) async => null,
        );
        addTearDown(() => fileRequest.body!.close());
        final fileResponse = await const ContractHttpTransport().send(
          fileRequest,
        );
        await fileResponse.close();
        expect(
          utf8.decode(seen.last),
          contains('Content-Transfer-Encoding: $codec\r\n\r\n$wire\r\n'),
        );
      },
    );

  test('quoted-printable distinguishes text CRLF from binary octets and rejects illegal encoder spellings', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-mime-text-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final seen = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      seen.add(await utf8.decoder.bind(request).join());
      request.response.statusCode = 204;
      await request.response.close();
    });
    const data = 'a=3D\r\nb';
    final (project, plan, root) = await _fixture(
      temp,
      engine,
      '3.2.1',
      'json',
      server.port,
      codec: 'quoted-printable',
      encodedContentType: 'text/plain',
      encodedEnum: data,
    );
    addTearDown(project.close);
    addTearDown(plan.close);
    final source = await root.readAsString();
    final result = await const ContractRequestExecutor().execute(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        body: RequestBodyDraft.multipartValue(
          json: jsonEncode({'encoded': data, 'text': 'a\r\nb'}),
        ),
      ),
      resolveSecret: (_) async => null,
    );
    expect(result.outgoing.complete, isTrue);
    expect(result.outgoing.valid, isTrue);
    expect(
      seen.single,
      contains('Content-Transfer-Encoding: quoted-printable\r\n\r\n$data\r\n'),
    );
    expect(
      seen.single,
      contains(
        'Content-Transfer-Encoding: quoted-printable\r\n\r\n=61\r\n=62\r\n',
      ),
    );
    await result.close();
    final file = File('${temp.path}/text.txt');
    await file.writeAsString('a\r\nb');
    final prepared = await const ContractRequestBuilder().build(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        body: RequestBodyDraft.multipart([], [
          MultipartFileValue(name: 'file', path: file.path),
        ]),
      ),
      resolveSecret: (_) async => null,
    );
    try {
      final response = await const ContractHttpTransport().send(prepared);
      await response.close();
      expect(
        seen.last,
        contains(
          'Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=61\r\n=62\r\n',
        ),
      );
    } finally {
      await prepared.body!.close();
    }
    final count = seen.length;
    for (final value in ['=3d', '=+A', '=A', '=', 'a\nb']) {
      await expectLater(
        const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipartValue(
              json: jsonEncode({'encoded': value}),
            ),
          ),
          resolveSecret: (_) async => null,
        ),
        throwsA(
          isA<CoreFailure>()
              .having(
                (failure) => failure.code,
                'code',
                'request.multipart.encoded-input',
              )
              .having(
                (failure) => failure.source?.resource,
                'source',
                root.uri.toString(),
              )
              .having(
                (failure) => failure.message,
                'message',
                contains('Part encoded'),
              ),
        ),
      );
    }
    await expectLater(
      const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: const RequestBodyDraft.multipartValue(json: '{"text":"a\\nb"}'),
        ),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'request.multipart.encoded-input',
        ),
      ),
    );
    expect(seen.length, count);
    expect(await root.readAsString(), source);
  });

  test('malformed encoded values, transfer conflicts, limits, cancellation and stale captures do not dispatch', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-mime-refusal-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final (project, plan, root) = await _fixture(
      temp,
      engine,
      '3.0.4',
      'yaml',
      1,
    );
    addTearDown(project.close);
    addTearDown(plan.close);
    final before = await root.readAsBytes();
    for (final text in ['not base64', 'Zg', 'Zg%3D%3D', 'Zh==', 'Zm9=', '雪']) {
      await expectLater(
        const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.multipartValue(
              json: jsonEncode({'encoded': text}),
            ),
          ),
          resolveSecret: (_) async => null,
        ),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'request.multipart.encoded-input',
          ),
        ),
      );
    }
    final file = File('${temp.path}/large.bin');
    await file.writeAsBytes(List.filled(4096, 255));
    await expectLater(
      const ContractRequestBuilder(maximumUploadBytes: 4200).build(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: RequestBodyDraft.multipart([], [
            MultipartFileValue(name: 'file', path: file.path),
          ]),
        ),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'limit.request.body',
        ),
      ),
    );
    final cancellation = RunCancellation()..cancel();
    await expectLater(
      const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: const RequestBodyDraft.multipartValue(
            json: '{"encoded":"Zg=="}',
          ),
        ),
        resolveSecret: (_) async => null,
        cancellation: cancellation,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'cancelled',
        ),
      ),
    );
    final buffer = await project.buffer(root.uri.toString());
    project.store.replace(
      buffer.id,
      buffer.text.replaceFirst('3.0.4', '3.1.2'),
    );
    await expectLater(
      const ContractRequestBuilder().build(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          body: const RequestBodyDraft.multipartValue(
            json: '{"encoded":"Zg=="}',
          ),
        ),
        resolveSecret: (_) async => null,
      ),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'request.draft.stale',
        ),
      ),
    );
    expect(await root.readAsBytes(), before);
  });
}
