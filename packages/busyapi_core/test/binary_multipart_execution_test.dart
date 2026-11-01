import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _exact = '9007199254740993';
Future<
  ({BusyProject project, OperationRequestPlan plan, File root, File shared})
>
_open(
  Directory temp,
  int port,
  String version,
  String format, {
  Map<String, Object?> binary = const {
    'type': 'string',
    'format': 'binary',
    'minLength': 1,
    'maxLength': 4,
  },
  bool transfer = false,
}) async {
  final shared = File('${temp.path}/shared.yaml');
  await shared.writeAsString(
    '# Keep shared binary rules\r\nBinary: ${jsonEncode(binary)}\r\nForm:\r\n  type: object\r\n  required: [exact]\r\n  properties:\r\n    exact: {type: integer, enum: [$_exact]}\r\n    asset: {\$ref: "#/Binary"}\r\n    values: {type: array, items: {\$ref: "#/Binary"}}\r\n',
  );
  final document = {
    'openapi': version,
    'info': {'title': 'Binary parts', 'version': 'api-version'},
    'servers': [
      {'url': 'http://127.0.0.1:$port'},
    ],
    'paths': {
      '/upload': {
        'post': {
          'requestBody': {
            'content': {
              'multipart/form-data': {
                'schema': {r'$ref': 'shared.yaml#/Form'},
                if (transfer)
                  'encoding': {
                    'asset': {
                      'headers': {
                        'Content-Transfer-Encoding': {
                          'schema': {
                            'type': 'string',
                            'enum': ['base64'],
                          },
                        },
                      },
                    },
                  },
              },
            },
          },
          'responses': {
            '204': {'description': 'Empty'},
          },
        },
      },
    },
    'x-number': 'EXACT_VALUE',
  };
  final json = jsonEncode(document)
      .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
  final root = File('${temp.path}/api.$format');
  await root.writeAsString(
    format == 'yaml' ? '# Preserve original 雪\r\n$json\r\n' : json,
  );
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  addTearDown(engine.close);
  final project = await BusyProject.open(root.path, engine);
  addTearDown(project.close);
  final checked = await project.check(root.uri.toString());
  expect(checked['complete'], true, reason: '$checked');
  final operation = (checked['projection']['operations'] as List).single as Map;
  final plan = await project.prepareRequest(
    root.uri.toString(),
    resource: operation['resource'] as String,
    pointer: operation['pointer'] as String,
    occurrence: operation['occurrence'] as String,
  );
  addTearDown(plan.close);
  return (project: project, plan: plan, root: root, shared: shared);
}

