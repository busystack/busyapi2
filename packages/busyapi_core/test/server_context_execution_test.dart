import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';
import 'server_context_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format server specification, unsupported and real HTTP outcomes keep their own meaning',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-server-context-execution-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
          addTearDown(() => server.close(force: true));
          final requests = <String>[];
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/v1/items');
            expect(
              request.headers.value(HttpHeaders.hostHeader),
              '[::1]:${server.port}',
            );
            expect(
              await request.fold<List<int>>([], (a, b) => a..addAll(b)),
              isEmpty,
            );
            requests.add(request.uri.toString());
            request.response.headers.contentType = ContentType.text;
            request.response.write(serverContextBody);
            await request.response.close();
          });
          final swagger = version == '2.0';
          final invalid = swagger
              ? 'user@[::1]:${server.port}'
              : 'http://[::1]:${server.port}/%zz';
          final future = swagger ? '[v1.future]' : 'http://[v1.future]/v1';
          final valid = swagger
              ? '[::1]:${server.port}'
              : 'http://[::1]:${server.port}/v1';
          final source = serverContextSource(version, format, invalid);
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
                  'name': 'held',
                  'operation': {'method': 'get', 'path': '/items'},
                  'expect': {'status': 200},
                },
              ],
            }),
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(temp.path, engine);
          addTearDown(() => project.close());
          final root = project.roots.single.id,
              buffer = await project.buffer(project.roots.single.id);
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
                  .having(outputFailureExitCode, 'exit', 1),
            ),
          );
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'held', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 1, reason: '${cli.stdout}\n${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['complete'], true);
          expect(report['executedOperations'], isEmpty);
          expect(report['cases'][0]['operationalFailure'], false);
          expect(report['cases'][0]['dispatched'], false);
          expect(report['cases'][0]['findings'][0]['resource'], root);
          project.store.replace(root, source.replaceFirst(invalid, future));
          final unsupported = await const ContractTestRunner().run(
            project,
            root,
            selectedCases: const ['held'],
            resolveSecret: (_) async => null,
            saved: false,
          );
          expect(unsupported.complete, false);
          expect(unsupported.cases.single.operationalFailure, false);
          expect(unsupported.cases.single.dispatched, false);
          final incompletePage = await project.referencePage(
            root,
            root,
            '/paths/~1items/get',
          );
          expect(incompletePage['complete'], false);
          expect(requests, isEmpty);
          final pointer = swagger ? '' : '/servers/0';
          final inspected = await project.inspectObject(root, root, pointer),
              range = List<int>.from(inspected['range'] as List);
          await project.proposeAndApply(
            root,
            PropertySession(
              root: root,
              buffer: root,
              generation: buffer.generation,
              pointer: pointer,
              range: range,
              expected: buffer.text.substring(range[0], range[1]),
            ),
            [
              {
                'kind': 'set',
                'pointer': swagger ? '/host' : '/servers/0/url',
                'value': valid,
              },
            ],
          );
          final working = source.replaceFirst(invalid, valid);
          expect(buffer.text, working);
          expect(file.readAsBytesSync(), original);
          expect((await project.check(root))['status'], 'complete');
          expect(
            (await project.referencePage(
              root,
              root,
              '/paths/~1items/get',
            ))['complete'],
            true,
          );
          final outcome = await const ContractTestRunner().run(
            project,
            root,
            selectedCases: const ['held'],
            resolveSecret: (_) async => null,
            saved: false,
          );
          expect(outcome.complete, true, reason: '${outcome.toJson()}');
          expect(outcome.passed, true, reason: '${outcome.toJson()}');
          expect(outcome.cases.single.operationalFailure, false);
          expect(requests, hasLength(1));
          project.store.undo();
          expect(buffer.text, source.replaceFirst(invalid, future));
          expect((await project.check(root))['status'], 'incomplete');
          project.store.redo();
          await project.save(buffer);
          final saved = [0xef, 0xbb, 0xbf, ...utf8.encode(working)];
          expect(file.readAsBytesSync(), saved);
          await project.save(buffer);
          expect(file.readAsBytesSync(), saved);
          project.close();
          project = await BusyProject.open(temp.path, engine);
          final reopened = await const ContractTestRunner().run(
            project,
            root,
            selectedCases: const ['held'],
            resolveSecret: (_) async => null,
          );
          expect(reopened.passed, true, reason: '${reopened.toJson()}');
          expect(requests, hasLength(2));
          expect(file.readAsBytesSync(), saved);
        },
      );
    }
  }
}
