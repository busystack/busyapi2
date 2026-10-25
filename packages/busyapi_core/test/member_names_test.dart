import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _secret = '11111111-1111-4111-8111-111111111111';
String _escape(String value) =>
    value.replaceAll('~', '~0').replaceAll('/', '~1');

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test(
        'native documentation labels empty names and retains working source $version $format',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-member-name-docs-',
          );
          addTearDown(() => directory.delete(recursive: true));
          const name = 'clé/雪 ~😀 #?%';
          final schema = {
            'type': 'object',
            'properties': {
              '': {'type': 'string'},
              name: {'type': 'integer'},
            },
          };
          final data = {
            if (version == '2.0') 'swagger': version else 'openapi': version,
            'info': {'title': 'Saved title', 'version': '1'},
            'paths': {},
            if (version == '2.0')
              'definitions': {name: schema, '': schema}
            else
              'components': {
                'schemas': {'Named': schema},
              },
            'x-large': 'EXACT',
          };
          final original =
              '${format == 'yaml' ? '# retained source\r\n' : ''}${jsonEncode(data).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              buffer = await project.buffer(project.roots.single.id),
              before = file.readAsBytesSync();
          project.store.replace(
            root,
            original.replaceFirst('Saved title', 'Unsaved title'),
          );
          final plan = await project.prepareDocumentation(
            root,
            '${directory.path}/docs',
          );
          addTearDown(plan.close);
          expect(plan.unsaved, true);
          await plan.publish();
          final html = File('${directory.path}/docs/index.html')
              .readAsStringSync();
          expect(html, contains('Unsaved title'));
          expect(html, contains(name));
          expect(html, contains('9007199254740993.00'));
          expect(html, contains('(empty name)'));
          expect(html, isNot(contains('<dt></dt>')));
          expect(file.readAsBytesSync(), before);
          expect(buffer.dirty, true);
        },
      );
    }
  for (final format in ['yaml', 'json']) {
    for (final name in ['clé/雪 ~😀 #?%', '']) {
      for (final group in [
        'definitions',
        'parameters',
        'responses',
        'securityDefinitions',
      ]) {
        test(
          'Swagger $format $group rename to ${jsonEncode(name)} retains references, wire behavior and publication',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-member-names-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            var received = 0;
            server.listen((request) async {
              received++;
              expect(request.method, 'GET');
              expect(request.uri.toString(), '/selected');
              expect(request.headers.value('X-Key'), 'synthetic-key');
              expect(
                await request.fold<List<int>>(
                  [],
                  (bytes, chunk) => bytes..addAll(chunk),
                ),
                isEmpty,
              );
              request.response.statusCode = 204;
              await request.response.close();
            });
            final data = {
              'swagger': '2.0',
              'info': {'title': 'Native names 雪😀', 'version': '1'},
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'paths': {
                '/selected': {
                  'get': {
                    'parameters': [
                      {r'$ref': '#/parameters/Old'},
                    ],
                    'responses': {
                      '204': {r'$ref': '#/responses/Old'},
                      '200': {
                        'description': 'Model',
                        'schema': {r'$ref': '#/definitions/Old'},
                      },
                    },
                  },
                },
              },
              'definitions': {
                'Old': {'type': 'string'},
              },
              'parameters': {
                'Old': {'name': 'q', 'in': 'query', 'type': 'string'},
              },
              'responses': {
                'Old': {'description': 'Empty'},
              },
              'securityDefinitions': {
                'Old': {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
              },
              'security': [
                {'Old': <String>[]},
              ],
              'x-literal': {'Old': 'unchanged', 'large': 'EXACT'},
            };
            final original =
                '${format == 'yaml' ? '# retained source 雪😀\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(data).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
            final file = File('${directory.path}/api.$format')
              ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
            final configuration =
                '''version: 1
roots: [{name: api, path: api.$format}]
environments:
  manual:
    authentication:
      alternative: 0
      schemes:
        Old: {secretRef: '$_secret'} # keep original reference
tests:
  - name: names
    operation: {method: GET, path: /selected}
    expect: {status: 204}
''';
            final manifest = File('${directory.path}/busyapi.yaml')
              ..writeAsStringSync(configuration);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            var project = await BusyProject.open(file.path, engine);
            addTearDown(() => project.close());
            final root = project.roots.single.id,
                buffer = await project.buffer(project.roots.single.id);
            final target = await project.inspectObject(
              root,
              root,
              '/$group/Old',
            );
            expect(target['componentDefinition'], true);
            expect(
              MemberNamePolicy.fromJson(target['componentNamePolicy'])
                  .allows(name),
              true,
            );
            final plan = await project.planComponentRename(target, name);
            expect(buffer.text, original);
            await project.applyRefactoring(plan);
            final accepted = buffer.text,
                destination = '/$group/${_escape(name)}';
            final after = await project.check(root);
            expect(after['status'], 'complete', reason: '${after['findings']}');
            expect(
              (after['references'] as List).any(
                (ref) => ref['targetPointer'] == destination,
              ),
              true,
            );
            final parsed = jsonDecode(
              accepted.replaceFirst('# retained source 雪😀\r\n', ''),
            ) as Map;
            expect((parsed[group] as Map).containsKey(name), true);
            expect((parsed[group] as Map).containsKey('Old'), false);
            expect(parsed['x-literal']['Old'], 'unchanged');
            expect(accepted, contains('9007199254740993.00'));
            final configBuffer = await project.buffer(manifest.uri.toString());
            final acceptedConfiguration = configBuffer.text;
            if (group == 'securityDefinitions') {
              expect(acceptedConfiguration, isNot(configuration));
              expect(
                acceptedConfiguration,
                contains('# keep original reference'),
              );
            } else {
              expect(acceptedConfiguration, configuration);
            }
            project.store.undo();
            expect(buffer.text, original);
            expect(configBuffer.text, configuration);
            project.store.redo();
            expect(buffer.text, accepted);
            expect(configBuffer.text, acceptedConfiguration);
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(original),
            ]);
            final checked = await project.check(root),
                operation =
                    (checked['projection']['operations'] as List).single as Map;
            final prepared = await project.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            try {
              final result = await const ContractRequestExecutor().execute(
                prepared,
                OperationRequestDraft(
                  planIdentity: prepared.identity,
                  environment: 'manual',
                ),
                resolveSecret: (reference) async {
                  expect(reference, _secret);
                  return 'synthetic-key';
                },
              );
              try {
                expect(result.conforming, true);
              } finally {
                await result.close();
              }
            } finally {
              prepared.close();
            }
            expect(received, 1);
            expect(
              (await PublicationStore(
                '${directory.path}/publication',
              ).save(project, [buffer])).complete,
              true,
            );
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(accepted),
            ]);
            expect(manifest.readAsStringSync(), acceptedConfiguration);
            project.close();
            project = await BusyProject.open(file.path, engine);
            expect((await project.check(root))['status'], 'complete');
            expect((await project.buffer(root)).text, accepted);
            final cli = await runCliWithSecrets(
              [
                'test',
                directory.path,
                '--case',
                'names',
                '--environment',
                'manual',
                '--json',
              ],
              {_secret: 'synthetic-key'},
            );
            expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
            expect(jsonDecode(cli.output)['complete'], true);
            expect(jsonDecode(cli.output)['cases'].single['passed'], true);
            expect(cli.output, isNot(contains('synthetic-key')));
            expect(cli.error, isNot(contains('synthetic-key')));
            expect(received, 2);
            final saved = file.readAsBytesSync();
            expect(
              (await PublicationStore(
                '${directory.path}/publication',
              ).save(project, project.store.buffers.values)).complete,
              true,
            );
            expect(file.readAsBytesSync(), saved);
          },
        );
      }
    }
  }
  for (final version in ['3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test(
        'modern $version $format component names retain their own restrictions',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-modern-names-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final original =
              '${format == 'yaml' ? '# retained\r\n' : ''}${jsonEncode({
                'openapi': version,
                'info': {'title': 'Modern', 'version': '1'},
                'paths': {},
                'components': {
                  'schemas': {
                    'Old': {'type': 'string'},
                  },
                },
              })}';
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              target = await project.inspectObject(
                project.roots.single.id,
                project.roots.single.id,
                '/components/schemas/Old',
              );
          final policy = MemberNamePolicy.fromJson(
            target['componentNamePolicy'],
          );
          for (final name in ['clé/雪 ~😀 #?%', '']) {
            expect(policy.allows(name), false);
            await expectLater(
              project.planComponentRename(target, name),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'refactor.name',
                ),
              ),
            );
            expect((await project.buffer(root)).text, original);
            expect(file.readAsStringSync(), original);
          }
        },
      );
    }
}
