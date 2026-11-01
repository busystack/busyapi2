import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _root(String version, String format) {
  final swagger = version == '2.0';
  if (format == 'yaml') {
    return '\uFEFF# Retain native root organization\r\n'
        '${swagger ? 'swagger' : 'openapi'}: "$version"\r\n'
        'info: {title: Original, version: api-version}\r\n'
        '${swagger ? 'produces: [application/json]\r\n' : ''}'
        'paths:\r\n  /data:\r\n    get:\r\n      responses:\r\n'
        '        "200":\r\n          description: Generated\r\n'
        '${swagger ? '          schema: {\$ref: "./model.yaml#/Schema"}\r\n' : '          content:\r\n            application/json:\r\n              schema: {\$ref: "./model.yaml#/Schema"}\r\n'}';
  }
  final schema = {r'$ref': './model.json#/Schema'};
  return '\uFEFF${jsonEncode({
    swagger ? 'swagger' : 'openapi': version,
    'info': {'title': 'Original', 'version': 'api-version'},
    if (swagger) 'produces': ['application/json'],
    'paths': {
      '/data': {
        'get': {
          'responses': {
            '200': {
              'description': 'Generated',
              if (swagger) 'schema': schema else 'content': {
                  'application/json': {'schema': schema},
                },
            },
          },
        },
      },
    },
  })}\r\n';
}

String _model(String format, {bool nested = false}) => format == 'yaml'
    ? '\uFEFF# Retain shared comments, aliases and Unicode 雪\r\n'
          'Schema: &schema\r\n'
          '${nested ? '  type: object\r\n  required: [id]\r\n  properties:\r\n    id: {type: integer, enum: [9007199254740992.00]}\r\n  additionalProperties: false\r\n' : '  type: integer\r\n  default: 9007199254740992.00\r\n'}'
          'Alias: *schema\r\nx-literal: {\$ref: literal, zero: 0, false: false}\r\n'
    : '\uFEFF{"Schema":${nested ? '{"type":"object","required":["id"],"properties":{"id":{"type":"integer","enum":[9007199254740992.00]}},"additionalProperties":false}' : '{"type":"integer","default":9007199254740992.00}'},'
          '"x-literal":{"\$ref":"literal","zero":0,"false":false,"text":"雪"}}\r\n';

Future<void> _wire(HttpClient client, Uri base, String expected) async {
  final request = await client.getUrl(base.resolve('/data'));
  final response = await request.close();
  final bytes = await response.fold<List<int>>(
    [],
    (bytes, chunk) => bytes..addAll(chunk),
  );
  expect(response.statusCode, 200, reason: utf8.decode(bytes));
  expect(bytes, utf8.encode(expected));
  expect(response.contentLength, bytes.length);
  expect(response.headers.contentType?.mimeType, 'application/json');
  expect(
    response.headers.value('busyapi-response-validation-complete'),
    'true',
  );
  expect(jsonDecode(response.headers.value('sl-violations') ?? '[]'), isEmpty);
}

class _CliMock {
  _CliMock(this.process, this.errors, this.lines);
  final Process process;
  final Future<String> errors;
  final StreamSubscription<String> lines;
  late Uri base;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    process.kill(ProcessSignal.sigterm);
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      expect(code, 0, reason: await errors);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      fail('The installed CLI mock did not finish its owned shutdown');
    } finally {
      await lines.cancel();
    }
  }
}

