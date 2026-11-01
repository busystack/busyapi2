import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _versions = [
  '2.0',
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
];
const _payload =
    r'{"n":9007199254740993.00,"flag":false,"empty":"","text":"雪😀","$ref":"literal.json"}';

String _render(Object value, String format) =>
    '${format == 'yaml' ? '# Keep examples and CRLF\r\n' : ''}'
    '${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';

Future<
  ({
    BusyProject project,
    File file,
    File shared,
    String original,
    String originalShared,
  })
>
_open(
  Directory directory,
  HttpServer server,
  String version,
  String format, {
  String mediaType = 'application/json',
  bool form = false,
}) async {
  final legacy = version == '2.0';
  final modern = version.startsWith('3.1') || version.startsWith('3.2');
  final base = legacy ? '/definitions/' : '/components/schemas/';
  final schema = {r'$ref': 'shared.$format#${base}Value~1~0'};
  final annotation = form
      ? {'label': '雪 +&', 'flag': false, 'zero': 0, 'empty': ''}
      : {
          'n': 'EXACT',
          'flag': false,
          'empty': '',
          'text': '雪😀',
          r'$ref': 'literal.json',
        };
  final definition = {
    'type': 'object',
    'properties': form
        ? {
            'label': {'type': 'string'},
            'flag': {'type': 'boolean'},
            'zero': {'type': 'integer'},
            'empty': {'type': 'string'},
          }
        : {
            'n': {
              'type': 'integer',
              'enum': ['EXACT'],
            },
            'flag': {'type': 'boolean'},
            'empty': {'type': 'string'},
            'text': {'type': 'string'},
            r'$ref': {'type': 'string'},
          },
    if (modern) 'examples': [annotation] else 'example': annotation,
  };
  final originalShared = _render({
    legacy ? 'swagger' : 'openapi': version,
    'info': {'title': 'Original shared', 'version': 'business'},
    'paths': <String, Object?>{},
    if (legacy)
      'definitions': {'Value/~': definition}
    else
      'components': {
        'schemas': {'Value/~': definition},
      },
  }, format);
  final original = _render({
    legacy ? 'swagger' : 'openapi': version,
    'info': {'title': 'Original root', 'version': 'business'},
    if (legacy) ...{
      'host': '127.0.0.1:${server.port}',
      'schemes': ['http'],
      'basePath': '/v1',
      'consumes': [mediaType],
    } else
      'servers': [
        {'url': 'http://127.0.0.1:${server.port}/v1'},
      ],
    'paths': {
      '/data': {
        'post': {
          if (legacy)
            'parameters': [
              {
                'in': 'body',
                'name': 'payload',
                'required': true,
                'schema': schema,
              },
            ]
          else
            'requestBody': {
              'required': true,
              'content': {
                mediaType: {'schema': schema},
              },
            },
          'responses': {
            '204': {'description': 'None'},
          },
        },
      },
    },
  }, format);
  final file = File('${directory.path}/api.$format'),
      shared = File('${directory.path}/shared.$format');
  await file.writeAsBytes([239, 187, 191, ...utf8.encode(original)]);
  await shared.writeAsString(originalShared);
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  addTearDown(engine.close);
  final project = await BusyProject.open(file.path, engine);
  addTearDown(project.close);
  return (
    project: project,
    file: file,
    shared: shared,
    original: original,
    originalShared: originalShared,
  );
}

Future<OperationRequestPlan> _plan(
  BusyProject project,
  File file, {
  bool saved = false,
}) => project.prepareRequest(
  file.uri.toString(),
  resource: file.uri.toString(),
  pointer: '/paths/~1data/post',
  saved: saved,
);

Map _example(OperationRequestPlan plan) =>
    ((plan.result['requestBody'] as Map)['content'] as List).single['example']
        as Map;

