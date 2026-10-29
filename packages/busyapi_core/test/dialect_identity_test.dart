import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _literal = 'https://example.invalid/payload#';
const _body =
    '{"n":9007199254740993.000,"flag":false,"empty":"","\$schema":"$_literal","children":[{"n":0,"flag":false,"empty":"","\$schema":"$_literal"}]}';

void main() {
  for (final version in ['3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format dialect identity supports source edits, exact HTTP and saved reopen',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-dialect-identity-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final seen = <(String, String, String?, List<int>)>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
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
          final uri =
              'https://spec.openapis.org/oas/${version.substring(0, 3)}/dialect/base';
          final schema = {r'$ref': 'model.$format'};
          final api = {
            'openapi': version,
            'jsonSchemaDialect': uri,
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
          };
          final model = {
            r'$schema': uri,
            r'$id': './model-id',
            r'$dynamicAnchor': 'node',
            'type': 'object',
            'required': ['n', 'flag', 'empty', r'$schema'],
            'properties': {
              'n': {
                'type': 'integer',
                'enum': ['EXACT', 0],
              },
              'flag': {
                'type': 'boolean',
                'enum': [false],
              },
              'empty': {
                'type': 'string',
                'enum': [''],
              },
              r'$schema': {
                'type': 'string',
                'enum': [_literal],
              },
              'children': {
                'type': 'array',
                'items': {r'$dynamicRef': '#node'},
              },
            },
          };
          final sourceFiles = {
            File('${temp.path}/api.$format'): api,
            File('${temp.path}/model.$format'): model,
          };
          final original = <File, List<int>>{};
          for (final entry in sourceFiles.entries) {
            final text =
                '${format == 'yaml' ? '# Keep organization 雪\r\n' : ''}${jsonEncode(entry.value).replaceAll('"EXACT"', '9007199254740993.000')}\r\n';
            original[entry.key] = [239, 187, 191, ...utf8.encode(text)];
            await entry.key.writeAsBytes(original[entry.key]!);
          }
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = sourceFiles.keys.first,
              modelFile = sourceFiles.keys.last;
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(),
              rootBuffer = await project.buffer(root),
              modelBuffer = await project.buffer(modelFile.uri.toString());
          final initial = await project.check(root);
          expect(initial['complete'], true, reason: '$initial');
          final operation = (initial['projection']['operations'] as List)
              .whereType<Map>()
              .single;
          final stale = await project.prepareRequest(
            root,
            resource: root,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(stale.close);
          for (final buffer in [rootBuffer, modelBuffer]) {
            expect(buffer.text.split(uri), hasLength(2));
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst(uri, '$uri#'),
            );
          }
          expect(stale.outdated, true);
          final working = {
            for (final buffer in [rootBuffer, modelBuffer])
              buffer.id: buffer.text,
          };
          final checked = await project.check(root);
          expect(checked['complete'], true, reason: '$checked');
          expect(checked['status'], 'complete');
          expect(checked['snapshot'], isNot(initial['snapshot']));
          expect(
            checked['categories']['openapi']['schema']['producerVersion'],
            '1.18.0+42',
          );
          final plan = await project.prepareRequest(
            root,
            resource: root,
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
                text: _body,
              ),
            ),
            resolveSecret: (_) async => null,
          );
          addTearDown(result.close);
          expect(
            result.conforming,
            true,
            reason: '${result.outgoing.findings}\n${result.received.findings}',
          );
          expect(result.outgoing.complete && result.received.complete, true);
          expect(await result.response.bytes(), utf8.encode(_body));
          expect(seen, hasLength(1));
          expect(seen.single.$1, 'POST');
          expect(seen.single.$2, '/items');
          expect(seen.single.$3, 'application/json');
          expect(seen.single.$4, utf8.encode(_body));
          for (final entry in original.entries)
            expect(await entry.key.readAsBytes(), entry.value);
          for (final buffer in [rootBuffer, modelBuffer])
            await project.save(buffer);
          for (final buffer in [rootBuffer, modelBuffer]) {
            expect(buffer.text, working[buffer.id]);
            expect(await File(buffer.path).readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(working[buffer.id]!),
            ]);
            await project.save(buffer);
            expect(await File(buffer.path).readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(working[buffer.id]!),
            ]);
          }
          final reopened = await BusyProject.open(file.path, engine);
          addTearDown(reopened.close);
          expect((await reopened.check(root))['complete'], true);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
          for (final buffer in [rootBuffer, modelBuffer])
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst(
                '$uri#',
                'https://example.invalid/dialect#',
              ),
            );
          final unsupported = await project.check(root);
          expect(unsupported['complete'], false);
          expect(
            (unsupported['findings'] as List).whereType<Map>().any(
              (finding) => finding['code'] == 'schema.dialect.incomplete',
            ),
            true,
          );
          expect(
            modelBuffer.text,
            contains('https://example.invalid/dialect#'),
          );
          expect(seen, hasLength(1));
        },
      );
    }
  }
}
