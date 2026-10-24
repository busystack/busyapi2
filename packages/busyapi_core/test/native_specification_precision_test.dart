import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['json', 'yaml']) {
      test('$version $format validates exact schema numbers and enum objects', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-precision-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final file = File('${temp.path}/api.$format');
        final swagger = version == '2.0';
        final declaration = swagger ? 'swagger' : 'openapi';
        final document = {
          declaration: version,
          'info': {'title': 'Exact 雪😀', 'version': '1'},
          'paths': <String, Object?>{},
          if (swagger) 'definitions': <String, Object?>{},
          if (!swagger) 'components': {'schemas': <String, Object?>{}},
        };
        // JSON is also standard YAML. The YAML case adds a block owner and
        // comments so both CST paths, including unchanged save, are exercised.
        final prefix = format == 'json'
            ? jsonEncode(document).replaceFirst(
                swagger ? '"definitions":{}' : '"schemas":{}',
                swagger ? '"definitions":SCHEMAS' : '"schemas":SCHEMAS',
              )
            : '# exact source\r\n$declaration: "$version"\r\ninfo: {title: "Exact 雪😀", version: "1"}\r\npaths: {}\r\n${swagger ? 'definitions' : 'components:\r\n  schemas'}: SCHEMAS\r\n';
        for (final schema in [
          '{"type":"number","multipleOf":1e-999}',
          '{"enum":[9007199254740992,9007199254740993]}',
          '{"enum":[{"id":1},{"id":2}]}',
          '{"type":"number","multipleOf":0}',
          '{"type":"number","multipleOf":-1e-999}',
          '{"enum":[9007199254740993,9007199254740993.00]}',
        ]) {
          final source = prefix.replaceFirst('SCHEMAS', '{"N":$schema}');
          await file.writeAsString(source);
          final project = await BusyProject.open(file.path, engine);
          try {
            final report = await project.check(file.uri.toString());
            final valid =
                !schema.contains('multipleOf":0') &&
                !schema.contains('multipleOf":-') &&
                !(swagger && schema.contains('9007199254740993.00'));
            expect(
              report['status'],
              valid ? 'complete' : 'invalid',
              reason: '$schema: $report',
            );
            await project.save(await project.buffer(file.uri.toString()));
            expect(await file.readAsString(), source);
          } finally {
            project.close();
          }
        }
      });
    }
  }
}
