import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _versions = ['3.0.0', '3.0.1', '3.0.2', '3.0.3', '3.0.4',
  '3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1'];

String _source(String version, String format, String external, String mediaType,
    {String? server}) {
  final schema = mediaType == 'application/json'
      ? {'type': 'object', 'required': ['n'], 'properties': {'n': {'type': 'integer', 'minimum': 9007199254740992}}}
      : {'type': 'string', 'enum': ['café']};
  final media = {'schema': schema, 'examples': {'Local': {'externalValue': external}}};
  final value = <String, Object?>{
    'openapi': version,
    'info': {'title': 'External byte capture 雪😀', 'version': 'business'},
    if (server != null) 'servers': [{'url': server}],
    'paths': {'/example': {'post': {
      'requestBody': {'required': true, 'content': {mediaType: media}},
      'responses': {'200': {'description': 'Reply', 'content': {mediaType: media}}},
    }}},
    'x-literal': {r'$ref': 'never-read.json', 'externalValue': 'never-read.bin'},
  };
  return format == 'yaml'
      ? '# Keep root source\r\n${value.entries.map((e) => '${jsonEncode(e.key)}: ${jsonEncode(e.value)}').join('\r\n')}\r\n'
      : '${jsonEncode(value)}\r\n';
}

class _AfterEvaluation extends EngineProcess {
  _AfterEvaluation(this.after) : super(executable: runtimeNode, helper: runtimeHelper);
  final Future<void> Function(String method, Map<String, Object?> params) after;
  @override
  Future<Map<String, dynamic>> request(String method, Map<String, Object?> params,
      {String? requestId}) async {
    final result = await super.request(method, params, requestId: requestId);
    await after(method, params);
    return result;
  }
}

