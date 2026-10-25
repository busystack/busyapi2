import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _root(String version, String format) {
  final legacy = version == '2.0';
  if (format == 'yaml') {
    return '\uFEFF# Retain response source 雪\r\n'
        '${legacy ? 'swagger' : 'openapi'}: "$version"\r\n'
        'info: {title: Captured responses, version: api-version}\r\n'
        '${legacy ? 'produces: [application/json]\r\n' : ''}'
        'paths:\r\n  /data:\r\n    post:\r\n      responses:\r\n'
        '        "200":\r\n          description: Actual response\r\n'
        '          headers:\r\n            X-Exact:\r\n'
        '${legacy ? '              type: integer\r\n              enum: [9007199254740992.00]\r\n' : '              schema: {type: integer, enum: [9007199254740992.00]}\r\n'}'
        '${legacy ? '          schema: {\$ref: "./model.yaml#/Schema"}\r\n' : '          content:\r\n            application/json:\r\n              schema: {\$ref: "./model.yaml#/Schema"}\r\n'}';
  }
  final schema = {
    'type': 'integer',
    'enum': ['EXACT_VALUE'],
  };
  return jsonEncode({
    if (legacy) 'swagger': version else 'openapi': version,
    'info': {'title': 'Captured responses', 'version': 'api-version'},
    if (legacy) 'produces': ['application/json'],
    'paths': {
      '/data': {
        'post': {
          'responses': {
            '200': {
              'description': 'Actual response',
              'headers': {
                'X-Exact': legacy ? schema : {'schema': schema},
              },
              if (legacy)
                'schema': {r'$ref': './model.json#/Schema'}
              else
                'content': {
                  'application/json': {
                    'schema': {r'$ref': './model.json#/Schema'},
                  },
                },
            },
          },
        },
      },
    },
  }).replaceAll('"EXACT_VALUE"', '9007199254740992.00');
}

String _model(String format) => format == 'yaml'
    ? '# Retain shared model\r\nSchema: &schema\r\n  type: integer\r\n  enum: [9007199254740992.00]\r\n'
    : '{"Schema":{"type":"integer","enum":[9007199254740992.00]}}';

