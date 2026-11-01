import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('SIGKILL after a definition publication preserves every intent and a newer destination', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-definition-kill-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.json'),
        destination = File('${temp.path}/models.json');
    await root.writeAsString(
      r'{"openapi":"3.2.1","info":{"title":"Kill","version":"1"},"paths":{},"components":{"schemas":{"Public":{"type":"integer","examples":[900719925474099312345]},"Use":{"$ref":"#/components/schemas/Public"}}}}',
    );
    const originalDestination =
        '{"openapi":"3.2.1","info":{"title":"Models","version":"1"},"paths":{}}';
    await destination.writeAsString(originalDestination);
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots:\n  - name: working\n    path: root.json\n  - name: models\n    path: models.json\n',
    );
    final child = await Process.start('$testBundle/definition-move-child', [
      temp.path,
      '${temp.path}/state',
    ]);
    addTearDown(() async {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    });
    final stderrText = child.stderr.transform(utf8.decoder).join();
    expect(
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 12)),
      'definition-published-before-receipt',
    );
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
    expect(await stderrText, isEmpty);
    final publishedRoot = await root.readAsBytes();
    expect(
      utf8.decode(publishedRoot),
      contains('models.json#/components/schemas/Stored'),
    );
    expect(await destination.readAsString(), originalDestination);
    const externalDestination = '$originalDestination\n';
    await destination.writeAsString(externalDestination);
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final publications = PublicationStore('${temp.path}/state');
    final record = (await publications.inspect(project)).single;
    expect(
      record['published'],
      isEmpty,
      reason: 'The child died before recording the real first publication',
    );
    final outcomes = (record['outcomes'] as List).cast<Map>();
    expect(
      outcomes.singleWhere((e) => e['id'] == root.uri.toString())['outcome'],
      'published',
    );
    final pending = outcomes.singleWhere(
      (e) => e['id'] == destination.uri.toString(),
    );
    expect(pending['outcome'], 'conflict');
    await publications.recover(project, Map<String, dynamic>.from(pending));
    final recovered = project.store.get(destination.uri.toString());
    expect(recovered.text, contains('900719925474099312345'));
    expect(recovered.text, contains('"Stored"'));
    expect(recovered.externalConflict, true);
    expect((await publications.save(project, [recovered])).complete, false);
    expect(await destination.readAsString(), externalDestination);
    expect(await root.readAsBytes(), publishedRoot);
    expect(File(record['recordPath'] as String).existsSync(), true);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'definition move $version $json reviews every root and retains exact publication/history',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-definition-move-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final root = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
          final destination = File('${temp.path}/models.json');
          final fragment = File('${temp.path}/consumer.json');
          final original = const JsonEncoder.withIndent('  ')
              .convert({
                'openapi': version,
                'info': {'title': 'Move', 'version': '1'},
                'paths': <String, Object?>{},
                'components': {
                  'schemas': {
                    'Public': {
                      'type': 'object',
                      'properties': {
                        'value': {'type': 'integer'},
                      },
                      'examples': [
                        {'value': 'EXACT', r'$ref': 'literal payload'},
                      ],
                    },
                    'Use': {r'$ref': '#/components/schemas/Public'},
                    'Consumer': {r'$ref': 'consumer.json#/Use'},
                  },
                },
                'x-data': {
                  r'$ref': '#/components/schemas/Public/properties/value',
                },
              })
              .replaceAll('"EXACT"', '900719925474099312345');
          await root.writeAsString(
            '\ufeff${json ? '' : '# retained\r\n'}${original.replaceAll('\n', '\r\n')}',
          );
          await destination.writeAsString(
            jsonEncode({
              'openapi': version,
              'info': {'title': 'Models', 'version': '1'},
              'paths': <String, Object?>{},
            }),
          );
          await fragment.writeAsString(
            jsonEncode({
              'Use': {
                r'$ref':
                    '${root.uri.pathSegments.last}#/components/schemas/Public/properties/value',
              },
            }),
          );
          final manifest = File('${temp.path}/busyapi.yaml');
          const manifestPrefix =
              '# root paths stay authored\nversion: 1\nroots:\n';
          await manifest.writeAsString(
            '${manifestPrefix}  - name: working\n    path: ${root.uri.pathSegments.last}\n  - name: models\n    path: models.json\nx-kept: true\n',
          );
          final manifestBytes = await manifest.readAsBytes();
          var project = await BusyProject.open(temp.path, engine);
          addTearDown(() => project.close());
          final source = await project.buffer(root.uri.toString());
          final consumer = await project.buffer(fragment.uri.toString());
          project.store.replace(consumer.id, '${consumer.text}\n');
          final before = {
            source.id: source.bytes(),
            consumer.id: consumer.bytes(),
            destination.uri.toString(): await destination.readAsBytes(),
          };
          Future<RefactoringPlan> prepare() =>
              project.planComponentDefinitionMove(
                {
                  'root': source.id,
                  'resource': source.id,
                  'pointer': '/components/schemas/Public',
                  'generation': source.generation,
                },
                'Stored',
                destinationResource: destination.uri.toString(),
              );
          final stale = await prepare();
          expect(stale.checkedRoots.toSet(), {
            root.uri.toString(),
            destination.uri.toString(),
          });
          for (final entry in before.entries) {
            expect(
              project.store.buffers[entry.key]?.bytes() ??
                  await File.fromUri(Uri.parse(entry.key)).readAsBytes(),
              entry.value,
            );
          }
          final target = await project.buffer(destination.uri.toString());
          project.store.replace(target.id, '${target.text}\n');
          await expectLater(
            project.applyRefactoring(stale),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'refactor.stale',
              ),
            ),
          );
          expect(source.bytes(), before[source.id]);
          expect(consumer.bytes(), before[consumer.id]);
          project.store.undo();
          final plan = await prepare();
          await project.applyRefactoring(plan);
          expect(
            jsonDecode(
              source.text.substring(source.text.indexOf('{')),
            )['components']['schemas']['Use'][r'$ref'],
            '#/components/schemas/Public',
          );
          expect(
            source.text,
            contains('models.json#/components/schemas/Stored'),
          );
          expect(
            consumer.text,
            contains('models.json#/components/schemas/Stored/properties/value'),
          );
          expect(target.text, contains('900719925474099312345'));
          expect(source.text, contains('"x-data"'));
          expect(
            source.text,
            contains('#/components/schemas/Public/properties/value'),
          );
          final moved = {
            for (final b in [source, consumer, target]) b.id: b.bytes(),
          };
          project.store.undo();
          for (final entry in before.entries) {
            expect(project.store.get(entry.key).bytes(), entry.value);
          }
          project.store.redo();
          for (final entry in moved.entries) {
            expect(project.store.get(entry.key).bytes(), entry.value);
          }
          final publication = PublicationStore(
            '${temp.path}/private-publication',
          );
          if (version == '3.2.1' && json) {
            final partial = await publication.save(
              project,
              project.store.buffers.values,
              beforePublish: (path) async {
                if (path == target.path)
                  throw StateError('Injected definition publication failure');
              },
            );
            expect(partial.complete, false);
            expect(partial.failed.keys, contains(target.id));
            expect(
              (await publication.inspect(project)).single['outcomes'],
              isNotEmpty,
            );
            final external =
                '${await destination.readAsString()}\nexternal edit';
            await destination.writeAsString(external);
            expect(
              (await publication.save(
                project,
                project.store.buffers.values,
              )).complete,
              false,
            );
            expect(await destination.readAsString(), external);
            for (final entry in moved.entries) {
              expect(project.store.get(entry.key).bytes(), entry.value);
            }
            // Another live owner must not take over this process's journal.
            final restarted = PublicationStore(
              '${temp.path}/private-publication',
            );
            expect(await restarted.inspect(project), isEmpty);
            expect(await destination.readAsString(), external);
            expect(await manifest.readAsBytes(), manifestBytes);
            return;
          }
          expect(
            (await publication.save(
              project,
              project.store.buffers.values,
            )).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(temp.path, engine);
          for (final entry in moved.entries) {
            expect((await project.buffer(entry.key)).bytes(), entry.value);
          }
          expect(
            (await project.check(root.uri.toString()))['status'],
            'complete',
          );
          expect(await manifest.readAsBytes(), manifestBytes);
          expect((await project.buffer(root.uri.toString())).hasBom, true);
        },
      );
    }
  }
}