void main() {
  for (final version in _versions) for (final format in ['yaml', 'json']) {
    test('$version $format available JSON and Latin1 examples share Core/CLI and real HTTP bytes', () async {
      final directory = await Directory.systemTemp.createTemp('bex-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.bin');
      final observed = <List<int>>[];
      var mediaType = 'application/json';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/example');
        expect(request.headers.value('content-type'), mediaType);
        final bytes = await request.fold<List<int>>([], (all, part) => all..addAll(part));
        observed.add(bytes);
        request.response.headers.set('content-type', mediaType);
        request.response.add(bytes);
        await request.response.close();
      });
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      for (final json in [true, false]) {
        mediaType = json ? 'application/json' : 'text/plain; charset=iso-8859-1';
        final wire = json
            ? utf8.encode('{"n":9007199254740993.00,"false":false,"zero":0,"null":null,"empty":"","externalValue":"data-only","unicode":"雪😀"}')
            : [99, 97, 102, 233];
        await payload.writeAsBytes(wire);
        final original = _source(version, format, './payload.bin', mediaType,
            server: 'http://127.0.0.1:${server.port}');
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        try {
          final root = file.uri.toString();
          final checked = await project.check(root);
          expect(checked['complete'], true, reason: '${checked['findings']}');
          expect((checked['references'] as List).whereType<Map>().any((v) => v['value'] == 'never-read.json'), false);
          final plan = await project.prepareRequest(root, resource: root,
              pointer: '/paths/~1example/post');
          try {
            expect(plan.snapshot.exampleResources.single.bytes, wire);
            final content = ((plan.result['requestBody'] as Map)['content'] as List).cast<Map>().single;
            final example = (content['examples'] as List).cast<Map>().single;
            expect(base64Decode(example['wireBase64'] as String), wire);
            final result = await const ContractRequestExecutor().execute(plan,
                OperationRequestDraft(planIdentity: plan.identity,
                    body: RequestBodyDraft.raw(mediaType: mediaType, text: example['raw'] as String)),
                resolveSecret: (_) async => null);
            try {
              expect(result.outgoing.complete, true);
              expect(result.outgoing.valid, true, reason: '${result.outgoing.findings}');
              expect(result.received.complete, true);
              expect(result.received.valid, true);
              expect(observed.last, wire);
            } finally { await result.close(); }
          } finally { plan.close(); }
          final cli = await Process.run('$testBundle/busyapi', ['check', file.path, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'}, includeParentEnvironment: false);
          expect(cli.exitCode, 0, reason: cli.stderr as String);
          expect(jsonDecode(cli.stdout as String)['complete'], true);
          expect(await file.readAsString(), original);
          expect(await payload.readAsBytes(), wire);
        } finally { project.close(); }
      }
      expect(observed.length, 2);
    });
  }

  for (final format in ['yaml', 'json']) {
    test('$format missing and denied examples preserve precise incomplete findings', () async {
      final directory = await Directory.systemTemp.createTemp('bed-');
      final outside = await Directory.systemTemp.createTemp('beo-');
      addTearDown(() => directory.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final external = File('${outside.path}/payload.json');
      await external.writeAsString('{"n":9007199254740993.00}');
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      for (final target in ['./missing.json', external.uri.toString()]) {
        final source = _source('3.1.2', format, target, 'application/json');
        await file.writeAsString(source);
        final project = await BusyProject.open(file.path, engine);
        try {
          final checked = await project.check(file.uri.toString());
          expect(checked['complete'], false);
          final findings = (checked['findings'] as List).cast<Map>();
          expect(findings.any((finding) => finding['incomplete'] == true &&
              (finding['pointer'] as String).endsWith('/externalValue')), true);
          if (target == external.uri.toString()) {
            expect(findings.any((finding) => jsonEncode(finding).contains('access.outside')), true);
          }
          expect(await file.readAsString(), source);
          expect(await external.readAsString(), '{"n":9007199254740993.00}');
        } finally { project.close(); }
      }
    });

    test('$format a payload changed during evaluation retires the old proof', () async {
      final directory = await Directory.systemTemp.createTemp('bes-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.json');
      final source = _source('3.1.2', format, './payload.json', 'application/json');
      await file.writeAsString(source);
      await payload.writeAsString('{"n":9007199254740993.00}');
      var changed = false;
      final engine = _AfterEvaluation((method, params) async {
        if (method == 'evaluateSchemas' && !changed) {
          changed = true;
          await payload.writeAsString('{"n":0}');
        }
      });
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final checked = await project.check(file.uri.toString());
      expect(changed, true);
      expect((checked['findings'] as List).cast<Map>().any((v) => v['code'] == 'example.serialization.incompatible'), true);
      expect(await file.readAsString(), source);
      expect(await payload.readAsString(), '{"n":0}');
    });

    test('$format cancellation after byte capture publishes no evaluation or files', () async {
      final directory = await Directory.systemTemp.createTemp('bec-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.json');
      final source = _source('3.1.2', format, './payload.json', 'application/json');
      await file.writeAsString(source);
      const bytes = '{"n":9007199254740993.00}';
      await payload.writeAsString(bytes);
      var cancelled = false;
      final engine = _AfterEvaluation((method, params) async {
        if (method == 'analyse' && params['exampleResources'] != null) cancelled = true;
      });
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      await expectLater(project.check(file.uri.toString(), cancelled: () => cancelled),
          throwsA(isA<CoreFailure>().having((v) => v.code, 'code', 'cancelled')));
      expect(await file.readAsString(), source);
      expect(await payload.readAsString(), bytes);
    });

    test('$format unsaved external text participates in history and snapshot invalidation', () async {
      final directory = await Directory.systemTemp.createTemp('beu-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.json');
      final source = _source('3.1.2', format, './%70ayload.json', 'application/json');
      await file.writeAsString(source);
      const original = '{"n":9007199254740993.00}';
      await payload.writeAsString(original);
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final root = file.uri.toString(), buffer = await project.buffer(payload.uri.toString());
      final old = await project.prepareRequest(root, resource: root, pointer: '/paths/~1example/post');
      addTearDown(old.close);
      expect(old.snapshot.exampleResources.single.id, payload.uri.toString());
      project.store.replace(buffer.id, '{"n":0}');
      expect(old.outdated, true);
      final historical = await old.evaluateRuntime([RuntimeSchemaInstance(
        subject: 'response-body', location: 'body', text: original,
        schemaResource: root,
        schemaPointer: '/paths/~1example/post/responses/200/content/application~1json/schema',
        mediaType: 'application/json',
      )]);
      expect((historical['runtimeEvaluations'] as List).cast<Map>()
          .every((value) => value['complete'] == true && value['valid'] == true), true);
      await expectLater(old.evaluateRuntime([RuntimeSchemaInstance(
        subject: 'request-body', location: 'body', text: original,
        schemaResource: root,
        schemaPointer: '/paths/~1example/post/requestBody/content/application~1json/schema',
        mediaType: 'application/json',
      )]), throwsA(isA<CoreFailure>().having((value) => value.code, 'code', 'request.draft.stale')));
      final checked = await project.check(root);
      expect(checked['unsaved'], true);
      expect((checked['findings'] as List).cast<Map>().any((v) => v['code'] == 'example.serialization.incompatible'), true);
      project.store.undo();
      expect(buffer.text, original);
      expect((await project.check(root))['complete'], true);
      project.store.redo();
      expect(buffer.text, '{"n":0}');
      expect(await payload.readAsString(), original);
      expect(await file.readAsString(), source);
    });
  }
  for (final format in ['yaml', 'json']) {
    test('$format readable examples migrate explicitly and changed payload rejects stale publication', () async {
      final directory = await Directory.systemTemp.createTemp('bem-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.txt');
      final source = _source('3.0.4', format, './payload.txt', 'text/plain');
      await file.writeAsString(source);
      await payload.writeAsString('café');
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final destination = '${directory.path}/migrated';
      final review = await project.prepareMigration(file.uri.toString(), destination, targetVersion: '3.1.2');
      addTearDown(review.close);
      expect(review.publishable, true, reason: '${review.result}');
      expect(await file.readAsString(), source);
      await payload.writeAsString('changed');
      await expectLater(review.publish(), throwsA(isA<CoreFailure>()
          .having((error) => error.code, 'code', 'migration.stale')));
      expect(await Directory(destination).exists(), false);
      expect(await file.readAsString(), source);
      expect(await payload.readAsString(), 'changed');
    });

    test('$format relocated resource package retains external Latin1 bytes without originals', () async {
      final directory = await Directory.systemTemp.createTemp('bep-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.bin');
      final source = _source('3.1.2', format, './payload.bin', 'text/plain; charset=iso-8859-1');
      final bytes = [99, 97, 102, 233];
      await file.writeAsString(source);
      await payload.writeAsBytes(bytes);
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final destination = '${directory.path}/package';
      final output = await project.prepareBundle(file.uri.toString(), destination,
          format: BundleFormat.resourcePackage);
      addTearDown(output.close);
      await output.publish();
      expect(await file.readAsString(), source);
      expect(await payload.readAsBytes(), bytes);
      final moved = await Directory(destination).rename('${directory.path}/moved package 雪');
      await file.delete();
      await payload.delete();
      final packaged = await ResourcePackage.open(moved.path, engine);
      expect(packaged.snapshot.exampleResources.single.bytes, bytes);
      final checked = await packaged.check(engine);
      expect(checked['complete'], true, reason: '$checked');
      expect(await file.exists(), false);
      expect(await payload.exists(), false);
    });
  }

  for (final format in ['yaml', 'json']) {
    test('$format invalid working Unicode never becomes replacement payload bytes', () async {
      final directory = await Directory.systemTemp.createTemp('beq-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format');
      final payload = File('${directory.path}/payload.json');
      final source = _source('3.1.2', format, './payload.json', 'application/json');
      await file.writeAsString(source);
      const original = '{"n":9007199254740993.00}';
      await payload.writeAsString(original);
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final buffer = await project.buffer(payload.uri.toString());
      project.store.replace(buffer.id, String.fromCharCode(0xd800));
      final checked = await project.check(file.uri.toString());
      expect(checked['complete'], false);
      expect((checked['findings'] as List).cast<Map>().any((value) =>
          value['detailCode'] == 'example.external-value.encoding' && value['condition'] == 'invalid'), true);
      expect(buffer.text.codeUnits, [0xd800]);
      expect(await payload.readAsString(), original);
      expect(await file.readAsString(), source);
    });
  }

}
