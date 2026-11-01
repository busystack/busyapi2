import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'operation relocation $version $json reviews every root and preserves source/history/publication',
        () async {
          final temporary = await Directory.systemTemp.createTemp(
            'busyapi-operation-move-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          BusyProject? project;
          try {
            final extension = json ? 'json' : 'yaml';
            final file = File('${temporary.path}/root.$extension');
            final links = File('${temporary.path}/links.json');
            final other = File('${temporary.path}/other.json');
            final manifest = File('${temporary.path}/busyapi.yaml');
            const sourcePointer = '/paths/~1old~1{id}/get';
            final value = {
              'openapi': version,
              'info': {'title': 'Root', 'version': '1'},
              'paths': {
                '/old/{id}': {
                  'parameters': [
                    {
                      'name': 'id',
                      'in': 'path',
                      'required': true,
                      'schema': {'type': 'integer', 'minimum': 111},
                    },
                  ],
                  'servers': [
                    {'url': './source'},
                  ],
                  'get': {
                    'operationId': 'moveMe',
                    'summary': 'Before',
                    'responses': {
                      '204': {'description': 'Bodyless'},
                    },
                  },
                  'post': {
                    'operationId': 'sibling',
                    'responses': {
                      '204': {'description': 'Sibling'},
                    },
                  },
                },
                '/new/{id}': {
                  'parameters': [
                    {
                      'name': 'id',
                      'in': 'path',
                      'required': true,
                      'schema': {'type': 'integer'},
                    },
                  ],
                  'get': {
                    'operationId': 'destinationSibling',
                    'responses': {
                      '204': {'description': 'Destination sibling'},
                    },
                  },
                },
              },
              'components': {
                'links': {
                  'Usage': {r'$ref': 'links.json#/Usage'},
                },
              },
              'x-kept': {r'$ref': '#$sourcePointer', 'n': 111},
            };
            final text = json
                ? const JsonEncoder.withIndent('  ')
                      .convert(value)
                      .replaceAll('111', '9007199254740993.00')
                : '# preserved 雪😀\r\nopenapi: $version\r\ninfo: {title: Root, version: \'1\'}\r\npaths:\r\n  /old/{id}:\r\n    parameters:\r\n      - name: id\r\n        in: path\r\n        required: true\r\n        schema: {type: integer, minimum: 9007199254740993.00}\r\n    servers: [{url: ./source}]\r\n    get:\r\n      operationId: moveMe\r\n      summary: \'Before\'\r\n      responses: {204: {description: Bodyless}}\r\n    post: {operationId: sibling, responses: {204: {description: Sibling}}}\r\n  /new/{id}:\r\n    parameters: [{name: id, in: path, required: true, schema: {type: integer}}]\r\n    get: {operationId: destinationSibling, responses: {204: {description: Destination sibling}}}\r\ncomponents:\r\n  links:\r\n    Usage: {\$ref: "links.json#/Usage"}\r\nx-kept: {\$ref: "#$sourcePointer", n: 9007199254740993.00}';
            await file.writeAsString('\uFEFF$text');
            final linksText =
                '{"Usage":{"operationRef":"root.$extension#$sourcePointer"},"x-data":{"\$ref":"#$sourcePointer","number":9007199254740993}}';
            await links.writeAsString(linksText);
            final otherText = jsonEncode({
              'openapi': version,
              'info': {'title': 'Other', 'version': '1'},
              'paths': {},
              'components': {
                'links': {
                  'Usage': {r'$ref': 'links.json#/Usage'},
                },
              },
            });
            await other.writeAsString(otherText);
            const manifestText =
                '# retained configuration\nversion: 1\nroots: [{name: Main, path: root.EXT}, {name: Other, path: other.json}]\nx-kept: true\n';
            await manifest.writeAsString(
              manifestText.replaceFirst('EXT', extension),
            );
            project = await BusyProject.open(temporary.path, engine);
            final root = file.uri.toString(), linkId = links.uri.toString();
            final buffer = await project.buffer(root);
            project.store.replace(
              root,
              buffer.text.replaceFirst('Before', 'Unsaved'),
            );
            final before = buffer.bytes(),
                otherBuffer = await project.buffer(other.uri.toString());
            Future<RefactoringPlan> prepare({bool noop = false}) async {
              final owner = project!;
              final object = await owner.inspectObject(
                root,
                root,
                sourcePointer,
              );
              final range = List<int>.from(object['range'] as List);
              return owner.planOperationMove(
                {
                  'root': root,
                  'resource': root,
                  'pointer': sourcePointer,
                  'generation': buffer.generation,
                  'range': range,
                  'expected': buffer.text.substring(range[0], range[1]),
                },
                method: noop
                    ? 'get'
                    : version.startsWith('3.2')
                    ? 'COPY'
                    : 'patch',
                additional: !noop && version.startsWith('3.2'),
                context: 'preserve',
                path: noop ? '/old/{id}' : '/new/{id}',
              );
            }

            final noop = await prepare(noop: true);
            expect(noop.hasChanges, false);
            final generation = buffer.generation;
            final stale = await prepare();
            expect(stale.checkedRoots.toSet(), {root, other.uri.toString()});
            expect(stale.edits.map((edit) => edit.buffer).toSet(), {
              root,
              linkId,
            });
            expect(stale.result['usages'], isNotEmpty);
            expect(buffer.bytes(), before);
            expect(
              buffer.generation,
              generation,
              reason: 'Planning and cancellation cannot mutate source',
            );
            project.store.replace(
              otherBuffer.id,
              otherBuffer.text.replaceFirst('Other', 'Later'),
            );
            await expectLater(
              project.applyRefactoring(stale),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'refactor.stale',
                ),
              ),
            );
            expect(buffer.bytes(), before);
            expect((await project.buffer(linkId)).text, linksText);
            project.store.undo();
            final plan = await prepare();
            final changed = await project.applyRefactoring(plan);
            expect(changed, {root, linkId});
            final moved = buffer.bytes(),
                movedLinks = (await project.buffer(linkId)).bytes();
            expect(buffer.text, contains('9007199254740993.00'));
            expect(
              buffer.text,
              contains('#$sourcePointer'),
              reason:
                  'Literal payload references do not follow the semantic move',
            );
            final destination = plan.result['to']['pointer'] as String;
            expect(
              (await project.inspectObject(
                root,
                root,
                destination,
              ))['value']['summary'],
              'Unsaved',
            );
            expect(
              (await project.check(root))['operations'].any(
                (operation) =>
                    operation['operationId'] == 'sibling' ||
                    operation['value']['operationId'] == 'sibling',
              ),
              true,
            );
            project.store.undo();
            expect(buffer.bytes(), before);
            expect((await project.buffer(linkId)).text, linksText);
            project.store.redo();
            expect(buffer.bytes(), moved);
            expect((await project.buffer(linkId)).bytes(), movedLinks);
            expect(await file.readAsBytes(), utf8.encode('\uFEFF$text'));
            for (final id in changed) {
              await project.save(await project.buffer(id));
            }
            expect(await file.readAsBytes(), moved);
            expect(await links.readAsBytes(), movedLinks);
            expect(await other.readAsString(), otherText);
            expect(
              await manifest.readAsString(),
              manifestText.replaceFirst('EXT', extension),
            );
            project.close();
            project = await BusyProject.open(temporary.path, engine);
            expect((await project.buffer(root)).bytes(), moved);
            expect((await project.buffer(linkId)).bytes(), movedLinks);
            final reopened = await project.check(root);
            expect(reopened['status'], 'complete', reason: '$reopened');
            final result = await Process.run(
              '$testBundle/busyapi',
              ['check', temporary.path, '--root', 'Main', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(jsonDecode(result.stdout as String)['complete'], true);
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
