import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final defaultMedia in [false, true]) {
        for (final binding
            in version.startsWith('3.0.')
                ? ['reference']
                : ['reference', 'dynamic-pointer', 'dynamic-anchor']) {
          test(
            '$version $format $binding ${defaultMedia ? 'default' : 'declared'} media file shapes control HTTP and captured validation',
            () async {
              final directory = await Directory.systemTemp.createTemp(
                'busyapi-file-shapes-',
              );
              addTearDown(() => directory.delete(recursive: true));
              final engine = EngineProcess(
                executable: runtimeNode,
                helper: runtimeHelper,
              );
              addTearDown(engine.close);
              final server = await HttpServer.bind(
                InternetAddress.loopbackIPv4,
                0,
              );
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
              final legacy = version.startsWith('3.0.');
              final bytes = legacy ? [0, 255, 65] : utf8.encode('café');
              final partType = legacy
                  ? 'application/octet-stream'
                  : defaultMedia
                  ? 'text/plain'
                  : 'text/plain; charset=utf-8';
              final scalar = {
                'type': 'string',
                if (legacy) 'format': 'binary',
                'minLength': legacy ? 3 : 4,
                'maxLength': legacy ? 3 : 4,
              };
              final Map<String, Object> property = legacy || defaultMedia
                  ? {
                      'oneOf': [
                        scalar,
                        {
                          'type': 'array',
                          'minItems': 1,
                          'maxItems': 2,
                          'items': scalar,
                        },
                      ],
                    }
                  : {
                      'type': ['string', 'array'],
                      'minLength': 4,
                      'maxLength': 4,
                      'minItems': 1,
                      'maxItems': 2,
                      'items': scalar,
                    };
              if (binding == 'dynamic-anchor')
                property[r'$dynamicAnchor'] = 'part';
              final sharedText = binding == 'dynamic-anchor'
                  ? '# Keep schema comments\r\n${jsonEncode({
                      ...property,
                      'x-literal': {'value': false},
                    })}\r\n'
                  : '# Keep schema comments\r\nFile: ${jsonEncode(property)}\r\nx-literal: {value: false}\r\n';
              final shared = File('${directory.path}/model.yaml');
              await shared.writeAsString(sharedText);
              final operation = <String, Object?>{
                'requestBody': {
                  'required': true,
                  'content': {
                    'multipart/form-data': {
                      'schema': {
                        'type': 'object',
                        'required': ['exact', 'asset'],
                        'properties': {
                          'exact': {'type': 'integer'},
                          'asset': {
                            binding == 'reference'
                                ? r'$ref'
                                : r'$dynamicRef': binding == 'dynamic-anchor'
                                ? './model.yaml#part'
                                : './model.yaml#/File',
                          },
                        },
                      },
                      'encoding': {
                        'exact': {'contentType': 'application/json'},
                        if (!defaultMedia) 'asset': {'contentType': partType},
                      },
                    },
                  },
                },
                'responses': {
                  '204': {'description': 'No response body'},
                },
              };
              final bodyVersion = binding == 'dynamic-pointer' && !defaultMedia
                  ? version == '3.1.2'
                        ? '3.2.1'
                        : '3.1.2'
                  : version;
              File? definingBody;
              String? definingText;
              if (bodyVersion != version) {
                final bodyDocument = {
                  'openapi': bodyVersion,
                  'info': {'title': 'Defining body 雪', 'version': 'unrelated'},
                  'paths': <String, Object?>{},
                  'components': {
                    'requestBodies': {'Upload': operation['requestBody']},
                  },
                };
                definingText = format == 'json'
                    ? jsonEncode(bodyDocument)
                    : '# Keep defining body\r\n${bodyDocument.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n';
                definingBody = File('${directory.path}/body.$format');
                await definingBody.writeAsString(definingText);
                operation['requestBody'] = {
                  r'$ref': './body.$format#/components/requestBodies/Upload',
                };
              }
              final document = {
                'openapi': version,
                'info': {'title': 'Keep 雪', 'version': 'unrelated'},
                'servers': [
                  {'url': 'http://127.0.0.1:${server.port}'},
                ],
                'paths': {
                  '/files': {'post': operation},
                },
              };
              final text = format == 'json'
                  ? jsonEncode(document)
                  : '# Keep CRLF\r\n${document.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n';
              final file = File('${directory.path}/api.$format');
              final source = [0xef, 0xbb, 0xbf, ...utf8.encode(text)];
              await file.writeAsBytes(source);
              final upload = File('${directory.path}/blob.bin');
              await upload.writeAsBytes(bytes);
              final project = await BusyProject.open(file.path, engine);
              addTearDown(project.close);
              final plan = await project.prepareRequest(
                file.uri.toString(),
                resource: file.uri.toString(),
                pointer: '/paths/~1files/post',
              );
              addTearDown(plan.close);
              expect(
                plan.result['requestBody']['content'][0]['family'],
                bodyVersion.substring(0, 3),
              );
              if (definingBody != null)
                expect(
                  plan.result['requestBody']['content'][0]['definition']['resource'],
                  definingBody.uri.toString(),
                );
              expect(
                plan
                    .formMediaOptions('multipart/form-data')
                    .singleWhere((part) => part.name == 'asset')
                    .fileShapes,
                [MultipartFileShape.single, MultipartFileShape.array],
              );
              OperationRequestDraft draft(
                MultipartFileShape? shape, [
                int count = 1,
              ]) => OperationRequestDraft(
                planIdentity: plan.identity,
                body: RequestBodyDraft.multipartValue(
                  json: '{"exact":9007199254740993.00}',
                  files: [
                    for (var i = 0; i < count; i++)
                      MultipartFileValue(name: 'asset', path: upload.path),
                  ],
                  fileShapes: {if (shape != null) 'asset': shape},
                ),
              );
              await expectLater(
                const ContractRequestBuilder().build(
                  plan,
                  draft(null),
                  resolveSecret: (_) async => null,
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'request.multipart.encoding.unsupported',
                  ),
                ),
              );
              expect(seen, isEmpty);
              for (final (shape, count) in [
                (MultipartFileShape.single, 1),
                (MultipartFileShape.array, 1),
                (MultipartFileShape.array, 2),
              ]) {
                final input = draft(shape, count);
                final prepared = await const ContractRequestBuilder().build(
                  plan,
                  input,
                  resolveSecret: (_) async => null,
                );
                try {
                  expect(prepared.body!.fileShapes, {'asset': shape});
                  expect(
                    () => prepared.body!.fileShapes['asset'] =
                        MultipartFileShape.single,
                    throwsUnsupportedError,
                  );
                  input.body.fileShapes['asset'] =
                      shape == MultipartFileShape.single
                      ? MultipartFileShape.array
                      : MultipartFileShape.single;
                  if (legacy) {
                    final instance =
                        jsonDecode(prepared.body!.formInstance!) as Map;
                    final expected = latin1.decode(bytes);
                    expect(
                      instance['asset'],
                      shape == MultipartFileShape.single
                          ? expected
                          : List.filled(count, expected),
                    );
                  }
                  final conformance = await const ContractRequestExecutor()
                      .validateOutgoing(
                        plan,
                        input,
                        prepared.runId,
                        preparedBody: prepared.body,
                      );
                  expect(
                    conformance.complete,
                    isTrue,
                    reason: '${conformance.findings}',
                  );
                  expect(
                    conformance.valid,
                    isTrue,
                    reason: '${conformance.findings}',
                  );
                } finally {
                  input.body.fileShapes['asset'] = shape;
                  await prepared.body!.close();
                }
                final result = await const ContractRequestExecutor().execute(
                  plan,
                  input,
                  resolveSecret: (_) async => null,
                );
                try {
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
                  expect(result.received.complete, isTrue);
                  expect(result.response.status, 204);
                } finally {
                  await result.close();
                }
                final request = seen.last,
                    boundary = ContentType.parse(seen.last.$4)
                        .parameters['boundary']!;
                final expected = <int>[
                  ...utf8.encode(
                    '--$boundary\r\nContent-Disposition: form-data; name="exact"\r\nContent-Type: application/json\r\n\r\n9007199254740993.00\r\n',
                  ),
                  for (var i = 0; i < count; i++) ...[
                    ...utf8.encode(
                      '--$boundary\r\nContent-Disposition: form-data; name="asset"; filename="blob.bin"\r\nContent-Type: $partType\r\n\r\n',
                    ),
                    ...bytes,
                    13,
                    10,
                  ],
                  ...utf8.encode('--$boundary--\r\n'),
                ];
                expect(request.$1, 'POST');
                expect(request.$2, '/files');
                expect(request.$3, '127.0.0.1:${server.port}');
                expect(request.$5, expected);
                expect(await upload.readAsBytes(), bytes);
              }
              await expectLater(
                const ContractRequestBuilder().build(
                  plan,
                  draft(MultipartFileShape.single, 2),
                  resolveSecret: (_) async => null,
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'request.multipart.file-shape',
                  ),
                ),
              );
              expect(seen.length, 3);
              final mutable = {'asset': MultipartFileShape.array};
              final pending = plan.multipartEncoding(
                'multipart/form-data',
                [],
                ['asset'],
                fileShapes: mutable,
                requestId: 'stale-file-shape',
              );
              mutable['asset'] = MultipartFileShape.single;
              await expectLater(
                pending,
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'request.multipart.file-shape.stale',
                  ),
                ),
              );
              final cancelled = RunCancellation()..cancel();
              final mediaShapes = {'asset': MultipartFileShape.array};
              final pendingMedia = plan.formMediaTypes(
                'multipart/form-data',
                [],
                {},
                files: [
                  {'name': 'asset', 'fallback': 'application/octet-stream'},
                ],
                fileShapes: mediaShapes,
                requestId: 'stale-file-shape-media',
              );
              mediaShapes['asset'] = MultipartFileShape.single;
              await expectLater(
                pendingMedia,
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'request.multipart.file-shape.stale',
                  ),
                ),
              );
              await expectLater(
                const ContractRequestBuilder().build(
                  plan,
                  draft(MultipartFileShape.array),
                  resolveSecret: (_) async => null,
                  cancellation: cancelled,
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'cancelled',
                  ),
                ),
              );
              expect(seen.length, 3);
              expect(await file.readAsBytes(), source);
              expect(await shared.readAsString(), sharedText);
              await File('${directory.path}/busyapi.yaml').writeAsString(
                jsonEncode({
                  'version': 1,
                  'roots': [
                    {'name': 'api', 'path': 'api.$format'},
                  ],
                  'tests': [
                    for (final shape in ['single', 'array'])
                      {
                        'name': shape,
                        'operation': {'method': 'post', 'path': '/files'},
                        'body': {
                          'mediaType': 'multipart/form-data',
                          'value': {'exact': 'EXACT'},
                          'files': [
                            {'name': 'asset', 'path': 'blob.bin'},
                          ],
                          'fileShapes': {'asset': shape},
                        },
                        'expect': {'status': 204},
                      },
                  ],
                }).replaceAll('"EXACT"', '9007199254740993.00'),
              );
              final cases = await BusyProject.open(directory.path, engine);
              try {
                final report = await const ContractTestRunner().run(
                  cases,
                  file.uri.toString(),
                  selectedCases: ['single', 'array'],
                  resolveSecret: (_) async => null,
                );
                expect(report.complete, isTrue, reason: '${report.toJson()}');
                expect(report.passed, isTrue, reason: '${report.toJson()}');
                // The borrowed upload capability remains usable after capture.
                expect(await cases.access.read(upload.path), bytes);
              } finally {
                cases.close();
              }
              final cli = await Process.run(
                '$testBundle/busyapi',
                [
                  'test',
                  directory.path,
                  '--case',
                  'single',
                  '--case',
                  'array',
                  '--json',
                ],
                environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
                includeParentEnvironment: false,
              );
              expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
              final report = jsonDecode(cli.stdout as String) as Map;
              expect(report['complete'], isTrue, reason: '${cli.stdout}');
              expect(report['passed'], isTrue, reason: '${cli.stdout}');
              expect(seen.length, 7);
              for (final request in seen.skip(3)) {
                final boundary = ContentType.parse(request.$4)
                    .parameters['boundary']!;
                expect(request.$1, 'POST');
                expect(request.$2, '/files');
                expect(request.$3, '127.0.0.1:${server.port}');
                expect(request.$5, [
                  ...utf8.encode(
                    '--$boundary\r\nContent-Disposition: form-data; name="exact"\r\nContent-Type: application/json\r\n\r\n9007199254740993.00\r\n',
                  ),
                  ...utf8.encode(
                    '--$boundary\r\nContent-Disposition: form-data; name="asset"; filename="blob.bin"\r\nContent-Type: $partType\r\n\r\n',
                  ),
                  ...bytes,
                  13,
                  10,
                  ...utf8.encode('--$boundary--\r\n'),
                ]);
              }
              expect(await file.readAsBytes(), source);
              expect(await shared.readAsString(), sharedText);
              if (definingBody != null)
                expect(await definingBody.readAsString(), definingText);
              if (binding == 'dynamic-anchor' && !defaultMedia) {
                final buffer = await project.buffer(file.uri.toString());
                project.store.replace(
                  buffer.id,
                  buffer.text.replaceFirst('Keep 雪', 'Unsaved 雪'),
                );
                final mockPlan = await project.prepareMock(buffer.id);
                try {
                  final mock = await mockPlan.start(
                    nodeExecutable: runtimeNode,
                    helper: '$testBundle/libexec/busyapi/mock-server.cjs',
                  );
                  final client = HttpClient();
                  try {
                    final request = await client.postUrl(
                      mock.baseUri.resolve('/files'),
                    );
                    request.headers.set(
                      HttpHeaders.contentTypeHeader,
                      seen.last.$4,
                    );
                    request.contentLength = seen.last.$5.length;
                    request.add(seen.last.$5);
                    final response = await request.close();
                    await response.drain<void>();
                    expect(response.statusCode, 204);
                    expect(response.headers.value('sl-violations'), isNull);
                    expect(mock.nativeValidation.version, '1.18.0+41');
                    project.store.replace(
                      buffer.id,
                      buffer.text.replaceFirst(
                        version,
                        version == '3.2.1' ? '3.1.2' : '3.2.1',
                      ),
                    );
                    expect(mockPlan.outdated, isTrue);
                    expect(mock.outdated, isTrue);
                    await expectLater(
                      mockPlan.start(
                        nodeExecutable: runtimeNode,
                        helper: '$testBundle/libexec/busyapi/mock-server.cjs',
                      ),
                      throwsA(
                        isA<CoreFailure>().having(
                          (failure) => failure.code,
                          'code',
                          'mock.stale',
                        ),
                      ),
                    );
                    expect(await file.readAsBytes(), source);
                    expect(buffer.text, contains('Unsaved 雪'));
                  } finally {
                    client.close(force: true);
                    await mock.stop();
                  }
                } finally {
                  mockPlan.close();
                }
              }
              if (version == '3.0.4' && format == 'yaml' && !defaultMedia) {
                final outside = await Directory.systemTemp.createTemp(
                  'busyapi-outside-upload-',
                );
                addTearDown(() => outside.delete(recursive: true));
                await File('${outside.path}/secret.bin')
                    .writeAsString('must remain private');
                await Link('${directory.path}/linked').create(outside.path);
                await Link('${directory.path}/alias.bin')
                    .create('${outside.path}/secret.bin');
                for (final path in [
                  'linked/secret.bin',
                  'alias.bin',
                  'missing.bin',
                ]) {
                  final manifest = {
                    'version': 1,
                    'roots': [
                      {'name': 'api', 'path': 'api.$format'},
                    ],
                    'tests': [
                      {
                        'name': 'unsafe',
                        'operation': {'method': 'post', 'path': '/files'},
                        'body': <String, Object?>{
                          'mediaType': 'multipart/form-data',
                          'value': {'exact': 'EXACT'},
                          'files': [
                            {'name': 'asset', 'path': path},
                          ],
                          'fileShapes': {'asset': 'single'},
                        },
                      },
                    ],
                  };
                  await File('${directory.path}/busyapi.yaml').writeAsString(
                    jsonEncode(manifest)
                        .replaceAll('"EXACT"', '9007199254740993.00'),
                  );
                  final unsafe = await BusyProject.open(directory.path, engine);
                  try {
                    final report = await const ContractTestRunner().run(
                      unsafe,
                      file.uri.toString(),
                      selectedCases: ['unsafe'],
                      resolveSecret: (_) async => null,
                    );
                    expect(report.passed, isFalse);
                    expect(report.cases.single.dispatched, isFalse);
                    expect(report.cases.single.operationalFailure, isTrue);
                    expect(seen.length, 7);
                    expect(await unsafe.access.read(upload.path), bytes);
                  } finally {
                    unsafe.close();
                  }
                  for (final invalid in [
                    {
                      'files': [
                        {'name': 'asset', 'path': '../secret.bin'},
                      ],
                    },
                    {
                      'files': [
                        {'name': 'asset', 'path': '${outside.path}/secret.bin'},
                      ],
                    },
                    {'files': null},
                    {
                      'files': [
                        {'name': 'asset', 'path': 'blob.bin'},
                      ],
                      'fileShapes': {'asset': 'tuple'},
                    },
                    {
                      'files': [
                        {'name': 'asset', 'path': 'blob.bin'},
                      ],
                      'fileShapes': {'other': 'array'},
                    },
                    {
                      'files': [
                        {'name': 'asset', 'path': 'blob.bin'},
                      ],
                      'fileShapes': null,
                    },
                  ]) {
                    final body =
                        ((manifest['tests'] as List).single as Map)['body']
                            as Map;
                    body.remove('fileShapes');
                    body.addAll(invalid);
                    await File('${directory.path}/busyapi.yaml').writeAsString(
                      jsonEncode(manifest)
                          .replaceAll('"EXACT"', '9007199254740993.00'),
                    );
                    final invalidProject = await BusyProject.open(
                      directory.path,
                      engine,
                    );
                    try {
                      await expectLater(
                        const ContractTestRunner().run(
                          invalidProject,
                          file.uri.toString(),
                          selectedCases: ['unsafe'],
                          resolveSecret: (_) async => null,
                        ),
                        throwsA(
                          isA<CoreFailure>().having(
                            (failure) => failure.code,
                            'code',
                            'test.configuration',
                          ),
                        ),
                      );
                    } finally {
                      invalidProject.close();
                    }
                    expect(seen.length, 7);
                  }
                }
                expect(
                  await File('${outside.path}/secret.bin').readAsString(),
                  'must remain private',
                );
              }
            },
          );
        }
      }
    }
  }
}
