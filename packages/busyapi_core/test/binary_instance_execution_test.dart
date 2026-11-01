import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

enum _Representation { raw, named, ordered, nested }

const _binary = [0, 255, 128, 0];
const _exact = '9007199254740993.00';
const _rounded = '9007199254740992';

String _type(_Representation kind) => switch (kind) {
  _Representation.raw => 'application/octet-stream',
  _Representation.named => 'multipart/form-data',
  _ => 'multipart/mixed',
};

Map<String, Object?> _media(_Representation kind) {
  const binary = {
    'not': {'type': 'null'},
  };
  const metadata = {
    'type': 'object',
    'required': ['id'],
    'properties': {
      'id': {
        'type': 'integer',
        'enum': ['EXACT'],
      },
    },
  };
  if (kind == _Representation.raw) return {'schema': binary};
  if (kind == _Representation.named) {
    return {
      'schema': {
        'type': 'object',
        'required': ['file', 'metadata'],
        'properties': {'file': binary, 'metadata': metadata},
      },
      'encoding': {
        'file': {'contentType': 'application/octet-stream'},
        'metadata': {'contentType': 'application/json'},
      },
    };
  }
  final nested = kind == _Representation.nested;
  return {
    'schema': {
      'type': 'array',
      'minItems': 2,
      'maxItems': 2,
      'prefixItems': [
        nested ? {'type': 'array', 'items': binary, 'minItems': 1} : binary,
        metadata,
      ],
      'items': false,
    },
    'prefixEncoding': [
      nested
          ? {
              'contentType': 'multipart/mixed',
              'itemEncoding': {'contentType': 'application/octet-stream'},
            }
          : {'contentType': 'application/octet-stream'},
      {'contentType': 'application/json'},
    ],
  };
}

List<int> _wire(
  _Representation kind, {
  String number = _exact,
  String boundary = 'Fixture',
  List<int> binary = _binary,
  bool generated = false,
}) {
  if (kind == _Representation.raw) return binary;
  final bytes = <int>[];
  void part(String headers, List<int> value) {
    bytes.addAll(utf8.encode('--$boundary\r\n$headers\r\n'));
    bytes.addAll(value);
    bytes.addAll(ascii.encode('\r\n'));
  }

  final named = kind == _Representation.named;
  final name = named
      ? 'Content-Disposition: form-data; name="metadata"\r\n'
      : '';
  void metadata() => part(
    '${name}Content-Type: application/json\r\n',
    ascii.encode('{"id":$number}'),
  );
  void file() => part(
    named
        ? 'Content-Disposition: form-data; name="file"${generated ? '; filename="opaque.bin"' : ''}\r\nContent-Type: application/octet-stream\r\n'
        : kind == _Representation.nested
        ? 'Content-Type: multipart/mixed; boundary=Inner\r\n'
        : 'Content-Type: application/octet-stream\r\n',
    kind == _Representation.nested
        ? [
            ...ascii.encode(
              '--Inner\r\nContent-Type: application/octet-stream\r\n\r\n',
            ),
            ...binary,
            ...ascii.encode('\r\n--Inner--\r\n'),
          ]
        : binary,
  );
  if (generated) {
    metadata();
    file();
  } else {
    file();
    metadata();
  }
  bytes.addAll(ascii.encode('--$boundary--\r\n'));
  return bytes;
}

