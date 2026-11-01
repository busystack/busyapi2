import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format inactive annotations publish as native Swagger with captured source ownership', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-inactive-migration-');
        addTearDown(() => directory.delete(recursive: true));
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final file = File('${directory.path}/api.$format');
        final original = '${format == 'yaml' ? '# retain inactive annotations\r\n' : ''}${jsonEncode({
          'openapi': version,
          'info': {'title': 'Original', 'version': 'business'},
          'paths': <String, Object?>{},
          'components': {'schemas': {
            'Model': {'type': 'object', 'required': ['value'], 'properties': {
              'value': {'type': 'string', 'readOnly': false, 'writeOnly': false, 'deprecated': false, 'default': ''},
            }},
            if (version != '3.0.4') 'False': {r'$ref': '#/components/schemas/Model/properties/value/writeOnly'},
          }},
        })}\r\n';
        await file.writeAsString(original);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id;
        final destination = '${directory.path}/converted';
        Future<MigrationOutput> prepare() => project.prepareMigration(root, destination, targetVersion: '2.0');
        final review = await prepare();
        addTearDown(review.close);
        expect(review.publishable, true, reason: '${review.result}');
        expect(review.result['acceptedDecisions'], isEmpty);
        await expectLater(review.publish(cancelled: () => true),
            throwsA(isA<CoreFailure>().having((failure) => failure.code, 'code', 'cancelled')));
        expect(await Directory(destination).exists(), false);
        project.store.replace(root, original.replaceFirst('Original', 'Captured 雪'));
        await expectLater(review.publish(),
            throwsA(isA<CoreFailure>().having((failure) => failure.code, 'code', 'migration.stale')));
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
        final inspected = await output.inspectObject(outputRoot, outputRoot, '/definitions/Model');
        final value = jsonDecode(await output.readDataValue(inspected)) as Map;
        final field = value['properties']['value'] as Map;
        expect(field['readOnly'], false);expect(field['default'], '');
        expect(field.containsKey('writeOnly'), false);expect(field.containsKey('deprecated'), false);
        if (version != '3.0.4') {
          final references = (checked['projection'] as Map)['references'] as List;
          final reference = references.singleWhere((reference) => reference['pointer'] == r'/definitions/False/$ref');
          expect(reference['resolution'], 'resolved');
          expect(reference['targetPointer'], startsWith('/definitions/_migrated_annotation_'));
        }
        expect(await file.readAsString(), original);
        expect((await project.buffer(root)).dirty, true);
      });
    }
  }
}
