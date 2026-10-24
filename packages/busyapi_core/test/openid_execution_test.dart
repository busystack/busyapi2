import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

Future<({int code, String output, String error})> _cli(
  Directory directory,
  String reference,
) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    [
      'test',
      directory.path,
      '--case',
      'manual-token',
      '--environment',
      'manual',
      '--secrets-stdin',
      '--json',
    ],
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  var exited = false;
  final completion = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  try {
    process.stdin.write(jsonEncode({reference: 'synthetic-access-token'}));
    await process.stdin.close();
    final code = await completion.timeout(const Duration(seconds: 30));
    return (code: code, output: await output, error: await error);
  } finally {
    if (!exited) {
      process.kill();
      await completion.timeout(const Duration(seconds: 5));
    }
  }
}

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format an explicitly configured OpenID access token reaches the API',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-openid-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => api.close(force: true));
          final discovery = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(discovery.close);
          var discoveryConnections = 0, received = 0, secretReads = 0;
          discovery.listen((socket) {
            discoveryConnections++;
            socket.destroy();
          });
          api.listen((request) async {
            received++;
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/items');
            expect(
              request.headers.value('authorization'),
              'Bearer synthetic-access-token',
            );
            expect(await request.toList(), isEmpty);
            request.response.statusCode = 204;
            await request.response.close();
          });
          final discoveryUrl =
              'https://127.0.0.1:${discovery.port}/.well-known/openid-configuration';
          final security = File('${directory.path}/security.$format');
          final securityText = format == 'json'
              ? jsonEncode({
                  'Provider': {
                    'type': 'openIdConnect',
                    'openIdConnectUrl': discoveryUrl,
                  },
                })
              : '''# original provider metadata
Provider:
  type: openIdConnect
  openIdConnectUrl: '$discoveryUrl'
''';
          security.writeAsStringSync(securityText);
          final file = File('${directory.path}/api.$format');
          final original = format == 'json'
              ? jsonEncode({
                  'openapi': version,
                  'info': {'title': 'OpenID 雪', 'version': '1'},
                  'servers': [
                    {'url': 'http://127.0.0.1:${api.port}'},
                  ],
                  'security': [
                    {
                      'Provider': ['items:read'],
                    },
                  ],
                  'components': {
                    'securitySchemes': {
                      'Provider': {r'$ref': 'security.$format#/Provider'},
                    },
                  },
                  'paths': {
                    '/items': {
                      'get': {
                        'responses': {
                          '204': {'description': 'Empty'},
                        },
                      },
                    },
                  },
                })
              : '''openapi: $version
info: {title: OpenID 雪, version: '1'}
servers: [{url: 'http://127.0.0.1:${api.port}'}]
security: [{Provider: ['items:read']}]
components:
  securitySchemes:
    Provider: {\$ref: 'security.$format#/Provider'}
paths: {/items: {get: {responses: {'204': {description: Empty}}}}}
''';
          file.writeAsStringSync(original);
          const reference = '11111111-1111-4111-8111-111111111111';
          final manifest = File('${directory.path}/busyapi.yaml')
            ..writeAsStringSync(
              jsonEncode({
                'version': 1,
                'roots': [
                  {'name': 'api', 'path': 'api.$format'},
                ],
                'environments': {
                  'manual': {
                    'authentication': {
                      'alternative': 0,
                      'schemes': {
                        'Provider': {'accessTokenRef': reference},
                      },
                    },
                  },
                },
                'tests': [
                  {
                    'name': 'manual-token',
                    'operation': {'method': 'GET', 'path': '/items'},
                    'expect': {'status': 204},
                  },
                ],
              }),
            );
          final configurationText = manifest.readAsStringSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString();
          final checked = await project.check(root);
          expect(checked['complete'], true, reason: '$checked');
          expect(
            (checked['findings'] as List).whereType<Map>().where(
              (d) => d['severity'] == 'error',
            ),
            isEmpty,
          );
          final operation =
              (checked['projection']['operations'] as List).single as Map;
          final plan = await project.prepareRequest(
            root,
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          final draft = OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'manual',
          );
          Future<String?> resolve(String value) async {
            secretReads++;
            expect(value, reference);
            return 'synthetic-access-token';
          }

          await expectLater(
            const ContractRequestBuilder().build(
              plan,
              draft,
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'secret.unavailable',
              ),
            ),
          );
          await expectLater(
            const ContractRequestBuilder().build(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                environment: 'manual',
                headers: const [
                  RequestHeaderValue('Authorization', 'explicit-value'),
                ],
              ),
              resolveSecret: (_) async => throw StateError(
                'A collision cannot acquire the selected token',
              ),
            ),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'request.security.collision',
              ),
            ),
          );
          expect(received, 0);
          expect(discoveryConnections, 0);
          final preview = await const ContractRequestBuilder().build(
            plan,
            draft,
            previewOnly: true,
            resolveSecret: resolve,
          );
          expect(
            preview.headers
                .singleWhere(
                  (header) => header.$1.toLowerCase() == 'authorization',
                )
                .$2,
            'Bearer [REDACTED]',
          );
          expect(secretReads, 0);
          expect(discoveryConnections, 0);
          final result = await const ContractRequestExecutor().execute(
            plan,
            draft,
            resolveSecret: resolve,
          );
          addTearDown(result.close);
          expect(result.conforming, true);
          expect(received, 1);
          expect(secretReads, 1);
          expect(discoveryConnections, 0);
          final cli = await _cli(directory, reference);
          expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
          expect(cli.error, isEmpty);
          final report = jsonDecode(cli.output) as Map;
          expect(report['complete'], true);
          expect((report['cases'] as List).single['passed'], true);
          expect((report['cases'] as List).single['dispatched'], true);
          expect(cli.output, isNot(contains('synthetic-access-token')));
          expect(received, 2);
          expect(discoveryConnections, 0);
          final scheme = plan.result['security']['schemes']['Provider'] as Map;
          expect(scheme['type'], 'openIdConnect');
          expect(scheme['openIdConnectUrl'], discoveryUrl);
          expect(scheme['definition']['resource'], security.uri.toString());
          expect(scheme['definition']['pointer'], '/Provider');
          expect(
            plan.result['security']['requirements'][0]['scopes']['Provider'],
            ['items:read'],
          );
          expect(
            result.request.displayUri.toString(),
            isNot(contains('synthetic-access-token')),
          );
          expect(file.readAsStringSync(), original);
          expect(security.readAsStringSync(), securityText);
          expect(manifest.readAsStringSync(), configurationText);
        },
      );
    }
  }
}
