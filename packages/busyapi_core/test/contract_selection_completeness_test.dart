import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _source(String version, String format, int port, String state) {
  if (state == 'syntax') return format == 'json' ? '{' : '[broken:';
  final swagger = version == '2.0';
  final declaration = <String, Object?>{
    if (state != 'missing')
      swagger ? 'swagger' : 'openapi': switch (state) {
        'malformed' => false,
        'unsupported' => '3.3.0',
        _ => version,
      },
    if (state == 'conflicting')
      swagger ? 'openapi' : 'swagger': swagger ? '3.0.4' : '2.0',
  };
  final fields = <String, Object?>{
    ...declaration,
    'info': {'title': 'Selection 雪', 'version': 'API-1'},
    if (swagger) ...{
      'host': '127.0.0.1:$port',
      'schemes': ['http'],
    } else
      'servers': [
        {'url': 'http://127.0.0.1:$port'},
      ],
    'paths': state == 'structure'
        ? []
        : state == 'unresolved'
        ? {
            '/items': {r'$ref': './missing-path.yaml'},
          }
        : {
            '/items': {
              'get': {
                'responses': {
                  '204': {'description': 'empty'},
                },
              },
            },
          },
    'x-exact': 'EXACT',
    'x-literal': {'openapi': false, 'swagger': 'literal', 'null': null},
  };
  final text = format == 'json'
      ? const JsonEncoder.withIndent('  ').convert(fields)
      : '# Retain selection source\r\n${fields.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\nx-held: &held [false, 0, null, "雪"]\r\nx-copy: *held';
  return '${text.replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format incomplete inventory retains captured diagnostics and recovers from unsaved source',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-selection-completeness-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final requests = <String>[];
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/items');
            expect(request.headers.value('host'), '127.0.0.1:${server.port}');
            expect(
              await request.fold<List<int>>([], (a, b) => a..addAll(b)),
              isEmpty,
            );
            requests.add(request.uri.toString());
            request.response.statusCode = 204;
            await request.response.close();
          });
          final file = File('${temp.path}/api.$format');
          final valid = _source(version, format, server.port, 'valid');
          file.writeAsBytesSync([0xef, 0xbb, 0xbf, ...utf8.encode(valid)]);
          final manifest = File('${temp.path}/busyapi.yaml')
            ..writeAsStringSync(
              jsonEncode({
                'version': 1,
                'roots': [
                  {'name': 'api', 'path': 'api.$format'},
                ],
                'tests': [
                  for (final name in ['held', 'missing'])
                    {
                      'name': name,
                      'operation': {
                        'method': 'get',
                        'path': name == 'held' ? '/items' : '/absent',
                      },
                      'expect': {'status': 204},
                    },
                ],
              }),
            );
          final configuration = manifest.readAsBytesSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id;
          final buffer = await project.buffer(root);
          Future<ContractTestReport> run(String name) =>
              const ContractTestRunner().run(
                project,
                root,
                selectedCases: [name],
                resolveSecret: (_) async => null,
                saved: false,
              );
          final good = await run('held');
          expect(good.passed, true);
          expect(requests, ['/items']);
          final missing = await run('missing');
          expect(missing.complete, true);
          expect(missing.cases.single.operationalFailure, true);
          expect(
            missing.cases.single.findings.single['code'],
            'test.operation',
          );
          final observed = <Map<String, Object?>>[];
          for (final state in [
            'missing',
            'conflicting',
            'malformed',
            'unsupported',
            'syntax',
            'structure',
            'unresolved',
          ]) {
            final source = _source(version, format, server.port, state);
            final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
            file.writeAsBytesSync(bytes);
            await project.reload(buffer);
            final analysis = await project.check(root);
            final result = await run('held');
            final child = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', 'held', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            final cli = jsonDecode(child.stdout as String) as Map;
            expect(
              child.exitCode,
              state == 'structure' ? 1 : 2,
              reason: '${child.stdout}\n${child.stderr}',
            );
            final cliCase = (cli['cases'] as List).single as Map;
            final blockers = (analysis['findings'] as List)
                .whereType<Map>()
                .where((finding) => finding['severity'] == 'error')
                .toList();
            expect(blockers, isNotEmpty, reason: '$state $analysis');
            observed.add({
              'state': state,
              'coreComplete': result.complete,
              'cliComplete': cli['complete'],
              'coreOperational': result.cases.single.operationalFailure,
              'cliOperational': cliCase['operationalFailure'],
              'cliProducer': cli['producerVersion'],
              'codeRetained': result.cases.single.findings.any(
                (finding) => finding['code'] == blockers.first['code'],
              ),
              'sourceRetained': result.cases.single.findings.any(
                (finding) =>
                    finding['resource'] == root &&
                    finding['pointer'] == blockers.first['pointer'] &&
                    jsonEncode(finding['range']) ==
                        jsonEncode(blockers.first['range']),
              ),
            });
            expect(result.executedOperations, isEmpty);
            expect(cli['executedOperations'], isEmpty);
            expect(result.cases.single.dispatched, false);
            expect(cliCase['dispatched'], false);
            expect(requests, ['/items']);
            expect(file.readAsBytesSync(), bytes);
            expect(manifest.readAsBytesSync(), configuration);
          }
          expect(observed, [
            for (final state in [
              'missing',
              'conflicting',
              'malformed',
              'unsupported',
              'syntax',
              'structure',
              'unresolved',
            ])
              {
                'state': state,
                'coreComplete': state == 'structure',
                'cliComplete': state == 'structure',
                'coreOperational': false,
                'cliOperational': false,
                'cliProducer': '2',
                'codeRetained': true,
                'sourceRetained': true,
              },
          ]);
          expect(good.toJson()['producerVersion'], '2');
          final invalidBytes = file.readAsBytesSync();
          project.store.replace(root, valid);
          expect((await run('held')).passed, true);
          expect(requests, ['/items', '/items']);
          expect(file.readAsBytesSync(), invalidBytes);
          project.store.undo();
          expect((await run('held')).passed, false);
          expect(requests, ['/items', '/items']);
          project.store.redo();
          await project.save(buffer);
          expect(file.readAsBytesSync(), [
            0xef,
            0xbb,
            0xbf,
            ...utf8.encode(valid),
          ]);
          expect(manifest.readAsBytesSync(), configuration);
        },
      );
    }
  }
}
