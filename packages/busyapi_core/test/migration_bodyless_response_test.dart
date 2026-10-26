import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final targetVersion in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$format bodyless Swagger → $targetVersion retains HTTP body refusal',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-bodyless-migration-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var payload = false;
          final seen = <(String, String, List<int>)>[];
          server.listen((request) async {
            seen.add((
              request.method,
              request.uri.toString(),
              await request.fold<List<int>>(
                [],
                (bytes, next) => bytes..addAll(next),
              ),
            ));
            request.response.statusCode = 200;
            if (payload) {
              request.response.headers.contentType = ContentType.json;
              request.response.write('{"unexpected":false}');
            }
            await request.response.close();
          });
          final source = Directory('${temp.path}/source');
          await source.create();
          final file = File('${source.path}/api.$format');
          final document = {
            'swagger': '2.0',
            'info': {'title': 'No response body', 'version': '1'},
            'host': '127.0.0.1:${server.port}',
            'schemes': ['http'],
            'produces': ['application/json'],
            'paths': {
              '/items': {
                'get': {
                  'responses': {
                    '200': {r'$ref': '#/responses/Empty'},
                  },
                },
              },
            },
            'responses': {
              'Empty': {'description': 'No payload'},
            },
          };
          final text =
              (format == 'yaml' ? '# Keep bodyless response\r\n' : '') +
              jsonEncode(document);
          final bytes = utf8.encode(text);
          await file.writeAsBytes(bytes);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final original = await BusyProject.open(file.path, engine);
          addTearDown(original.close);
          final review = await original.prepareMigration(
            file.uri.toString(),
            '${temp.path}/target',
            targetVersion: targetVersion,
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          await review.publish();
          final migrated = await BusyProject.open(review.destination, engine);
          addTearDown(migrated.close);
          for (final owner in [original, migrated]) {
            final root = owner.roots.single.id;
            final check = await owner.check(root);
            expect(check['complete'], true, reason: '$check');
            final operation =
                (check['projection']['operations'] as List).single as Map;
            final plan = await owner.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            addTearDown(plan.close);
            for (final bodyPresent in [false, true]) {
              payload = bodyPresent;
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async => null,
              );
              addTearDown(result.close);
              expect(result.outgoing.complete, true);
              expect(result.outgoing.valid, true);
              expect(
                result.received.complete,
                true,
                reason: '${result.received.findings}',
              );
              expect(
                result.received.valid,
                !bodyPresent,
                reason: '${result.received.findings}',
              );
              expect(
                await result.response.bytes(),
                bodyPresent ? utf8.encode('{"unexpected":false}') : <int>[],
              );
            }
          }
          expect(seen, hasLength(4));
          for (final request in seen) {
            expect(request.$1, 'GET');
            expect(request.$2, '/items');
            expect(request.$3, isEmpty);
          }
          expect(await file.readAsBytes(), bytes);
        },
      );
    }
  }
}
