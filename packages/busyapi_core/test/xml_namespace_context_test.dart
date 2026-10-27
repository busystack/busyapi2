import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format namespace repair preserves native family, bytes and history',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-namespace-core-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          final definitions = version == '2.0' ? 'definitions' : 'components';
          final model = {
            'type': 'string',
            'xml': {'name': 'document', 'namespace': './relative'},
            'x-kept': 'EXACT',
          };
          final value = {
            version == '2.0' ? 'swagger' : 'openapi': version,
            'info': {'title': 'Namespace 雪', 'version': '1'},
            'paths': {},
            definitions: version == '2.0'
                ? {'Model': model}
                : {
                    'schemas': {'Model': model},
                  },
          };
          final original = format == 'json'
              ? const JsonEncoder.withIndent('  ')
                    .convert(value)
                    .replaceFirst('"EXACT"', '9007199254740993.00')
              : '# Keep namespace 雪\r\n${version == '2.0' ? 'swagger' : 'openapi'}: "$version"\r\ninfo: {title: "Namespace 雪", version: "1"}\r\npaths: {}\r\n${version == '2.0' ? 'definitions:' : 'components:\r\n  schemas:'}\r\n    Model:\r\n      type: string\r\n      xml: {name: document, namespace: "./relative"}\r\n      x-kept: 9007199254740993.00\r\n';
          await file.writeAsString(original);
          var project = await BusyProject.open(file.path, engine);
          addTearDown(() => project.close());
          final root = file.uri.toString(),
              pointer = version == '2.0'
                  ? '/definitions/Model/xml'
                  : '/components/schemas/Model/xml';
          final before = await project.check(root);
          expect(before['status'], version == '2.0' ? 'complete' : 'invalid');
          final issues = (before['findings'] as List)
              .where((f) => f['code'] == 'xml.namespace.uri')
              .toList();
          expect(issues.length, version == '2.0' ? 0 : 1);
          if (issues.isNotEmpty) {
            expect(issues.single['resource'], root);
            expect(issues.single['pointer'], '$pointer/namespace');
          }
          final buffer = await project.buffer(root),
              page = await project.inspectObject(root, root, pointer);
          final range = List<int>.from(page['range'] as List);
          const target = 'https://namespace.example.invalid/%E9%9B%AA#part';
          await project.proposeAndApply(
            root,
            PropertySession(
              root: root,
              buffer: root,
              generation: buffer.generation,
              pointer: pointer,
              range: range,
              expected: buffer.text.substring(range[0], range[1]),
            ),
            [
              {'kind': 'set', 'pointer': '$pointer/namespace', 'value': target},
            ],
          );
          final changed = buffer.text;
          expect(changed, startsWith(original.substring(0, range[0])));
          expect(changed, endsWith(original.substring(range[1])));
          expect(changed, contains('9007199254740993.00'));
          expect(await file.readAsString(), original);
          expect((await project.check(root))['status'], 'complete');
          project.store.undo();
          expect(buffer.text, original);
          expect(
            (await project.check(root))['status'],
            version == '2.0' ? 'complete' : 'invalid',
          );
          project.store.redo();
          expect(buffer.text, changed);
          await project.save(buffer);
          final saved = await file.readAsBytes();
          await project.save(buffer);
          expect(await file.readAsBytes(), saved);
          project.close();
          project = await BusyProject.open(file.path, engine);
          expect((await project.check(root))['status'], 'complete');
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout} ${cli.stderr}');
          expect(
            (jsonDecode(cli.stdout as String) as Map)['status'],
            'complete',
          );
        },
      );
    }
  }
  test('shared XML namespace switches URI and IRI semantics with its captured root', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-namespace-roots-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final manifest = File('${temp.path}/busyapi.yaml');
    await manifest.writeAsString(
      'version: 1\nroots: [{name: old, path: old.json}, {name: modern, path: modern.json}]\n',
    );
    final shared = File('${temp.path}/shared.json');
    await shared.writeAsString(
      '{"Model":{"type":"string","xml":{"name":"document","namespace":"https://例え.invalid/雪"},"x-kept":9007199254740993.00}}',
    );
    final roots = <String, File>{};
    for (final entry in {'old': '3.0.4', 'modern': '3.2.1'}.entries) {
      final file = File('${temp.path}/${entry.key}.json');
      await file.writeAsString(
        jsonEncode({
          'openapi': entry.value,
          'info': {'title': entry.key, 'version': '1'},
          'paths': {},
          'components': {
            'schemas': {
              'Model': {r'$ref': 'shared.json#/Model'},
            },
          },
        }),
      );
      roots[entry.key] = file;
    }
    final originals = {
      for (final file in [manifest, shared, ...roots.values])
        file.path: await file.readAsBytes(),
    };
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    for (final name in ['old', 'modern', 'old', 'modern']) {
      final result = await project.check(roots[name]!.uri.toString());
      expect(result['status'], name == 'old' ? 'invalid' : 'complete');
      final issues = (result['findings'] as List)
          .where((f) => f['code'] == 'xml.namespace.uri')
          .toList();
      expect(issues.length, name == 'old' ? 1 : 0);
      if (issues.isNotEmpty)
        expect(issues.single['resource'], shared.uri.toString());
    }
    for (final entry in originals.entries)
      expect(await File(entry.key).readAsBytes(), entry.value);
  });
  for (final version in ['3.0.4', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format unsupported namespace hosts remain incomplete in Core and CLI',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-namespace-incomplete-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          final original =
              '${format == 'yaml' ? '# Keep source\r\n' : ''}${jsonEncode({
                'openapi': version,
                'info': {'title': 'Incomplete namespace', 'version': '1'},
                'paths': {},
                'components': {
                  'schemas': {
                    'Model': {
                      'type': 'string',
                      'xml': {'namespace': 'https://[v1.future]/namespace'},
                    },
                  },
                },
              })}';
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final result = await project.check(file.uri.toString());
          expect(result['complete'], false);
          expect(result['status'], 'incomplete');
          expect(
            (result['findings'] as List).singleWhere(
              (finding) => finding['code'] == 'xml.namespace.unsupported',
            )['severity'],
            'warning',
          );
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 2, reason: '${cli.stdout} ${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['status'], 'incomplete');
          expect(report['complete'], false);
          expect(
            (report['findings'] as List).any(
              (finding) => finding['code'] == 'xml.namespace.unsupported',
            ),
            true,
          );
          expect(await file.readAsString(), original);
        },
      );
    }
  }
}
