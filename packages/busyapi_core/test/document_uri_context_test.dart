import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format native terms repair preserves bytes and history', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-terms-core-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final file = File('${temp.path}/api.$format');
        final value = {
          version == '2.0' ? 'swagger' : 'openapi': version,
          'info': {
            'title': 'Terms 雪',
            'version': '1',
            'termsOfService': 'Internal use only',
          },
          'paths': {},
          'x-number': 'EXACT',
        };
        final original = format == 'json'
            ? const JsonEncoder.withIndent('  ')
                  .convert(value)
                  .replaceFirst('"EXACT"', '9007199254740993.00')
            : '# Keep terms 雪\r\n${version == '2.0' ? 'swagger' : 'openapi'}: "$version"\r\ninfo: {title: "Terms 雪", version: "1", termsOfService: "Internal use only"}\r\npaths: {}\r\nx-number: 9007199254740993.00\r\n';
        await file.writeAsString(original);
        var project = await BusyProject.open(file.path, engine);
        addTearDown(() => project.close());
        final root = file.uri.toString(), before = await project.check(root);
        expect(before['status'], version == '2.0' ? 'complete' : 'invalid');
        expect(
          (before['findings'] as List)
              .where((f) => f['code'] == 'metadata.uri')
              .length,
          version == '2.0' ? 0 : 1,
        );
        final buffer = await project.buffer(root),
            page = await project.inspectObject(root, root, '/info'),
            range = List<int>.from(page['range'] as List);
        const target = 'https://terms.example.invalid/%E9%9B%AA#part';
        await project.proposeAndApply(
          root,
          PropertySession(
            root: root,
            buffer: root,
            generation: buffer.generation,
            pointer: '/info',
            range: range,
            expected: buffer.text.substring(range[0], range[1]),
          ),
          [
            {'kind': 'set', 'pointer': '/info/termsOfService', 'value': target},
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
        expect((jsonDecode(cli.stdout as String) as Map)['status'], 'complete');
      });
    }
  }
  for (final format in ['yaml', 'json']) {
    for (final terms in [
      'Internal use only',
      'https://terms.example.invalid/policy',
    ]) {
      test(
        '$format migration reviews Swagger terms intent without publishing originals: $terms',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-terms-migration-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          await file.writeAsString(
            jsonEncode({
              'swagger': '2.0',
              'info': {
                'title': 'Terms',
                'version': '1',
                'termsOfService': terms,
              },
              'paths': {},
            }),
          );
          final original = await file.readAsBytes(),
              project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(), buffer = await project.buffer(root);
          project.store.replace(
            root,
            buffer.text.replaceFirst('"Terms"', '"Unsaved terms"'),
          );
          final destination = '${temp.path}/migrated',
              review = await project.prepareMigration(
                root,
                destination,
                targetVersion: '3.0.4',
              );
          addTearDown(review.close);
          final isProse = terms == 'Internal use only';
          expect(
            review.status,
            isProse
                ? MigrationStatus.blocked
                : MigrationStatus.requiresDecision,
          );
          expect(review.unsaved, true);
          expect(await Directory(destination).exists(), false);
          final issue = review.problems.singleWhere(
            (p) =>
                p.code ==
                (isProse
                    ? 'migration.info.terms-uri'
                    : 'migration.info.terms-uri-activation'),
          );
          expect(issue.pointer, '/info/termsOfService');
          expect(issue.resource, root);
          expect(await file.readAsBytes(), original);
          if (!isProse) {
            final accepted = await project.prepareMigration(
              root,
              destination,
              targetVersion: '3.0.4',
              decisions: {issue.id: 'interpret-terms-as-uri'},
            );
            addTearDown(accepted.close);
            expect(
              accepted.status,
              MigrationStatus.faithfullyConvertible,
              reason: '${accepted.result}',
            );
            await accepted.publish();
            final copy = await BusyProject.open(destination, engine);
            addTearDown(copy.close);
            final result = await copy.check(copy.roots.single.id);
            expect(result['status'], 'complete');
            expect(await file.readAsBytes(), original);
            expect(buffer.text, contains('Unsaved terms'));
          }
        },
      );
    }
  }
}
