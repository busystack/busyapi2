import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'server_context_support.dart';
import 'server_variable_defaults_support.dart';
import 'test_support.dart';

void manifest(Directory directory, int status, String format) {
  File('${directory.path}/busyapi.yaml').writeAsStringSync(
    jsonEncode({
      'version': 1,
      'roots': [
        {'name': 'api', 'path': 'api.$format'},
      ],
      'tests': [
        {
          'name': 'held',
          'operation': {'method': 'get', 'path': '/items'},
          'expect': {'status': status},
        },
      ],
    }),
  );
}

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final (fragment, substitution) in [
        ('#anchor', false),
        ('#', false),
        ('#anchor', true),
      ]) {
        test(
          '$version $format fragment $fragment substitution=$substitution retains source and reaches only its native HTTP target',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-fragment-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final endpoint = await HttpServer.bind(
              InternetAddress.loopbackIPv6,
              0,
            );
            addTearDown(() => endpoint.close(force: true));
            final received = <String>[];
            endpoint.listen((request) async {
              expect(request.method, 'GET');
              expect(
                request.headers.value(HttpHeaders.hostHeader),
                '[::1]:${endpoint.port}',
              );
              expect(request.uri.hasFragment, false);
              expect(
                await request.fold<List<int>>([], (a, b) => a..addAll(b)),
                isEmpty,
              );
              received.add(request.uri.toString());
              request.response.statusCode = 204;
              await request.response.close();
            });
            final url = substitution
                ? 'http://[::1]:${endpoint.port}/v{suffix}'
                : 'http://[::1]:${endpoint.port}/v{suffix}?base=0$fragment';
            final source = serverVariableDefaultsSource(
              version,
              format,
              endpoint.port,
              substitution ? '1?base=0$fragment' : '1',
              [substitution ? '1?base=0$fragment' : '1'],
              serverUrl: url,
            );
            final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
            final file = File('${temp.path}/api.$format')
              ..writeAsBytesSync(original);
            manifest(temp, 204, format);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = project.roots.single.id;
            final allowed = version.startsWith('3.0') || substitution;
            expect(
              (await project.check(root))['status'],
              allowed ? 'complete' : 'invalid',
            );
            if (allowed) {
              final plan = await project.prepareRequest(
                root,
                resource: root,
                pointer: '/paths/~1items/get',
              );
              addTearDown(plan.close);
              expect(plan.result['servers'][0]['url'], url);
              expect(plan.result['servers'][0]['httpFragmentPolicy'], 'omit');
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              try {
                expect(result.conforming, true);
                expect(result.request.uri.hasFragment, false);
              } finally {
                await result.close();
              }
              expect(received, ['/v1/items?base=0']);
            } else {
              await expectLater(
                project.prepareRequest(
                  root,
                  resource: root,
                  pointer: '/paths/~1items/get',
                ),
                throwsA(
                  isA<CoreFailure>()
                      .having(
                        (e) => e.kind,
                        'kind',
                        CoreFailureKind.specification,
                      )
                      .having(
                        (e) => e.source?.pointer,
                        'source',
                        '/servers/0/url',
                      ),
                ),
              );
              expect(received, isEmpty);
            }
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', 'held', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              cli.exitCode,
              allowed ? 0 : 1,
              reason: '${cli.stdout}\n${cli.stderr}',
            );
            final report = jsonDecode(cli.stdout as String) as Map;
            expect(report['complete'], true);
            expect(report['passed'], allowed);
            expect(report['cases'][0]['dispatched'], allowed);
            expect(report['cases'][0]['operationalFailure'], false);
            expect(
              received,
              allowed ? List.filled(2, '/v1/items?base=0') : isEmpty,
            );
            final buffer = await project.buffer(root);
            await project.save(buffer);
            expect(file.readAsBytesSync(), original);
          },
        );
      }
    }
  }
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json'])
      for (final scheme
          in version == '2.0' ? ['ws', 'wss'] : ['ws', 'wss', 'file', 'urn']) {
        test(
          '$version $format $scheme transport limitation is incomplete, located and never dispatched',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-unsupported-scheme-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final endpoint = await HttpServer.bind(
              InternetAddress.loopbackIPv6,
              0,
            );
            addTearDown(() => endpoint.close(force: true));
            var received = 0;
            endpoint.listen((request) async {
              received++;
              await request.response.close();
            });
            var source = serverContextSource(
              version,
              format,
              version == '2.0'
                  ? '[::1]:${endpoint.port}'
                  : switch (scheme) {
                      'file' => 'file:///busyapi-must-not-open',
                      'urn' => 'urn:busyapi:synthetic-transport',
                      _ => '$scheme://[::1]:${endpoint.port}/v1',
                    },
            );
            if (version == '2.0')
              source = source.replaceFirst(
                format == 'json' ? '"http"' : '[http]',
                format == 'json' ? '"$scheme"' : '[$scheme]',
              );
            final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
            final file = File('${temp.path}/api.$format')
              ..writeAsBytesSync(original);
            manifest(temp, 200, format);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(temp.path, engine);
            addTearDown(project.close);
            final root = project.roots.single.id;
            expect((await project.check(root))['status'], 'complete');
            final report = await const ContractTestRunner().run(
              project,
              root,
              selectedCases: const ['held'],
              resolveSecret: (_) async => null,
            );
            final machine = report.toJson();
            expect(machine['complete'], false);
            expect(machine['passed'], false);
            final outcome = (machine['cases'] as List).single as Map;
            expect(outcome['dispatched'], false);
            expect(outcome['operationalFailure'], false);
            final finding = (outcome['findings'] as List).single as Map;
            expect(finding['code'], 'request.scheme.unsupported');
            expect(finding['resource'], root);
            expect(
              finding['pointer'],
              version == '2.0' ? '/schemes/0' : '/servers/0/url',
            );
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', 'held', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 2, reason: '${cli.stdout}\n${cli.stderr}');
            final result = jsonDecode(cli.stdout as String) as Map;
            expect(result['complete'], false);
            expect(result['cases'][0]['operationalFailure'], false);
            expect(result['cases'][0]['dispatched'], false);
            expect(received, 0);
            expect(file.readAsBytesSync(), original);
          },
        );
      }
}
