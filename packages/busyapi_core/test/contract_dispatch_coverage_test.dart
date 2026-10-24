import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _source(String version, int port, String format) {
  final swagger = version == '2.0';
  if (format == 'json') {
    return jsonEncode({
      swagger ? 'swagger' : 'openapi': version,
      'info': {'title': 'Dispatch coverage', 'version': 'api-version'},
      if (swagger) ...{
        'host': '127.0.0.1:$port',
        'schemes': ['http'],
        'basePath': '/api',
      } else
        'servers': [
          {'url': 'http://127.0.0.1:$port/api'},
        ],
      'paths': {
        '/things/{id}': {
          'get': {
            'parameters': [
              {
                'name': 'id',
                'in': 'path',
                'required': true,
                if (swagger) 'type': 'string' else 'schema': {'type': 'string'},
              },
              {
                'name': 'marker',
                'in': 'query',
                if (swagger) 'type': 'string' else 'schema': {'type': 'string'},
              },
            ],
            'responses': {
              '204': {'description': 'ok'},
            },
          },
        },
      },
    });
  }
  return '''# Retain authoritative native source
${swagger ? "swagger: '2.0'" : 'openapi: $version'}
info: {title: Dispatch coverage, version: api-version}
${swagger ? "host: '127.0.0.1:$port'\nschemes: [http]\nbasePath: /api" : "servers: [{url: 'http://127.0.0.1:$port/api'}]"}
paths:
  /things/{id}:
    get:
      parameters:
        - {name: id, in: path, required: true, ${swagger ? 'type: string' : 'schema: {type: string}'}}
        - {name: marker, in: query, ${swagger ? 'type: string' : 'schema: {type: string}'}}
      responses: {'204': {description: ok}}
''';
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['json', 'yaml']) {
      test(
        '$version $format case coverage distinguishes preparation refusal and dispatched transport failure',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-dispatch-coverage-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <(String, String)>[];
          server.listen((request) async {
            seen.add((request.method, request.uri.path));
            if (request.uri.path.endsWith('/broken')) {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
            } else {
              request.response.statusCode = 204;
              await request.response.close();
            }
          });
          final file = File('${temp.path}/api.$format'),
              original = _source(version, server.port, format);
          await file.writeAsString(original);
          final manifest = File('${temp.path}/busyapi.yaml');
          final configuration = jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'tests': [
              for (final name in ['good', 'missing', 'broken'])
                {
                  'name': name,
                  'operation': {'method': 'get', 'path': '/things/{id}'},
                  'parameters': {
                    'query': {'marker': 'synthetic-dispatch-secret'},
                    if (name != 'missing')
                      'path': {'id': name == 'good' ? 'ok' : 'broken'},
                  },
                  'expect': {'status': 204},
                },
            ],
          });
          await manifest.writeAsString(configuration);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          for (final name in ['missing', 'good', 'broken']) {
            final before = seen.length;
            final report = await const ContractTestRunner().run(
              project,
              file.uri.toString(),
              selectedCases: [name],
              resolveSecret: (_) async => null,
            );
            final value = report.cases.single;
            final dispatched = name != 'missing';
            expect(value.dispatched, dispatched);
            expect(report.executedOperations.length, dispatched ? 1 : 0);
            expect(report.untestedOperations.length, dispatched ? 0 : 1);
            expect(report.passed, name == 'good');
            expect(report.complete, name != 'broken');
            expect(value.operationalFailure, name != 'good');
            expect(value.responseStatus, name == 'good' ? 204 : null);
            expect(
              jsonEncode(report.toJson()),
              isNot(contains('synthetic-dispatch-secret')),
            );
            if (dispatched) {
              expect(seen.length, greaterThan(before));
              expect(seen.last, (
                'GET',
                '/api/things/${name == 'good' ? 'ok' : 'broken'}',
              ));
            } else
              expect(seen.length, before);
            final afterCore = seen.length;
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', name, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              cli.exitCode,
              name == 'good'
                  ? 0
                  : name == 'missing'
                  ? 1
                  : 2,
              reason: '${cli.stdout}\n${cli.stderr}',
            );
            final json = jsonDecode(cli.stdout as String) as Map;
            expect(cli.stdout, isNot(contains('synthetic-dispatch-secret')));
            expect(json['cases'][0]['dispatched'], dispatched);
            expect(json['cases'][0]['operationalFailure'], name != 'good');
            expect(
              (json['executedOperations'] as List).length,
              dispatched ? 1 : 0,
            );
            expect(
              (json['untestedOperations'] as List).length,
              dispatched ? 0 : 1,
            );
            expect(
              json['coverage']['execution'],
              'transport-dispatched-attempts',
            );
            if (dispatched)
              expect(seen.length, greaterThan(afterCore));
            else
              expect(seen.length, afterCore);
          }
          expect(await file.readAsString(), original);
          expect(await manifest.readAsString(), configuration);
        },
      );
    }
}
