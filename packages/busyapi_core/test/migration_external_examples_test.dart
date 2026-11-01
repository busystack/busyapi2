import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _render(Map<String, Object?> value, String format) => format == 'yaml'
    ? '# Keep original source 雪\r\n${value.entries.map((entry) => '${jsonEncode(entry.key)}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n'
    : '${jsonEncode(value)}\r\n';

({String mediaType, List<int> bytes, Map<String, Object?> schema}) _payload(String kind) => switch (kind) {
  'json' => (mediaType: 'application/json', bytes: utf8.encode('{"n":9007199254740993.00,"empty":"","false":false,"zero":0,"null":null,"unicode":"雪😀","externalValue":"literal-only"}'),
    schema: {'type': 'object', 'required': ['n'], 'properties': {'n': {'type': 'integer', 'minimum': 9007199254740992}}}),
  'latin1' => (mediaType: 'text/plain; charset=iso-8859-1', bytes: [99, 97, 102, 233], schema: {'type': 'string', 'enum': ['café']}),
  'empty' => (mediaType: 'text/plain', bytes: [], schema: {'type': 'string', 'enum': ['']}),
  'mime' => (mediaType: 'multipart/form-data; boundary=Test', bytes: latin1.encode('--Test\r\nContent-Disposition: form-data; name="label"\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncafé\r\n--Test--\r\n'),
    schema: {'type': 'object', 'required': ['label'], 'properties': {'label': {'type': 'string', 'enum': ['café']}}}),
  _ => throw ArgumentError.value(kind),
};

String _source(String version, String format, String kind, {int? port, bool logical = false}) {
  final payload = _payload(kind);
  final media = {'schema': payload.schema, 'examples': {'External': {'externalValue': './payload.bin'}}};
  return _render({
    'openapi': version,
    if (logical) r'$self': 'https://contracts.invalid/api.$format',
    'info': {'title': 'Original', 'version': 'business'},
    'servers': [{'url': port == null ? 'https://api.invalid' : 'http://127.0.0.1:$port'}],
    'paths': {'/echo': {'post': {
      'requestBody': {'required': true, 'content': {payload.mediaType: media}},
      'responses': {'200': {'description': 'Echo', 'content': {payload.mediaType: media}}},
    }}},
    'x-literal': {r'$ref': 'not-a-resource', 'externalValue': 'data-only', 'empty': '', 'false': false},
  }, format);
}

