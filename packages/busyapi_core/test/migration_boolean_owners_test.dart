import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final policy in [false, true]) {
      for (final target in ['3.0.4', '2.0']) {
        test('$format shared boolean $policy migrates to $target from unsaved external resources', () async {
          final directory = await Directory.systemTemp.createTemp('busyapi-boolean-owners-');
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
          addTearDown(engine.close);
          final root = File('${directory.path}/api.$format');
          final models = File('${directory.path}/models.$format');
          final model = {'type': 'object', 'properties': {'known': {'type': 'string'}}, 'additionalProperties': policy};
          final original = format == 'yaml'
              ? 'openapi: 3.2.1\r\ninfo: {title: Original, version: "business"}\r\n'
                  'servers: [{url: "https://api.invalid"}]\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n'
                  '    Model: {\$ref: "models.yaml#/Model"}\r\n'
                  '    Detached: {\$ref: "models.yaml#/Model/additionalProperties"}\r\n'
                  '    additionalProperties: $policy\r\n'
              : '${jsonEncode({
                  'openapi': '3.2.1', 'info': {'title': 'Original', 'version': 'business'},
                  'servers': [{'url': 'https://api.invalid'}], 'paths': <String, Object?>{},
                  'components': {'schemas': {
                    'Model': {r'$ref': 'models.json#/Model'},
                    'Detached': {r'$ref': 'models.json#/Model/additionalProperties'},
                    'additionalProperties': policy,
                  }},
                })}\n';
          final source = format == 'yaml'
              ? '# Keep shared boolean\r\nModel: &model\r\n  type: object\r\n'
                  '  properties: {known: {type: string}}\r\n  additionalProperties: &policy $policy # keep policy\r\n'
                  'x-literal: *model # keep literal\r\nx-policy: *policy\r\nx-exact: 9007199254740993.00\r\n'
              : '${jsonEncode({'Model': model, 'x-literal': model, 'x-policy': policy, 'x-exact': 'EXACT'})}\n'
                  .replaceAll('"EXACT"', '9007199254740993.00');
          await root.writeAsString(original);
          await models.writeAsString(source);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(models.uri.toString());
          final working = source.replaceAll('9007199254740993.00', '9007199254740995.00');
          project.store.replace(buffer.id, working);
          final destination = '${directory.path}/converted';
          Future<MigrationOutput> prepare() => project.prepareMigration(root.uri.toString(), destination, targetVersion: target);
          final review = await prepare();
          addTearDown(review.close);
          expect(review.publishable, true, reason: '${review.result}');
          expect(review.unsaved, true);
          expect(review.result['producerVersion'], '39');
          expect(review.result['acceptedDecisions'], isEmpty);
          await expectLater(review.publish(cancelled: () => true),
              throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled')));
          expect(await Directory(destination).exists(), false);
          project.store.replace(root.uri.toString(), original.replaceFirst('Original', 'Captured'));
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
          expect(checked['projection']['specification']['declaredVersion'], target);
          final prefix = target == '2.0' ? '/definitions' : '/components/schemas';
          final references = (checked['projection'] as Map)['references'] as List;
          final reference = references.singleWhere((reference) => reference['pointer'] == '$prefix/Detached/\$ref');
          expect(reference['resolution'], 'resolved');
          expect(reference['targetResource'], outputRoot);
          expect(reference['targetPointer'], startsWith('$prefix/_migrated_additional_'));
          final generated = await output.inspectObject(outputRoot, outputRoot, reference['targetPointer'] as String);
          final generatedValue = jsonDecode(await output.readDataValue(generated)) as Map;
          expect(generatedValue, policy ? isEmpty : contains(target == '2.0' ? 'allOf' : 'not'));
          final modelReference = references.singleWhere((reference) => reference['pointer'] == '$prefix/Model/\$ref');
          final modelResource = modelReference['targetResource'] as String;
          final inspected = await output.inspectObject(outputRoot, modelResource, '/Model');
          final converted = jsonDecode(await output.readDataValue(inspected)) as Map;
          expect(converted['additionalProperties'], policy);
          final document = await output.inspectObject(outputRoot, modelResource, '');
          final entries = (document['entries'] as List).whereType<Map>();
          final literal = Map<String, dynamic>.from(entries.singleWhere((entry) => entry['name'] == 'x-literal'));
          final literalValue = jsonDecode(await output.readDataValue(literal)) as Map;
          expect(literalValue, model);
          final exact = Map<String, dynamic>.from(entries.singleWhere((entry) => entry['name'] == 'x-exact'));
          expect(await output.readDataValue(exact), '9007199254740995.00');
          expect(await root.readAsString(), original);
          expect(await models.readAsString(), source);
          expect(buffer.dirty, true);
        });
      }
    }
  }
}
