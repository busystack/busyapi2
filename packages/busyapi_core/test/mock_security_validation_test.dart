import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

(String, String) _sources(String version, String format) {
  if (format == 'yaml') {
    return (
      '\uFEFF# Retain native authentication\r\n'
          '${version == '2.0' ? 'swagger' : 'openapi'}: "$version"\r\n'
          'info: {title: Captured security, version: api-version}\r\n'
          '${version == '2.0' ? 'securityDefinitions:\r\n  Key:' : 'components:\r\n  securitySchemes:\r\n    Key:'} {type: apiKey, in: header, name: X-Old}\r\n'
          'paths:\r\n  /secure: {\$ref: "shared.yaml#/Secure"}\r\n  /public: {\$ref: "shared.yaml#/Public"}\r\n'
          'x-literal: {\$ref: "shared.yaml#/Literal", n: 9007199254740993.00}\r\n',
      '# Retain shared operation\r\nSecure: &secure\r\n  get:\r\n    summary: Before\r\n    security: [{Key: []}]\r\n    responses: {"204": {description: Empty}}\r\n'
          'Public:\r\n  get:\r\n    security: [{}, {Key: []}]\r\n    responses: {"204": {description: Empty}}\r\n',
    );
  }
  return (
    jsonEncode({
      if (version == '2.0') 'swagger': version else 'openapi': version,
      'info': {'title': 'Captured security', 'version': 'api-version'},
      if (version == '2.0')
        'securityDefinitions': {
          'Key': {'type': 'apiKey', 'in': 'header', 'name': 'X-Old'},
        }
      else
        'components': {
          'securitySchemes': {
            'Key': {'type': 'apiKey', 'in': 'header', 'name': 'X-Old'},
          },
        },
      'paths': {
        '/secure': {r'$ref': 'shared.json#/Secure'},
        '/public': {r'$ref': 'shared.json#/Public'},
      },
      'x-literal': {r'$ref': 'shared.json#/Literal', 'n': 'EXACT'},
    }).replaceFirst('"EXACT"', '9007199254740993.00'),
    jsonEncode({
      'Secure': {
        'get': {
          'summary': 'Before',
          'security': [
            {'Key': <String>[]},
          ],
          'responses': {
            '204': {'description': 'Empty'},
          },
        },
      },
      'Public': {
        'get': {
          'security': [
            <String, Object?>{},
            {'Key': <String>[]},
          ],
          'responses': {
            '204': {'description': 'Empty'},
          },
        },
      },
    }),
  );
}

Future<({int status, List<Map> findings, String? complete})> _send(
  HttpClient client,
  Uri base,
  String path,
  Map<String, String> headers,
) async {
  final request = await client.getUrl(base.resolve(path));
  headers.forEach(request.headers.set);
  final response = await request.close();
  await response.drain<void>();
  return (
    status: response.statusCode,
    findings: (jsonDecode(
      response.headers.value('sl-violations') ?? '[]',
    ) as List).cast<Map>(),
    complete: response.headers.value('busyapi-request-security-complete'),
  );
}

