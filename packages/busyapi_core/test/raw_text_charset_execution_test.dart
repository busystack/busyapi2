import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _patches = [
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
const _latin = '\u0000\u007f\u0080\u009fÿ café\r\n';
const _iso = 'text/plain; charset=ISO-8859-1';
const _media = [
  _iso,
  'text/plain; charset=latin1',
  'text/plain; charset=us-ascii',
  'text/plain; charset=utf-8',
  'text/plain',
  'text/plain; charset=shift_jis',
  'application/json; charset=iso-8859-1',
  'text/event-stream; charset=iso-8859-1',
];

typedef _Seen = ({
  String method,
  String uri,
  ContentType type,
  int length,
  List<int> bytes,
});

Future<
  ({
    BusyProject project,
    OperationRequestPlan plan,
    File file,
    File shared,
    String original,
    String sharedText,
  })
>
_open(
  Directory temp,
  HttpServer server,
  String version,
  String format, {
  List<String> types = _media,
}) async {
  final legacy = version == '2.0';
  final media = {
    for (final type in types)
      type: {
        'schema': {r'$ref': 'schemas.$format#/A~1B~0'},
      },
  };
  final document = {
    legacy ? 'swagger' : 'openapi': version,
    'info': {'title': 'Original charset 雪😀', 'version': 'business'},
    if (legacy) ...{
      'host': '127.0.0.1:${server.port}',
      'schemes': ['http'],
      'basePath': '/v1',
      'consumes': types,
      'produces': types,
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
                'name': 'payload',
                'in': 'body',
                'required': true,
                'schema': {r'$ref': 'schemas.$format#/A~1B~0'},
              },
            ]
          else
            'requestBody': {'required': true, 'content': media},
          'responses': {
            '200': {
              'description': 'Echo',
              if (legacy)
                'schema': {r'$ref': 'schemas.$format#/A~1B~0'}
              else
                'content': media,
            },
          },
        },
      },
    },
    'x-number': 'EXACT',
  };
  final original =
      '${format == 'yaml' ? '# Keep root\r\n' : ''}'
      '${jsonEncode(document).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
  final sharedText =
      '${format == 'yaml' ? '# Keep schema\r\n' : ''}'
      '${jsonEncode({
        'A/B~': {
          'type': 'string',
          'enum': [_latin, '', '0', 'false', 'null', 'café 雪😀'],
        },
      })}\r\n';
  final file = File('${temp.path}/api.$format'),
      shared = File('${temp.path}/schemas.$format');
  await file.writeAsBytes([239, 187, 191, ...utf8.encode(original)]);
  await shared.writeAsString(sharedText);
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  addTearDown(engine.close);
  final project = await BusyProject.open(file.path, engine);
  addTearDown(project.close);
  final buffer = await project.buffer(file.uri.toString());
  project.store.replace(
    buffer.id,
    original.replaceFirst('Original', 'Unsaved'),
  );
  final result = await project.check(buffer.id);
  expect(result['complete'], true, reason: '$result');
  expect(
    (result['findings'] as List).whereType<Map>().where(
      (finding) => finding['severity'] == 'error',
    ),
    isEmpty,
    reason: '$result',
  );
  final plan = await project.prepareRequest(
    buffer.id,
    resource: buffer.id,
    pointer: '/paths/~1data/post',
  );
  addTearDown(plan.close);
  return (
    project: project,
    plan: plan,
    file: file,
    shared: shared,
    original: original,
    sharedText: sharedText,
  );
}

OperationRequestDraft _draft(
  OperationRequestPlan plan,
  String media,
  String text,
) => OperationRequestDraft(
  planIdentity: plan.identity,
  body: RequestBodyDraft.raw(mediaType: media, text: text),
);

Future<List<_Seen>> _echo(HttpServer server) async {
  final seen = <_Seen>[];
  server.listen((request) async {
    final bytes = await request.fold<List<int>>(
      [],
      (all, next) => all..addAll(next),
    );
    seen.add((
      method: request.method,
      uri: request.uri.toString(),
      type: request.headers.contentType!,
      length: request.contentLength,
      bytes: bytes,
    ));
    request.response.headers.set(
      'content-type',
      request.headers.value('content-type')!,
    );
    request.response.add(bytes);
    await request.response.close();
  });
  return seen;
}

