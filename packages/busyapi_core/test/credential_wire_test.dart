import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _reference = '123e4567-e89b-42d3-a456-426614174000';
const _patches = [
  '3.0.0',
  '3.0.1',
  '3.0.2',
  '3.0.3',
  '3.0.4',
  '2.0',
  '3.1.0',
  '3.1.1',
  '3.1.2',
  '3.2.0',
  '3.2.1',
];

void main() {
  for (final version in _patches) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format credential rules preserve actual bytes and refuse before dispatch',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-credential-wire-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final calls = <Map<String, String?>>[];
          var validHeader = true;
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/data');
            expect(
              await request.fold<List<int>>(
                [],
                (bytes, part) => bytes..addAll(part),
              ),
              isEmpty,
            );
            calls.add({
              'authorization': request.headers.value('authorization'),
              'key': request.headers.value('x-key'),
            });
            request.response.statusCode = 204;
            request.response.headers.set(
              'X-Result',
              validHeader ? 'pass' : 'wrong',
            );
            await request.response.close();
          });
          final swagger = version == '2.0';
          final schemes = {
            'basic': swagger
                ? {'type': 'basic'}
                : {'type': 'http', 'scheme': 'basic'},
            'key': {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
            'token': swagger
                ? {
                    'type': 'oauth2',
                    'flow': 'application',
                    'tokenUrl': 'http://127.0.0.1:${server.port}/token',
                    'scopes': <String, String>{},
                  }
                : {'type': 'http', 'scheme': 'bearer'},
          };
          final response = {
            'description': 'Empty',
            'headers': {
              'X-Result': swagger
                  ? {
                      'type': 'string',
                      'enum': ['pass'],
                    }
                  : {
                      'schema': {
                        'type': 'string',
                        'enum': ['pass'],
                      },
                    },
            },
          };
          final data = {
            if (swagger) 'swagger': version else 'openapi': version,
            'info': {'title': 'Credential wire 雪', 'version': 'api-version'},
            if (swagger) ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'securityDefinitions': schemes,
            } else ...{
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
              'components': {'securitySchemes': schemes},
            },
            'security': [
              {'basic': <String>[]},
              {'key': <String>[]},
              {'token': <String>[]},
            ],
            'paths': {
              '/data': {
                'get': {
                  'responses': {'204': response},
                },
              },
            },
            'x-exact': 'EXACT',
          };
          final original = format == 'yaml'
              ? '\uFEFF# Retain credential contract\r\n'
                    '${swagger ? 'swagger' : 'openapi'}: "$version"\r\n'
                    'info: {title: "Credential wire 雪", version: api-version}\r\n'
                    '${swagger ? 'host: "127.0.0.1:${server.port}"\r\nschemes: [http]\r\nsecurityDefinitions: ${jsonEncode(schemes)}\r\n' : 'servers: [{url: "http://127.0.0.1:${server.port}"}]\r\ncomponents: {securitySchemes: ${jsonEncode(schemes)}}\r\n'}'
                    'security: [{basic: []}, {key: []}, {token: []}]\r\n'
                    'paths:\r\n  /data:\r\n    get:\r\n      responses: {"204": ${jsonEncode(response)}}\r\n'
                    'x-exact: 9007199254740993.00\r\n'
              : const JsonEncoder.withIndent('  ')
                    .convert(data)
                    .replaceFirst('"EXACT"', '9007199254740993.00');
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(original);
          final manifest = File('${directory.path}/busyapi.yaml')
            ..writeAsStringSync(
              'version: 1\nroots: [{name: api, path: api.$format}]\n'
              'environments:\n  local:\n    authentication:\n      alternative: 0\n      schemes:\n'
              '        basic: {username: "user", passwordRef: $_reference}\n'
              '        key: {secretRef: $_reference}\n'
              '        token: {${swagger ? 'accessTokenRef' : 'tokenRef'}: $_reference}\n'
              'tests: [{name: auth, operation: {method: GET, path: /data}, expect: {status: 204}}]\n',
            );
          final originalBytes = file.readAsBytesSync(),
              originalManifest = manifest.readAsBytesSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(directory.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(),
              checked = await project.check(file.uri.toString());
          expect(
            checked['status'],
            'complete',
            reason: '${checked['findings']}',
          );
          final operation = (checked['projection']['operations'] as List)
              .cast<Map>()
              .single;
          final plan = await project.prepareRequest(
            root,
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          var previewReads = 0;
          for (final alternative in [0, 1, 2]) {
            final preview = await const ContractRequestBuilder().build(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                environment: 'local',
                securityAlternative: alternative,
              ),
              previewOnly: true,
              resolveSecret: (_) async {
                previewReads++;
                throw StateError('A preview acquired credentials');
              },
            );
            expect(preview.runId, 'preview');
          }
          expect(previewReads, 0);
          expect(calls, isEmpty);
          Future<ContractRequestResult> send(
            int alternative,
            String? value,
          ) async {
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                environment: 'local',
                securityAlternative: alternative,
              ),
              resolveSecret: (reference) async {
                expect(reference, _reference);
                return value;
              },
            );
            addTearDown(result.close);
            expect(
              result.conforming,
              true,
              reason: '${result.outgoing.findings} ${result.received.findings}',
            );
            return result;
          }

          await send(0, 'password:tail:雪');
          expect(
            utf8.decode(
              base64.decode(calls.last['authorization']!.substring(6)),
            ),
            'user:password:tail:雪',
          );
          await send(0, '');
          expect(calls.last['authorization'], 'Basic dXNlcjo=');
          await send(1, '');
          expect(calls.last['key'], '');
          expect(calls.last['authorization'], null);
          await send(2, 'abc_DEF.~-+/==');
          expect(calls.last['authorization'], 'Bearer abc_DEF.~-+/==');
          validHeader = false;
          final invalidHeader = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              environment: 'local',
              securityAlternative: 1,
            ),
            resolveSecret: (_) async => '',
          );
          addTearDown(invalidHeader.close);
          expect(invalidHeader.received.complete, true);
          expect(invalidHeader.received.valid, false);
          expect(
            invalidHeader.received.findings.any((finding) {
              final schema = finding['schema'];
              return finding['code'] == 'runtime.schema.incompatible' &&
                  finding['location'] == 'X-Result' &&
                  schema is Map &&
                  schema['resource'] == root;
            }),
            true,
            reason: '${invalidHeader.received.findings}',
          );
          validHeader = true;
          final before = calls.length;
          for (final value in [
            ...List.generate(
              32,
              (index) => 'private${String.fromCharCode(index)}tail',
            ),
            'private\u007ftail',
            String.fromCharCode(0xd800),
            '雪' * 21846,
          ]) {
            await expectLater(
              send(0, value),
              throwsA(
                isA<CoreFailure>().having(
                  (error) => error.code,
                  'code',
                  'secret.value',
                ),
              ),
            );
          }
          for (final value in [
            '',
            'two words',
            'abc\tdef',
            'abc=tail',
            '[REDACTED]',
            '=abc',
            '雪',
            String.fromCharCode(0xd800),
          ]) {
            await expectLater(
              send(2, value),
              throwsA(
                isA<CoreFailure>().having(
                  (error) => error.code,
                  'code',
                  'secret.value',
                ),
              ),
            );
          }
          for (final alternative in [0, 1, 2]) {
            await expectLater(
              send(alternative, null),
              throwsA(
                isA<CoreFailure>().having(
                  (error) => error.code,
                  'code',
                  'secret.unavailable',
                ),
              ),
            );
          }
          expect(
            calls,
            hasLength(before),
            reason:
                'Invalid or unavailable credentials must fail before transport',
          );
          final empty = await runCliWithSecrets(
            [
              'test',
              directory.path,
              '--case',
              'auth',
              '--environment',
              'local',
              '--json',
            ],
            {_reference: ''},
          );
          expect(empty.code, 0, reason: '${empty.output}\n${empty.error}');
          expect(jsonDecode(empty.output)['passed'], true);
          expect(calls.last['authorization'], 'Basic dXNlcjo=');
          final invalid = await runCliWithSecrets(
            [
              'test',
              directory.path,
              '--case',
              'auth',
              '--environment',
              'local',
              '--json',
            ],
            {_reference: 'private\r\ntail'},
          );
          expect(invalid.code, isNot(0));
          expect(jsonDecode(invalid.output)['passed'], false);
          expect(
            '${invalid.output}\n${invalid.error}',
            isNot(contains('private\r\ntail')),
          );
          expect(calls, hasLength(before + 1));
          expect(file.readAsBytesSync(), originalBytes);
          expect(manifest.readAsBytesSync(), originalManifest);
          await project.save(await project.buffer(root));
          expect(file.readAsBytesSync(), originalBytes);
        },
      );
    }
  }
}
