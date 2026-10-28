import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'server_variable_defaults_support.dart';
import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    test(
      '3.0 $format captured empty-enum default survives bundle, migration and actual HTTP',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-default-copy-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
        addTearDown(() => server.close(force: true));
        final received = <String>[];
        server.listen((request) async {
          expect(request.method, 'GET');
          expect(
            request.headers.value(HttpHeaders.hostHeader),
            '[::1]:${server.port}',
          );
          expect(
            await request.fold<List<int>>([], (a, b) => a..addAll(b)),
            isEmpty,
          );
          received.add(request.uri.toString());
          request.response.statusCode = 204;
          await request.response.close();
        });
        final source = serverVariableDefaultsSource(
          '3.0.4',
          format,
          server.port,
          'http://[::1]:${server.port}/saved',
          const [],
          serverUrl: '{suffix}',
        );
        final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
        final file = File('${temp.path}/api.$format')
          ..writeAsBytesSync(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id;
        final buffer = await project.buffer(root);
        final working = buffer.text.replaceFirst('/saved', '/v雪');
        project.store.replace(root, working);
        Future<void> send(BusyProject owner) async {
          final id = owner.roots.single.id;
          final plan = await owner.prepareRequest(
            id,
            resource: id,
            pointer: '/paths/~1items/get',
          );
          try {
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(planIdentity: plan.identity),
              resolveSecret: (_) async => null,
            );
            try {
              expect(result.conforming, true);
              expect(result.response.status, 204);
            } finally {
              await result.close();
            }
          } finally {
            plan.close();
          }
        }

        await send(project);
        final bundle = await project.prepareBundle(root, '${temp.path}/bundle');
        addTearDown(bundle.close);
        expect(bundle.unsaved, true);
        expect(bundle.result['producerVersion'], '4');
        expect(
          bundle.result['output']['text'],
          contains('9007199254740993.00'),
        );
        await bundle.publish();
        final bundled = await BusyProject.open(
          '${bundle.destination}/openapi.json',
          engine,
        );
        addTearDown(bundled.close);
        expect(
          (await bundled.check(bundled.roots.single.id))['status'],
          'complete',
        );
        await send(bundled);
        for (final target in ['3.0.4', '3.1.2', '3.2.1']) {
          final migration = await project.prepareMigration(
            root,
            '${temp.path}/migration-$target',
            targetVersion: target,
          );
          addTearDown(migration.close);
          expect(
            migration.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${migration.result}',
          );
          expect(migration.unsaved, true);
          expect(migration.result['producerVersion'], '24');
          await migration.publish();
          final migrated = await BusyProject.open(
            migration.destination,
            engine,
          );
          addTearDown(migrated.close);
          expect(
            (await migrated.check(migrated.roots.single.id))['status'],
            'complete',
          );
          await send(migrated);
        }
        expect(received, List.filled(5, '/v%E9%9B%AA/items'));
        expect(file.readAsBytesSync(), original);
        expect(buffer.text, working);
        await expectLater(
          project.prepareBundle(
            root,
            '${temp.path}/cancel',
            cancelled: () => true,
          ),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        expect(Directory('${temp.path}/cancel').existsSync(), false);
        final cli = await Process.run(
          '$testBundle/busyapi',
          ['bundle', file.path, '--output', '${temp.path}/cli', '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
        expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
        final saved = await BusyProject.open(
          '${temp.path}/cli/openapi.json',
          engine,
        );
        addTearDown(saved.close);
        await send(saved);
        expect(received.last, '/saved/items');
        expect(received, hasLength(6));
        expect(file.readAsBytesSync(), original);
        expect(buffer.text, working);
      },
    );
    test(
      '3.0 $format incompatible default URI forms refuse bundle with original coordinates and no publication',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-default-refusal-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final source = serverVariableDefaultsSource(
          '3.0.4',
          format,
          1,
          'https://api.example.invalid/v1',
          const ['relative'],
          serverUrl: '{suffix}',
        );
        final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
        final file = File('${temp.path}/api.$format')
          ..writeAsBytesSync(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id,
            buffer = await project.buffer(root);
        project.store.replace(
          root,
          buffer.text.replaceFirst('Server defaults', 'Captured defaults'),
        );
        await expectLater(
          project.prepareBundle(root, '${temp.path}/native'),
          throwsA(
            isA<OutputAnalysisFailure>()
                .having((e) => e.kind, 'kind', CoreFailureKind.unsupported)
                .having((e) => e.source?.pointer, 'pointer', '/servers/0/url')
                .having((e) => e.source?.resource, 'resource', root)
                .having(
                  (e) => buffer.text.substring(
                    e.source!.range.start,
                    e.source!.range.end,
                  ),
                  'source token',
                  '"{suffix}"',
                )
                .having(outputFailureExitCode, 'exit', 2),
          ),
        );
        expect(Directory('${temp.path}/native').existsSync(), false);
        final cli = await Process.run(
          '$testBundle/busyapi',
          ['bundle', file.path, '--output', '${temp.path}/cli', '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(cli.exitCode, 2, reason: '${cli.stdout}\n${cli.stderr}');
        final report = jsonDecode(cli.stdout as String) as Map;
        expect(report['complete'], false);
        expect(report['status'], 'incomplete');
        expect(report['error']['code'], 'bundle.server.template-context');
        expect(report['error']['source']['resource'], root);
        expect(report['error']['source']['pointer'], '/servers/0/url');
        expect(Directory('${temp.path}/cli').existsSync(), false);
        expect(file.readAsBytesSync(), original);
        expect(buffer.text, contains('Captured defaults'));
      },
    );
  }
}