void main() {
  test('large binary file instances retain escaped octets and captured wire bytes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-large-binary-part-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    List<int>? received;
    String? contentType;
    server.listen((request) async {
      contentType = request.headers.value('content-type');
      received = await request.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      request.response.statusCode = 204;
      await request.response.close();
    });
    final bytes = List<int>.generate(
      300000,
      (index) => [0, 255, 34, 92, 10][index % 5],
    );
    final fixture = await _open(
      temp,
      server.port,
      '3.0.4',
      'yaml',
      binary: {
        'type': 'string',
        'format': 'binary',
        'minLength': bytes.length,
        'maxLength': bytes.length,
      },
    );
    final file = File('${temp.path}/large.bin');
    await file.writeAsBytes(bytes);
    final draft = OperationRequestDraft(
      planIdentity: fixture.plan.identity,
      body: RequestBodyDraft.multipartValue(
        json: '{"exact":$_exact}',
        files: [MultipartFileValue(name: 'asset', path: file.path)],
      ),
    );
    final prepared = await const ContractRequestBuilder().build(
      fixture.plan,
      draft,
      resolveSecret: (_) async => null,
    );
    addTearDown(prepared.body!.close);
    expect(prepared.body!.formInstance, contains('"exact":$_exact'));
    expect(
      (jsonDecode(prepared.body!.formInstance!) as Map)['asset'],
      latin1.decode(bytes),
    );
    await file.writeAsBytes([1]);
    final checked = await const ContractRequestExecutor().validateOutgoing(
      fixture.plan,
      draft,
      prepared.runId,
      preparedBody: prepared.body,
    );
    expect(checked.complete, true, reason: '${checked.toJson()}');
    expect(checked.valid, true);
    final response = await const ContractHttpTransport().send(prepared);
    addTearDown(response.close);
    expect(response.status, 204);
    final boundary = ContentType.parse(contentType!).parameters['boundary']!;
    final prefix = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="exact"\r\nContent-Type: text/plain\r\n\r\n$_exact\r\n--$boundary\r\nContent-Disposition: form-data; name="asset"; filename="large.bin"\r\nContent-Type: application/octet-stream\r\n\r\n',
    );
    final suffix = utf8.encode('\r\n--$boundary--\r\n');
    expect(received!.length, prefix.length + bytes.length + suffix.length);
    expect(
      contentIdentity(received!),
      contentIdentity([...prefix, ...bytes, ...suffix]),
    );
  });
  for (final version in ['3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format binary-format text fields retain their family\'s length semantics',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-binary-family-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <List<int>>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            seen.add(
              await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              ),
            );
            request.response.statusCode = 204;
            await request.response.close();
          });
          final fixture = await _open(
            temp,
            server.port,
            version,
            format,
            binary: const {
              'type': 'string',
              'format': 'binary',
              'maxLength': 2,
            },
          );
          final result = await const ContractRequestExecutor().execute(
            fixture.plan,
            OperationRequestDraft(
              planIdentity: fixture.plan.identity,
              body: const RequestBodyDraft.multipartValue(
                json: '{"exact":$_exact,"asset":"雪😀"}',
              ),
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(
            result.outgoing.complete,
            true,
            reason: '${result.outgoing.toJson()}',
          );
          expect(result.outgoing.valid, version != '3.0.4');
          expect(
            latin1.decode(seen.single),
            contains(latin1.decode(utf8.encode('雪😀'))),
          );
        },
      );
    }
  for (final format in ['yaml', 'json']) {
    test(
      '3.0 $format binary file length is checked before its MIME transfer encoding',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-binary-transfer-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <List<int>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          seen.add(
            await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            ),
          );
          request.response.statusCode = 204;
          await request.response.close();
        });
        final fixture = await _open(
          temp,
          server.port,
          '3.0.4',
          format,
          transfer: true,
          binary: {
            'type': 'string',
            'format': 'binary',
            'maxLength': 4,
            'enum': ['\u0000ÿ\r\n'],
          },
        );
        final bytes = [0, 255, 13, 10], file = File('${temp.path}/binary.bin');
        await file.writeAsBytes(bytes);
        final draft = OperationRequestDraft(
          planIdentity: fixture.plan.identity,
          body: RequestBodyDraft.multipartValue(
            json: '{"exact":$_exact}',
            files: [MultipartFileValue(name: 'asset', path: file.path)],
          ),
        );
        final prepared = await const ContractRequestBuilder().build(
          fixture.plan,
          draft,
          resolveSecret: (_) async => null,
        );
        addTearDown(prepared.body!.close);
        expect(
          prepared.body!.formInstance,
          contains(jsonEncode(latin1.decode(bytes))),
        );
        final checked = await const ContractRequestExecutor().validateOutgoing(
          fixture.plan,
          draft,
          prepared.runId,
          preparedBody: prepared.body,
        );
        expect(checked.complete, true, reason: '${checked.toJson()}');
        expect(checked.valid, true);
        final response = await const ContractHttpTransport().send(prepared);
        addTearDown(response.close);
        expect(
          latin1.decode(seen.single),
          contains(
            'Content-Transfer-Encoding: base64\r\n\r\n${base64.encode(bytes)}\r\n',
          ),
        );
      },
    );
    test(
      '3.0 $format binary arrays merge field and file instances in actual part order',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-binary-array-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seen = <List<int>>[];
        server.listen((request) async {
          seen.add(
            await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            ),
          );
          request.response.statusCode = 204;
          await request.response.close();
        });
        final fixture = await _open(temp, server.port, '3.0.4', format),
            upload = File('${temp.path}/file.bin');
        final bytes = [0, 255, 0, 254];
        await upload.writeAsBytes(bytes);
        final draft = OperationRequestDraft(
          planIdentity: fixture.plan.identity,
          body: RequestBodyDraft.multipartValue(
            json: '{"exact":$_exact,"values":["雪"]}',
            files: [MultipartFileValue(name: 'values', path: upload.path)],
          ),
        );
        final prepared = await const ContractRequestBuilder().build(
          fixture.plan,
          draft,
          resolveSecret: (_) async => null,
        );
        addTearDown(prepared.body!.close);
        expect((jsonDecode(prepared.body!.formInstance!) as Map)['values'], [
          latin1.decode(utf8.encode('雪')),
          latin1.decode(bytes),
        ]);
        final checked = await const ContractRequestExecutor().validateOutgoing(
          fixture.plan,
          draft,
          prepared.runId,
          preparedBody: prepared.body,
        );
        expect(checked.complete, true, reason: '${checked.toJson()}');
        expect(checked.valid, true);
        final response = await const ContractHttpTransport().send(prepared);
        addTearDown(response.close);
        final actual = latin1.decode(seen.single);
        expect(
          actual.indexOf(latin1.decode(utf8.encode('雪'))),
          lessThan(actual.indexOf('filename="file.bin"')),
        );
        expect(actual, contains(latin1.decode(bytes)));
      },
    );
  }
  for (final version in ['3.0.0', '3.0.4'])
    for (final format in ['yaml', 'json']) {
      test('$version $format binary file instances use immutable captured octets', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-binary-part-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <(String, String, String, List<int>)>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          seen.add((
            request.method,
            request.uri.toString(),
            request.headers.value('content-type')!,
            await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            ),
          ));
          request.response.statusCode = 204;
          await request.response.close();
        });
        final fixture = await _open(temp, server.port, version, format),
            rootBefore = await fixture.root.readAsBytes(),
            sharedBefore = await fixture.shared.readAsBytes();
        final upload = File('${temp.path}/asset.bin');
        for (final bytes in [
          [0, 255, 1, 2],
          <int>[],
          [0, 1, 2, 3, 4],
        ]) {
          await upload.writeAsBytes(bytes);
          final draft = OperationRequestDraft(
            planIdentity: fixture.plan.identity,
            body: RequestBodyDraft.multipartValue(
              json: '{"exact":$_exact}',
              files: [MultipartFileValue(name: 'asset', path: upload.path)],
            ),
          );
          final prepared = await const ContractRequestBuilder().build(
            fixture.plan,
            draft,
            resolveSecret: (_) async => null,
          );
          addTearDown(prepared.body!.close);
          expect(prepared.body!.formInstance, isNotNull);
          expect(prepared.body!.formInstance, contains('"exact":$_exact'));
          // Changing the selected file after preparation must not change either
          // its schema instance or the bytes sent by the already captured body.
          await upload.writeAsBytes([99, 98, 97]);
          final outgoing = await const ContractRequestExecutor()
              .validateOutgoing(
                fixture.plan,
                draft,
                prepared.runId,
                preparedBody: prepared.body,
              );
          expect(outgoing.complete, true, reason: '${outgoing.toJson()}');
          expect(outgoing.valid, bytes.length == 4);
          if (bytes.length != 4)
            expect(
              outgoing.findings.any(
                (finding) =>
                    finding['code'] == 'runtime.schema.incompatible' &&
                    finding['pointer'] == '/asset',
              ),
              true,
            );
          final response = await const ContractHttpTransport().send(prepared);
          addTearDown(response.close);
          expect(response.status, 204);
          final actual = seen.last,
              boundary = ContentType.parse(actual.$3).parameters['boundary']!;
          final expected = [
            ...utf8.encode(
              '--$boundary\r\nContent-Disposition: form-data; name="exact"\r\nContent-Type: text/plain\r\n\r\n$_exact\r\n--$boundary\r\nContent-Disposition: form-data; name="asset"; filename="asset.bin"\r\nContent-Type: application/octet-stream\r\n\r\n',
            ),
            ...bytes,
            ...utf8.encode('\r\n--$boundary--\r\n'),
          ];
          expect((actual.$1, actual.$2), ('POST', '/upload'));
          expect(actual.$4, expected);
        }
        expect(await fixture.root.readAsBytes(), rootBefore);
        expect(await fixture.shared.readAsBytes(), sharedBefore);
      });
    }
  for (final format in ['yaml', 'json'])
    for (final typed in [false, true]) {
      test(
        '3.0 $format ${typed ? 'typed' : 'literal'} binary fields count UTF-8 octets',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-binary-field-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <List<int>>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            seen.add(
              await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              ),
            );
            request.response.statusCode = 204;
            await request.response.close();
          });
          final fixture = await _open(
            temp,
            server.port,
            '3.0.4',
            format,
            binary: const {
              'type': 'string',
              'format': 'binary',
              'minLength': 7,
              'maxLength': 7,
            },
          );
          for (final value in ['雪😀', '雪']) {
            final body = typed
                ? RequestBodyDraft.multipartValue(
                    json: '{"exact":$_exact,"asset":${jsonEncode(value)}}',
                  )
                : RequestBodyDraft.multipart([
                    const RequestFormField('exact', _exact),
                    RequestFormField('asset', value),
                  ], const []);
            final result = await const ContractRequestExecutor().execute(
              fixture.plan,
              OperationRequestDraft(
                planIdentity: fixture.plan.identity,
                body: body,
              ),
              resolveSecret: (_) async => null,
            );
            addTearDown(result.close);
            expect(
              result.outgoing.complete,
              true,
              reason: '${result.outgoing.toJson()}',
            );
            expect(result.outgoing.valid, value == '雪😀');
            expect(
              latin1.decode(seen.last),
              contains(latin1.decode(utf8.encode(value))),
            );
          }
          if (typed) {
            final configuration =
                '{"version":1,"roots":[{"name":"api","path":"api.$format"}],"tests":[{"name":"binary-field","operation":{"method":"post","path":"/upload"},"body":{"mediaType":"multipart/form-data","value":{"exact":$_exact,"asset":"雪😀"}},"expect":{"status":204}}]}';
            await File('${temp.path}/busyapi.yaml')
                .writeAsString(configuration);
            final command = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', 'binary-field', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              command.exitCode,
              0,
              reason: '${command.stdout}\n${command.stderr}',
            );
            final report = jsonDecode(command.stdout as String) as Map;
            expect(report['complete'], true);
            expect((report['cases'] as List).single['passed'], true);
            final first = latin1.decode(seen.first),
                last = latin1.decode(seen.last);
            final firstBoundary = first.substring(2, first.indexOf('\r\n')),
                lastBoundary = last.substring(2, last.indexOf('\r\n'));
            expect(
              latin1.encode(last.replaceAll(lastBoundary, firstBoundary)),
              seen.first,
            );
          }
        },
      );
    }
}