Future<({int status, String text, List<dynamic> findings, String? complete})>
_send(HttpClient client, Uri uri) async {
  final request = await client.postUrl(uri);
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  return (
    status: response.statusCode,
    text: text,
    findings:
        jsonDecode(response.headers.value('sl-violations') ?? '[]') as List,
    complete: response.headers.value('busyapi-response-validation-complete'),
  );
}

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format packaged proxy checks captured unsaved responses',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-mock-responses-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final original = _root(version, format), model = _model(format);
          final file = File('${temp.path}/api.$format');
          final fragment = File('${temp.path}/model.$format');
          await file.writeAsString(original);
          await fragment.writeAsString(model);
          final upstream = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(() => upstream.close(force: true));
          final received = <(String, String, List<int>)>[];
          final subscription = upstream.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            received.add((request.method, request.uri.path, bytes));
            final valid = request.uri.queryParameters.containsKey('valid');
            request.response.headers.contentType = ContentType.json;
            request.response.headers.set(
              'x-exact',
              valid ? '9007199254740993.000' : '9007199254740992',
            );
            request.response.write(
              valid ? '9007199254740993.000' : '9007199254740992',
            );
            await request.response.close();
          });
          addTearDown(subscription.cancel);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          final shared = await project.buffer(fragment.uri.toString());
          final originalText = buffer.text;
          expect(buffer.hasBom, format == 'yaml');
          expect(buffer.bytes(), utf8.encode(original));
          final working = originalText.replaceAll(
            '9007199254740992.00',
            '9007199254740993.00',
          );
          final workingModel = model.replaceAll(
            '9007199254740992.00',
            '9007199254740993.00',
          );
          project.store.replace(buffer.id, working);
          project.store.replace(shared.id, workingModel);
          final plan = await project.prepareMock(buffer.id);
          addTearDown(plan.close);
          final run = await plan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            proxyTarget: Uri.parse('http://127.0.0.1:${upstream.port}'),
          );
          addTearDown(run.stop);
          expect(run.upstreamForwarding, true);
          expect(run.nativeResponseValidation.name, 'busyapi-native-response');
          expect(run.nativeResponseValidation.version, '1');
          expect(
            run.nativeResponseValidation.configuration,
            startsWith('response-wire-v1:'),
          );
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final valid = await _send(client, run.baseUri.resolve('/data?valid'));
          expect(valid.status, 200);
          expect(valid.text, '9007199254740993.000');
          expect(valid.complete, 'true');
          expect(valid.findings, isEmpty);
          final invalid = await _send(client, run.baseUri.resolve('/data'));
          expect(invalid.status, 200);
          expect(invalid.text, '9007199254740992');
          expect(invalid.complete, 'true');
          for (final subject in ['response-body', 'response-header']) {
            expect(
              invalid.findings.whereType<Map>().any(
                (finding) =>
                    finding['code'] == 'runtime.schema.incompatible' &&
                    (finding['location'] as List).contains(subject) &&
                    (finding['source'] as Map)['resource'] == buffer.id,
              ),
              true,
              reason: '$subject: ${invalid.findings}',
            );
          }
          expect(received, hasLength(2));
          for (final call in received) {
            expect(call.$1, 'POST');
            expect(call.$2, '/data');
            expect(call.$3, isEmpty);
          }
          expect(buffer.text, working);
          expect(shared.text, workingModel);
          expect(await file.readAsBytes(), utf8.encode(original));
          expect(await fragment.readAsBytes(), utf8.encode(model));
          project.store.replace(buffer.id, originalText);
          project.store.replace(shared.id, model);
          expect(run.outdated, true);
          expect(
            (await _send(client, run.baseUri.resolve('/data?valid'))).findings,
            isEmpty,
            reason: 'A running mock retains its coherent captured graph',
          );
          await project.save(buffer);
          await project.save(shared);
          expect(await file.readAsBytes(), utf8.encode(original));
          expect(await fragment.readAsBytes(), utf8.encode(model));
        },
      );
    }
    test('$version installed CLI proxy checks actual response bytes', () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-mock-responses-cli-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final source = _root(
        version,
        'json',
      ).replaceAll('9007199254740992.00', '9007199254740993.00');
      final file = File('${temp.path}/api.json');
      await file.writeAsString(source);
      await File('${temp.path}/model.json').writeAsString(
        _model('json').replaceAll('9007199254740992.00', '9007199254740993.00'),
      );
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      final subscription = upstream.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-exact', '9007199254740992');
        request.response.write('9007199254740992');
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final process = await Process.start(
        '$testBundle/busyapi',
        [
          'mock',
          file.path,
          '--proxy',
          'http://127.0.0.1:${upstream.port}',
          '--port',
          '0',
          '--json',
        ],
        environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
        includeParentEnvironment: false,
      );
      final ready = Completer<Map<String, dynamic>>();
      final errors = process.stderr.transform(utf8.decoder).join();
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (ready.isCompleted) return;
            try {
              final value = jsonDecode(line);
              if (value is Map<String, dynamic>) ready.complete(value);
            } on FormatException catch (error) {
              ready.completeError(error);
            }
          });
      unawaited(
        process.exitCode.then((code) async {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('CLI exited $code: ${await errors}'),
            );
          }
        }),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
        await lines.cancel();
        await errors;
      });
      final message = await ready.future.timeout(const Duration(seconds: 30));
      expect(message['status'], 'ready');
      expect(
        (message['nativeResponseValidation'] as Map)['name'],
        'busyapi-native-response',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await _send(
        client,
        Uri(
          scheme: 'http',
          host: message['host'] as String,
          port: message['port'] as int,
          path: '/data',
        ),
      );
      expect(response.status, 200);
      expect(response.text, '9007199254740992');
      expect(response.complete, 'true');
      expect(
        response.findings.whereType<Map>().where(
          (finding) => finding['code'] == 'runtime.schema.incompatible',
        ),
        hasLength(2),
      );
      expect(await file.readAsString(), source);
      process.kill(ProcessSignal.sigterm);
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
    });
    test(
      '$version native request execution rejects invalid default response statuses',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-default-status-',
        );
        addTearDown(() => temp.delete(recursive: true));
        var status = 600;
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => upstream.close(force: true));
        final subscription = upstream.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = status;
          request.response.headers.contentType = ContentType.json;
          request.response.write('0');
          await request.response.close();
        });
        addTearDown(subscription.cancel);
        final legacy = version == '2.0';
        final schema = {
          'type': 'integer',
          'enum': [0],
        };
        final original = jsonEncode({
          if (legacy) 'swagger': version else 'openapi': version,
          'info': {'title': 'Actual default response', 'version': '1'},
          if (legacy) ...{
            'host': '127.0.0.1:${upstream.port}',
            'schemes': ['http'],
            'produces': ['application/json'],
          } else
            'servers': [
              {'url': 'http://127.0.0.1:${upstream.port}'},
            ],
          'paths': {
            '/data': {
              'post': {
                'responses': {
                  'default': {
                    'description': 'Other HTTP statuses',
                    if (legacy)
                      'schema': schema
                    else
                      'content': {
                        'application/json': {'schema': schema},
                      },
                  },
                },
              },
            },
          },
        });
        final file = File('${temp.path}/api.json');
        await file.writeAsString(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final plan = await project.prepareRequest(
          file.uri.toString(),
          resource: file.uri.toString(),
          pointer: '/paths/~1data/post',
        );
        addTearDown(plan.close);
        for (final code in [201, 600, 999]) {
          status = code;
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(planIdentity: plan.identity),
            resolveSecret: (_) async => null,
          );
          try {
            expect(result.response.status, code);
            expect(await result.response.bytes(), utf8.encode('0'));
            expect(result.received.complete, true);
            expect(result.conforming, code == 201);
            expect(
              result.received.findings.any(
                (finding) =>
                    finding['code'] == 'runtime.response.status.invalid',
              ),
              code != 201,
            );
          } finally {
            await result.close();
          }
        }
        await File('${temp.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots: [{name: api, path: api.json}]\n'
          'tests: [{name: status, operation: {method: POST, path: /data}}]\n',
        );
        for (final code in [201, 600]) {
          status = code;
          final cli = await runCliWithSecrets([
            'test',
            temp.path,
            '--case',
            'status',
            '--json',
          ], {});
          expect(
            cli.code,
            code == 201 ? 0 : 1,
            reason: '${cli.output}\n${cli.error}',
          );
          final report = jsonDecode(cli.output) as Map;
          expect(report['complete'], true);
          expect((report['cases'] as List).single['passed'], code == 201);
          expect(
            cli.output.contains('runtime.response.status.invalid'),
            code != 201,
          );
        }
        expect(await file.readAsString(), original);
      },
    );
  }
}
