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

Future<(File, File, String, String)> _files(
  Directory directory,
  String version,
  String format, {
  String composition = 'oneOf',
  bool required = false,
}) async {
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
  final parent = <String, Object?>{
    'type': 'object',
    'discriminator': {'propertyName': 'kind'},
    if (required) 'required': ['kind'],
    if (required || composition == 'allOf') 'properties': {'kind': {'type': 'string'}},
    if (composition != 'allOf') composition: [{r'$ref': '#/Cat'}, {r'$ref': '#/Other'}],
    'example': {if (required) 'kind': 'future', 'value': 'café'},
  };
  final schemas = <String, Object?>{
    'Parent': parent,
    'Cat': {'type': 'object', 'required': ['kind'], 'properties': {'kind': {'enum': ['Cat']}}},
    'Other': {'type': 'object', 'required': ['value'], 'properties': {
      'kind': {'type': 'string', 'not': {'enum': ['Cat', 'Other']}},
      'value': {'type': 'string'},
    }},
  };
  if (composition == 'allOf') {
    for (final name in ['Cat', 'Other']) {
      schemas[name] = {'allOf': [{r'$ref': '#/Parent'}, schemas[name]]};
    }
  }
  final definitions = _render(schemas, format);
  await root.writeAsString(original);
  await models.writeAsString(definitions);
  return (root, models, original, definitions);
}

void main() {
  for (final format in ['yaml', 'json']) {
    for (final composition in ['oneOf', 'anyOf', 'allOf']) {
      test('3.0.4 $format $composition optional discriminator cannot enter fallback review', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-invalid-discriminator-');
        addTearDown(() => directory.delete(recursive: true));
        final (root, models, original, definitions) = await _files(directory, '3.0.4', format, composition: composition);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final result = await project.check(root.uri.toString());
        expect(result['status'], 'invalid', reason: '$result');
        expect((result['findings'] as List).where((finding) =>
            finding['code'] == 'discriminator.required' &&
            finding['resource'] == models.uri.toString() &&
            finding['pointer'] == '/Parent/discriminator/propertyName'), isNotEmpty);
        final destination = '${directory.path}/converted';
        final review = await project.prepareMigration(root.uri.toString(), destination, targetVersion: '3.2.1');
        addTearDown(review.close);
        expect(review.status, MigrationStatus.blocked);
        expect(review.problems.any((problem) => problem.code == 'migration.validation.discriminator.required'), true);
        expect(review.problems.any((problem) => problem.code == 'migration.discriminator.default'), false);
        expect(review.publishable, false);
        await expectLater(review.publish(), throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.blocked')));
        expect(await Directory(destination).exists(), false);
        expect(await root.readAsString(), original);expect(await models.readAsString(), definitions);
      });

      test('3.0.4 $format $composition required discriminator upgrades without a fallback decision', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-required-discriminator-');
        addTearDown(() => directory.delete(recursive: true));
        final (root, models, original, definitions) = await _files(directory, '3.0.4', format, composition: composition, required: true);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final source = await project.check(root.uri.toString());
        expect(source['status'], 'complete', reason: '$source');
        final destination = '${directory.path}/converted';
        final review = await project.prepareMigration(root.uri.toString(), destination, targetVersion: '3.2.1');
        addTearDown(review.close);
        expect(review.publishable, true, reason: '${review.result}');
        expect(review.problems, isEmpty);expect(review.result['acceptedDecisions'], isEmpty);
        await review.publish();
        final output = await BusyProject.open(destination, engine);
        addTearDown(output.close);
        final checked = await output.check(output.roots.single.id);
        expect(checked['status'], 'complete', reason: '$checked');
        final references = (checked['projection'] as Map)['references'] as List;
        expect(references.where((reference) => reference['keyword'] == 'defaultMapping'), isEmpty);
        final parentReference = references.singleWhere((reference) => reference['pointer'] == r'/components/schemas/Parent/$ref');
        final parent = await output.inspectObject(output.roots.single.id,
            parentReference['targetResource'] as String, parentReference['targetPointer'] as String);
        expect(parent['value']['required'], ['kind']);
        expect(parent['value']['discriminator']['propertyName'], 'kind');
        expect((parent['value']['discriminator'] as Map).containsKey('defaultMapping'), false);
        expect(await root.readAsString(), original);expect(await models.readAsString(), definitions);
      });
    }
  }

  for (final version in ['3.1.2']) {
    for (final format in ['yaml', 'json']) {
      for (final composition in ['oneOf', 'anyOf', 'allOf']) {
        test('$version $format $composition fallback decisions bind unsaved resources and publish only the chosen alternative', () async {
          final directory = await Directory.systemTemp.createTemp('busyapi-discriminator-default-');
          addTearDown(() => directory.delete(recursive: true));
          final (root, models, original, definitions) = await _files(directory, version, format, composition: composition);
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
          final references = (checked['projection'] as Map)['references'] as List;
          final fallback = references.singleWhere((reference) => reference['keyword'] == 'defaultMapping');
          expect(fallback['resolution'], 'resolved');expect(fallback['targetPointer'], '/Other');
          final selectedSchema = await output.inspectObject(output.roots.single.id, fallback['targetResource'] as String, '/Other');
          final selectedValue = selectedSchema['value'] as Map;
          final assertions = composition == 'allOf' ? (selectedValue['allOf'] as List)[1] as Map : selectedValue;
          expect(assertions['required'], ['value']);expect((assertions['properties'] as Map)['value'], {'type': 'string'});
          expect(await root.readAsString(), original);
          expect(await models.readAsString(), definitions);
          expect(buffer.dirty, true);
        });
      }
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
