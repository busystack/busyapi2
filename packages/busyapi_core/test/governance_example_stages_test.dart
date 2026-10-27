import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in [
    '3.0.0',
    '3.0.4',
    '3.1.0',
    '3.1.2',
    '3.2.0',
    '3.2.1',
  ]) {
    for (final format in ['yaml', 'json']) {
      test('$version $format policy owns authored-data completeness', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-policy-example-stages-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final document = {
          'openapi': version,
          'info': {'title': 'Stages 雪', 'version': 'api-version'},
          'paths': {
            '/check': {
              'get': {
                'responses': {
                  '200': {
                    'description': 'Read',
                    'content': {
                      'application/json': {
                        'schema': {
                          'type': 'integer',
                          'enum': [0],
                        },
                        'examples': {
                          'good': {'value': 0},
                          'bad': {'value': false},
                          'external': {
                            'externalValue':
                                'https://example.invalid/not-acquired',
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
          'x-exact': 'EXACT',
        };
        String render() =>
            '${format == 'yaml' ? '# retained stage ownership\r\n' : ''}${jsonEncode(document).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
        final original = render(), file = File('${directory.path}/api.$format');
        final bytes = [239, 187, 191, ...utf8.encode(original)];
        await file.writeAsBytes(bytes);
        await File('${directory.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots: [{name: Main, path: api.$format}]\n'
          'policy: {rulesets: ["spectral:oas"]}\n',
        );
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(file.uri.toString());
        final captured = await project.lint(buffer.id);
        expect(captured['complete'], false);
        expect(lintExitCode(captured), 2);
        expect(captured['categories']['openapi']['complete'], false);
        expect(captured['categories']['policy']['complete'], true);
        final schema = captured['categories']['openapi']['schema'];
        expect(schema['producerVersion'], '1.18.0+33');
        expect(schema['coverage']['authoredData']['complete'], true);
        expect(
          schema['coverage']['serializedMediaExamples']['complete'],
          false,
        );
        expect(
          (captured['findings'] as List)
              .where((f) => f['code'] == 'policy.rule.oas3-valid-media-example')
              .single['pointer'],
          endsWith('/examples/bad/value'),
        );
        final process = await Process.run('$testBundle/busyapi', [
          'lint',
          file.path,
          '--json',
        ]);
        expect(
          process.exitCode,
          2,
          reason: '${process.stdout}\n${process.stderr}',
        );
        final cli = jsonDecode(process.stdout as String);
        final categories = (cli['categories'] as List).single['results'];
        expect(categories['openapi']['complete'], false);
        expect(categories['policy']['complete'], true);
        expect(categories['openapi']['schema']['coverage'], schema['coverage']);
        project.store.replace(
          buffer.id,
          buffer.text.replaceFirst(
            ',"external":{"externalValue":"https://example.invalid/not-acquired"}',
            '',
          ),
        );
        expect(buffer.dirty, true);
        final working = await project.lint(buffer.id);
        expect(working['complete'], true, reason: jsonEncode(working));
        expect(lintExitCode(working), 1);
        final saved = await project.lint(buffer.id, saved: true);
        expect(saved['complete'], false);
        expect(saved['categories']['policy']['complete'], true);
        expect(await file.readAsBytes(), bytes);
        project.store.undo();
        expect(buffer.text, original);
      });
    }
  }
}
