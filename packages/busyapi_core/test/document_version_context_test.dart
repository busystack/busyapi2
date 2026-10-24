import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'owning document $version $json keeps native fields, Source help, history and saved bytes',
        () async {
          final temporary = await Directory.systemTemp.createTemp(
            'busyapi-document-version-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          BusyProject? project;
          try {
            final family = version.substring(0, 3);
            final entry = family == '3.1' ? '3.2.1' : '3.1.2';
            final extension = json ? 'json' : 'yaml';
            final root = File('${temporary.path}/entry.$extension');
            final part = File('${temporary.path}/part.$extension');
            final reference = 'part.$extension#/components/pathItems/Shared';
            await root.writeAsString(
              json
                  ? jsonEncode({
                      'openapi': entry,
                      'info': {'title': 'Entry', 'version': '1'},
                      'paths': {
                        '/shared': {r'$ref': reference},
                      },
                    })
                  : 'openapi: $entry\ninfo: {title: Entry, version: "1"}\npaths:\n  /shared: {\$ref: "$reference"}\n',
            );
            final text = json
                ? jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Owned 雪😀', 'version': '1'},
                    'paths': {},
                    'components': {
                      'pathItems': {
                        'Shared': {
                          'get': {
                            'summary': 'Before',
                            'responses': {
                              '204': {'description': 'Bodyless'},
                            },
                          },
                        },
                      },
                      'schemas': {
                        'Model': {'type': 'integer'},
                      },
                    },
                    'x-number': 111,
                  }).replaceFirst('111', '9007199254740993')
                : '# Preserved\r\nopenapi: $version\r\ninfo: {title: "Owned 雪😀", version: \'1\'}\r\npaths: {}\r\ncomponents:\r\n  pathItems:\r\n    Shared:\r\n      get:\r\n        summary: \'Before\'\r\n        responses: {204: {description: Bodyless}}\r\n  schemas:\r\n    Model: {type: integer}\r\nx-number: 9007199254740993';
            final original = utf8.encode('\uFEFF$text');
            await part.writeAsBytes(original);
            project = await BusyProject.open(root.path, engine);
            final rootId = root.uri.toString(), partId = part.uri.toString();
            final result = await project.check(rootId);
            expect(
              result['status'],
              'complete',
              reason: '${result['findings']}',
            );
            final page = await project.inspectObject(
              rootId,
              partId,
              '/components/pathItems/Shared',
            );
            expect(page['family'], family);
            expect(
              (page['fields'] as List).any((field) => field['name'] == 'query'),
              family == '3.2',
            );
            expect(
              (page['fields'] as List).any(
                (field) => field['name'] == 'additionalOperations',
              ),
              family == '3.2',
            );
            final buffer = await project.buffer(partId);
            final caret = buffer.text.indexOf('summary') + 3;
            final help = await project.assistSource(
              rootId,
              partId,
              SourceSelection(caret, caret),
              action: 'help',
            );
            expect(
              help.result['help']['standard'],
              contains('/v$version.html#operation-object'),
            );
            expect(
              help.result['help']['dialect'],
              'https://spec.openapis.org/oas/$family/dialect/base',
            );
            final referencePage = await project.referencePage(
              rootId,
              partId,
              '/components/pathItems/Shared/get',
            );
            expect(referencePage['family'], family);

            Future<void> change(String summary) async {
              const pointer = '/components/pathItems/Shared/get';
              final owner = project!;
              final object = await owner.inspectObject(rootId, partId, pointer);
              final range = List<int>.from(object['range'] as List);
              await owner.proposeAndApply(
                rootId,
                PropertySession(
                  root: rootId,
                  buffer: partId,
                  generation: buffer.generation,
                  pointer: pointer,
                  range: range,
                  expected: buffer.text.substring(range[0], range[1]),
                ),
                [
                  {
                    'kind': 'set',
                    'pointer': '$pointer/summary',
                    'value': summary,
                  },
                ],
              );
            }

            final generation = buffer.generation;
            await change('Before');
            expect(buffer.generation, generation);
            expect(buffer.bytes(), original);
            await change('After 雪😀');
            final expectedText = text.replaceFirst('Before', 'After 雪😀');
            expect(buffer.bytes(), utf8.encode('\uFEFF$expectedText'));
            expect(
              await part.readAsBytes(),
              original,
              reason: 'Unsaved authoring is not publication',
            );
            project.store.undo();
            expect(buffer.bytes(), original);
            project.store.redo();
            expect(buffer.bytes(), utf8.encode('\uFEFF$expectedText'));
            await project.save(buffer);
            expect(await part.readAsBytes(), buffer.bytes());
            project.close();
            project = await BusyProject.open(root.path, engine);
            expect(
              (await project.buffer(partId)).bytes(),
              utf8.encode('\uFEFF$expectedText'),
            );
            expect(
              (await project.inspectObject(
                rootId,
                partId,
                '/components/pathItems/Shared',
              ))['family'],
              family,
            );
            expect((await project.check(rootId))['status'], 'complete');
            expect(await root.readAsString(), contains(entry));
          } finally {
            project?.close();
            await engine.close();
            await temporary.delete(recursive: true);
          }
        },
      );
    }
  }
}