Future<Uri> _cli(String path) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    ['mock', path, '--port', '0', '--json'],
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  final ready = Completer<Map>();
  final errors = process.stderr.transform(utf8.decoder).join();
  final lines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (ready.isCompleted) return;
        try {
          final value = jsonDecode(line);
          if (value is Map) ready.complete(value);
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
  expect(message['input'], 'saved-source');
  final identity = message['nativeSecurityValidation'] as Map;
  expect(identity['name'], 'busyapi-native-security');
  expect(identity['version'], '1');
  expect(identity['configuration'], startsWith('security-wire-v1:'));
  return Uri(
    scheme: 'http',
    host: message['host'] as String,
    port: message['port'] as int,
  );
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format native mocks retain captured security and original shared source locations',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-native-mock-security-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final sources = _sources(version, format),
              file = File('${directory.path}/api.$format'),
              sharedFile = File('${directory.path}/shared.$format');
          await file.writeAsString(sources.$1);
          await sharedFile.writeAsString(sources.$2);
          final original = file.readAsBytesSync(),
              originalShared = sharedFile.readAsBytesSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = await project.buffer(file.uri.toString()),
              shared = await project.buffer(sharedFile.uri.toString());
          final workingRoot = root.text.replaceFirst('X-Old', 'X-Current'),
              workingShared = shared.text.replaceFirst('Before', 'Captured');
          project.store.replace(root.id, workingRoot);
          project.store.replace(shared.id, workingShared);
          final plan = await project.prepareMock(root.id);
          addTearDown(plan.close);
          final run = await plan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(run.stop);
          expect(run.nativeSecurityValidation.name, 'busyapi-native-security');
          expect(run.nativeSecurityValidation.version, '1');
          expect(
            run.nativeSecurityValidation.configuration,
            'security-wire-v1:${run.nativeValidation.configuration}',
          );
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final valid = await _send(client, run.baseUri, '/secure', {
            'X-Current': 'synthetic-private-value',
          });
          expect(valid.status, 204);
          expect(valid.findings, isEmpty);
          expect(valid.complete, 'true');
          for (final headers in [
            <String, String>{},
            {'X-Old': 'synthetic-private-value'},
          ]) {
            final invalid = await _send(
              client,
              run.baseUri,
              '/secure',
              headers,
            );
            expect(invalid.status, 401);
            expect(invalid.complete, 'true');
            final finding = invalid.findings.singleWhere(
              (value) =>
                  value['nativeCode'] == 'runtime.request.security.required',
            );
            final source = finding['source'] as Map;
            expect(source['resource'], shared.id);
            expect(source['pointer'], '/Secure/get/security/0');
            expect(source['snapshot'], plan.snapshot.identity);
            final range = source['range'] as List;
            expect(
              workingShared.substring(range[0] as int, range[1] as int),
              contains('Key'),
            );
            expect(
              jsonEncode(invalid.findings),
              isNot(contains('synthetic-private-value')),
            );
          }
          expect(
            (await _send(client, run.baseUri, '/public', {
              'Authorization': 'Bearer synthetic-private-value',
            })).status,
            204,
          );
          project.store.replace(
            root.id,
            workingRoot.replaceFirst('X-Current', 'X-Later'),
          );
          project.store.replace(
            shared.id,
            workingShared.replaceFirst('Captured', 'Later'),
          );
          expect(run.outdated, true);
          expect(
            (await _send(client, run.baseUri, '/secure', {
              'X-Current': 'synthetic-private-value',
            })).status,
            204,
          );
          expect(
            (await _send(client, run.baseUri, '/secure', {
              'X-Later': 'synthetic-private-value',
            })).status,
            401,
          );
          final saved = await _cli(file.path);
          expect(
            (await _send(client, saved, '/secure', {
              'X-Old': 'synthetic-private-value',
            })).status,
            204,
          );
          expect(
            (await _send(client, saved, '/secure', {
              'X-Current': 'synthetic-private-value',
            })).status,
            401,
          );
          expect(file.readAsBytesSync(), original);
          expect(sharedFile.readAsBytesSync(), originalShared);
          expect(root.dirty, true);
          expect(shared.dirty, true);
        },
      );
    }
  }
  for (final corruption in ['name', 'version']) {
    test('an unrelated native security $corruption cannot report a ready mock', () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-security-protocol-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.json')
        ..writeAsStringSync(
          '{"openapi":"3.0.4","info":{"title":"Protocol","version":"1"},"paths":{"/p":{"get":{"responses":{"204":{"description":"Empty"}}}}}}',
        );
      final original = file.readAsBytesSync();
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final plan = await project.prepareMock(file.uri.toString());
      addTearDown(plan.close);
      final backend = await Directory('${directory.path}/backend').create();
      await File(runtimeHelper).copy('${backend.path}/engine.cjs');
      final source = await File('$testBundle/libexec/busyapi/mock-server.cjs')
          .readAsString();
      const marker = 'name: "busyapi-native-security", version: "1"';
      expect(source.split(marker), hasLength(2));
      final pidFile = File('${backend.path}/pid');
      final helper = File('${backend.path}/mock-server.cjs');
      final changed = source.replaceFirst(
        marker,
        corruption == 'name'
            ? 'name: "unrelated-security", version: "1"'
            : 'name: "busyapi-native-security", version: "unqualified"',
      );
      await helper.writeAsString(
        'require("node:fs").writeFileSync(${jsonEncode(pidFile.path)}, String(process.pid));\n$changed',
      );
      await expectLater(
        plan.start(nodeExecutable: runtimeNode, helper: helper.path),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'mock.readiness',
          ),
        ),
      );
      final pid = int.parse(await pidFile.readAsString());
      final clock = Stopwatch()..start();
      while (await File('/proc/$pid/cmdline').exists() &&
          clock.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        await File('/proc/$pid/cmdline').exists(),
        false,
        reason: 'The rejected backend must leave no owned listener process',
      );
      expect(file.readAsBytesSync(), original);
    });
  }
}