Future<_CliMock> _cli(String path) async {
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
  final owned = _CliMock(process, errors, lines);
  addTearDown(owned.close);
  unawaited(
    process.exitCode.then((code) async {
      if (!ready.isCompleted)
        ready.completeError(StateError('CLI exited $code: ${await errors}'));
    }),
  );
  final message = await ready.future.timeout(const Duration(seconds: 30));
  expect(message['status'], 'ready', reason: '$message');
  expect(message['input'], 'saved-source');
  expect(message['nativeGeneration'], {
    'name': 'busyapi-native-schema-samples',
    'version': '3',
    'configuration':
        'captured-schema-candidates-v3:${message['nativeValidation']['configuration']}',
  });
  final host = message['host'], port = message['port'];
  if (host is! String || port is! int)
    throw StateError('Malformed installed CLI address');
  owned.base = Uri(scheme: 'http', host: host, port: port);
  return owned;
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format exact bound generation uses captured buffers and the packaged CLI', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-mock-numeric-capture-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/api.$format');
        final fragment = File('${directory.path}/model.$format');
        final original = _root(version, format);
        final source = '${format == 'yaml' ? '# keep exact bounds\r\n' : ''}'
            '{"Schema":{"type":"integer","minimum":9007199254740993.00,"maximum":9007199254740993.00}}\r\n';
        await file.writeAsString(original);
        await fragment.writeAsString(source);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id;
        final model = await project.buffer(fragment.uri.toString());
        final working = source.replaceAll('9007199254740993.00', '9007199254740995.00');
        project.store.replace(model.id, working);
        await expectLater(project.prepareMock(root, cancelled: () => true),
            throwsA(isA<CoreFailure>().having((failure) => failure.code, 'code', 'cancelled')));
        final plan = await project.prepareMock(root);
        addTearDown(plan.close);
        final run = await plan.start(
          nodeExecutable: runtimeNode,
          helper: '$testBundle/libexec/busyapi/mock-server.cjs',
        );
        addTearDown(run.stop);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        await _wire(client, run.baseUri, '9007199254740995');
        project.store.replace(model.id, working.replaceAll('9007199254740995.00', '9007199254740997.00'));
        expect(run.outdated, true);
        await _wire(client, run.baseUri, '9007199254740995');
        await expectLater(plan.start(
          nodeExecutable: runtimeNode,
          helper: '$testBundle/libexec/busyapi/mock-server.cjs',
        ), throwsA(isA<CoreFailure>()));
        await run.stop();
        final cli = await _cli(file.path);
        addTearDown(cli.close);
        await _wire(client, cli.base, '9007199254740993');
        await cli.close();
        expect(await file.readAsString(), original);
        expect(await fragment.readAsString(), source);
        expect(model.dirty, true);
      });
    }
  }
  for (final version in [
    '3.0.0',
    '3.0.1',
    '3.0.2',
    '3.0.3',
    '3.0.4',
    '2.0',
    '3.1.0',
    '3.1.1',
    '3.1.2',
    '3.2.0',
    '3.2.1',
  ]) {
    for (final format in ['yaml', 'json']) {
      for (final nested in [false, true]) {
        test(
          '$version $format installed native samples use captured unsaved data and saved CLI source nested=$nested',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-native-samples-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final file = File('${directory.path}/api.$format');
            final fragment = File('${directory.path}/model.$format');
            await file.writeAsString(_root(version, format));
            await fragment.writeAsString(_model(format, nested: nested));
            String expected(String number) =>
                nested ? '{"id":$number}' : number;
            final original = file.readAsBytesSync(),
                originalModel = fragment.readAsBytesSync();
            File? manifest;
            if (format == 'yaml') {
              manifest = File('${directory.path}/busyapi.yaml');
              await manifest.writeAsString(
                'version: 1\r\n# Retain optional project\r\nroots: [{name: api, path: api.yaml}]\r\n',
              );
            }
            final originalManifest = manifest?.readAsBytesSync();
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final opening = manifest == null ? file.path : directory.path;
            var project = await BusyProject.open(opening, engine);
            addTearDown(() => project.close());
            final root = await project.buffer(file.uri.toString());
            final model = await project.buffer(fragment.uri.toString());
            final workingRoot = root.text.replaceFirst('Original', 'Captured');
            final workingModel = model.text.replaceFirst(
              '9007199254740992.00',
              '9007199254740993.00',
            );
            project.store.replace(root.id, workingRoot);
            project.store.replace(model.id, workingModel);
            final plan = await project.prepareMock(root.id);
            addTearDown(plan.close);
            final run = await plan.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            addTearDown(run.stop);
            expect(run.nativeGeneration.name, 'busyapi-native-schema-samples');
            expect(run.nativeGeneration.version, '3');
            expect(
              run.nativeGeneration.configuration,
              'captured-schema-candidates-v3:${run.nativeValidation.configuration}',
            );
            final client = HttpClient();
            addTearDown(() => client.close(force: true));
            await _wire(client, run.baseUri, expected('9007199254740993.00'));
            final laterModel = workingModel.replaceFirst(
              '9007199254740993.00',
              '9007199254740994.00',
            );
            project.store.replace(model.id, laterModel);
            expect(run.outdated, true);
            await _wire(client, run.baseUri, expected('9007199254740993.00'));
            await expectLater(
              plan.start(
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
            final saved = await _cli(opening);
            await _wire(client, saved.base, expected('9007199254740992.00'));
            await saved.close();
            final next = await project.prepareMock(root.id);
            addTearDown(next.close);
            final nextRun = await next.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            addTearDown(nextRun.stop);
            await _wire(
              client,
              nextRun.baseUri,
              expected('9007199254740994.00'),
            );
            expect(file.readAsBytesSync(), original);
            expect(fragment.readAsBytesSync(), originalModel);
            expect(manifest?.readAsBytesSync(), originalManifest);
            expect(root.dirty && model.dirty, true);
            await run.stop();
            await nextRun.stop();
            expect(
              (await PublicationStore(
                '${directory.path}/publication',
              ).save(project, [root, model])).complete,
              true,
            );
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(workingRoot),
            ]);
            expect(fragment.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(laterModel),
            ]);
            final after = await _cli(opening);
            await _wire(client, after.base, expected('9007199254740994.00'));
            await after.close();
            project.close();
            project = await BusyProject.open(opening, engine);
            expect((await project.buffer(root.id)).text, workingRoot);
            expect((await project.buffer(model.id)).text, laterModel);
            final reopened = await project.prepareMock(root.id);
            addTearDown(reopened.close);
            final reopenedRun = await reopened.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            addTearDown(reopenedRun.stop);
            await _wire(
              client,
              reopenedRun.baseUri,
              expected('9007199254740994.00'),
            );
            await reopenedRun.stop();
            expect(manifest?.readAsBytesSync(), originalManifest);
            if (manifest == null)
              expect(
                File('${directory.path}/busyapi.yaml').existsSync(),
                false,
              );
          },
        );
      }
    }
  }
}
