import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    test('$version shared Markdown uses captured source and safe publication', () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-migration-shared-text-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final original = 'openapi: "$version"\r\n'
          'info: &info {title: Shared, version: "business", description: "[Guide](./guide.md)", x-exact: 9007199254740993.00}\r\n'
          'paths: {}\r\nx-literal: *info # retain literal use\r\n';
      final file = File('${directory.path}/api.yaml');
      await file.writeAsString(original);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final root = project.roots.single.id;
      final buffer = await project.buffer(root);
      final unsaved = original.replaceFirst('./guide.md', './unsaved.md');
      project.store.replace(root, unsaved);
      final destination = '${directory.path}/migrated';
      Future<MigrationOutput> review() => project.prepareMigration(
        root, destination, targetVersion: '3.2.1',
      );
      final prepared = await review();
      addTearDown(prepared.close);
      expect(prepared.publishable, true, reason: '${prepared.result}');
      expect(prepared.unsaved, true);
      expect(prepared.changes.single.after, contains('9007199254740993.00'));
      expect((prepared.result['presentationChanges'] as List).whereType<Map>()
          .any((change) => change['pointer'] == '/x-literal'), true);
      await expectLater(prepared.publish(cancelled: () => true),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled')));
      expect(await Directory(destination).exists(), false);
      project.store.replace(root, unsaved.replaceFirst('Shared', 'Changed'));
      await expectLater(prepared.publish(),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.stale')));
      expect(await Directory(destination).exists(), false);
      final fresh = await review();
      addTearDown(fresh.close);
      expect(fresh.publishable, true, reason: '${fresh.result}');
      await fresh.publish();
      expect(await file.readAsString(), original);
      expect(buffer.dirty, true);
      final output = await BusyProject.open('$destination/openapi.yaml', engine);
      addTearDown(output.close);
      final outputRoot = output.roots.single.id;
      final info = await output.inspectObject(outputRoot, outputRoot, '/info');
      final document = await output.inspectObject(outputRoot, outputRoot, '');
      final target = Map<String, dynamic>.from((document['entries'] as List).singleWhere((entry) => entry['name'] == 'x-literal') as Map);
      final literal = jsonDecode(await output.readDataValue(target)) as Map;
      expect(info['value']['description'], contains(file.uri.resolve('./unsaved.md').toString()));
      expect(literal['description'], '[Guide](./unsaved.md)');
      expect(literal['title'], 'Changed');
      expect((await output.check(outputRoot))['complete'], true);
    });
  }
}
