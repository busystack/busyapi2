import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final (version, retainedIdentity) in [
    ('3.2.0', true),
    ('3.2.1', true),
    for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) (version, false),
  ]) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format migration retains Markdown destinations identity=$retainedIdentity and original bytes',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-markdown-migration-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final description = retainedIdentity
              ? '[Guide](../guides/Guide%20One.md?q=a%2Fb#Intro)'
              : '[Guide](/guides/Guide%20One.md?q=a%2Fb#Intro) [More](/more)';
          final source = format == 'yaml'
              ? [
                  '# Keep organization 雪',
                  "${version == '2.0' ? 'swagger' : 'openapi'}: '$version'",
                  if (retainedIdentity)
                    r'$self: https://example.invalid/contracts/api',
                  "info: {title: Keep, version: '1', description: '$description'}",
                  'paths: {}',
                  'x-exact: 9007199254740993.00 # exact',
                  '',
                ].join('\r\n')
              : '${jsonEncode({
                  if (version == '2.0') 'swagger': version else 'openapi': version,
                  if (retainedIdentity) r'$self': 'https://example.invalid/contracts/api',
                  'info': {'title': 'Keep', 'version': '1', 'description': description},
                  'paths': <String, Object?>{},
                  'x-exact': 'EXACT',
                }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync('\ufeff$source');
          final original = file.readAsBytesSync();
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              buffer = await project.buffer(project.roots.single.id);
          project.store.replace(
            root,
            buffer.text.replaceFirst(
              format == 'yaml' ? 'title: Keep' : '"title":"Keep"',
              format == 'yaml' ? 'title: Unsaved' : '"title":"Unsaved"',
            ),
          );
          final working = buffer.text;
          final destination = '${directory.path}/migrated';
          final review = await project.prepareMigration(
            root,
            destination,
            targetVersion: '3.2.1',
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.result['producerVersion'], '10');
          expect(review.unsaved, isTrue);
          expect(Directory(destination).existsSync(), isFalse);
          await expectLater(
            review.publish(cancelled: () => true),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'cancelled',
              ),
            ),
          );
          expect(Directory(destination).existsSync(), isFalse);
          await review.publish();
          expect(file.readAsBytesSync(), original);
          expect(buffer.text, working);
          final output = File('$destination/openapi.$format');
          final migrated = output.readAsStringSync();
          expect(migrated, contains(description));
          expect(migrated, contains('9007199254740993.00'));
          if (retainedIdentity)
            expect(migrated, contains('https://example.invalid/contracts/api'));
          final copy = await BusyProject.open(output.path, engine);
          addTearDown(copy.close);
          final copyRoot = copy.roots.single.id;
          expect((await copy.check(copyRoot))['complete'], isTrue);
          final info = await copy.inspectObject(copyRoot, copyRoot, '/info');
          expect(info['value']['description'], description);
          expect(info['value']['title'], 'Unsaved');
          final standalone = await Directory('${directory.path}/standalone')
              .create();
          final standaloneFile = await output.copy(
            '${standalone.path}/api.$format',
          );
          final standaloneProject = await BusyProject.open(
            standaloneFile.path,
            engine,
          );
          addTearDown(standaloneProject.close);
          expect(
            (await standaloneProject.check(
              standaloneProject.roots.single.id,
            ))['complete'],
            isTrue,
          );
          expect(File('${standalone.path}/busyapi.yaml').existsSync(), isFalse);
          final staleDestination = '${directory.path}/stale';
          final stale = await project.prepareMigration(
            root,
            staleDestination,
            targetVersion: '3.2.1',
          );
          addTearDown(stale.close);
          project.store.replace(
            root,
            buffer.text.replaceFirst('Unsaved', 'Changed'),
          );
          await expectLater(
            stale.publish(),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'migration.stale',
              ),
            ),
          );
          expect(Directory(staleDestination).existsSync(), isFalse);
          final cliDestination = '${directory.path}/cli-migrated';
          Future<ProcessResult> cli(List<String> extra) => Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              '3.2.1',
              '--output',
              cliDestination,
              '--json',
              ...extra,
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final prepared = await cli([]);
          expect(
            prepared.exitCode,
            0,
            reason: '${prepared.stdout}\n${prepared.stderr}',
          );
          final report = jsonDecode(prepared.stdout as String) as Map;
          expect(report['producerVersion'], '10');
          expect(report['published'], isFalse);
          final published = await cli([
            '--apply',
            report['reviewIdentity'] as String,
          ]);
          expect(
            published.exitCode,
            0,
            reason: '${published.stdout}\n${published.stderr}',
          );
          expect(jsonDecode(published.stdout as String)['published'], isTrue);
          expect(
            File('$cliDestination/openapi.$format').readAsStringSync(),
            contains(description),
          );
          expect(file.readAsBytesSync(), original);
        },
      );
    }
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final target in ['3.0.4', '2.0']) {
      for (final format in ['yaml', 'json']) {
        test(
          '$version to $target $format preserves original Markdown context through stages',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-original-markdown-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final source =
                '${format == 'yaml' ? '# Keep 雪😀\r\n' : ''}${jsonEncode({
                  'openapi': version,
                  'info': {'title': 'Keep 雪😀', 'version': '1'},
                  'paths': <String, Object?>{},
                  'components': {
                    'schemas': {
                      'Value': {r'$id': 'https://schemas.example.invalid/value', 'type': 'string', 'description': '[Guide](/guide)'},
                    },
                  },
                })}\r\n';
            final bytes = [239, 187, 191, ...utf8.encode(source)];
            final file = File('${directory.path}/api.$format')
              ..writeAsBytesSync(bytes);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = project.roots.single.id,
                destination = '${directory.path}/blocked';
            final review = await project.prepareMigration(
              root,
              destination,
              targetVersion: target,
            );
            addTearDown(review.close);
            expect(review.status, MigrationStatus.blocked);
            expect(review.result['complete'], false);
            final issue = (review.result['problems'] as List)
                .whereType<Map>()
                .singleWhere(
                  (p) => p['code'] == 'migration.description.relative-links',
                );
            expect(issue['resource'], root);
            expect(issue['pointer'], '/components/schemas/Value/description');
            final range = issue['range'] as List;
            expect(
              source.substring(range[0] as int, range[1] as int),
              contains('Guide'),
            );
            expect(Directory(destination).existsSync(), false);
            await expectLater(
              review.publish(),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'migration.blocked',
                ),
              ),
            );
            expect(Directory(destination).existsSync(), false);
            expect(file.readAsBytesSync(), bytes);
            final cli = await Process.run(
              '$testBundle/busyapi',
              [
                'migrate',
                file.path,
                '--target',
                target,
                '--output',
                destination,
                '--json',
              ],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, isNot(0));
            final report = jsonDecode(cli.stdout as String) as Map;
            expect(report['complete'], false);
            expect(report['producerVersion'], '10');
            expect(Directory(destination).existsSync(), false);
            expect(file.readAsBytesSync(), bytes);
          },
        );
      }
    }
  }
}
