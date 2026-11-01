import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final direction in [
      ('3.1.2', '3.2.1'),
      ('3.2.1', '3.1.2'),
      ('3.1.2', '3.0.4'),
      ('3.2.1', '2.0'),
    ]) {
      test(
        'role migration ${direction.$1} to ${direction.$2} $format preserves captured ownership',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-role-migration-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final value = {
            'openapi': direction.$1,
            'info': {'title': 'Original', 'version': 'api-version'},
            'paths': <String, Object?>{},
            'components': {
              'securitySchemes': {
                'Key': {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
              },
            },
            'security': [
              {
                'Key': ['reader', '雪'],
              },
            ],
          };
          final text =
              '${format == 'yaml' ? '# Retain roles\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(value)}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsBytesSync([239, 187, 191, ...utf8.encode(text)]);
          final original = file.readAsBytesSync();
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              buffer = await project.buffer(project.roots.single.id);
          project.store.replace(
            root,
            buffer.text.replaceFirst('Original', 'Unsaved'),
          );
          final destination = '${directory.path}/migrated';
          final review = await project.prepareMigration(
            root,
            destination,
            targetVersion: direction.$2,
          );
          addTearDown(review.close);
          expect(review.unsaved, true);
          final modern = direction.$2 == '3.1.2' || direction.$2 == '3.2.1';
          if (modern) {
            expect(
              review.status,
              MigrationStatus.faithfullyConvertible,
              reason: '${review.result}',
            );
            await review.publish();
            final copy = await BusyProject.open(destination, engine);
            addTearDown(copy.close);
            final migrated = await copy.buffer(copy.roots.single.id);
            expect(migrated.text, contains('Unsaved'));
            final json = jsonDecode(
              migrated.text.replaceFirst('# Retain roles\r\n', ''),
            ) as Map;
            expect(json['security'], [
              {
                'Key': ['reader', '雪'],
              },
            ]);
            expect(json['info']['version'], 'api-version');
            expect(
              (await copy.check(copy.roots.single.id))['status'],
              'complete',
            );
          } else {
            expect(review.status, MigrationStatus.blocked);
            final blocker = (review.result['problems'] as List)
                .cast<Map>()
                .singleWhere(
                  (problem) => problem['code'] == 'migration.security.roles',
                );
            expect(blocker['reason'], 'target-representation');
            expect(blocker['resource'], root);
            expect(blocker['pointer'], '/security/0/Key');
            final range = blocker['range'] as List;
            expect(range[1] as int, greaterThan(range[0] as int));
            await expectLater(
              review.publish(),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'migration.blocked',
                ),
              ),
            );
            expect(Directory(destination).existsSync(), false);
          }
          final cliDestination = '${directory.path}/cli-copy';
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              direction.$2,
              '--output',
              cliDestination,
              '--json',
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            cli.exitCode,
            modern ? 0 : 2,
            reason: '${cli.stdout}\n${cli.stderr}',
          );
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(
            report['status'],
            modern ? 'faithfully-convertible' : 'blocked',
          );
          expect(report['published'], false);
          expect(Directory(cliDestination).existsSync(), false);
          expect(file.readAsBytesSync(), original);
          expect(buffer.text, contains('Unsaved'));
          expect(buffer.dirty, true);
        },
      );
    }
  }
}
