import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _futureDialect = 'https://[v1.future]/dialect';
const _dialect = 'https://json-schema.org/draft/2020-12/schema#';
const _body = '{"n":9007199254740993.000,"flag":false,"text":"雪"}';

void main() {
  for (final version in ['3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1']) {
    for (final (format, unsupported) in [
      for (final format in ['yaml', 'json'])
        for (final unsupported in [false, true]) (format, unsupported),
    ]) {
      test(
        '$version $format ${unsupported ? 'unsupported host' : 'malformed'} dialect remains correctable without fallback',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-malformed-dialect-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <(String, String, String?, List<int>)>[];
          server.listen((request) async {
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('content-type'),
              await request.fold<List<int>>(
                [],
                (all, chunk) => all..addAll(chunk),
              ),
            ));
            request.response.headers.contentType = ContentType.json;
            request.response.write(_body);
            await request.response.close();
          });
          final schema = {r'$ref': '#/components/schemas/Value'};
          final api = {
            'openapi': version,
            'jsonSchemaDialect': _dialect,
            'info': {'title': 'Keep 雪', 'version': 'api-version'},
            'servers': [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            'paths': {
              '/items': {
                'post': {
                  'requestBody': {
                    'required': true,
                    'content': {
                      'application/json': {'schema': schema},
                    },
                  },
                  'responses': {
                    '200': {
                      'description': 'Value',
                      'content': {
                        'application/json': {'schema': schema},
                      },
                    },
                  },
                },
              },
            },
            'components': {
              'schemas': {
                'Value': {
                  'type': 'object',
                  'required': ['n', 'flag', 'text'],
                  'properties': {
                    'n': {
                      'type': 'integer',
                      'enum': ['EXACT'],
                    },
                    'flag': {'type': 'boolean'},
                    'text': {'type': 'string'},
                  },
                },
              },
            },
            'x-literal': {
              r'$schema': false,
              'jsonSchemaDialect': null,
              'n': 'EXACT',
            },
          };
          final original =
              '${format == 'yaml' ? '# Keep comment 雪\r\n' : ''}${jsonEncode(api).replaceAll('"EXACT"', '9007199254740993.000')}\r\n';
          final originalBytes = [239, 187, 191, ...utf8.encode(original)];
          final file = File('${temp.path}/api.$format');
          await file.writeAsBytes(originalBytes);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(), buffer = await project.buffer(root);
          expect((await project.check(root))['complete'], true);
          Future<OperationRequestPlan> prepare() => project.prepareRequest(
            root,
            resource: root,
            pointer: '/paths/~1items/post',
          );
          Future<ContractRequestResult> send(OperationRequestPlan plan) =>
              const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: const RequestBodyDraft.raw(
                    mediaType: 'application/json',
                    text: _body,
                  ),
                ),
                resolveSecret: (_) async => null,
              );
          for (final placement in ['default', 'schema']) {
            final stale = await prepare();
            addTearDown(stale.close);
            final broken = placement == 'default'
                ? original.replaceFirst(
                    '"jsonSchemaDialect":"$_dialect"',
                    '"jsonSchemaDialect":${unsupported ? jsonEncode(_futureDialect) : 'false'}',
                  )
                : original.replaceFirst(
                    '"Value":{"type":"object"',
                    '"Value":{"\$schema":${unsupported ? jsonEncode(_futureDialect) : 'null'},"type":"object"',
                  );
            expect(broken, isNot(original));
            project.store.replace(root, broken);
            expect(stale.outdated, true);
            await expectLater(
              send(stale),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'request.draft.stale',
                ),
              ),
            );
            final checked = await project.check(root);
            expect(checked['complete'], false);
            final pointer = placement == 'default'
                ? '/jsonSchemaDialect'
                : '/components/schemas/Value/\$schema';
            expect(
              (checked['findings'] as List).whereType<Map>().any(
                (f) =>
                    f['code'] ==
                        (unsupported
                            ? 'schema.dialect.incomplete'
                            : 'schema.dialect.malformed') &&
                    f['resource'] == root &&
                    f['pointer'] ==
                        (unsupported ? '/components/schemas/Value' : pointer),
              ),
              true,
              reason: '${checked['findings']}',
            );
            final context = SpecificationContext.fromJson(
              checked['projection']['specification'],
            );
            expect(context.declaredVersion, version);
            expect(
              context.schemaDialect,
              placement == 'default'
                  ? (unsupported ? _futureDialect : null)
                  : _dialect,
            );
            final invalid = await prepare();
            addTearDown(invalid.close);
            final badResult = await send(invalid);
            addTearDown(badResult.close);
            expect(badResult.outgoing.complete, false);
            expect(badResult.received.complete, false);
            expect(badResult.conforming, false);
            expect(await badResult.response.bytes(), utf8.encode(_body));
            expect(buffer.text, broken);
            expect(await file.readAsBytes(), originalBytes);
            await project.save(buffer);
            expect(await file.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(broken),
            ]);
            final invalidCli = await Process.run(
              '$testBundle/busyapi',
              ['check', file.path, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(invalidCli.exitCode, unsupported ? 2 : isNot(0));
            expect(jsonDecode(invalidCli.stdout as String)['complete'], false);
            project.store.replace(root, original);
            expect(invalid.outdated, true);
            final fixed = await project.check(root);
            expect(fixed['complete'], true, reason: '${fixed['findings']}');
            expect(
              fixed['categories']['openapi']['schema']['producerVersion'],
              '1.18.0+45',
            );
            final valid = await prepare();
            addTearDown(valid.close);
            final result = await send(valid);
            addTearDown(result.close);
            expect(
              result.conforming,
              true,
              reason:
                  '${result.outgoing.findings}\n${result.received.findings}',
            );
            expect(await result.response.bytes(), utf8.encode(_body));
            await project.save(buffer);
            await project.save(buffer);
            expect(await file.readAsBytes(), originalBytes);
          }
          expect(seen, hasLength(4));
          for (final request in seen) {
            expect(request.$1, 'POST');
            expect(request.$2, '/items');
            expect(request.$3, 'application/json');
            expect(request.$4, utf8.encode(_body));
          }
          final reopened = await BusyProject.open(file.path, engine);
          addTearDown(reopened.close);
          expect((await reopened.check(root))['complete'], true);
          final validCli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            validCli.exitCode,
            0,
            reason: '${validCli.stdout}\n${validCli.stderr}',
          );
          expect(jsonDecode(validCli.stdout as String)['complete'], true);
          expect(await file.readAsBytes(), originalBytes);
        },
      );
    }
  }
}
