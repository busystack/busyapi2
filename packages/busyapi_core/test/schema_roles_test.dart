import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'schema_role_support.dart';
import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final keyword in [r'$defs', 'definitions']) {
        test(
          '$version $format $keyword shared schema roles preserve captured HTTP and source ownership',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-schema-roles-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final received = <List<int>>[];
            server.listen((request) async {
              expect(request.method, 'POST');
              expect(request.uri.toString(), '/echo');
              expect(request.headers.contentType?.mimeType, 'application/json');
              final bytes = await request.fold<List<int>>(
                [],
                (all, next) => all..addAll(next),
              );
              received.add(bytes);
              request.response.headers.contentType = ContentType.json;
              request.response.add(bytes);
              await request.response.close();
            });
            final original = schemaRoleSource(
              version,
              format,
              keyword,
              server.port,
            );
            final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(original)];
            final file = File('${temp.path}/api.$format')
              ..writeAsBytesSync(bytes);
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            addTearDown(engine.close);
            final project = await BusyProject.open(file.path, engine);
            addTearDown(project.close);
            final root = project.roots.single.id;
            final buffer = await project.buffer(root);
            project.store.replace(
              root,
              buffer.text.replaceFirst(
                'Shared schema',
                'Unsaved shared schema',
              ),
            );
            final captured = buffer.text;
            final checked = await project.check(root);
            expect(checked['status'], 'complete', reason: jsonEncode(checked));
            expect(checked['complete'], true);
            final map = await project.inspectObject(
              root,
              root,
              '/components/schemas/Envelope/$keyword',
            );
            expect(map['kind'], 'schema-map');
            expect(map['memberNamePolicy'], isNull);
            final target = await project.inspectObject(
              root,
              root,
              '/components/schemas/Envelope/$keyword/properties',
            );
            await expectLater(
              project.planSchemaDefinitionRename(target, 'type'),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'refactor.shared-role',
                ),
              ),
            );
            expect(buffer.text, captured);
            final plan = await project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1echo/post',
            );
            try {
              final invalid = OperationRequestDraft(
                planIdentity: plan.identity,
                body: RequestBodyDraft.raw(
                  text: '{"Leaf":9007199254740992}',
                  mediaType: 'application/json',
                ),
              );
              final built = await const ContractRequestBuilder().build(
                plan,
                invalid,
                resolveSecret: (_) async => null,
              );
              try {
                final report = await const ContractRequestExecutor()
                    .validateOutgoing(
                      plan,
                      invalid,
                      built.runId,
                      preparedBody: built.body,
                    );
                expect(report.complete, true, reason: '${report.toJson()}');
                expect(report.valid, false);
              } finally {
                await built.body?.close();
              }
              expect(received, isEmpty);
              const body = '{"Leaf":9007199254740993.00}';
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(
                    text: body,
                    mediaType: 'application/json',
                  ),
                ),
                resolveSecret: (_) async => null,
              );
              try {
                expect(result.conforming, true);
                expect(
                  await File(result.response.bodyFile).readAsBytes(),
                  utf8.encode(body),
                );
                expect(received.single, utf8.encode(body));
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
            expect(buffer.text, captured);
            expect(file.readAsBytesSync(), bytes);
            project.store.undo();
            expect(buffer.text, original);
            final publication = PublicationStore('${temp.path}/publication');
            expect(
              (await publication.save(
                project,
                project.store.buffers.values,
              )).complete,
              true,
            );
            expect(file.readAsBytesSync(), bytes);
            project.store.replace(
              root,
              original.replaceFirst(version, '3.0.4'),
            );
            final older = await project.check(root);
            expect(older['status'], isNot('complete'));
            project.store.undo();
            expect((await project.check(root))['status'], 'complete');
            expect(file.readAsBytesSync(), bytes);
          },
        );
      }
    }
  }
}
