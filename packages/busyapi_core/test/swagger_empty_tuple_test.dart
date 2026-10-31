import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _wire =
    '[null,false,0,"",{},[],{"\$ref":"literal","n":9007199254740993.00,"text":"雪😀"}]';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final targetVersion in ['3.0.4', '3.1.2', '3.2.1']) {
      test(
        'Swagger $format empty tuple captures, HTTP, saved CLI and reviewed $targetVersion conversion',
        () async {
          final directory = await Directory.systemTemp.createTemp('bet-');
          addTearDown(() => directory.delete(recursive: true));
          final seen = <(String, String, String?, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (bytes, chunk) => bytes..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.contentType?.mimeType,
              bytes,
            ));
            request.response.headers.contentType = ContentType.json;
            request.response.add(bytes);
            await request.response.close();
          });
          String source(Object value) =>
              '${format == 'yaml' ? '# Keep original tuple\r\n' : ''}${jsonEncode(value).replaceAll('"@exact"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format');
          final shared = File('${directory.path}/shared.$format');
          await file.writeAsBytes([
            239,
            187,
            191,
            ...utf8.encode(
              source({
                'swagger': '2.0',
                'info': {'title': 'Native tuple', 'version': 'business'},
                'host': '127.0.0.1:${server.port}',
                'basePath': '/v1',
                'schemes': ['http'],
                'consumes': ['application/json'],
                'produces': ['application/json'],
                'paths': {
                  '/data': {
                    'post': {
                      'parameters': [
                        {
                          'name': 'body',
                          'in': 'body',
                          'required': true,
                          'schema': {r'$ref': 'shared.$format#/a~1b'},
                        },
                      ],
                      'responses': {
                        '200': {
                          'description': 'Echo',
                          'schema': {r'$ref': 'shared.$format#/a~1b'},
                        },
                      },
                    },
                  },
                },
                'x-number': '@exact',
                'x-payload': {r'$ref': 'literal.json'},
              }),
            ),
          ]);
          await shared.writeAsBytes([
            239,
            187,
            191,
            ...utf8.encode(
              source({
                'a/b': {
                  'type': 'array',
                  'items': [
                    {'type': 'integer'},
                  ],
                },
              }),
            ),
          ]);
          final manifest = File('${directory.path}/busyapi.yaml');
          await manifest.writeAsString('''
version: 1
roots: [{name: api, path: api.$format}]
tests:
  - name: tuple
    operation: {method: post, path: /data}
    body: {mediaType: application/json, value: $_wire}
    expect: {status: 200, mediaType: application/json}
''');
          final originalRoot = await file.readAsBytes(),
              originalShared = await shared.readAsBytes(),
              originalManifest = await manifest.readAsBytes();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(directory.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(),
              buffer = await project.buffer(shared.uri.toString());
          project.store.replace(
            buffer.id,
            source({
              'a/b': {'type': 'array', 'items': []},
            }),
          );

          Future<void> send(BusyProject owner, String root) async {
            final analysis = await owner.check(root);
            expect(
              analysis['status'],
              'complete',
              reason: jsonEncode(analysis),
            );
            final operation =
                (analysis['projection']['operations'] as List).single as Map;
            final plan = await owner.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            addTearDown(plan.close);
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                body: const RequestBodyDraft.raw(
                  mediaType: 'application/json',
                  text: _wire,
                ),
              ),
              resolveSecret: (_) async => null,
            );
            expect(
              result.outgoing.complete,
              true,
              reason: '${result.outgoing.findings}',
            );
            expect(
              result.outgoing.valid,
              true,
              reason: '${result.outgoing.findings}',
            );
            expect(
              result.received.complete,
              true,
              reason: '${result.received.findings}',
            );
            expect(
              result.received.valid,
              true,
              reason: '${result.received.findings}',
            );
            await result.close();
          }

          final captured = await project.check(root);
          expect(captured['unsaved'], true);
          expect((captured['versions'] as Map)['swaggerSchemaRules'], '1');
          await send(project, root);
          expect(seen, hasLength(1));
          final mockPlan = await project.prepareMock(root);
          addTearDown(mockPlan.close);
          final mock = await mockPlan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(mock.stop);
          expect(mock.nativeValidation.version, '1.18.0+44');
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final mockRequest = await client.postUrl(
            mock.baseUri.resolve('/data'),
          );
          mockRequest.headers.contentType = ContentType.json;
          mockRequest.add(utf8.encode(_wire));
          final mockResponse = await mockRequest.close();
          final mockBody = await utf8.decoder.bind(mockResponse).join();
          expect(mockResponse.statusCode, 200, reason: mockBody);
          expect(jsonDecode(mockBody), isA<List>());
          await mock.stop();
          client.close(force: true);
          final documentation = await project.prepareDocumentation(
            root,
            '${directory.path}/documentation',
          );
          addTearDown(documentation.close);
          await documentation.publish();
          final html = await File('${documentation.destination}/index.html')
              .readAsString();
          expect(html, contains('Native tuple'));
          expect(html, contains('2.0'));
          expect(await file.readAsBytes(), originalRoot);
          expect(await shared.readAsBytes(), originalShared);
          final constrained = await Process.run('$testBundle/busyapi', [
            'test',
            directory.path,
            '--case',
            'tuple',
            '--json',
          ]);
          expect(
            constrained.exitCode,
            1,
            reason: '${constrained.stdout}\n${constrained.stderr}',
          );
          final constrainedReport =
              jsonDecode(constrained.stdout as String) as Map;
          expect(constrainedReport['complete'], true);
          expect(constrainedReport['passed'], false);
          expect(
            (constrainedReport['cases'] as List).single['dispatched'],
            true,
          );
          expect(
            seen,
            hasLength(2),
            reason: 'The saved constraint changes conformance of identical wire bytes.',
          );

          final cancelled = await project.prepareMigration(
            root,
            '${directory.path}/cancelled',
            targetVersion: targetVersion,
          );
          addTearDown(cancelled.close);
          expect(cancelled.publishable, true, reason: '${cancelled.result}');
          await expectLater(
            cancelled.publish(cancelled: () => true),
            throwsA(isA<CoreFailure>()),
          );
          expect(await Directory(cancelled.destination).exists(), false);
          final stale = await project.prepareMigration(
            root,
            '${directory.path}/stale',
            targetVersion: targetVersion,
          );
          addTearDown(stale.close);
          project.store.replace(
            buffer.id,
            source({
              'a/b': {
                'type': 'array',
                'items': [],
                'description': 'Changed while under review',
              },
            }),
          );
          await expectLater(
            stale.publish(),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'migration.stale',
              ),
            ),
          );
          expect(await Directory(stale.destination).exists(), false);
          project.store.undo();

          final review = await project.prepareMigration(
            root,
            '${directory.path}/converted',
            targetVersion: targetVersion,
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.unsaved, true);
          expect(review.result['producerVersion'], '26');
          await review.publish();
          expect(await file.readAsBytes(), originalRoot);
          expect(await shared.readAsBytes(), originalShared);
          expect(await manifest.readAsBytes(), originalManifest);
          final copy = await BusyProject.open(review.destination, engine);
          addTearDown(copy.close);
          await send(copy, copy.roots.single.id);
          final checked = await Process.run('$testBundle/busyapi', [
            'check',
            review.destination,
            '--json',
          ]);
          expect(
            checked.exitCode,
            0,
            reason: '${checked.stdout}\n${checked.stderr}',
          );
          expect(jsonDecode(checked.stdout as String)['complete'], true);
          await project.save(buffer);
          final executed = await Process.run('$testBundle/busyapi', [
            'test',
            directory.path,
            '--case',
            'tuple',
            '--json',
          ]);
          expect(
            executed.exitCode,
            0,
            reason: '${executed.stdout}\n${executed.stderr}',
          );
          expect(seen, hasLength(4));
          for (final request in seen) {
            expect(request.$1, 'POST');
            expect(request.$2, '/v1/data');
            expect(request.$3, 'application/json');
            expect(request.$4, utf8.encode(_wire));
          }
          expect(await file.readAsBytes(), originalRoot);
          expect(await manifest.readAsBytes(), originalManifest);
          final saved = await shared.readAsBytes();
          expect(saved, buffer.bytes());
          await project.save(buffer);
          expect(await shared.readAsBytes(), saved);
        },
      );
    }
  }
}
