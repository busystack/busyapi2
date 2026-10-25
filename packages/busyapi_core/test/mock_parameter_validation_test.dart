import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _root(String version, String format) {
  final legacy = version == '2.0';
  if (format == 'yaml') {
    final schema = legacy
        ? 'type: integer, enum: [9007199254740992.00]'
        : 'schema: {type: integer, enum: [9007199254740992.00]}';
    return '\uFEFF# Retain native parameters 雪\r\n'
        '${legacy ? 'swagger' : 'openapi'}: "$version"\r\n'
        'info: {title: Captured parameters, version: api-version}\r\n'
        'paths:\r\n  /precise/{ID}:\r\n    post:\r\n'
        '      parameters:\r\n'
        '        - {name: ID, in: path, required: true, $schema}\r\n'
        '        - {\$ref: "./parameters.yaml#/Exact"}\r\n'
        '        - {name: X-Exact, in: header, required: true, $schema}\r\n'
        '      responses:\r\n        "204": {description: Accepted}\r\n';
  }
  final schema = <String, dynamic>{
    'type': 'integer',
    'enum': ['EXACT_VALUE'],
  };
  Map<String, dynamic> parameter(String name, String location) => {
    'name': name,
    'in': location,
    'required': true,
    if (legacy) ...schema else 'schema': schema,
  };
  return jsonEncode({
    if (legacy) 'swagger': version else 'openapi': version,
    'info': {'title': 'Captured parameters', 'version': 'api-version'},
    'paths': {
      '/precise/{ID}': {
        'post': {
          'parameters': [
            parameter('ID', 'path'),
            {r'$ref': './parameters.json#/Exact'},
            parameter('X-Exact', 'header'),
          ],
          'responses': {
            '204': {'description': 'Accepted'},
          },
        },
      },
    },
  }).replaceAll('"EXACT_VALUE"', '9007199254740992.00');
}

String _parameters(String version, String format) {
  final legacy = version == '2.0';
  if (format == 'yaml') {
    return '# Retain shared parameter\r\nExact: &parameter\r\n'
        '  name: N\r\n  in: query\r\n  required: true\r\n'
        '${legacy ? '  type: integer\r\n  enum: [9007199254740992.00]\r\n' : '  schema: {type: integer, enum: [9007199254740992.00]}\r\n'}';
  }
  const schema = '"type":"integer","enum":[9007199254740992.00]';
  return '{"Exact":{"name":"N","in":"query","required":true,'
      '${legacy ? schema : '"schema":{$schema}'}}}';
}

Future<({int status, List<dynamic> findings})> _send(
  HttpClient client,
  Uri base,
  String path, {
  String header = '9007199254740993',
}) async {
  final request = await client.postUrl(base.resolve(path));
  request.headers.set('x-exact', header);
  final response = await request.close();
  await response.drain<void>();
  return (
    status: response.statusCode,
    findings:
        jsonDecode(response.headers.value('sl-violations') ?? '[]') as List,
  );
}

