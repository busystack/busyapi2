import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _render(Map<String, Object?> value, String format) =>
    '\ufeff${format == 'yaml' ? '# Keep models 雪\r\n' : ''}${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';

Map<String, Object?> _base({required bool external}) => {
  'type': 'object', 'discriminator': 'kind', 'required': ['kind'],
  'properties': {'kind': {'type': 'string'}, 'next': {r'$ref': external ? '#/Base' : '#/definitions/Base'}},
  'description': '[Model](./guide.md)',
};

Map<String, Object?> _document(int port, {required bool external, required bool multi}) {
  final base = external ? 'models/base.json#/Base' : '#/definitions/Base';
  final reference = {r'$ref': '#/definitions/Base'};
  return {
    'swagger': '2.0', 'info': {'title': 'Original models', 'version': 'business'},
    'host': '127.0.0.1:$port', 'schemes': ['http'],
    'consumes': ['application/json'], 'produces': ['application/json'],
    'paths': {'/model': {'post': {
      'parameters': [{'name': 'payload', 'in': 'body', 'required': true, 'schema': reference}],
      'responses': {'200': {'description': 'Echo', 'schema': reference}},
    }}},
    'definitions': {
      'Base': external ? {r'$ref': base} : _base(external: false),
      'Cat': {
        if (multi) 'discriminator': 'subkind',
        if (multi) 'required': ['subkind'],
        if (multi) 'properties': {'subkind': {'type': 'string'}},
        'allOf': [{r'$ref': base}, {'type': 'object', 'required': ['value'],
          'properties': {'value': {'type': 'integer', 'minimum': 'EXACT'}}}],
      },
      'Dog': {'allOf': [{r'$ref': base}, {'type': 'object', 'required': ['flag'],
        'properties': {'flag': {'type': 'boolean'}}}]},
      if (multi) 'Grand': {'allOf': [{r'$ref': '#/definitions/Cat'},
        {'type': 'object', 'required': ['extra'], 'properties': {'extra': {'type': 'boolean'}}}]},
    },
    'x-exact': 'EXACT',
  };
}

