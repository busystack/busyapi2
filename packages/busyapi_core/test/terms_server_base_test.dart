import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final target in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
      test(
        '3.0 $format captured Terms Server base survives bundle and migration to $target',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-terms-base-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          final original = format == 'json'
              ? jsonEncode({
                  'openapi': '3.0.4',
                  'info': {
                    'title': 'Original',
                    'version': '1',
                    'termsOfService': 'terms',
                  },
                  'servers': [
                    {'url': 'https://api.example.invalid/v1/'},
                  ],
                  'paths': {},
                  'x-exact': 'EXACT',
                }).replaceFirst('"EXACT"', '9007199254740993.00')
              : '# Keep Terms 雪\r\nopenapi: 3.0.4\r\ninfo: {title: Original, version: "1", termsOfService: terms}\r\nservers: [{url: "https://api.example.invalid/v1/"}]\r\npaths: {}\r\nx-exact: 9007199254740993.00\r\n';
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(),
              buffer = await project.buffer(file.uri.toString());
          project.store.replace(
            root,
            original.replaceFirst('Original', 'Unsaved terms'),
          );
          final bundle = await project.prepareBundle(
            root,
            '${temp.path}/bundle',
          );
          addTearDown(bundle.close);
          final bundled =
              jsonDecode(bundle.result['output']['text'] as String) as Map;
          expect(bundled['info']['termsOfService'], 'terms');
          expect(
            Uri.parse(bundled['servers'][0]['url'] as String)
                .resolve(bundled['info']['termsOfService'] as String)
                .toString(),
            'https://api.example.invalid/v1/terms',
          );
          expect(await Directory(bundle.destination).exists(), false);
          final review = await project.prepareMigration(
            root,
            '${temp.path}/migrated',
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.unsaved, true);
          expect(await file.readAsString(), original);
          final output = (review.result['outputs'] as List)
              .cast<Map>()
              .singleWhere((o) => o['id'] == review.result['outputRoot']);
          final expected = target == '3.0.4'
              ? 'terms'
              : 'https://api.example.invalid/v1/terms';
          expect(output['text'], contains(expected));
          expect(output['text'], contains('9007199254740993.00'));
          await review.publish();
          final copy = await BusyProject.open(review.destination, engine);
          addTearDown(copy.close);
          expect(
            (await copy.check(copy.roots.single.id))['status'],
            'complete',
          );
          final info = await copy.inspectObject(
            copy.roots.single.id,
            copy.roots.single.id,
            '/info',
          );
          expect(info['value']['termsOfService'], expected);
          expect(await file.readAsString(), original);
          expect(buffer.text, contains('Unsaved terms'));
          expect(buffer.dirty, true);
        },
      );
    }
    for (final variable in [false, true]) {
      test(
        '3.0 $format ambiguous Terms Server $variable refuses publication in Core and CLI',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-terms-bases-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/api.$format');
          final original = jsonEncode({
            'openapi': '3.0.4',
            'info': {
              'title': 'Terms',
              'version': '1',
              'termsOfService': 'terms',
            },
            'servers': variable
                ? [
                    {
                      'url': 'https://{host}.example.invalid/',
                      'variables': {
                        'host': {'default': 'one'},
                      },
                    },
                  ]
                : [
                    {'url': 'https://one.example.invalid/'},
                    {'url': 'https://two.example.invalid/'},
                  ],
            'paths': {},
          });
          await file.writeAsString(original);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final destination = '${temp.path}/migrated';
          final review = await project.prepareMigration(
            file.uri.toString(),
            destination,
            targetVersion: '3.1.2',
          );
          addTearDown(review.close);
          expect(review.status, MigrationStatus.blocked);
          expect(review.result['outputs'], isEmpty);
          final code = variable
              ? 'migration.info.terms-server-variable'
              : 'migration.info.terms-bases';
          expect(review.problems.any((p) => p.code == code), true);
          expect(await Directory(destination).exists(), false);
          expect(await file.readAsString(), original);
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              '3.1.2',
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
            (report['problems'] as List).any((p) => p['code'] == code),
            true,
          );
          expect(await Directory(destination).exists(), false);
          expect(await file.readAsString(), original);
        },
      );
    }
  }
}