Future<Uri> _startCli(String path) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    ['mock', path, '--port', '0', '--json'],
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
      if (!ready.isCompleted)
        ready.completeError(StateError('CLI exited $code: ${await errors}'));
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
    (message['nativeParameterValidation'] as Map)['name'],
    'busyapi-native-parameters',
  );
  return Uri(
    scheme: 'http',
    host: message['host'] as String,
    port: message['port'] as int,
  );
}

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    test(
      '$version installed CLI enforces native parameter assertions offline',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-mock-parameters-cli-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final source = _root(
          version,
          'json',
        ).replaceAll('9007199254740992.00', '9007199254740993.00');
        final external = _parameters(
          version,
          'json',
        ).replaceAll('9007199254740992.00', '9007199254740993.00');
        final file = File('${temp.path}/api.json');
        final shared = File('${temp.path}/parameters.json');
        await file.writeAsString(source);
        await shared.writeAsString(external);
        final base = await _startCli(file.path);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        expect(
          (await _send(
            client,
            base,
            '/precise/9007199254740993?N=9007199254740993',
          )).status,
          204,
        );
        final invalid = await _send(
          client,
          base,
          '/precise/9007199254740993?N=9007199254740992',
        );
        expect(invalid.status, 422);
        expect(
          invalid.findings.whereType<Map>().any(
            (finding) =>
                finding['nativeCode'] == 'runtime.schema.incompatible' &&
                (finding['location'] as List).contains('query:N') &&
                finding['source']['resource'] == shared.uri.toString(),
          ),
          true,
        );
        expect(await file.readAsString(), source);
        expect(await shared.readAsString(), external);
      },
    );
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format mock checks captured unsaved parameter sources',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-mock-parameters-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final original = _root(version, format);
          final external = _parameters(version, format);
          final file = File('${temp.path}/api.$format');
          final sharedFile = File('${temp.path}/parameters.$format');
          await file.writeAsString(original);
          await sharedFile.writeAsString(external);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = await project.buffer(file.uri.toString());
          final shared = await project.buffer(sharedFile.uri.toString());
          final originalText = root.text;
          final working = originalText.replaceAll(
            '9007199254740992.00',
            '9007199254740993.00',
          );
          final workingShared = shared.text.replaceAll(
            '9007199254740992.00',
            '9007199254740993.00',
          );
          project.store.replace(root.id, working);
          project.store.replace(shared.id, workingShared);
          final plan = await project.prepareMock(root.id);
          addTearDown(plan.close);
          final run = await plan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(run.stop);
          expect(
            run.nativeParameterValidation.name,
            'busyapi-native-parameters',
          );
          expect(run.nativeParameterValidation.version, '3');
          expect(
            run.nativeParameterValidation.configuration,
            'parameter-wire-v3:${run.nativeValidation.configuration}',
          );
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final valid = await _send(
            client,
            run.baseUri,
            '/precise/9007199254740993?N=9007199254740993.000',
          );
          expect(valid.status, 204);
          expect(valid.findings, isEmpty);
          for (final (path, header, location, source) in [
            (
              '/precise/9007199254740992?N=9007199254740993',
              '9007199254740993',
              'path:ID',
              root.id,
            ),
            (
              '/precise/9007199254740993?N=9007199254740992',
              '9007199254740993',
              'query:N',
              shared.id,
            ),
            (
              '/precise/9007199254740993?N=9007199254740993',
              '9007199254740992',
              'header:X-Exact',
              root.id,
            ),
          ]) {
            final invalid = await _send(
              client,
              run.baseUri,
              path,
              header: header,
            );
            expect(invalid.status, 422);
            expect(
              invalid.findings.whereType<Map>().any(
                (finding) =>
                    finding['nativeCode'] == 'runtime.schema.incompatible' &&
                    (finding['location'] as List).contains(location) &&
                    (finding['source'] as Map)['resource'] == source,
              ),
              true,
              reason: '$location: ${invalid.findings}',
            );
          }
          expect(
            (await _send(
              client,
              run.baseUri,
              '/precise/9007199254740993?n=9007199254740993',
            )).status,
            422,
          );
          expect(root.text, working);
          expect(shared.text, workingShared);
          expect(await file.readAsBytes(), utf8.encode(original));
          expect(await sharedFile.readAsBytes(), utf8.encode(external));
          project.store.replace(root.id, originalText);
          project.store.replace(shared.id, external);
          expect(run.outdated, true);
          expect(
            (await _send(
              client,
              run.baseUri,
              '/precise/9007199254740993?N=9007199254740993',
            )).status,
            204,
          );
          await expectLater(
            plan.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            ),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'mock.stale',
              ),
            ),
          );
          await project.save(root);
          await project.save(shared);
          expect(await file.readAsBytes(), utf8.encode(original));
          expect(await sharedFile.readAsBytes(), utf8.encode(external));
        },
      );
    }
  }
}