void main() {
  for (final target in ['3.0.4', '3.1.2', '3.2.1']) for (final format in ['yaml', 'json']) {
    for (final mode in ['plain', 'multi', 'external']) {
      test('Swagger $format $mode -> $target preserves real request/response dispatch and originals', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-discriminator-');
        addTearDown(() => directory.delete(recursive: true));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seen = <List<int>>[];
        server.listen((request) async {
          expect(request.method, 'POST');expect(request.uri.toString(), '/model');
          expect(request.headers.value('host'), '127.0.0.1:${server.port}');
          expect(request.headers.contentType?.mimeType, 'application/json');
          final bytes = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
          seen.add(bytes);request.response.headers.contentType = ContentType.json;
          request.response.add(bytes);await request.response.close();
        });
        final external = mode == 'external', multi = mode == 'multi';
        final file = File('${directory.path}/api.$format')
          ..writeAsStringSync(_render(_document(server.port, external: external, multi: multi), format));
        final model = File('${directory.path}/models/base.json');
        if (external) { await model.parent.create();await model.writeAsString(_render({'Base': _base(external: true)}, 'json')); }
        final original = file.readAsBytesSync(), originalModel = external ? model.readAsBytesSync() : null;
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
        final root = project.roots.single.id, buffer = await project.buffer(project.roots.single.id);
        project.store.replace(root, buffer.text.replaceFirst('Original', 'Unsaved'));
        final working = buffer.bytes(), destination = '${directory.path}/converted';
        final review = await project.prepareMigration(root, destination, targetVersion: target);
        addTearDown(review.close);
        expect(review.status, MigrationStatus.faithfullyConvertible, reason: '${review.result}');
        expect(review.result['producerVersion'], '38');expect(review.unsaved, true);
        await review.publish();expect(buffer.bytes(), working);expect(file.readAsBytesSync(), original);
        if (external) expect(model.readAsBytesSync(), originalModel);
        final output = File('$destination/openapi.$format');
        expect(output.readAsStringSync(), contains('_migrated_selection_'));
        expect(output.readAsStringSync(), contains('9007199254740993.00'));
        final migrated = await BusyProject.open(output.path, engine);addTearDown(migrated.close);
        final subkind = multi ? ',"subkind":"Cat"' : '';
        final payloads = ['{"kind":"Base"}', '{"kind":"Cat","value":9007199254740993.00$subkind}',
          '{"kind":"Cat","value":9007199254740992$subkind}', '{"kind":"Dog","flag":true}',
          '{"kind":"Unknown"}', '{"kind":"Cat","value":9007199254740993.00$subkind,"next":{"kind":"Dog","flag":true}}',
          '{"kind":"Cat","value":9007199254740993.00$subkind,"next":{"kind":"Unknown"}}',
          if (multi) '{"kind":"Cat","subkind":"Grand","value":9007199254740993.00,"extra":true}',
          if (multi) '{"kind":"Cat","subkind":"Grand","value":9007199254740993.00}',
        ];
        final outcomes = <List<(bool, bool)>>[];
        for (final active in [project, migrated]) {
          final activeRoot = active.roots.single.id;
          final checked = await active.check(activeRoot);
          expect(checked['complete'], true);
          expect((checked['findings'] as List).whereType<Map>().where((value) => value['severity'] == 'error'), isEmpty);
          final plan = await active.prepareRequest(activeRoot, resource: activeRoot, pointer: '/paths/~1model/post');
          try {
            final values = <(bool, bool)>[];
            for (final payload in payloads) {
              final result = await const ContractRequestExecutor().execute(plan,
                OperationRequestDraft(planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(mediaType: 'application/json', text: payload)),
                resolveSecret: (_) async => throw StateError('No credentials'));
              try {
                expect(result.outgoing.complete, true, reason: '${result.outgoing.findings}');
                expect(result.received.complete, true, reason: '${result.received.findings}');
                expect(seen.last, utf8.encode(payload));expect(await result.response.decodedBytes(), utf8.encode(payload));
                values.add((result.outgoing.valid, result.received.valid));
              } finally { await result.close(); }
            }
            outcomes.add(values);
          } finally { plan.close(); }
        }
        expect(outcomes[1], outcomes[0]);
        expect(outcomes.first.take(7), [(true, true), (true, true), (false, false), (true, true), (false, false), (true, true), (false, false)]);
        expect(seen.length, payloads.length * 2);
        final cli = await Process.run('$testBundle/busyapi', ['migrate', file.path,
          '--target', target, '--output', '${directory.path}/cli-review', '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'}, includeParentEnvironment: false);
        expect(cli.exitCode, 0, reason: '${cli.stdout} ${cli.stderr}');
        final report = jsonDecode(cli.stdout as String) as Map;
        expect(report['producerVersion'], '38');expect(report['complete'], true);expect(report['published'], false);
        expect(Directory('${directory.path}/cli-review').existsSync(), false);
        expect(file.readAsBytesSync(), original);if (external) expect(model.readAsBytesSync(), originalModel);
      });
    }
  }
  for (final format in ['yaml', 'json']) {
    test('$format discriminator review cancellation and stale source preserve originals and destination', () async {
      final directory = await Directory.systemTemp.createTemp('busyapi-discriminator-stale-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format')
        ..writeAsStringSync(_render(_document(12345, external: false, multi: false), format));
      final original = file.readAsBytesSync();
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);addTearDown(project.close);
      final root = project.roots.single.id, destination = '${directory.path}/reviewed';
      final review = await project.prepareMigration(root, destination, targetVersion: '3.2.1');addTearDown(review.close);
      expect(review.status, MigrationStatus.faithfullyConvertible, reason: '${review.result}');
      await expectLater(review.publish(cancelled: () => true), throwsA(isA<CoreFailure>()
        .having((e) => e.code, 'code', 'cancelled')));
      expect(Directory(destination).existsSync(), false);
      final buffer = await project.buffer(root);project.store.replace(root, buffer.text.replaceFirst('Original', 'Changed'));
      await expectLater(review.publish(), throwsA(isA<CoreFailure>()
        .having((e) => e.code, 'code', 'migration.stale')));
      expect(file.readAsBytesSync(), original);expect(Directory(destination).existsSync(), false);
    });
  }
}
