import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final field in [
        'externalValue',
        if (version.startsWith('3.2.')) 'serializedValue',
      ]) {
        test('$version $format $field cannot report complete validation', () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-example-coverage-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final example = <String, Object?>{
            field: field == 'externalValue' ? './wire.txt' : 'id=0',
            if (version.startsWith('3.2.')) 'dataValue': 0,
          };
          final document = {
            'openapi': version,
            'info': {'title': 'Keep 雪', 'version': 'api-version'},
            'paths': {
              '/check': {
                'get': {
                  'parameters': [
                    {
                      'name': 'id',
                      'in': 'query',
                      'schema': {'type': 'integer'},
                      'examples': {'Case': example},
                    },
                  ],
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
          };
          final original =
              '${format == 'yaml' ? '# retained 雪\r\n' : ''}${jsonEncode(document)}\r\n';
          final file = File('${directory.path}/api.$format');
          final bytes = [239, 187, 191, ...utf8.encode(original)];
          await file.writeAsBytes(bytes);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          final pointer =
              '/paths/~1check/get/parameters/0/examples/Case/$field';
          Future<void> incomplete() async {
            final result = await project.check(buffer.id);
            expect(result['complete'], false, reason: jsonEncode(result));
            expect(result['status'], 'incomplete');
            final findings = result['findings'] as List;
            final finding = findings.singleWhere(
              (value) => value['code'] == 'example.serialization.incomplete',
            );
            expect(finding['resource'], buffer.id);
            expect(finding['pointer'], pointer);
            expect(finding['severity'], 'warning');
            expect(
              finding['detailCode'],
              field == 'externalValue'
                  ? 'example.external-value.unavailable'
                  : 'example.serialization.context-unchecked',
            );
            expect(
              result['categories']['openapi']['schema']['producerVersion'],
              '1.18.0+28',
            );
          }

          await incomplete();
          final before = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(
            before.exitCode,
            2,
            reason: '${before.stdout}\n${before.stderr}',
          );
          expect(jsonDecode(before.stdout as String)['status'], 'incomplete');
          expect(await file.readAsBytes(), bytes);
          final repaired = version.startsWith('3.2.')
              ? original.replaceFirst(
                  '${jsonEncode(field)}:${jsonEncode(example[field])},',
                  '',
                )
              : original.replaceFirst(
                  '${jsonEncode(field)}:${jsonEncode(example[field])}',
                  '"value":0',
                );
          expect(repaired, isNot(original));
          project.store.replace(buffer.id, repaired);
          final checked = await project.check(buffer.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(checked['status'], 'complete');
          expect(await file.readAsBytes(), bytes);
          project.store.undo();
          expect(buffer.bytes(), bytes);
          await incomplete();
          project.store.redo();
          expect(buffer.text, repaired);
          await project.save(buffer);
          final after = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(after.exitCode, 0, reason: '${after.stdout}\n${after.stderr}');
          expect(jsonDecode(after.stdout as String)['status'], 'complete');
          expect(await file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(repaired),
          ]);
          expect(await File('${directory.path}/wire.txt').exists(), false);
        });
      }
    }
  }
}
