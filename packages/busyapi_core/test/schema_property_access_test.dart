import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format execution and CLI retain referenced property access and unsaved ownership',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-schema-access-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <(String, String, String?, List<int>)>[];
          const body = '{"id/~雪":""}', empty = '{}';
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.contentType?.mimeType,
              bytes,
            ));
            request.response.headers.contentType = ContentType.json;
            request.response.write(body);
            await request.response.close();
          });
          final source = File('${temp.path}/api.$format'),
              part = File('${temp.path}/part.$format'),
              manifest = File('${temp.path}/busyapi.yaml');
          final defs = version == '2.0'
              ? '/definitions'
              : '/components/schemas';
          final model = {
            'type': 'object',
            'required': ['id/~雪'],
            'properties': {
              'id/~雪': {r'$ref': 'part.$format#/Chain'},
            },
          };
          final schema = {r'$ref': '#$defs/Model'};
          final value = <String, Object?>{
            version == '2.0' ? 'swagger' : 'openapi': version,
            'info': {'title': 'Access 雪', 'version': '1'},
            if (version == '2.0') ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'basePath': '/v1',
              'consumes': ['application/json'],
              'produces': ['application/json'],
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}/v1'},
              ],
            'paths': {
              '/items': {
                'post': {
                  if (version == '2.0')
                    'parameters': [
                      {
                        'name': 'body',
                        'in': 'body',
                        'required': true,
                        'schema': schema,
                      },
                    ]
                  else
                    'requestBody': {
                      'required': true,
                      'content': {
                        'application/json': {'schema': schema},
                      },
                    },
                  'responses': {
                    '200': {
                      'description': 'Read',
                      if (version == '2.0')
                        'schema': schema
                      else
                        'content': {
                          'application/json': {'schema': schema},
                        },
                    },
                  },
                },
              },
            },
            version == '2.0' ? 'definitions' : 'components': version == '2.0'
                ? {'Model': model}
                : {
                    'schemas': {'Model': model},
                  },
            'x-kept': {'n': 'EXACT', 'false': false, 'empty': ''},
          };
          String text(Object value) =>
              '${format == 'yaml' ? '# Keep comments 雪\r\n' : ''}${jsonEncode(value).replaceFirst('"EXACT"', '9007199254740993.000')}\r\n';
          final original = text(value),
              originalPart = text({
                'Read': {'type': 'string', 'readOnly': true},
                'Chain': {r'$ref': '#/Read'},
              });
          await source.writeAsString(original);
          await part.writeAsString(originalPart);
          await manifest.writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'tests': [
                {
                  'name': 'present',
                  'operation': {'method': 'post', 'path': '/items'},
                  'body': {
                    'mediaType': 'application/json',
                    'value': {'id/~雪': ''},
                  },
                  'expect': {'status': 200},
                },
              ],
            }),
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(temp.path, engine);
          addTearDown(() => project.close());
          final root = source.uri.toString(), partId = part.uri.toString();
          expect((await project.check(root))['complete'], true);
          Future<OperationRequestPlan> prepare() => project.prepareRequest(
            root,
            resource: root,
            pointer: '/paths/~1items/post',
          );
          Future<ContractRequestResult> send(
            OperationRequestPlan plan,
            String body,
          ) => const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.raw(
                mediaType: 'application/json',
                text: body,
              ),
            ),
            resolveSecret: (_) async => null,
          );
          for (final payload in [body, empty]) {
            final plan = await prepare();
            addTearDown(plan.close);
            final run = await send(plan, payload);
            addTearDown(run.close);
            expect(run.outgoing.complete, true);
            expect(
              run.outgoing.valid,
              payload == body ? version != '2.0' : version.startsWith('3.0'),
              reason: '${run.outgoing.findings}',
            );
            expect(run.received.complete && run.received.valid, true);
            expect(run.conforming, run.outgoing.valid);
            expect(await run.response.bytes(), utf8.encode(body));
            expect(seen.last.$1, 'POST');
            expect(seen.last.$2, '/v1/items');
            expect(seen.last.$3, 'application/json');
            expect(seen.last.$4, utf8.encode(payload));
          }
          final stale = await prepare();
          addTearDown(stale.close);
          final buffer = await project.buffer(partId);
          project.store.replace(
            partId,
            buffer.text.replaceFirst('"readOnly":true', '"readOnly":false'),
          );
          expect(stale.outdated, true);
          await expectLater(
            send(stale, body),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'request.draft.stale',
              ),
            ),
          );
          final corrected = await prepare();
          addTearDown(corrected.close);
          final run = await send(corrected, body);
          addTearDown(run.close);
          expect(run.conforming, true);
          expect(await source.readAsString(), original);
          expect(await part.readAsString(), originalPart);
          Future<ProcessResult> cli() => Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'present', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final saved = await cli();
          expect(
            saved.exitCode,
            version == '2.0' ? 1 : 0,
            reason: '${saved.stdout}${saved.stderr}',
          );
          await project.save(buffer);
          final published = await part.readAsString();
          expect(
            published,
            originalPart.replaceFirst('"readOnly":true', '"readOnly":false'),
          );
          final next = await cli();
          expect(next.exitCode, 0, reason: '${next.stdout}${next.stderr}');
          project.close();
          project = await BusyProject.open(temp.path, engine);
          expect((await project.check(root))['complete'], true);
          final reopened = await project.buffer(partId);
          await project.save(reopened);
          expect(await part.readAsString(), published);
          expect(await source.readAsString(), original);
        },
      );
    }
  }
}
