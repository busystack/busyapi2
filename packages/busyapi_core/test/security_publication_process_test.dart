import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final uri in [false, if (version == '3.2.1') true]) {
      for (final phase in [
        'draft',
        'published',
        'published-newer',
        'published-later',
      ]) {
        test(
          'SIGKILL security $version URI=$uri $phase retains linked publication',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-security-kill-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final rootFile = File('${directory.path}/api.json');
            final root = rootFile.uri.toString();
            final swagger = version == '2.0';
            final binding = uri ? '#/components/securitySchemes/Old' : 'Old';
            final targetBinding = uri
                ? '#/components/securitySchemes/Renamed'
                : 'Renamed';
            final source = jsonEncode({
              if (swagger) 'swagger': version else 'openapi': version,
              'info': {'title': 'Recovery 雪', 'version': '1'},
              'paths': <String, Object?>{},
              'security': [
                {binding: <String>[]},
              ],
              if (swagger)
                'securityDefinitions': {
                  'Old': {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
                }
              else
                'components': {
                  'securitySchemes': {
                    'Old': {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
                  },
                },
            });
            rootFile.writeAsStringSync(source);
            final manifest = File('${directory.path}/busyapi.yaml');
            final configuration =
                '''version: 1
roots: [{name: api, path: api.json}]
environments:
  manual:
    authentication:
      schemes:
        ${jsonEncode(binding)}: {secretRef: synthetic-reference} # retained
''';
            manifest.writeAsStringSync(configuration);
            final state = '${directory.path}/state';
            final child = await Process.start('$testBundle/publication-child', [
              directory.path,
              state,
              'security-${phase == 'draft' ? 'draft' : 'published'}',
            ]);
            addTearDown(() async {
              child.kill(ProcessSignal.sigkill);
              await child.exitCode;
            });
            final error = child.stderr.transform(utf8.decoder).join();
            expect(
              await child.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .first
                  .timeout(const Duration(seconds: 15)),
              phase == 'draft' ? 'draft-durable' : 'first-published',
            );
            child.kill(ProcessSignal.sigkill);
            await child.exitCode;
            expect(await error, isEmpty);
            if (phase == 'published-newer') {
              rootFile.writeAsStringSync('$source\n');
            }
            final before = rootFile.readAsStringSync();
            expect(manifest.readAsStringSync(), configuration);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(directory.path, engine);
            addTearDown(project.close);
            final publications = PublicationStore(state);
            if (phase == 'draft') {
              final recovery = RecoveryStore(state);
              final record = (await recovery.available()).single;
              expect(record['publicationGroups'], [
                unorderedEquals([root, manifest.uri.toString()]),
              ]);
              await recovery.adoptFileMoves(record, project.recoveryOwner);
            } else {
              final record = (await publications.inspect(project)).single;
              final outcomes = (record['outcomes'] as List).cast<Map>();
              expect(
                outcomes.first['outcome'],
                phase == 'published-newer' ? 'conflict' : 'published',
              );
              // Recovering the outstanding repair also retains its published peer.
              await publications.recover(
                project,
                Map<String, dynamic>.from(
                  outcomes.singleWhere(
                    (entry) => entry['id'] == manifest.uri.toString(),
                  ),
                ),
              );
            }
            expect(rootFile.readAsStringSync(), before);
            expect(manifest.readAsStringSync(), configuration);
            final savedRoot = project.store.get(root);
            expect(savedRoot.text, contains('Renamed'));
            final config = project.store.get(manifest.uri.toString());
            expect(
              loadYaml(
                config.text,
              )['environments']['manual']['authentication']['schemes'][targetBinding]['secretRef'],
              'synthetic-reference',
            );
            expect(config.text, contains('# retained'));
            if (phase == 'published-later')
              rootFile.writeAsStringSync('$source\n');
            final result = await publications.save(project, [savedRoot]);
            expect(
              result.complete,
              !['published-newer', 'published-later'].contains(phase),
            );
            if (['published-newer', 'published-later'].contains(phase)) {
              expect(result.published, isEmpty);
              if (phase == 'published-newer')
                expect(savedRoot.externalConflict, true);
              expect(rootFile.readAsStringSync(), '$source\n');
              expect(manifest.readAsStringSync(), configuration);
            } else {
              expect(rootFile.readAsStringSync(), savedRoot.text);
              expect(manifest.readAsStringSync(), config.text);
              expect(savedRoot.dirty, false);
              expect(config.dirty, false);
            }
          },
        );
      }
    }
  }
}
