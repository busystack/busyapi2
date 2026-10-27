import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final unsupported in [false, true]) {
        test(
          '$version $format Server repair preserves source and incomplete evaluation $unsupported',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-server-url-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final file = File('${temp.path}/api.$format');
            final url = unsupported
                ? 'https://[v1.future]/api'
                : 'https://api.example.invalid/%zz';
            final source = format == 'json'
                ? '{"openapi":"$version","info":{"title":"Servers 雪","version":"1"},"paths":{},"servers":[{"url":"$url"}],"x-exact":9007199254740993.00}'
                : '# Keep Servers 雪\r\nopenapi: "$version"\r\ninfo: {title: "Servers 雪", version: "1"}\r\npaths: {}\r\nservers:\r\n  - url: "$url" # Keep URL comment\r\nx-exact: 9007199254740993.00\r\n';
            await file.writeAsString(source);
            var project = await BusyProject.open(file.path, engine);
            addTearDown(() => project.close());
            final root = file.uri.toString(),
                buffer = await project.buffer(root);
            final before = await project.check(root);
            expect(before['status'], unsupported ? 'incomplete' : 'invalid');
            expect(before['complete'], !unsupported);
            final findings = (before['findings'] as List).where(
              (f) => (f['code'] as String).startsWith('server.url.'),
            );
            expect(findings, hasLength(1));
            expect(findings.single['pointer'], '/servers/0/url');
            expect(findings.single['resource'], root);
            final cliBefore = await Process.run(
              '$testBundle/busyapi',
              ['check', file.path, '--json'],
              environment: {'PATH': ''},
              includeParentEnvironment: false,
            );
            expect(
              cliBefore.exitCode,
              unsupported ? 2 : 1,
              reason: '${cliBefore.stdout} ${cliBefore.stderr}',
            );
            expect(
              (jsonDecode(cliBefore.stdout as String) as Map)['status'],
              before['status'],
            );
            final page = await project.inspectObject(root, root, '/servers/0'),
                range = List<int>.from(page['range'] as List);
            const repaired = 'https://api.example.invalid/%20';
            await project.proposeAndApply(
              root,
              PropertySession(
                root: root,
                buffer: root,
                generation: buffer.generation,
                pointer: '/servers/0',
                range: range,
                expected: buffer.text.substring(range[0], range[1]),
              ),
              [
                {'kind': 'set', 'pointer': '/servers/0/url', 'value': repaired},
              ],
            );
            expect(buffer.text, source.replaceFirst(url, repaired));
            expect(await file.readAsString(), source);
            expect((await project.check(root))['status'], 'complete');
            project.store.undo();
            expect(buffer.text, source);
            expect((await project.check(root))['status'], before['status']);
            project.store.redo();
            await project.save(buffer);
            final saved = await file.readAsBytes();
            await project.save(buffer);
            expect(await file.readAsBytes(), saved);
            project.close();
            project = await BusyProject.open(file.path, engine);
            expect((await project.check(root))['status'], 'complete');
            expect(
              (await project.buffer(root)).text,
              source.replaceFirst(url, repaired),
            );
          },
        );
      }
    }
  }
  for (final format in ['yaml', 'json']) {
    for (final target in ['3.1.2', '3.2.1']) {
      test(
        '3.0 $format Server query migration to $target refuses publication and retains unsaved input',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-server-migration-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          final source =
              '${format == 'yaml' ? '# Keep original\r\n' : ''}{"openapi":"3.0.4","info":{"title":"Original","version":"1"},"paths":{},"servers":[{"url":"https://api.example.invalid/v1?selected=1"}]}';
          await file.writeAsString(source);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(), buffer = await project.buffer(root);
          project.store.replace(
            root,
            source.replaceFirst('Original', 'Unsaved'),
          );
          expect((await project.check(root))['status'], 'complete');
          final destination = '${temp.path}/migrated';
          final review = await project.prepareMigration(
            root,
            destination,
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(review.status, MigrationStatus.blocked);
          expect(review.unsaved, true);
          expect(review.result['outputs'], isEmpty);
          expect(
            (review.result['problems'] as List).any(
              (p) =>
                  p['code'] == 'migration.validation.server.url.query-fragment',
            ),
            true,
          );
          await expectLater(review.publish(), throwsA(isA<CoreFailure>()));
          expect(await Directory(destination).exists(), false);
          expect(await file.readAsString(), source);
          expect(buffer.text, contains('Unsaved'));
          expect(buffer.dirty, true);
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
            environment: {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, isNot(0), reason: '${cli.stdout} ${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['status'], 'blocked');
          expect(
            (report['problems'] as List).any(
              (p) =>
                  p['code'] == 'migration.validation.server.url.query-fragment',
            ),
            true,
          );
          expect(await Directory(destination).exists(), false);
          expect(await file.readAsString(), source);
        },
      );
    }
  }
}