void main() {
  for (final version in _versions) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format captured schema example sends exact JSON and preserves saved source',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-schema-input-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <List<int>>[];
          server.listen((request) async {
            expect(request.method, 'POST');
            expect(request.uri.toString(), '/v1/data');
            expect(request.headers.contentType!.mimeType, 'application/json');
            seen.add(
              await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              ),
            );
            request.response.statusCode = 204;
            await request.response.close();
          });
          final fixture = await _open(directory, server, version, format);
          final rootBuffer = await fixture.project.buffer(
            fixture.file.uri.toString(),
          );
          final sharedBuffer = await fixture.project.buffer(
            fixture.shared.uri.toString(),
          );
          fixture.project.store.replace(
            sharedBuffer.id,
            sharedBuffer.text.replaceFirst('雪😀', 'Unsaved 雪😀'),
          );
          final plan = await _plan(fixture.project, fixture.file);
          addTearDown(plan.close);
          final example = _example(plan), text = example['raw'] as String;
          expect(text, _payload.replaceFirst('雪😀', 'Unsaved 雪😀'));
          expect(example['representation'], 'json');
          expect(example['origin'], 'schema');
          expect(example['source']['resource'], sharedBuffer.id);
          expect(example['source']['pointer'], contains('Value~1~0/'));
          expect(example['source']['generation'], sharedBuffer.generation);
          final range = example['source']['range'] as List;
          expect(
            sharedBuffer.text.substring(range[0] as int, range[1] as int),
            contains('9007199254740993.00'),
          );
          final draft = OperationRequestDraft(
            planIdentity: plan.identity,
            body: RequestBodyDraft.raw(
              mediaType: 'application/json',
              text: text,
            ),
          );
          final preview = await const ContractRequestBuilder().build(
            plan,
            draft,
            resolveSecret: (_) async => null,
            previewOnly: true,
          );
          expect(preview.method, 'POST');
          expect(preview.uri.path, '/v1/data');
          expect(
            preview.headers,
            contains(('Content-Type', 'application/json')),
          );
          await preview.body?.close();
          final result = await const ContractRequestExecutor().execute(
            plan,
            draft,
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(seen.single, utf8.encode(text));
          expect(
            result.outgoing.complete,
            true,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.outgoing.valid,
            true,
            reason: '${result.outgoing.findings}',
          );
          expect(result.received.complete, true);
          expect(result.received.valid, true);
          final saved = await _plan(fixture.project, fixture.file, saved: true);
          addTearDown(saved.close);
          expect(_example(saved)['raw'], _payload);
          await fixture.project.save(rootBuffer);
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.original),
          ]);
          expect(await fixture.shared.readAsString(), fixture.originalShared);
          fixture.project.store.replace(
            sharedBuffer.id,
            sharedBuffer.text.replaceFirst('Unsaved 雪😀', 'New revision'),
          );
          expect(
            plan.ensureCurrentPreparation,
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'request.draft.stale',
              ),
            ),
          );
          final current = await _plan(fixture.project, fixture.file);
          addTearDown(current.close);
          expect(_example(current)['raw'], contains('New revision'));
          expect(current.identity, isNot(plan.identity));
          final cancelled = fixture.project.prepareRequest(
            fixture.file.uri.toString(),
            resource: fixture.file.uri.toString(),
            pointer: '/paths/~1data/post',
            cancelled: () => true,
          );
          await expectLater(
            cancelled,
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
            ),
          );
          expect(seen, hasLength(1));
        },
      );
    }
  }
  for (final version in _versions.where((v) => v != '2.0')) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format schema form data keeps kinds through actual URL-encoded bytes',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-schema-form-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <String>[];
          server.listen((request) async {
            expect(request.method, 'POST');
            expect(request.uri.path, '/v1/data');
            expect(
              request.headers.contentType!.mimeType,
              'application/x-www-form-urlencoded',
            );
            seen.add(await utf8.decoder.bind(request).join());
            request.response.statusCode = 204;
            await request.response.close();
          });
          final fixture = await _open(
            directory,
            server,
            version,
            format,
            mediaType: 'application/x-www-form-urlencoded',
            form: true,
          );
          final plan = await _plan(fixture.project, fixture.file);
          addTearDown(plan.close);
          final example = _example(plan);
          expect(example['representation'], 'json');
          expect(example['dataKind'], 'object');
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.formValue(json: example['raw'] as String),
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(
            seen.single,
            'label=%E9%9B%AA+%2B%26&flag=false&zero=0&empty=',
          );
          expect(
            result.outgoing.complete,
            true,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.outgoing.valid,
            true,
            reason: '${result.outgoing.findings}',
          );
          expect(result.received.complete, true);
          expect(result.received.valid, true);
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.original),
          ]);
          expect(await fixture.shared.readAsString(), fixture.originalShared);
        },
      );
    }
  }
  for (final format in ['yaml', 'json']) {
    for (final kind in ['body-example', 'body-examples', 'flat']) {
      test(
        'Swagger $format $kind retains native choices while wrong-family source stays available',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-schema-swagger-context-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final parameter = kind == 'flat'
              ? {
                  'in': 'query',
                  'name': 'value',
                  'type': 'string',
                  'example': 'Wrong',
                  'schema': {'example': 'WrongSchema'},
                  'content': {
                    'application/json': {
                      'schema': {'example': 'WrongContent'},
                    },
                  },
                }
              : {
                  'in': 'body',
                  'name': 'payload',
                  'schema': {'example': 'Native'},
                  if (kind == 'body-example')
                    'example': 'Wrong'
                  else
                    'examples': {
                      'Named': {'value': 'Wrong'},
                    },
                };
          final source = _render({
            'swagger': '2.0',
            'info': {'title': 'Native Swagger fields', 'version': 'business'},
            'consumes': ['application/json'],
            'paths': {
              '/data': {
                'post': {
                  'parameters': [parameter],
                  'responses': {
                    '204': {
                      'description': 'None',
                      'headers': {
                        'X-Value': {
                          'type': 'string',
                          'schema': {'example': 'WrongHeader'},
                          'content': {
                            'application/json': {
                              'schema': {'example': 'WrongHeaderContent'},
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          }, format);
          final file = File('${directory.path}/api.$format');
          await file.writeAsString(source);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final check = await project.check(file.uri.toString());
          expect(check['complete'], true);
          expect(
            (check['findings'] as List).whereType<Map>().where(
              (f) => f['severity'] == 'error',
            ),
            isNotEmpty,
          );
          final plan = await _plan(project, file);
          addTearDown(plan.close);
          final header =
              ((plan.result['responses'] as List).single['headers'] as List)
                      .single
                  as Map;
          expect(header['type'], 'string');
          expect(header['schema']['resource'], file.uri.toString());
          expect(
            header['schema']['pointer'],
            '/paths/~1data/post/responses/204/headers/X-Value',
          );
          expect(header['content'], isEmpty);
          if (kind == 'flat') {
            final p = (plan.result['parameters'] as List).single as Map;
            expect(p['type'], 'string');
            expect(p['schema']['resource'], file.uri.toString());
            expect(p['schema']['pointer'], '/paths/~1data/post/parameters/0');
            expect(p['examples'], isEmpty);
            expect(p['example'], isNull);
            expect(p['content'], isEmpty);
          } else {
            final example = _example(plan);
            expect(example['raw'], '"Native"');
            expect(example['origin'], 'schema');
          }
          expect((await project.buffer(file.uri.toString())).text, source);
          expect(await file.readAsString(), source);
        },
      );
    }
  }
}
