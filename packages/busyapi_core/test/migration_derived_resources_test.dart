import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _ChangedDerivedReview extends EngineProcess {
  _ChangedDerivedReview(this.change)
    : super(executable: runtimeNode, helper: runtimeHelper);

  final void Function(Map<String, dynamic>) change;

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method != 'planMigration' || result['complete'] != true) return result;
    final changed = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
    change(changed);
    return changed;
  }
}

void main() {
  for (final corruption in [
    'missing-owner',
    'unknown-owner',
    'existing-resource',
    'duplicate-destination',
    'invented-before',
  ]) {
    test('Core rejects derived migration resource $corruption', () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-migration-derived-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.json');
      final schema = {
        'type': 'object',
        'required': ['value'],
        'properties': {
          'value': {'type': 'string', 'readOnly': true},
        },
      };
      final original = jsonEncode({
        'openapi': '3.0.4',
        'info': {'title': 'Derived schema review', 'version': '1'},
        'paths': {
          '/value': {
            'post': {
              'requestBody': {
                'content': {
                  'application/json': {'schema': schema},
                },
              },
              'responses': {
                '200': {
                  'description': 'Reply',
                  'content': {
                    'application/json': {'schema': schema},
                  },
                },
              },
            },
          },
        },
      });
      await file.writeAsString(original);
      var altered = false;
      final engine = _ChangedDerivedReview((result) {
        final changes = (result['changes'] as List).cast<Map>();
        final derived = changes.firstWhere(
          (change) => change.containsKey('createdFrom'),
        );
        switch (corruption) {
          case 'missing-owner':
            derived.remove('createdFrom');
            break;
          case 'unknown-owner':
            derived['createdFrom'] = 'file:///not-captured/api.json';
            break;
          case 'existing-resource':
            derived['resource'] = file.uri.toString();
            break;
          case 'duplicate-destination':
            derived['destination'] = changes.first['destination'];
            break;
          case 'invented-before':
            derived['before'] = 'not a captured source';
            break;
        }
        altered = true;
      });
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final destination = '${directory.path}/converted';
      await expectLater(
        project.prepareMigration(
          file.uri.toString(),
          destination,
          targetVersion: '3.1.2',
        ),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'migration.protocol',
          ),
        ),
      );
      expect(altered, true);
      expect(await Directory(destination).exists(), false);
      expect(await file.readAsString(), original);
    });
  }
}
