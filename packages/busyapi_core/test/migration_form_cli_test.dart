import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format installed CLI reviews and publishes native formData',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-form-cli-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final file = File('${temp.path}/api.$format');
          final media = {
            'schema': {
              'type': 'object',
              'required': ['name'],
              'properties': {
                'name': {'type': 'string'},
                'count': {'type': 'integer', 'default': 0},
                'tags': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
              },
            },
            'encoding': {
              'tags': {'style': 'form'},
            },
          };
          final document = {
            'openapi': version,
            'info': {'title': 'CLI 雪', 'version': '1'},
            'servers': [
              {'url': 'https://fixture.invalid'},
            ],
            'paths': {
              '/items': {
                'post': {
                  'requestBody': {
                    'required': true,
                    'content': {'application/x-www-form-urlencoded': media},
                  },
                  'responses': {
                    '200': {'description': 'No response body'},
                  },
                },
              },
            },
          };
          final original = utf8.encode(
            (format == 'yaml' ? '# Preserve CLI source\r\n' : '') +
                jsonEncode(document),
          );
          await file.writeAsBytes(original);
          final destination = '${temp.path}/published';
          Future<ProcessResult> command(List<String> arguments) => Process.run(
            '$testBundle/busyapi',
            arguments,
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final arguments = [
            'migrate',
            file.path,
            '--target',
            '2.0',
            '--output',
            destination,
            '--json',
          ];
          final reviewed = await command(arguments);
          expect(
            reviewed.exitCode,
            0,
            reason: '${reviewed.stdout}\n${reviewed.stderr}',
          );
          final report = jsonDecode(reviewed.stdout as String) as Map;
          expect(report['status'], 'faithfully-convertible');
          expect(report['published'], false);
          expect(await Directory(destination).exists(), false);
          final applied = await command([
            ...arguments,
            '--apply',
            report['reviewIdentity'] as String,
          ]);
          expect(
            applied.exitCode,
            0,
            reason: '${applied.stdout}\n${applied.stderr}',
          );
          expect(
            (jsonDecode(applied.stdout as String) as Map)['published'],
            true,
          );
          final checked = await command(['check', destination, '--json']);
          expect(
            checked.exitCode,
            0,
            reason: '${checked.stdout}\n${checked.stderr}',
          );
          final receipt = jsonDecode(
            await File('$destination/migration.json').readAsString(),
          ) as Map;
          expect((receipt['target'] as Map)['declaredVersion'], '2.0');
          final output = await File('$destination/${receipt['entry']}')
              .readAsString();
          expect(output, contains('formData'));
          expect(output, contains('multi'));
          expect(output, isNot(contains('requestBody')));
          expect(await file.readAsBytes(), original);
        },
      );
    }
  }
}