void _wire(_Seen seen, String media, List<int> bytes) {
  final type = ContentType.parse(media);
  expect(
    (seen.method, seen.uri, seen.type.mimeType, seen.type.charset),
    ('POST', '/v1/data', type.mimeType, type.charset),
  );
  expect(seen.length, bytes.length);
  expect(seen.bytes, bytes);
}

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format a concrete Latin-1 body uses its declared media range',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-raw-charset-range-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = await _echo(server);
          final fixture = await _open(
            temp,
            server,
            version,
            format,
            types: ['text/*'],
          );
          final result = await const ContractRequestExecutor().execute(
            fixture.plan,
            _draft(fixture.plan, _iso, _latin),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
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
          expect(
            result.received.complete,
            true,
            reason: '${result.received.findings}',
          );
          expect(
            result.received.valid,
            true,
            reason: '${result.received.findings}',
          );
          _wire(seen.single, _iso, latin1.encode(_latin));
          expect(await result.response.decodedBytes(), latin1.encode(_latin));
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.original),
          ]);
          expect(await fixture.shared.readAsString(), fixture.sharedText);
        },
      );
    }
  }
  for (final version in _patches) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format raw text uses declared bytes in preview, HTTP and saved CLI cases',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-raw-charset-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = await _echo(server);
          final fixture = await _open(temp, server, version, format);
          final cases = [
            (_iso, _latin, latin1.encode(_latin)),
            ('text/plain; charset=latin1', _latin, latin1.encode(_latin)),
            (_iso, '', <int>[]),
            (_iso, 'null', latin1.encode('null')),
            ('text/plain; charset=us-ascii', '0', ascii.encode('0')),
            ('text/plain; charset=utf-8', 'café 雪😀', utf8.encode('café 雪😀')),
            ('text/plain', 'false', utf8.encode('false')),
          ];
          for (final (media, text, expected) in cases) {
            final draft = _draft(fixture.plan, media, text);
            final preview = await const ContractRequestBuilder().build(
              fixture.plan,
              draft,
              resolveSecret: (_) async => null,
              previewOnly: true,
            );
            expect(preview.body!.length, 0);
            await preview.body!.close();
            final result = await const ContractRequestExecutor().execute(
              fixture.plan,
              draft,
              resolveSecret: (_) async => null,
            );
            addTearDown(result.close);
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
            expect(
              result.received.complete,
              true,
              reason: '${result.received.findings}',
            );
            expect(
              result.received.valid,
              true,
              reason: '${result.received.findings}',
            );
            _wire(seen.last, media, expected);
            expect(await result.response.decodedBytes(), expected);
          }
          for (final text in ['€', '雪😀']) {
            for (final preview in [false, true]) {
              await expectLater(
                const ContractRequestBuilder().build(
                  fixture.plan,
                  _draft(fixture.plan, _iso, text),
                  resolveSecret: (_) async => null,
                  previewOnly: preview,
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'request.charset',
                  ),
                ),
              );
            }
          }
          expect(seen, hasLength(cases.length));
          await File('${temp.path}/busyapi.yaml').writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                for (final (index, value) in cases.take(3).indexed)
                  {
                    'name': 'charset-$index',
                    'operation': {'method': 'post', 'path': '/data'},
                    'body': {'mediaType': value.$1, 'value': value.$2},
                    'expect': {'status': 200},
                  },
              ],
            }),
          );
          final cli = await runCliWithSecrets([
            'test',
            temp.path,
            for (var index = 0; index < 3; index++) ...[
              '--case',
              'charset-$index',
            ],
            '--json',
          ], const {});
          expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
          final report = jsonDecode(cli.output) as Map;
          expect(report['complete'], true, reason: cli.output);
          expect(
            (report['cases'] as List).map((value) => value['passed']),
            everyElement(true),
          );
          expect(seen, hasLength(cases.length + 3));
          for (final (index, value) in cases.take(3).indexed) {
            _wire(seen[cases.length + index], value.$1, value.$3);
          }
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.original),
          ]);
          expect(await fixture.shared.readAsString(), fixture.sharedText);
          expect(
            fixture.project.store.get(fixture.file.uri.toString()).text,
            fixture.original.replaceFirst('Original', 'Unsaved'),
          );
        },
      );
      test(
        '$version $format charset guards retain exact binary-file behavior',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-raw-charset-guard-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = await _echo(server);
          final fixture = await _open(temp, server, version, format);
          final upload = File('${temp.path}/body.bin');
          final bytes = latin1.encode(_latin);
          await upload.writeAsBytes(bytes);
          final result = await const ContractRequestExecutor().execute(
            fixture.plan,
            OperationRequestDraft(
              planIdentity: fixture.plan.identity,
              body: RequestBodyDraft.binaryFile(
                mediaType: _iso,
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
            result.outgoing.valid,
            true,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.received.complete,
            true,
            reason: '${result.received.findings}',
          );
          expect(
            result.received.valid,
            true,
            reason: '${result.received.findings}',
          );
          _wire(seen.single, _iso, bytes);
          expect(await result.response.decodedBytes(), bytes);
          for (final (media, text, code) in [
            ('text/plain; charset=us-ascii', 'é', 'request.charset'),
            (
              'text/plain; charset=shift_jis',
              'plain',
              'request.charset.unsupported',
            ),
            (
              'application/json; charset=iso-8859-1',
              '"café"',
              'request.charset.unsupported',
            ),
            (
              'text/event-stream; charset=iso-8859-1',
              'data: café\n\n',
              'request.charset.unsupported',
            ),
          ]) {
            for (final preview in [false, true]) {
              await expectLater(
                const ContractRequestBuilder().build(
                  fixture.plan,
                  _draft(fixture.plan, media, text),
                  resolveSecret: (_) async => null,
                  previewOnly: preview,
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    code,
                  ),
                ),
              );
            }
          }
          expect(seen, hasLength(1));
          await File('${temp.path}/busyapi.yaml').writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                {
                  'name': 'unsupported-charset',
                  'operation': {'method': 'post', 'path': '/data'},
                  'body': {
                    'mediaType': 'text/plain; charset=shift_jis',
                    'value': 'plain',
                  },
                  'expect': {'status': 200},
                },
              ],
            }),
          );
          final cli = await runCliWithSecrets([
            'test',
            temp.path,
            '--case',
            'unsupported-charset',
            '--json',
          ], const {});
          expect(cli.code, 2, reason: '${cli.output}\n${cli.error}');
          final report = jsonDecode(cli.output) as Map;
          expect(report['complete'], false, reason: cli.output);
          expect(report['status'], 'incomplete');
          final failed = (report['cases'] as List).single as Map;
          expect(failed['dispatched'], false);
          expect(failed['operationalFailure'], false);
          expect(
            (failed['findings'] as List).whereType<Map>().map(
              (finding) => finding['code'],
            ),
            contains('request.charset.unsupported'),
          );
          expect(seen, hasLength(1));
          expect(await upload.readAsBytes(), bytes);
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.original),
          ]);
          expect(await fixture.shared.readAsString(), fixture.sharedText);
        },
      );
    }
  }
}