class _ChangedReview extends EngineProcess {
  _ChangedReview(this.change) : super(executable: runtimeNode, helper: runtimeHelper);
  final void Function(Map<String, dynamic> result) change;
  @override
  Future<Map<String, dynamic>> request(String method, Map<String, Object?> params, {String? requestId}) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method != 'planMigration' || result['complete'] != true) return result;
    final copied = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
    change(copied);
    return copied;
  }
}

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) for (final format in ['yaml', 'json']) {
    for (final kind in ['json', 'latin1', 'mime', 'empty']) {
      test('$version $format $kind publishes exact captured examples, reopens after relocation and retains HTTP bytes', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-migration-examples-');
        addTearDown(() => directory.delete(recursive: true));
        final payload = _payload(kind), observed = <List<int>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          expect(request.method, 'POST');expect(request.uri.toString(), '/echo');
          expect(request.headers.value('host'), '127.0.0.1:${server.port}');
          expect(request.headers.value('content-type'), payload.mediaType);
          final bytes = await request.fold<List<int>>([], (all, part) => all..addAll(part));
          observed.add(bytes);request.response.headers.set('content-type', payload.mediaType);
          request.response.add(bytes);await request.response.close();
        });
        final file = File('${directory.path}/api.$format'), example = File('${directory.path}/payload.bin');
        final original = _source(version, format, kind, port: server.port);
        await file.writeAsString(original);await example.writeAsBytes(payload.bytes);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
        final root = file.uri.toString(), source = await project.buffer(root);
        project.store.replace(root, source.text.replaceFirst('Original', 'Unsaved'));
        final target = version.startsWith('3.2') ? '3.0.4' : version.startsWith('3.1') ? '3.2.1' : '3.1.2';
        final review = await project.prepareMigration(root, '${directory.path}/reviewed', targetVersion: target);
        addTearDown(review.close);
        expect(review.publishable, true, reason: '${review.result}');expect(review.unsaved, true);
        final copy = review.exampleCopies.single;
        expect(copy.resource, example.uri.toString());expect(copy.bytes, payload.bytes);
        expect(copy.identity, contentIdentity(payload.bytes));expect(copy.byteLength, payload.bytes.length);
        expect(copy.sources, isNotEmpty);expect(copy.sources.every((source) => source.pointer.endsWith('/externalValue')), true);
        expect(() => copy.bytes.add(1), throwsUnsupportedError);
        final checked = await project.check(root);expect(checked['complete'], true, reason: '$checked');
        Future<void> send(BusyProject owner, String selectedRoot, String payloadPath) async {
          final request = await owner.prepareRequest(selectedRoot, resource: selectedRoot, pointer: '/paths/~1echo/post');
          try {
            final result = await const ContractRequestExecutor().execute(request,
              OperationRequestDraft(planIdentity: request.identity,
                body: RequestBodyDraft.binaryFile(mediaType: payload.mediaType, file: payloadPath)),
              resolveSecret: (_) async => throw StateError('No credentials'));
            try {
              expect(result.outgoing.complete, true, reason: '${result.outgoing.findings}');expect(result.outgoing.valid, true);
              expect(result.received.complete, true, reason: '${result.received.findings}');expect(result.received.valid, true);
              expect(observed.last, payload.bytes);expect(await result.response.decodedBytes(), payload.bytes);
            } finally {await result.close();}
          } finally {request.close();}
        }
        await send(project, root, example.path);
        await review.publish();expect(await file.readAsString(), original);expect(await example.readAsBytes(), payload.bytes);
        final moved = await Directory(review.destination).rename('${directory.path}/moved output 雪');
        final copiedFile = File('${moved.path}/${copy.path}');expect(await copiedFile.readAsBytes(), payload.bytes);
        final metadata = jsonDecode(await File('${moved.path}/migration.json').readAsString()) as Map;
        expect((metadata['exampleCopies'] as List).single['identity'], contentIdentity(payload.bytes));
        expect((metadata['exampleCopies'] as List).single.containsKey('base64'), false);
        project.close();await file.delete();await example.delete();
        final migrated = await BusyProject.open(moved.path, engine);addTearDown(migrated.close);
        final migratedRoot = migrated.roots.single.id;
        final reopened = await migrated.check(migratedRoot);
        expect(reopened['complete'], true, reason: '$reopened');
        expect((reopened['findings'] as List).whereType<Map>().where((value) => value['severity'] == 'error'), isEmpty);
        expect(migrated.store.get(migratedRoot).text, contains('Unsaved'));
        await send(migrated, migratedRoot, copiedFile.path);expect(observed.length, 2);
        final cli = await Process.run('$testBundle/busyapi', ['check', moved.path, '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'}, includeParentEnvironment: false);
        expect(cli.exitCode, 0, reason: '${cli.stdout} ${cli.stderr}');expect(jsonDecode(cli.stdout as String)['complete'], true);
        expect(await file.exists(), false);expect(await example.exists(), false);
      });
    }
  }
  for (final format in ['yaml', 'json']) {
    test('$format retained document identity maps example copies locally after relocation', () async {
      final directory = await Directory.systemTemp.createTemp('busyapi-example-identity-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format'), payload = File('${directory.path}/payload.bin');
      final original = _source('3.2.1', format, 'latin1', logical: true);
      await file.writeAsString(original);await payload.writeAsBytes(_payload('latin1').bytes);
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
      await project.approveResource('https://contracts.invalid/payload.bin', payload.uri.toString());
      final review = await project.prepareMigration(file.uri.toString(), '${directory.path}/copy', targetVersion: '3.2.0');addTearDown(review.close);
      expect(review.publishable, true, reason: '${review.result}');await review.publish();
      final moved = await Directory(review.destination).rename('${directory.path}/moved');
      await file.delete();await payload.delete();
      final migrated = await BusyProject.open(moved.path, engine);addTearDown(migrated.close);
      final checked = await migrated.check(migrated.roots.single.id);
      expect(checked['complete'], true, reason: '$checked');
      expect((checked['findings'] as List).whereType<Map>().where((finding) => finding['severity'] == 'error'), isEmpty);
      expect(review.exampleCopies.single.bytes, _payload('latin1').bytes);
    });
    test('$format CLI reviews byte copies and applies only the captured review identity', () async {
      final directory = await Directory.systemTemp.createTemp('busyapi-example-cli-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format'), payload = File('${directory.path}/payload.bin');
      final original = _source('3.0.4', format, 'latin1'), bytes = _payload('latin1').bytes;
      await file.writeAsString(original);await payload.writeAsBytes(bytes);
      final destination = '${directory.path}/copy';
      final arguments = ['migrate', file.path, '--target', '3.2.1', '--output', destination];
      Future<ProcessResult> run(List<String> extra) => Process.run('$testBundle/busyapi', [...arguments, ...extra],
        environment: const {'PATH': '', 'LANG': 'C.UTF-8'}, includeParentEnvironment: false);
      final review = await run(['--json']);expect(review.exitCode, 0, reason: '${review.stdout} ${review.stderr}');
      final report = jsonDecode(review.stdout as String) as Map;
      expect(report['published'], false);expect(report['producerVersion'], '31');
      final copy = (report['exampleOutputs'] as List).single as Map;
      expect(base64Decode(copy['base64'] as String), bytes);expect(await Directory(destination).exists(), false);
      final textReview = await run([]);expect(textReview.exitCode, 0, reason: textReview.stderr as String);
      expect(textReview.stdout as String, contains('Copy 4 bytes unchanged: ${payload.uri} → '));
      final applied = await run(['--json', '--apply', report['reviewIdentity'] as String]);
      expect(applied.exitCode, 0, reason: '${applied.stdout} ${applied.stderr}');
      expect(jsonDecode(applied.stdout as String)['published'], true);
      expect(await File('$destination/${copy['path']}').readAsBytes(), bytes);
      expect(await file.readAsString(), original);expect(await payload.readAsBytes(), bytes);
    });
    for (final failure in ['cancel', 'race', 'failure', 'stale']) {
      test('$format byte-copy publication $failure leaves originals and no partial result', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-example-failure-');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/api.$format'), payload = File('${directory.path}/payload.bin');
        final original = _source('3.0.4', format, 'json'), bytes = _payload('json').bytes;
        await file.writeAsString(original);await payload.writeAsBytes(bytes);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
        final destination = '${directory.path}/target';
        final review = await project.prepareMigration(file.uri.toString(), destination, targetVersion: '3.2.1');addTearDown(review.close);
        expect(review.publishable, true, reason: '${review.result}');
        var cancelled = false;
        await expectLater(review.publish(cancelled: () => cancelled, beforePublish: () async {
          if (failure == 'cancel') cancelled = true;
          if (failure == 'race') {await Directory(destination).create();await File('$destination/foreign').writeAsString('Keep');}
          if (failure == 'stale') await payload.writeAsString('{"n":9007199254740994.00}');
          if (failure == 'failure') throw const FileSystemException('Controlled publication failure');
        }), throwsA(anything));
        expect(await file.readAsString(), original);
        expect(await payload.readAsBytes(), failure == 'stale' ? utf8.encode('{"n":9007199254740994.00}') : bytes);
        if (failure == 'race') {expect(await File('$destination/foreign').readAsString(), 'Keep');expect(await File('$destination/openapi.$format').exists(), false);}
        else {expect(await Directory(destination).exists(), false);}
      });
    }
    test('$format unsaved payload bytes are captured without changing saved originals', () async {
      final directory = await Directory.systemTemp.createTemp('busyapi-example-working-');addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format'), payload = File('${directory.path}/payload.bin');
      await file.writeAsString(_source('3.0.4', format, 'json'));await payload.writeAsBytes(_payload('json').bytes);
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
      final buffer = await project.buffer(payload.uri.toString());const working = '{"n":9007199254740994.00}';
      project.store.replace(buffer.id, working);
      final review = await project.prepareMigration(file.uri.toString(), '${directory.path}/copy', targetVersion: '3.1.2');addTearDown(review.close);
      expect(review.publishable, true, reason: '${review.result}');expect(review.exampleCopies.single.bytes, utf8.encode(working));
      await review.publish();expect(await payload.readAsBytes(), _payload('json').bytes);expect(buffer.text, working);
      expect(await File('${review.destination}/${review.exampleCopies.single.path}').readAsBytes(), utf8.encode(working));
      project.store.undo();expect(review.outdated, true);project.store.redo();expect(buffer.text, working);
    });
    for (final defect in ['base64', 'identity', 'path', 'owner', 'producer']) {
      test('$format engine $defect cannot authorize an unrelated byte copy', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-example-protocol-');addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/api.$format'), payload = File('${directory.path}/payload.bin');
        await file.writeAsString(_source('3.0.4', format, 'json'));await payload.writeAsBytes(_payload('json').bytes);
        final engine = _ChangedReview((result) {
          final copy = (result['exampleOutputs'] as List).single as Map;
          switch (defect) {
            case 'base64': copy['base64'] = base64Encode(utf8.encode('changed'));break;
            case 'identity': copy['identity'] = '0' * 64;break;
            case 'path': copy['path'] = '../escape.bin';break;
            case 'owner': (copy['source'] as Map)['resource'] = 'file:///not-captured';break;
            case 'producer': result['producerVersion'] = '30';break;
          }
        });addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
        await expectLater(project.prepareMigration(file.uri.toString(), '${directory.path}/copy', targetVersion: '3.1.2'),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.protocol')));
        expect(await Directory('${directory.path}/copy').exists(), false);expect(await payload.readAsBytes(), _payload('json').bytes);
      });
    }
  }
}
