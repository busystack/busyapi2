import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';
import 'server_variable_defaults_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final fallback in ['', '雪', '0']) {
        for (final options in [
          <String>[],
          ['allowed'],
        ]) {
          test(
            '$version $format default ${jsonEncode(fallback)} enum $options retains SHALL/SHOULD semantics on the wire',
            () async {
              final temp = await Directory.systemTemp.createTemp(
                'busyapi-server-default-',
              );
              addTearDown(() => temp.delete(recursive: true));
              final server = await HttpServer.bind(
                InternetAddress.loopbackIPv6,
                0,
              );
              addTearDown(() => server.close(force: true));
              final requests = <String>[];
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
                requests.add(request.uri.toString());
                request.response.statusCode = 204;
                await request.response.close();
              });
              final source = serverVariableDefaultsSource(
                version,
                format,
                server.port,
                fallback,
                options,
              );
              final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
              final file = File('${temp.path}/api.$format')
                ..writeAsBytesSync(bytes);
              File('${temp.path}/busyapi.yaml').writeAsStringSync(
                jsonEncode({
                  'version': 1,
                  'roots': [
                    {'name': 'api', 'path': 'api.$format'},
                  ],
                  'tests': [
                    {
                      'name': 'default',
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
              final project = await BusyProject.open(file.path, engine);
              addTearDown(project.close);
              final root = project.roots.single.id;
              final checked = await project.check(root);
              if (version != '3.0.4') {
                expect(checked['status'], 'invalid');
                await expectLater(
                  project.prepareRequest(
                    root,
                    resource: root,
                    pointer: '/paths/~1items/get',
                  ),
                  throwsA(
                    isA<CoreFailure>().having(
                      (e) => e.kind,
                      'kind',
                      CoreFailureKind.specification,
                    ),
                  ),
                );
                expect(requests, isEmpty);
                expect(file.readAsBytesSync(), bytes);
                return;
              }
              expect(
                checked['status'],
                'complete',
                reason: jsonEncode(checked),
              );
              expect(
                (checked['findings'] as List).any(
                  (dynamic f) =>
                      f['code'] == 'server.variable.default-enum' &&
                      f['severity'] == 'warning',
                ),
                true,
              );
              final plan = await project.prepareRequest(
                root,
                resource: root,
                pointer: '/paths/~1items/get',
              );
              addTearDown(plan.close);
              expect(
                plan.result['servers'][0]['variables']['suffix']['defaultOutsideEnumAllowed'],
                true,
              );
              final executor = const ContractRequestExecutor();
              Future<void> execute(Map<String, String> values) async {
                final result = await executor.execute(
                  plan,
                  OperationRequestDraft(
                    planIdentity: plan.identity,
                    variables: values,
                  ),
                  resolveSecret: (_) async => null,
                );
                try {
                  expect(result.conforming, true);
                  expect(result.response.status, 204);
                } finally {
                  await result.close();
                }
              }

              await execute(const {});
              await execute({'suffix': fallback});
              final expected = '/v${Uri.encodeComponent(fallback)}/items';
              expect(requests, [expected, expected]);
              await expectLater(
                execute(const {'suffix': 'outside-options'}),
                throwsA(
                  isA<CoreFailure>().having(
                    (e) => e.code,
                    'code',
                    'request.server.variable',
                  ),
                ),
              );
              expect(requests, hasLength(2));
              if (options.isNotEmpty) {
                await execute(const {'suffix': 'allowed'});
                expect(requests.last, '/vallowed/items');
              }
              final count = requests.length;
              final cli = await Process.run(
                '$testBundle/busyapi',
                ['test', temp.path, '--case', 'default', '--json'],
                environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
                includeParentEnvironment: false,
              );
              expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
              final report = jsonDecode(cli.stdout as String) as Map;
              expect(report['complete'], true);
              expect(report['passed'], true);
              expect(report['cases'][0]['operationalFailure'], false);
              expect(requests, hasLength(count + 1));
              expect(requests.last, expected);
              final buffer = await project.buffer(root);
              await project.save(buffer);
              expect(file.readAsBytesSync(), bytes);
            },
          );
        }
      }
    }
  }
}
