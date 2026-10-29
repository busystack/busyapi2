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

Future<
  ({BusyProject project, OperationRequestPlan plan, File file, String source})
>
_open(
  Directory temp,
  HttpServer server,
  String version,
  String format,
  String method,
) async {
  final legacy = version == '2.0';
  final schema = {
    'type': 'string',
    'enum': ['', 'false', 'null', '0', 'café', 'café 雪😀'],
  };
  final content = {
    'text/plain': {'schema': schema},
  };
  final operation = {
    if (method == 'post')
      if (legacy)
        'parameters': [
          {'name': 'payload', 'in': 'body', 'required': true, 'schema': schema},
        ]
      else
        'requestBody': {'required': true, 'content': content},
    'responses': {
      '200': {
        'description': 'Reply',
        if (legacy) 'schema': schema else 'content': content,
      },
    },
  };
  final document = {
    legacy ? 'swagger' : 'openapi': version,
    'info': {'title': 'Original plain text', 'version': 'business'},
    if (legacy) ...{
      'host': '127.0.0.1:${server.port}',
      'basePath': '/v1',
      'schemes': ['http'],
      'consumes': ['text/plain'],
      'produces': ['text/plain'],
    } else
      'servers': [
        {'url': 'http://127.0.0.1:${server.port}/v1'},
      ],
    'paths': {
      '/data': {method: operation},
    },
    'x-number': 'EXACT',
  };
  final source =
      '${format == 'yaml' ? '# Keep source\r\n' : ''}'
      '${jsonEncode(document).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
  final file = File('${temp.path}/api.$format');
  await file.writeAsBytes([239, 187, 191, ...utf8.encode(source)]);
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  addTearDown(engine.close);
  final project = await BusyProject.open(file.path, engine);
  addTearDown(project.close);
  final buffer = await project.buffer(file.uri.toString());
  project.store.replace(buffer.id, source.replaceFirst('Original', 'Unsaved'));
  final checked = await project.check(buffer.id);
  expect(checked['complete'], true, reason: '$checked');
  expect(
    (checked['findings'] as List).whereType<Map>().where(
      (finding) => finding['severity'] == 'error',
    ),
    isEmpty,
    reason: '$checked',
  );
  final plan = await project.prepareRequest(
    buffer.id,
    resource: buffer.id,
    pointer: '/paths/~1data/$method',
  );
  addTearDown(plan.close);
  return (project: project, plan: plan, file: file, source: source);
}

Future<void> _manifest(
  Directory temp,
  String format,
  List<Map<String, Object?>> cases,
) => File('${temp.path}/busyapi.yaml').writeAsString(
  jsonEncode({
    'version': 1,
    'roots': [
      {'name': 'api', 'path': 'api.$format'},
    ],
    'tests': cases,
  }),
);

void main() {
  for (final version in _patches) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format non-ASCII raw text declares UTF-8 without changing its bytes',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-plain-send-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <(String?, List<int>)>[];
          server.listen((request) async {
            expect(request.method, 'POST');
            expect(request.uri.toString(), '/v1/data');
            final bytes = await request.fold<List<int>>(
              [],
              (all, next) => all..addAll(next),
            );
            seen.add((request.headers.contentType!.charset, bytes));
            request.response.headers.set(
              'content-type',
              request.headers.value('content-type')!,
            );
            request.response.add(bytes);
            await request.response.close();
          });
          final fixture = await _open(temp, server, version, format, 'post');
          for (final (text, charset) in [
            ('café 雪😀', 'utf-8'),
            ('false', null),
            ('', null),
          ]) {
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
              seen.last.$1,
              charset,
              reason: 'RFC 6657 §4 retains US-ASCII for a bare text/plain Content-Type.',
            );
            expect(seen.last.$2, utf8.encode(text));
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
            expect(await result.response.decodedBytes(), utf8.encode(text));
          }
          await _manifest(temp, format, [
            {
              'name': 'unicode',
              'operation': {'method': 'post', 'path': '/data'},
              'body': {'mediaType': 'text/plain', 'value': 'café 雪😀'},
              'expect': {'status': 200},
            },
          ]);
          final cli = await runCliWithSecrets([
            'test',
            temp.path,
            '--case',
            'unicode',
            '--json',
          ], const {});
          expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
          expect((jsonDecode(cli.output) as Map)['complete'], true);
          expect(seen, hasLength(4));
          expect(seen.last.$1, 'utf-8');
          expect(seen.last.$2, utf8.encode('café 雪😀'));
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.source),
          ]);
          expect(
            fixture.project.store.get(fixture.file.uri.toString()).text,
            fixture.source.replaceFirst('Original', 'Unsaved'),
          );
        },
      );
      test(
        '$version $format bare text/plain rejects non-ASCII response octets without losing them',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-plain-receive-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final representations = <String, (String, List<int>, bool)>{
            'ascii': ('text/plain', ascii.encode('false'), true),
            'utf8-bare': ('text/plain', utf8.encode('café'), false),
            'latin1-bare': ('text/plain', latin1.encode('café'), false),
            'utf8': ('text/plain; charset=utf-8', utf8.encode('café'), true),
            'latin1': (
              'text/plain; charset=iso-8859-1',
              latin1.encode('café'),
              true,
            ),
            'null': ('text/plain', ascii.encode('null'), true),
            'empty': ('text/plain', [], true),
          };
          var observed = 0;
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/v1/data');
            await request.drain<void>();
            final selected =
                representations[request.headers.value('x-fixture-mode')]!;
            request.response.headers.set('content-type', selected.$1);
            request.response.add(selected.$2);
            observed++;
            await request.response.close();
          });
          final fixture = await _open(temp, server, version, format, 'get');
          for (final entry in representations.entries) {
            final result = await const ContractRequestExecutor().execute(
              fixture.plan,
              OperationRequestDraft(
                planIdentity: fixture.plan.identity,
                headers: [RequestHeaderValue('x-fixture-mode', entry.key)],
              ),
              resolveSecret: (_) async => null,
            );
            addTearDown(result.close);
            expect(result.outgoing.complete, true);
            expect(result.outgoing.valid, true);
            expect(
              result.received.complete,
              true,
              reason: '${result.received.findings}',
            );
            expect(
              result.received.valid,
              entry.value.$3,
              reason: 'RFC 6657 §4: ${entry.key}; ${result.received.findings}',
            );
            if (!entry.value.$3) {
              expect(
                result.received.findings.any(
                  (finding) =>
                      finding['code'] == 'runtime.response.body.encoding' ||
                      finding['code'] == 'runtime.media.charset',
                ),
                true,
              );
            }
            expect(await result.response.decodedBytes(), entry.value.$2);
          }
          await _manifest(temp, format, [
            {
              'name': 'bare-utf8',
              'operation': {'method': 'get', 'path': '/data'},
              'headers': {'x-fixture-mode': 'utf8-bare'},
              'expect': {'status': 200},
            },
          ]);
          final cli = await runCliWithSecrets([
            'test',
            temp.path,
            '--case',
            'bare-utf8',
            '--json',
          ], const {});
          expect(cli.code, 1, reason: '${cli.output}\n${cli.error}');
          final report = jsonDecode(cli.output) as Map;
          expect(report['complete'], true, reason: cli.output);
          final selected = (report['cases'] as List).single as Map;
          expect(selected['passed'], false);
          expect(selected['dispatched'], true);
          expect(selected['operationalFailure'], false);
          expect(observed, representations.length + 1);
          expect(await fixture.file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(fixture.source),
          ]);
        },
      );
    }
  }
}