void main() {
  for (final version in ['3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final kind in [
        _Representation.raw,
        _Representation.named,
        if (version.startsWith('3.2.')) ...[
          _Representation.ordered,
          _Representation.nested,
        ],
      ]) {
        test('$version $format ${kind.name} binary uses actual HTTP and CLI bytes', () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-binary-wire-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final observed = <(String, String, String, String, List<int>)>[];
          var roundResponse = false;
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, part) => all..addAll(part),
            );
            final type = request.headers.contentType.toString();
            observed.add((
              request.method,
              request.uri.toString(),
              request.headers.value('host')!,
              type,
              bytes,
            ));
            request.response.headers.set('content-type', type);
            request.response.add(
              roundResponse
                  ? latin1.encode(
                      latin1.decode(bytes).replaceAll(_exact, _rounded),
                    )
                  : bytes,
            );
            await request.response.close();
          });
          final type = _type(kind);
          final media = _media(kind);
          final operation = {
            'requestBody': {
              'required': true,
              'content': {type: media},
            },
            'responses': {
              '200': {
                'description': 'Echo',
                'content': {type: media},
              },
            },
          };
          final value = {
            'openapi': version,
            'info': {'title': 'Original', 'version': 'api-version'},
            'servers': [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            'paths': {
              '/parts': {'post': operation},
            },
          };
          final source =
              (format == 'json'
                      ? jsonEncode(value)
                      : '# Preserve 雪 and binary ownership\r\nopenapi: $version\r\ninfo: {title: Original, version: api-version}\r\n'
                            'servers: [{url: "http://127.0.0.1:${server.port}"}]\r\npaths:\r\n  /parts:\r\n    post: ${jsonEncode(operation)}\r\n')
                  .replaceAll('"EXACT"', _exact);
          final file = File('${directory.path}/api.$format');
          await file.writeAsString(source);
          final payload = File('${directory.path}/payload.bin');
          final upload = File('${directory.path}/opaque.bin');
          await upload.writeAsBytes(_binary);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Original', 'Unsaved'),
          );
          Future<OperationRequestPlan> prepare() => project.prepareRequest(
            buffer.id,
            resource: buffer.id,
            pointer: '/paths/~1parts/post',
          );
          final plan = await prepare();
          addTearDown(plan.close);
          final wireType = kind == _Representation.raw
              ? type
              : '$type; boundary=Fixture';
          for (final mode in [
            'exact',
            if (kind != _Representation.raw) 'rounded-input',
            if (kind != _Representation.raw) 'rounded-response',
            if (kind == _Representation.named) 'generated',
          ]) {
            final number = mode == 'rounded-input' ? _rounded : _exact;
            roundResponse = mode == 'rounded-response';
            await payload.writeAsBytes(_wire(kind, number: number));
            final generated = mode == 'generated';
            final draft = generated
                ? RequestBodyDraft.multipartValue(
                    json: '{"metadata":{"id":$_exact}}',
                    files: [
                      MultipartFileValue(name: 'file', path: upload.path),
                    ],
                  )
                : RequestBodyDraft.binaryFile(
                    mediaType: wireType,
                    file: payload.path,
                  );
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(planIdentity: plan.identity, body: draft),
              resolveSecret: (_) async => throw StateError('No credentials'),
            );
            try {
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
              expect(result.outgoing.valid, mode != 'rounded-input');
              expect(
                result.received.valid,
                mode != 'rounded-input' && !roundResponse,
              );
              expect(
                result.conforming,
                mode != 'rounded-input' && !roundResponse,
              );
              final actual = observed.last;
              expect(
                (actual.$1, actual.$2, actual.$3),
                ('POST', '/parts', '127.0.0.1:${server.port}'),
              );
              final content = ContentType.parse(actual.$4);
              expect(content.mimeType, type);
              final boundary = content.parameters['boundary'] ?? 'Fixture';
              if (generated)
                expect(boundary, matches(RegExp(r'^busyapi-[0-9a-f]{48}$')));
              final expected = _wire(
                kind,
                number: number,
                boundary: boundary,
                generated: generated,
              );
              expect(actual.$5, expected);
              final response = roundResponse
                  ? latin1.encode(
                      latin1.decode(expected).replaceAll(_exact, _rounded),
                    )
                  : expected;
              expect(
                await File(result.response.bodyFile).readAsBytes(),
                response,
              );
              expect(await result.response.decodedBytes(), response);
              expect(await payload.readAsBytes(), _wire(kind, number: number));
            } finally {
              await result.close();
            }
          }
          roundResponse = false;
          final count = observed.length;
          final changed = project.store.buffers[buffer.id]!.text.replaceFirst(
            '"not":{"type":"null"}',
            '"type":"null"',
          );
          expect(changed, isNot(project.store.buffers[buffer.id]!.text));
          project.store.replace(buffer.id, changed);
          await expectLater(
            () => const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                body: RequestBodyDraft.binaryFile(
                  mediaType: wireType,
                  file: payload.path,
                ),
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (value) => value.code,
                'code',
                'request.draft.stale',
              ),
            ),
          );
          expect(observed, hasLength(count));
          await payload.writeAsBytes(_wire(kind));
          final invalid = await prepare();
          addTearDown(invalid.close);
          final result = await const ContractRequestExecutor().execute(
            invalid,
            OperationRequestDraft(
              planIdentity: invalid.identity,
              body: RequestBodyDraft.binaryFile(
                mediaType: wireType,
                file: payload.path,
              ),
            ),
            resolveSecret: (_) async => null,
          );
          try {
            expect(result.outgoing.complete, isTrue);
            expect(result.received.complete, isTrue);
            expect(result.outgoing.valid, isFalse);
            expect(result.received.valid, isTrue);
            expect(observed.last.$5, _wire(kind));
          } finally {
            await result.close();
          }
          final manifest = File('${directory.path}/busyapi.yaml');
          final cliBinary = utf8.encode('binary\u0000雪');
          await manifest.writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                for (final number in [
                  _exact,
                  if (kind != _Representation.raw) _rounded,
                ])
                  {
                    'name': number,
                    'operation': {'method': 'post', 'path': '/parts'},
                    'body': {
                      'mediaType': wireType,
                      'value': utf8.decode(
                        _wire(kind, number: number, binary: cliBinary),
                      ),
                    },
                    'expect': {'status': 200},
                  },
              ],
            }),
          );
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'test',
              directory.path,
              '--case',
              _exact,
              if (kind != _Representation.raw) ...['--case', _rounded],
              '--json',
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            cli.exitCode,
            kind == _Representation.raw ? 0 : 1,
            reason: '${cli.stdout}\n${cli.stderr}',
          );
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['complete'], isTrue, reason: '${cli.stdout}');
          expect((report['cases'] as List).map((value) => value['passed']), [
            true,
            if (kind != _Representation.raw) false,
          ]);
          for (final number in [
            _exact,
            if (kind != _Representation.raw) _rounded,
          ]) {
            final actual =
                observed[observed.length -
                    (kind == _Representation.raw ? 1 : 2) +
                    (number == _exact ? 0 : 1)];
            expect(
              (actual.$1, actual.$2, actual.$3, actual.$4),
              ('POST', '/parts', '127.0.0.1:${server.port}', wireType),
            );
            expect(actual.$5, _wire(kind, number: number, binary: cliBinary));
          }
          expect(await file.readAsBytes(), utf8.encode(source));
          expect(await upload.readAsBytes(), _binary);
        });
        test(
          '$version $format ${kind.name} mock uses captured binary semantics',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-binary-mock-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final type = _type(kind);
            final operation = {
              'requestBody': {
                'required': true,
                'content': {type: _media(kind)},
              },
              'responses': {
                '204': {'description': 'Empty'},
              },
            };
            final value = {
              'openapi': version,
              'info': {'title': 'Original', 'version': 'api-version'},
              'paths': {
                '/parts': {'post': operation},
                if (kind == _Representation.raw)
                  '/invalid': {
                    'post': {
                      'requestBody': {
                        'required': true,
                        'content': {
                          type: {
                            'schema': {'type': 'null'},
                          },
                        },
                      },
                      'responses': {
                        '204': {'description': 'Empty'},
                      },
                    },
                  },
              },
            };
            final source =
                (format == 'json'
                        ? jsonEncode(value)
                        : '# Retain 雪 and CRLF\r\n${jsonEncode(value)}\r\n')
                    .replaceAll('"EXACT"', _rounded);
            final file = File('${directory.path}/api.$format');
            await file.writeAsString(source);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final buffer = await project.buffer(file.uri.toString());
            project.store.replace(
              buffer.id,
              buffer.text
                  .replaceAll(_rounded, _exact)
                  .replaceFirst('Original', 'Unsaved'),
            );
            final plan = await project.prepareMock(buffer.id);
            addTearDown(plan.close);
            final run = await plan.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            addTearDown(run.stop);
            expect(run.nativeValidation.version, '1.18.0+45');
            expect(
              run.nativeValidation.configuration,
              contains('binary-instance-v1'),
            );
            final client = HttpClient();
            addTearDown(() => client.close(force: true));
            Future<int> send(String path, List<int> bytes) async {
              final request = await client.postUrl(run.baseUri.resolve(path));
              request.headers.set(
                'content-type',
                kind == _Representation.raw ? type : '$type; boundary=Fixture',
              );
              request.contentLength = bytes.length;
              request.add(bytes);
              final response = await request.close();
              await response.drain<void>();
              return response.statusCode;
            }

            expect(await send('/parts', _wire(kind)), 204);
            if (kind == _Representation.raw) {
              expect(await send('/parts', []), 204);
              expect(await send('/invalid', _binary), 422);
            } else {
              expect(await send('/parts', _wire(kind, number: _rounded)), 422);
            }
            expect(await file.readAsBytes(), utf8.encode(source));
          },
        );
      }
    }
  }
}
