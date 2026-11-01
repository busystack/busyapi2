import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'mixed legal root dialects render/export through the shared core without bundling $version json=$json',
        () async {
          final temporary = await Directory.systemTemp.createTemp(
            'busyapi-resource-display-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          BusyProject? project;
          final outputs = <BundleOutput>[];
          try {
            final root = File(
                  p.join(temporary.path, json ? 'root.json' : 'root.yaml'),
                ),
                model = File(
                  p.join(temporary.path, json ? 'models.json' : 'models.yaml'),
                );
            if (json) {
              // Setup uses the shared exact-text fixture, not JS object decoding
              // of its large numeric source values. The shipped CLI does not
              // need this checkout or fixture generator.
              final prepared = await Process.run(runtimeNode, [
                '-e',
                'process.stdout.write(JSON.stringify(require(process.argv[1]).mixed(process.argv[2])))',
                p.join(
                  repositoryRoot,
                  'fixtures/compatibility/reference_display.cjs',
                ),
                version,
              ]);
              expect(prepared.exitCode, 0, reason: '${prepared.stderr}');
              final resources =
                  (jsonDecode(prepared.stdout as String) as Map)['resources']
                      as List;
              await root.writeAsString(resources[0]['text'] as String);
              await model.writeAsString(resources[1]['text'] as String);
            } else {
              for (final (file, name) in [(root, 'root'), (model, 'models')]) {
                final text = await File(
                  p.join(
                    repositoryRoot,
                    'fixtures/compatibility/mixed-dialects-$name.yaml',
                  ),
                ).readAsString();
                await file.writeAsString(
                  text.replaceFirst('openapi: 3.1.2', 'openapi: $version'),
                );
              }
            }
            final rootBytes = await root.readAsBytes(),
                modelBytes = await model.readAsBytes();
            project = await BusyProject.open(root.path, engine);
            final checked = await project.check(root.uri.toString());
            expect(checked['complete'], true);
            expect(
              (checked['findings'] as List).where(
                (finding) => finding['severity'] == 'error',
              ),
              isEmpty,
            );
            final buffer = await project.buffer(model.uri.toString());
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst(
                'OAS dialect schema sentinel',
                'Unsaved OAS dialect schema sentinel',
              ),
            );
            await expectLater(
              project.prepareBundle(
                root.uri.toString(),
                p.join(temporary.path, 'single-file'),
              ),
              throwsA(
                isA<CoreFailure>().having(
                  (error) => error.code,
                  'code',
                  'bundle.dialect.boundary',
                ),
              ),
            );
            expect(
              Directory(p.join(temporary.path, 'single-file')).existsSync(),
              false,
            );
            final capture = await project.captureDocumentationPresentation(
              root.uri.toString(),
            );
            expect(capture.unsaved, true);
            expect(capture.outdated, false);
            expect(
              capture.toJson()['representation'],
              'graph-addressed-display-only',
            );
            expect(capture.text, contains('9007199254740993.00'));
            expect(
              capture.text,
              contains('Unsaved OAS dialect schema sentinel'),
            );
            for (final (name, dialect) in [
              ('A', 'https://json-schema.org/draft/2020-12/schema'),
              (
                'B',
                'https://spec.openapis.org/oas/${version.substring(0, 3)}/dialect/base',
              ),
            ]) {
              final original = (capture.originalProjection['sections'] as List)
                  .singleWhere(
                    (section) =>
                        section['source']['resource'] == buffer.id &&
                        section['source']['pointer'] ==
                            '/components/schemas/$name',
                  );
              expect(original['dialect'], dialect);
              final record = capture.sourceProvenance.singleWhere(
                (record) =>
                    record['kind'] == 'schema' &&
                    record['source']['resource'] == buffer.id &&
                    record['source']['pointer'] == '/components/schemas/$name',
              );
              final pointer = record['derived']['pointer'] as String;
              final display = (capture.projection['sections'] as List)
                  .singleWhere(
                    (section) => section['source']['pointer'] == pointer,
                  );
              expect(display['dialect'], dialect);
              final action = capture.sourceActionFor(pointer)!;
              expect(action.source, original['source']);
              expect(action.authored, true);
            }
            for (final preset in ['native-reference', 'swagger', 'redoc']) {
              final plan = await project.prepareDocumentation(
                root.uri.toString(),
                p.join(temporary.path, 'working-$preset'),
                preset: preset,
              );
              outputs.add(plan);
              expect(plan.unsaved, true);
              await plan.publish();
              final html = await File(p.join(plan.destination, 'index.html'))
                  .readAsString();
              expect(html, contains('Mixed dialect operation sentinel'));
              expect(html, contains('Unsaved OAS dialect schema sentinel'));
              expect(html, contains('9007199254740993.00'));
              if (preset != 'native-reference') {
                expect(
                  plan.metadata['derivedRepresentation'],
                  contains('not an OpenAPI bundle'),
                );
                expect(
                  File(p.join(plan.destination, 'THIRD_PARTY_NOTICES.txt'))
                      .existsSync(),
                  true,
                );
              }
            }
            expect(await root.readAsBytes(), rootBytes);
            expect(await model.readAsBytes(), modelBytes);
            await project.save(buffer);
            // Saving identical working bytes does not make their frozen text
            // stale or rewrite its original unsaved-input provenance.
            expect(capture.outdated, false);
            expect(capture.unsaved, true);
            for (final preset in ['native-reference', 'swagger', 'redoc']) {
              final plan = await project.prepareDocumentation(
                root.uri.toString(),
                p.join(temporary.path, 'saved-$preset'),
                saved: true,
                preset: preset,
              );
              outputs.add(plan);
              await plan.publish();
              final cli = await Process.run(
                p.join(testBundle, 'busyapi'),
                [
                  'build-docs',
                  root.path,
                  '--preset',
                  preset,
                  '--output',
                  p.join(temporary.path, 'cli-$preset'),
                  '--json',
                ],
                workingDirectory: temporary.path,
                environment: {'PATH': '', 'DISPLAY': '', 'WAYLAND_DISPLAY': ''},
              );
              expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
              final left = await Directory(plan.destination)
                  .list(recursive: true, followLinks: false)
                  .where(
                    (entry) =>
                        entry is File &&
                        p.basename(entry.path) != 'busyapi-output.json',
                  )
                  .toList();
              for (final file in left) {
                final relative = p.relative(file.path, from: plan.destination);
                expect(
                  await File(p.join(temporary.path, 'cli-$preset', relative))
                      .readAsBytes(),
                  await File(file.path).readAsBytes(),
                  reason: 'GUI/core and CLI differ: $relative',
                );
              }
            }
            expect(await root.readAsBytes(), rootBytes);
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst('Unsaved OAS', 'Later OAS'),
            );
            expect(capture.outdated, true);
            expect(
              capture.text,
              contains('Unsaved OAS dialect schema sentinel'),
            );
            expect(
              capture.text,
              isNot(contains('Later OAS dialect schema sentinel')),
            );
          } finally {
            for (final output in outputs) output.close();
            project?.close();
            await engine.close();
            await temporary.delete(recursive: true);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
