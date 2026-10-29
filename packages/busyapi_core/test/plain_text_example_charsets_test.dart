import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

Future<({int code, String output, String error})> _check(String path) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    ['check', path, '--json'],
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  var exited = false;
  final completion = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  try {
    await process.stdin.close();
    final code = await completion.timeout(const Duration(seconds: 60));
    return (code: code, output: await output, error: await error);
  } finally {
    if (!exited) {
      process.kill();
      await completion.timeout(const Duration(seconds: 5));
    }
  }
}

void main() {
  for (final version in ['3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final (media, value, complete, valid) in [
        ('text/plain', 'false', true, true),
        ('text/plain', 'café', true, false),
        ('text/plain; charset=us-ascii', 'false', true, true),
        ('text/plain; charset=us-ascii', 'café', true, false),
        ('text/plain; charset=iso-8859-1', 'café', false, false),
        ('text/plain; charset=iso-8859-1', '雪😀', false, false),
        ('text/plain; charset=utf-8', '雪😀', true, true),
        ('text/plain; charset=shift_jis', 'plain', false, false),
      ]) {
        test('$version $format serialized Unicode example $media ${jsonEncode(value)}', () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-plain-example-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final root = File('${temp.path}/api.$format'),
              examples = File('${temp.path}/examples.$format');
          final source =
              '${format == 'yaml' ? '# Keep root\r\n' : ''}${jsonEncode({
                'openapi': version,
                'info': {'title': 'Original examples', 'version': 'business'},
                'paths': {
                  '/data': {
                    'post': {
                      'requestBody': {
                        'content': {
                          media: {
                            'schema': {'type': 'string'},
                            'examples': {
                              'Native': {r'$ref': 'examples.$format#/components/examples/Native'},
                            },
                          },
                        },
                      },
                      'responses': {
                        '204': {'description': 'None'},
                      },
                    },
                  },
                },
                'x-number': 'EXACT',
              }).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
          final exampleSource =
              '${format == 'yaml' ? '# Keep shared example\r\n' : ''}${jsonEncode({
                'openapi': '3.2.1',
                'info': {'title': 'Shared 3.2 example', 'version': 'business'},
                'paths': <String, Object?>{},
                'components': {
                  'examples': {
                    'Native': {'serializedValue': value},
                  },
                },
              })}\r\n';
          await root.writeAsString(source);
          await examples.writeAsString(exampleSource);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final result = await project.check(root.uri.toString());
          expect(result['complete'], complete, reason: jsonEncode(result));
          final evaluations =
              result['categories']['openapi']['schema']['serializedExamples']
                  as List;
          expect(evaluations, hasLength(1), reason: jsonEncode(result));
          expect(evaluations.single['complete'], complete);
          expect(evaluations.single['valid'], valid);
          expect(evaluations.single['resource'], examples.uri.toString());
          if (version == '3.2.1') {
            final cli = await _check(root.path);
            expect(
              cli.code,
              complete ? 0 : 2,
              reason: '${cli.output}\n${cli.error}',
            );
            final report = jsonDecode(cli.output) as Map;
            expect(report['complete'], complete);
            final checked =
                (report['categories'] as List)
                        .single['results']['openapi']['schema']['serializedExamples']
                    as List;
            expect(checked.single['valid'], valid);
            if (complete && !valid) {
              expect(
                (report['findings'] as List).whereType<Map>().any(
                  (finding) =>
                      finding['code'] == 'example.serialization.incompatible' &&
                      finding['severity'] == 'warning',
                ),
                true,
              );
            }
          }
          expect(await root.readAsString(), source);
          expect(await examples.readAsString(), exampleSource);
        });
      }
    }
  }
}
