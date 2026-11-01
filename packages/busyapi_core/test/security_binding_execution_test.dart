import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  final cases = [
    for (final version in ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1'])
      (version: version, uri: false),
    for (final version in ['3.2.0', '3.2.1']) (version: version, uri: true),
  ];
  for (final fixture in cases) {
    for (final format in ['yaml', 'json']) {
      test(
        '${fixture.version} $format security binding uri=${fixture.uri} reaches core and CLI wire',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-security-binding-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final uri = 'security.$format#/Alias';
          final names = fixture.uri
              ? ['Provider', uri]
              : ['__proto__', 'constructor', 'toString'];
          var received = 0;
          server.listen((request) async {
            received++;
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/items');
            for (var index = 0; index < names.length; index++) {
              expect(request.headers.value('x-key-$index'), 'synthetic-key');
            }
            expect(request.headers.value('reader'), isNull);
            expect(request.headers.value('role'), isNull);
            expect(await request.toList(), isEmpty);
            request.response.statusCode = 204;
            await request.response.close();
          });
          final definitions = {
            for (
              var index = 0;
              index < (fixture.uri ? 1 : names.length);
              index++
            )
              names[index]: {
                'type': 'apiKey',
                'in': 'header',
                'name': 'X-Key-$index',
              },
          };
          final requirement = {
            for (final name in names)
              name: <String>[if (fixture.uri && name == uri) 'reader'],
          };
          final swagger = fixture.version == '2.0';
          final value = {
            if (swagger)
              'swagger': fixture.version
            else
              'openapi': fixture.version,
            'info': {'title': 'Security binding 雪', 'version': '1'},
            if (swagger) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'securityDefinitions': definitions,
            } else ...{
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              'components': {'securitySchemes': definitions},
            },
            'security': [requirement],
            'paths': {
              '/items': {
                'get': {
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
          };
          final yaml =
              '''${swagger ? "swagger: '2.0'" : 'openapi: ${fixture.version}'}
info: {title: Security binding 雪, version: '1'}
${swagger ? "host: '127.0.0.1:${server.port}'\nschemes: [http]\nsecurityDefinitions:" : "servers: [{url: 'http://127.0.0.1:${server.port}'}]\ncomponents:\n  securitySchemes:"}
${definitions.entries.map((entry) => '${swagger ? '  ' : '    '}${jsonEncode(entry.key)}: ${jsonEncode(entry.value)}').join('\n')}
security: [${jsonEncode(requirement)}]
paths: {/items: {get: {responses: {'204': {description: Empty}}}}}
''';
          final original = format == 'yaml' ? yaml : jsonEncode(value);
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(original);
          final fragmentText = format == 'yaml'
              ? '''# unchanged URI definition
Alias: {\$ref: '#/Remote~1~0'}
Remote/~: {type: apiKey, in: header, name: X-Key-1}
'''
              : jsonEncode({
                  'Alias': {r'$ref': '#/Remote~1~0'},
                  'Remote/~': {
                    'type': 'apiKey',
                    'in': 'header',
                    'name': 'X-Key-1',
                  },
                });
          final fragment = File('${directory.path}/security.$format');
          if (fixture.uri) fragment.writeAsStringSync(fragmentText);
          const reference = '11111111-1111-4111-8111-111111111111';
          final configuration = jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'environments': {
              'manual': {
                'authentication': {
                  'alternative': 0,
                  'schemes': {
                    for (final name in names) name: {'secretRef': reference},
                  },
                },
              },
            },
            'tests': [
              {
                'name': 'bindings',
                'operation': {'method': 'GET', 'path': '/items'},
                'expect': {'status': 204},
              },
            ],
          });
          final manifest = File('${directory.path}/busyapi.yaml')
            ..writeAsStringSync(configuration);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(directory.path, engine);
          addTearDown(project.close);
          final checked = await project.check(file.uri.toString());
          expect(
            checked['status'],
            'complete',
            reason: '${checked['findings']}',
          );
          final operation =
              (checked['projection']['operations'] as List).single as Map;
          final plan = await project.prepareRequest(
            file.uri.toString(),
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              environment: 'manual',
            ),
            resolveSecret: (value) async {
              expect(value, reference);
              return 'synthetic-key';
            },
          );
          addTearDown(result.close);
          expect(result.conforming, true);
          expect(received, 1);
          expect((plan.result['security']['schemes'] as Map).keys, names);
          if (fixture.uri) {
            expect(
              plan.result['security']['schemes'][uri]['definition']['resource'],
              fragment.uri.toString(),
            );
            expect(
              plan.result['security']['schemes'][uri]['definition']['pointer'],
              '/Remote~1~0',
            );
            expect(plan.result['security']['requirements'][0]['scopes'][uri], [
              'reader',
            ]);
          }
          final cli = await runCliWithSecrets(
            [
              'test',
              directory.path,
              '--case',
              'bindings',
              '--environment',
              'manual',
              '--json',
            ],
            {reference: 'synthetic-key'},
          );
          expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
          expect(cli.error, isEmpty);
          final report = jsonDecode(cli.output) as Map;
          expect(report['complete'], true);
          expect((report['cases'] as List).single['passed'], true);
          expect((report['cases'] as List).single['dispatched'], true);
          expect(cli.output, isNot(contains('synthetic-key')));
          expect(received, 2);
          expect(file.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), configuration);
          if (fixture.uri) expect(fragment.readAsStringSync(), fragmentText);
        },
      );
    }
  }
}
