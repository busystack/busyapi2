import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final value in [false, true]) {
        test(
          'boolean data/schema bundle $version $json value=$value preserves source and standalone CLI output',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-boolean-bundle-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final extension = json ? 'json' : 'yaml',
                source = File('${temp.path}/root.$extension'),
                examples = File('${temp.path}/examples.$extension');
            final target = 'examples.$extension#/components/examples/Boolean';
            final document = {
              'openapi': version,
              'info': {'title': 'Boolean 雪😀', 'version': '1'},
              'paths': <String, Object?>{},
              'components': {
                'examples': {
                  'Captured': {r'$ref': target},
                },
                'schemas': {
                  'Use': {
                    r'$ref': '$target/value',
                    'examples': [0, 'sample'],
                  },
                },
              },
            };
            final definitions = {
              'openapi': version,
              'info': {'title': 'Examples', 'version': '1'},
              'paths': <String, Object?>{},
              'components': {
                'examples': {
                  'Boolean': {'summary': 'Saved data', 'value': value},
                },
              },
            };
            String encode(Object value) => json
                ? jsonEncode(value)
                : '\ufeff# unchanged 雪😀\r\n${jsonEncode(value)}';
            await source.writeAsString(encode(document));
            await examples.writeAsString(
              json
                  ? encode(definitions)
                  : '\ufeff# aliased Boolean data 雪😀\r\nopenapi: $version\r\ninfo: {title: Examples, version: "1"}\r\npaths: {}\r\nx-boolean: &boolean $value\r\ncomponents:\r\n  examples:\r\n    Boolean: {summary: Saved data, value: *boolean}',
            );
            final original = [
              await source.readAsBytes(),
              await examples.readAsBytes(),
            ];
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(source.path, engine);
            addTearDown(project.close);
            final buffer = await project.buffer(examples.uri.toString());
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst('Saved data', 'Unsaved data'),
            );
            final plan = await project.prepareBundle(
              source.uri.toString(),
              '${temp.path}/working output 雪',
            );
            addTearDown(plan.close);
            expect(plan.unsaved, true);
            final output =
                jsonDecode(plan.result['output']['text'] as String) as Map;
            final mapped = (plan.result['provenance'] as List).singleWhere(
              (entry) =>
                  entry['kind'] == 'example' &&
                  entry['source']['resource'] == examples.uri.toString() &&
                  entry['source']['pointer'] == '/components/examples/Boolean',
            );
            Object? definition = output;
            for (final token
                in (mapped['derived']['pointer'] as String)
                    .substring(1)
                    .split('/')) {
              definition =
                  (definition as Map)[token
                      .replaceAll('~1', '/')
                      .replaceAll('~0', '~')];
            }
            expect((definition as Map)['value'], value);
            expect(definition['summary'], 'Unsaved data');
            await plan.publish();
            expect(await source.readAsBytes(), original[0]);
            expect(await examples.readAsBytes(), original[1]);
            final relocated = await Directory(plan.destination)
                .rename('${temp.path}/relocated output 雪');
            final independent = await BusyProject.open(
              '${relocated.path}/openapi.json',
              engine,
            );
            addTearDown(independent.close);
            final checked = await independent.check(
              independent.roots.single.id,
            );
            expect(checked['complete'], true, reason: jsonEncode(checked));
            expect(
              (checked['findings'] as List).where(
                (finding) => finding['code'] == 'example.schema.incompatible',
              ),
              hasLength(value ? 0 : 2),
            );
            await project.save(buffer);
            final destination = '${temp.path}/CLI output 雪';
            final saved = await project.prepareBundle(
              source.uri.toString(),
              destination,
              saved: true,
            );
            addTearDown(saved.close);
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['bundle', source.path, '--output', destination, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
            expect(cli.stderr, isEmpty);
            expect(
              await File('$destination/openapi.json').readAsString(),
              saved.result['output']['text'],
            );
            expect(await source.readAsBytes(), original[0]);
            expect(await examples.readAsBytes(), buffer.bytes());
          },
        );
      }
    }
  }
}
