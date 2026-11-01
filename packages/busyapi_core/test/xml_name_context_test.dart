import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final nodeType in ['element', 'attribute']) {
        test(
          '$version $format $nodeType XML name repair keeps source, history and saved semantics',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-xml-name-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final file = File('${temp.path}/api.$format');
            const pointer =
                '/paths/~1xml/get/responses/200/content/application~1xml/schema/xml';
            final original = format == 'json'
                ? '{"openapi":"$version","info":{"title":"XML 雪","version":"1"},"paths":{"/xml":{"get":{"responses":{"200":{"description":"XML","content":{"application/xml":{"schema":{"type":"string","xml":{"nodeType":"$nodeType","x-keep":9007199254740993.00}}}}}}}}}}'
                : '# Keep presentation\r\nopenapi: $version\r\ninfo: {title: "XML 雪", version: "1"}\r\npaths:\r\n  /xml:\r\n    get:\r\n      responses:\r\n        "200":\r\n          description: XML\r\n          content:\r\n            application/xml:\r\n              schema:\r\n                type: string\r\n                xml: {nodeType: $nodeType, x-keep: 9007199254740993.00}\r\n';
            await file.writeAsString(original);
            var project = await BusyProject.open(file.path, engine);
            addTearDown(() => project.close());
            final root = file.uri.toString();
            final checked = await project.check(root);
            final findings = (checked['findings'] as List)
                .where((f) => f['code'] == 'xml.name.required')
                .toList();
            expect(findings, hasLength(1));
            expect(findings.single['resource'], root);
            expect(findings.single['pointer'], pointer);
            expect(await file.readAsString(), original);
            final page = await project.inspectObject(root, root, pointer);
            expect(
              (page['fields'] as List).singleWhere(
                (f) => f['name'] == 'name',
              )['required'],
              true,
            );
            final buffer = await project.buffer(root);
            final range = List<int>.from(page['range'] as List);
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
                {
                  'kind': 'set',
                  'pointer': '$pointer/name',
                  'value': 'document雪',
                },
              ],
            );
            final changed = buffer.text;
            expect(changed, startsWith(original.substring(0, range[0])));
            expect(changed, endsWith(original.substring(range[1])));
            expect(changed, contains('9007199254740993.00'));
            expect(await file.readAsString(), original);
            expect((await project.check(root))['status'], 'complete');
            expect(
              (await project.inspectObject(
                root,
                root,
                pointer,
              ))['fields'].singleWhere((f) => f['name'] == 'name')['required'],
              true,
            );
            project.store.undo();
            expect(buffer.text, original);
            expect(
              (await project.check(
                root,
              ))['findings'].any((f) => f['code'] == 'xml.name.required'),
              true,
            );
            project.store.redo();
            expect(buffer.text, changed);
            await project.save(buffer);
            expect(await file.readAsBytes(), utf8.encode(changed));
            project.close();
            project = await BusyProject.open(file.path, engine);
            expect((await project.check(root))['status'], 'complete');
            expect(
              (await project.referencePage(root, root, pointer))['entries']
                  .singleWhere((field) => field['name'] == 'name')['text'],
              'document雪',
            );
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
  }
}
