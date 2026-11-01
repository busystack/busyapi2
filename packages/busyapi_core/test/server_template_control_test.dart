import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'server_variable_defaults_support.dart';
import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format literal DEL is a located specification failure before dispatch',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-server-control-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final authored = serverVariableDefaultsSource(
            version,
            format,
            1,
            'v1',
            const ['v1'],
            serverUrl: 'http://127.0.0.1:1/{suffix}\x7f',
          );
          final source = format == 'yaml'
              ? authored.replaceFirst('\x7f', r'\u007f')
              : authored;
          final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
          final file = File('${temp.path}/api.$format')
            ..writeAsBytesSync(original);
          File('${temp.path}/busyapi.yaml').writeAsStringSync(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                {
                  'name': 'control',
                  'operation': {'method': 'get', 'path': '/items'},
                  'expect': {'status': 204},
                },
              ],
            }),
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id;
          expect((await project.check(root))['status'], 'invalid');
          await expectLater(
            project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1items/get',
            ),
            throwsA(
              isA<CoreFailure>()
                  .having((e) => e.kind, 'kind', CoreFailureKind.specification)
                  .having((e) => e.source?.resource, 'resource', root)
                  .having((e) => e.source?.pointer, 'pointer', '/servers/0/url')
                  .having(outputFailureExitCode, 'exit', 1),
            ),
          );
          final result = await const ContractTestRunner().run(
            project,
            root,
            selectedCases: const ['control'],
            resolveSecret: (_) async => throw StateError('No credentials'),
            saved: false,
          );
          expect(result.complete, true);
          expect(result.passed, false);
          expect(result.cases.single.operationalFailure, false);
          expect(result.cases.single.dispatched, false);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'control', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 1, reason: '${cli.stdout}\n${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['complete'], true);
          expect(report['cases'][0]['dispatched'], false);
          expect(report['cases'][0]['operationalFailure'], false);
          expect(report['cases'][0]['findings'][0]['resource'], root);
          expect(
            report['cases'][0]['findings'][0]['pointer'],
            '/servers/0/url',
          );
          final buffer = await project.buffer(root);
          await project.save(buffer);
          expect(file.readAsBytesSync(), original);
        },
      );
    }
  }
}
