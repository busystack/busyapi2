import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _oldSecretReference = '11111111-1111-4111-8111-111111111111';
const _newSecretReference = '22222222-2222-4222-8222-222222222222';

void main() {
  for (final format in ['yaml', 'json']) {
    test(
      'security Source completion and selectors invalidate across working version changes $format',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-security-source-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final original =
            '${format == 'yaml' ? '# retained\r\n' : ''}{"openapi":"3.2.1","info":{"title":"Source","version":"1"},"paths":{},"components":{"securitySchemes":{"Named":{"type":"apiKey","in":"header","name":"X-Key"}}},"security":[{}],"x-exact":9007199254740993.00}';
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
            buffer = await project.buffer(project.roots.single.id);
        Future<SourceAssistance> complete() {
          final caret =
              buffer.text.indexOf('{}', buffer.text.indexOf('"security"')) + 1;
          buffer.selection = SourceSelection(caret, caret);
          return project.assistSource(
            root,
            root,
            SourceSelection(caret, caret),
          );
        }

        final first = await complete();
        expect(
          first.completions.any(
            (entry) => (entry['label'] as String).contains(
              '#/components/securitySchemes/Named',
            ),
          ),
          true,
        );
        final named = first.completions.indexWhere(
          (entry) => entry['label'] == 'Named',
        );
        expect(named, greaterThanOrEqualTo(0));
        project.store.apply([
          first.completion(named, buffer),
        ], label: 'Security completion');
        expect(buffer.text, contains('9007199254740993.00'));
        expect((await project.check(root))['complete'], true);
        project.store.undo();
        expect(buffer.text, original);
        final page = await project.referenceChoices(
          root,
          root,
          '/security/0',
          keyword: 'security',
          bindingForm: SecurityBindingForm.uri,
        );
        project.store.replace(root, original.replaceFirst('3.2.1', '3.1.2'));
        expect(page.current, false);
        await expectLater(
          project.planReferenceSelection(page, 0),
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'code',
              'reference.choice.stale',
            ),
          ),
        );
        final older = await complete();
        expect(
          older.completions.any((entry) => entry['label'] == 'Named'),
          true,
        );
        expect(
          older.completions.any(
            (entry) => (entry['label'] as String).contains(
              '#/components/securitySchemes/Named',
            ),
          ),
          false,
        );
        final inspection = await project.inspectObject(
          root,
          root,
          '/security/0',
        );
        expect(
          SpecificationCapabilities.fromJson(inspection['capabilities'])
              .securityRequirementUris,
          false,
        );
        project.store.replace(root, original);
        final restored = await complete();
        expect(
          restored.completions.any(
            (entry) => (entry['label'] as String).contains(
              '#/components/securitySchemes/Named',
            ),
          ),
          true,
        );
        expect(file.readAsStringSync(), original);
      },
    );
  }
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final uri in [false, if (version == '3.2.1') true]) {
        test(
          'reviewed security selection $version $format URI=$uri preserves credentials, history and wire behavior',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'busyapi-security-selection-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final received = <HttpRequest>[];
            server.listen((request) async {
              received.add(request);
              expect(request.method, 'GET');
              expect(request.uri.toString(), '/selected');
              expect(request.headers.value('X-Old'), isNull);
              expect(request.headers.value('X-New'), 'synthetic-new');
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
            final old = {'type': 'apiKey', 'in': 'header', 'name': 'X-Old'};
            final next = {'type': 'apiKey', 'in': 'header', 'name': 'X-New'};
            final data = {
              if (version == '2.0') 'swagger': version else 'openapi': version,
              'info': {'title': 'Security 雪😀', 'version': '1'},
              if (version == '2.0') ...{
                'schemes': ['http'],
                'host': '127.0.0.1:${server.port}',
                'securityDefinitions': {'Old': old, 'New': next},
              } else ...{
                'servers': [
                  {'url': 'http://127.0.0.1:${server.port}'},
                ],
                'components': {
                  'securitySchemes': {
                    'Old': old,
                    'New': next,
                    if (uri) 'Remote': {r'$ref': 'security.json#/Remote'},
                  },
                },
              },
              'paths': {
                '/selected': {
                  'get': {
                    'responses': {
                      '204': {'description': 'Empty'},
                    },
                  },
                },
              },
              'security': [
                {
                  'Old': version == '3.2.1' ? ['operator', '雪'] : <String>[],
                },
              ],
              'x-number': 'EXACT',
            };
            final original =
                '${format == 'yaml' ? '# retained 雪😀\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(data).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
            final file = File('${directory.path}/api.$format')
              ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
            final external = File('${directory.path}/security.json')
              ..writeAsStringSync(jsonEncode({'Remote': next}));
            final configuration =
                '''version: 1
roots: [{name: api, path: api.$format}]
environments:
  manual:
    authentication:
      alternative: 0
      schemes:
        Old: {secretRef: '$_oldSecretReference'} # keep original binding
tests:
  - name: selection
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
            var project = await BusyProject.open(directory.path, engine);
            addTearDown(() => project.close());
            final root = file.uri.toString(),
                buffer = await project.buffer(root);
            final page = await project.referenceChoices(
              root,
              root,
              '/security/0/Old',
              keyword: 'security',
              bindingForm: uri
                  ? SecurityBindingForm.uri
                  : SecurityBindingForm.name,
              query: uri ? 'Remote' : 'New',
            );
            final entries = (page.result['entries'] as List).cast<Map>();
            final index = entries.indexWhere(
              (entry) => uri
                  ? entry['target']['resource'] == external.uri.toString()
                  : entry['value'] == 'New',
            );
            expect(index, greaterThanOrEqualTo(0));
            final binding = entries[index]['value'] as String;
            final plan = await project.planReferenceSelection(page, index);
            expect(plan.edits.every((edit) => edit.buffer == root), true);
            expect(buffer.text, original);
            expect(manifest.readAsStringSync(), configuration);
            await project.applyRefactoring(plan);
            final accepted = buffer.text;
            expect(accepted, contains('9007199254740993.00'));
            expect(
              jsonDecode(
                accepted.replaceFirst('# retained 雪😀\r\n', ''),
              )['security'],
              [
                {
                  binding: version == '3.2.1' ? ['operator', '雪'] : [],
                },
              ],
            );
            project.store.undo();
            expect(buffer.text, original);
            project.store.redo();
            expect(buffer.text, accepted);
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(original),
            ]);

            Future<OperationRequestPlan> prepare() async {
              final checked = await project.check(root);
              expect(
                checked['complete'],
                true,
                reason: '${checked['findings']}',
              );
              final operation =
                  (checked['projection']['operations'] as List).single as Map;
              return project.prepareRequest(
                root,
                resource: operation['resource'] as String,
                pointer: operation['pointer'] as String,
                occurrence: operation['occurrence'] as String,
              );
            }

            final unconfigured = await prepare();
            var secretReads = 0;
            try {
              await expectLater(
                const ContractRequestExecutor().execute(
                  unconfigured,
                  OperationRequestDraft(
                    planIdentity: unconfigured.identity,
                    environment: 'manual',
                  ),
                  resolveSecret: (_) async {
                    secretReads++;
                    return 'wrong';
                  },
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'request.security.configuration',
                  ),
                ),
              );
            } finally {
              unconfigured.close();
            }
            expect(secretReads, 0);
            expect(received, isEmpty);
            final configBuffer = await project.buffer(manifest.uri.toString());
            expect(configBuffer.text, configuration);
            project.store.replace(
              configBuffer.id,
              configuration.replaceFirst(
                '# keep original binding\n',
                '# keep original binding\n        ${jsonEncode(binding)}: {secretRef: "$_newSecretReference"}\n',
              ),
            );
            final prepared = await prepare();
            try {
              final result = await const ContractRequestExecutor().execute(
                prepared,
                OperationRequestDraft(
                  planIdentity: prepared.identity,
                  environment: 'manual',
                ),
                resolveSecret: (reference) async {
                  expect(reference, _newSecretReference);
                  return 'synthetic-new';
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
            expect(received, hasLength(1));
            final publication = await PublicationStore(
              '${directory.path}/publication',
            ).save(project, project.store.buffers.values);
            expect(publication.complete, true);
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(accepted),
            ]);
            expect(external.readAsStringSync(), jsonEncode({'Remote': next}));
            project.close();
            project = await BusyProject.open(directory.path, engine);
            final reopened = await project.check(root);
            expect(reopened['complete'], true);
            expect((await project.buffer(root)).text, accepted);
            final cli = await runCliWithSecrets(
              [
                'test',
                directory.path,
                '--case',
                'selection',
                '--environment',
                'manual',
                '--json',
              ],
              {_newSecretReference: 'synthetic-new'},
            );
            expect(cli.code, 0, reason: '${cli.output}\n${cli.error}');
            expect(jsonDecode(cli.output)['complete'], true);
            expect(jsonDecode(cli.output)['cases'].single['passed'], true);
            expect(cli.output, isNot(contains('synthetic-new')));
            expect(received, hasLength(2));
            final savedBytes = file.readAsBytesSync();
            expect(
              (await PublicationStore(
                '${directory.path}/publication',
              ).save(project, project.store.buffers.values)).complete,
              true,
            );
            expect(file.readAsBytesSync(), savedBytes);
          },
        );
      }
    }
  }
  test(
    'security selections reject cancelled and stale reviewed owners',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-security-stale-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.json')
        ..writeAsStringSync(
          '{"openapi":"3.2.1","info":{"title":"Stale","version":"1"},"paths":{},"components":{"securitySchemes":{"Next":{"type":"apiKey","in":"header","name":"X-Key"}}},"security":[]}',
        );
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final root = project.roots.single.id,
          buffer = await project.buffer(project.roots.single.id);
      final page = await project.referenceChoices(
        root,
        root,
        '/security',
        keyword: 'security',
        bindingForm: SecurityBindingForm.name,
      );
      await expectLater(
        project.planReferenceSelection(page, 0, cancelled: () => true),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'cancelled',
          ),
        ),
      );
      final plan = await project.planReferenceSelection(page, 0),
          before = buffer.text;
      project.store.replace(root, '$before\n');
      await expectLater(
        project.applyRefactoring(plan),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'refactor.stale',
          ),
        ),
      );
      expect(buffer.text, '$before\n');
      expect(file.readAsStringSync(), before);
    },
  );
}
