import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format migration retains Markdown context and original bytes', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-markdown-migration-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        const description = '[Guide](../guides/Guide%20One.md?q=a%2Fb#Intro)';
        final source = format == 'yaml'
            ? [
                '# Keep organization 雪',
                "openapi: '$version'",
                r'$self: https://example.invalid/contracts/api',
                "info: {title: Keep, version: '1', description: '$description'}",
                'paths: {}',
                'x-exact: 9007199254740993.00 # exact',
                '',
              ].join('\r\n')
            : '${jsonEncode({
                'openapi': version,
                r'$self': 'https://example.invalid/contracts/api',
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
        expect(review.result['producerVersion'], '8');
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
        expect(report['producerVersion'], '8');
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
      });
    }
  }
}
