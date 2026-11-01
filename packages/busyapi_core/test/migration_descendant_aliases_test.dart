import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    test('$format Swagger publication preserves outside definitions and captures nested alias values', () async {
      final directory = await Directory.systemTemp.createTemp('busyapi-descendant-aliases-');
      addTearDown(() => directory.delete(recursive: true));
      final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
      addTearDown(engine.close);
      final file = File('${directory.path}/api.$format');
      final original = format == 'yaml'
          ? '# Keep entry comments\r\nopenapi: 3.0.4\r\ninfo: {title: Original, version: "business"}\r\n'
              'servers: [{url: "https://api.invalid"}]\r\npaths: {}\r\n'
              'x-type: &kind string # keep definition\r\nx-type-copy: *kind # keep consumer\r\n'
              'x-values: &values ["", "café"]\r\nx-values-copy: *values\r\n'
              'components:\r\n  schemas:\r\n    Value:\r\n      type: *kind # keep type use\r\n      enum: *values\r\n'
              '    Alias: {\$ref: "#/components/schemas/Value"}\r\n'
              'x-later-type: &kind integer\r\nx-later-copy: *kind\r\nx-exact: 9007199254740993.00\r\n'
          : '${jsonEncode({
              'openapi': '3.0.4', 'info': {'title': 'Original', 'version': 'business'},
              'servers': [{'url': 'https://api.invalid'}], 'paths': <String, Object?>{},
              'x-type': 'string', 'x-type-copy': 'string', 'x-values': ['', 'café'], 'x-values-copy': ['', 'café'],
              'components': {'schemas': {
                'Value': {'type': 'string', 'enum': ['', 'café']},
                'Alias': {r'$ref': '#/components/schemas/Value'},
              }},
              'x-later-type': 'integer', 'x-later-copy': 'integer', 'x-exact': 'EXACT',
            })}\n'.replaceAll('"EXACT"', '9007199254740993.00');
      await file.writeAsString(original);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final root = project.roots.single.id;
      final buffer = await project.buffer(root);
      final working = original.replaceAll('café', 'café 東京');
      project.store.replace(root, working);
      final destination = '${directory.path}/converted';
      Future<MigrationOutput> prepare() => project.prepareMigration(root, destination, targetVersion: '2.0');
      final review = await prepare();
      addTearDown(review.close);
      expect(review.publishable, true, reason: '${review.result}');
      expect(review.unsaved, true);
      expect(review.result['producerVersion'], '40');
      expect(review.result['acceptedDecisions'], isEmpty);
      if (format == 'yaml') {
        expect((review.result['presentationChanges'] as List).whereType<Map>().any(
            (change) => change['resource'] == root && change['pointer'] == '/components/schemas/Value/type'), true);
      }
      await expectLater(review.publish(cancelled: () => true),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled')));
      expect(await Directory(destination).exists(), false);
      final current = working.replaceFirst('Original', 'Captured');
      project.store.replace(root, current);
      await expectLater(review.publish(),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.stale')));
      expect(await Directory(destination).exists(), false);
      final fresh = await prepare();
      addTearDown(fresh.close);
      expect(fresh.publishable, true, reason: '${fresh.result}');
      await fresh.publish();
      final output = await BusyProject.open(destination, engine);
      addTearDown(output.close);
      final outputRoot = output.roots.single.id;
      final checked = await output.check(outputRoot);
      expect(checked['status'], 'complete', reason: '$checked');
      expect(checked['projection']['specification']['declaredVersion'], '2.0');
      final inspected = await output.inspectObject(outputRoot, outputRoot, '/definitions/Value');
      expect(jsonDecode(await output.readDataValue(inspected)), {'type': 'string', 'enum': ['', 'café 東京']});
      final references = (checked['projection'] as Map)['references'] as List;
      final reference = references.singleWhere((reference) => reference['pointer'] == r'/definitions/Alias/$ref');
      expect(reference['resolution'], 'resolved');expect(reference['targetPointer'], '/definitions/Value');
      final rootObject = await output.inspectObject(outputRoot, outputRoot, '');
      final entries = (rootObject['entries'] as List).whereType<Map>();
      Future<String> data(String name) => output.readDataValue(Map<String, dynamic>.from(entries.singleWhere((entry) => entry['name'] == name)));
      expect(await data('x-type'), '"string"');expect(await data('x-type-copy'), '"string"');
      expect(await data('x-later-copy'), '"integer"');
      expect(jsonDecode(await data('x-values-copy')), ['', 'café 東京']);
      expect(await data('x-exact'), '9007199254740993.00');
      if (format == 'yaml') {
        final published = (await output.buffer(outputRoot)).text;
        expect(published, contains('x-type: &kind string # keep definition\r\nx-type-copy: *kind # keep consumer\r\n'));
        expect(published, contains('x-later-type: &kind integer\r\nx-later-copy: *kind\r\n'));
        expect(published, contains('# keep type use'));
      }
      expect(await file.readAsString(), original);
      expect(buffer.text, current);expect(buffer.dirty, true);
    });
  }
}
