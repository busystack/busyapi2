import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _render(Map<String, Object?> value, String format) => format == 'json'
    ? '${jsonEncode(value)}\r\n'
    : '# Keep owned source 雪\r\n${value.entries.map((entry) => '${jsonEncode(entry.key)}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n';

class _ChangedChoices extends EngineProcess {
  _ChangedChoices(this.alter) : super(executable: runtimeNode, helper: runtimeHelper);
  final void Function(Map<String, dynamic>) alter;

  @override
  Future<Map<String, dynamic>> request(String method, Map<String, Object?> params, {String? requestId}) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method != 'planMigration' || result['status'] != 'requires-decision') return result;
    final changed = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
    alter(changed);
    return changed;
  }
}

Future<(File, File, String, String)> _files(Directory directory, String version, String format) async {
  final root = File('${directory.path}/api.$format');
  final models = File('${directory.path}/models.$format');
  final binding = {r'$ref': 'models.$format#/Parent'};
  final original = _render({
    'openapi': version,
    'info': {'title': 'Original', 'version': 'business'},
    'servers': [{'url': 'https://api.invalid'}],
    'paths': {'/value': {'post': {
      'requestBody': {'content': {'application/json': {'schema': binding}}},
      'responses': {'200': {'description': 'Reply', 'content': {'application/json': {'schema': binding}}}},
    }}},
    'components': {'schemas': {
      'Parent': binding,
      'Cat': {r'$ref': 'models.$format#/Cat'},
      'Other': {r'$ref': 'models.$format#/Other'},
    }},
  }, format);
  final definitions = _render({
    'Parent': {'type': 'object', 'discriminator': {'propertyName': 'kind'},
      'oneOf': [{r'$ref': '#/Cat'}, {r'$ref': '#/Other'}], 'example': {'value': 'café'}},
    'Cat': {'type': 'object', 'required': ['kind'], 'properties': {'kind': {'enum': ['Cat']}}},
    'Other': {'type': 'object', 'required': ['value'], 'properties': {
      'kind': {'type': 'string', 'not': {'enum': ['Cat', 'Other']}},
      'value': {'type': 'string'},
    }},
  }, format);
  await root.writeAsString(original);
  await models.writeAsString(definitions);
  return (root, models, original, definitions);
}

void main() {
  for (final version in ['3.0.4', '3.1.2']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format fallback decisions bind unsaved resources and publish only the chosen alternative', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-discriminator-default-');
        addTearDown(() => directory.delete(recursive: true));
        final (root, models, original, definitions) = await _files(directory, version, format);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(root.uri.toString());
        project.store.replace(buffer.id, original.replaceFirst('Original', 'Unsaved 雪'));
        final destination = '${directory.path}/converted';
        Future<MigrationOutput> review([Map<String, String> decisions = const {}]) => project.prepareMigration(
          buffer.id, destination, targetVersion: '3.2.1', decisions: decisions,
        );
        final pending = await review();
        addTearDown(pending.close);
        expect(pending.status, MigrationStatus.requiresDecision);
        final problem = pending.problems.singleWhere((problem) => problem.code == 'migration.discriminator.default');
        expect(problem.choices, hasLength(1));
        final choice = problem.choiceDetails[problem.choices.single]!;
        expect(choice.label, 'Other');
        expect(choice.target.resource, models.uri.toString());
        expect(choice.target.pointer, '/Other');
        expect(choice.target.range.end, greaterThan(choice.target.range.start));
        await expectLater(pending.publish(), throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.blocked')));
        final selected = await review({problem.id: choice.value});
        addTearDown(selected.close);
        expect(selected.publishable, true, reason: '${selected.result}');
        await expectLater(selected.publish(cancelled: () => true),
            throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled')));
        expect(await Directory(destination).exists(), false);
        final shared = await project.buffer(models.uri.toString());
        project.store.replace(shared.id, definitions.replaceFirst('café', 'Changed'));
        await expectLater(selected.publish(), throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.stale')));
        expect(await Directory(destination).exists(), false);
        project.store.replace(shared.id, definitions);
        final fresh = await review();
        addTearDown(fresh.close);
        final refreshed = fresh.problems.singleWhere((problem) => problem.code == 'migration.discriminator.default');
        expect(refreshed.id, isNot(problem.id));
        final accepted = await review({refreshed.id: refreshed.choices.single});
        addTearDown(accepted.close);
        expect(accepted.publishable, true, reason: '${accepted.result}');
        expect(accepted.changes.singleWhere((change) => change.resource == models.uri.toString()).after, contains('defaultMapping'));
        await accepted.publish();
        final output = await BusyProject.open(destination, engine);
        addTearDown(output.close);
        final checked = await output.check(output.roots.single.id);
        expect(checked['complete'], true, reason: '$checked');
        expect(checked['projection']['specification']['declaredVersion'], '3.2.1');
        expect(await root.readAsString(), original);
        expect(await models.readAsString(), definitions);
        expect(buffer.dirty, true);
      });
    }
  }

  for (final corruption in ['unknown-source', 'unoffered-value', 'duplicate-choice', 'bad-range', 'missing-details']) {
    test('Core rejects fallback review $corruption before exposing a decision', () async {
      final directory = await Directory.systemTemp.createTemp('busyapi-discriminator-choice-');
      addTearDown(() => directory.delete(recursive: true));
      final (root, _, original, _) = await _files(directory, '3.1.2', 'json');
      var altered = false;
      final engine = _ChangedChoices((result) {
        final problem = (result['problems'] as List).cast<Map>().singleWhere((problem) => problem['code'] == 'migration.discriminator.default');
        final details = problem['choiceDetails'] as List;
        switch (corruption) {
          case 'unknown-source':
            (details.single['target'] as Map)['resource'] = 'file:///not-captured/model.json';
            break;
          case 'unoffered-value':
            details.single['value'] = 'not-offered';
            break;
          case 'duplicate-choice':
            details.add(details.single);
            break;
          case 'bad-range':
            (details.single['target'] as Map)['range'] = [0, 1 << 30];
            break;
          case 'missing-details':
            problem.remove('choiceDetails');
            break;
        }
        altered = true;
      });
      addTearDown(engine.close);
      final project = await BusyProject.open(root.path, engine);
      addTearDown(project.close);
      final destination = '${directory.path}/converted';
      await expectLater(project.prepareMigration(root.uri.toString(), destination, targetVersion: '3.2.1'),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.protocol')));
      expect(altered, true);
      expect(await Directory(destination).exists(), false);
      expect(await root.readAsString(), original);
    });
  }
}
