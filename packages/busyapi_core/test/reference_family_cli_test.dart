import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format installed CLI retains incomplete reference context and original files',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-reference-cli-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final source = File('${temp.path}/api.$format'),
              part = File('${temp.path}/part.$format');
          final legacy = version == '2.0';
          final reference = './part.$format#/components/schemas/Value';
          String text(Map<String, Object?> value) {
            final json = jsonEncode(value)
                .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
            return format == 'yaml' ? '# Preserve 雪\r\n$json\r\n' : json;
          }

          final original = text({
            legacy ? 'swagger' : 'openapi': version,
            'info': {'title': 'Original', 'version': 'api-version'},
            'paths': {},
            if (legacy)
              'definitions': {
                'Value': {r'$ref': reference},
              }
            else
              'components': {
                'schemas': {
                  'Value': {r'$ref': reference},
                },
              },
            'x-data': {r'$ref': 'literal', 'exact': 'EXACT_VALUE'},
          });
          final external = text({
            'openapi': '3.1.2',
            'info': {'title': 'External', 'version': 'api-version'},
            'paths': {},
            'components': {
              'schemas': {
                'Value': {'type': 'string', 'nullable': true},
              },
            },
          });
          await source.writeAsString(original);
          await part.writeAsString(external);
          for (final command in ['check', 'bundle', 'build-docs']) {
            final destination = '${temp.path}/output-$command';
            final result = await Process.run(
              '$testBundle/busyapi',
              [
                command,
                source.path,
                if (command != 'check') ...['--output', destination],
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              result.exitCode,
              2,
              reason: '${result.stdout}\n${result.stderr}',
            );
            final report = jsonDecode(result.stdout as String) as Map;
            expect(report['complete'], false);
            expect(report['status'], 'incomplete');
            final findings = (report['findings'] as List).whereType<Map>();
            expect(
              findings.any(
                (finding) =>
                    finding['code'] == 'reference.family.unsupported' &&
                    finding['resource'] == source.uri.toString() &&
                    finding['pointer'] ==
                        '${legacy ? '/definitions/Value' : '/components/schemas/Value'}/\$ref',
              ),
              true,
              reason: '${result.stdout}',
            );
            expect(Directory(destination).existsSync(), false);
            expect(await source.readAsString(), original);
            expect(await part.readAsString(), external);
          }
        },
      );
    }
  }
}
