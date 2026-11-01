import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    test(
      '$version actual parameter bytes distinguish empty names from whole queries',
      () async {
        final legacy = version == '2.0';
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-parameter-wire-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final seen = <(String, String, String?, List<int>)>[];
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
            request.headers.value('__proto__'),
            bytes,
          ));
          request.response.statusCode = 204;
          await request.response.close();
        });
        Map<String, dynamic> parameter(
          String name,
          String location,
          Map<String, dynamic> schema,
        ) => {
          'name': name,
          'in': location,
          'required': true,
          if (legacy)
            ...schema
          else ...{
            'schema': schema,
            if (name == 'q') ...{'style': 'form', 'explode': false},
          },
        };
        final value = {
          if (legacy) 'swagger': version else 'openapi': version,
          'info': {'title': 'Parameter bytes', 'version': 'api-version'},
          if (legacy) ...{
            'host': '127.0.0.1:${server.port}',
            'basePath': '/v1',
            'schemes': ['http'],
          } else
            'servers': [
              {'url': 'http://127.0.0.1:${server.port}/v1'},
            ],
          'paths': {
            '/p': {
              'post': {
                'parameters': [
                  parameter('', 'query', {
                    'type': 'string',
                    'enum': ['empty name', ''],
                  }),
                  parameter('__proto__', 'query', {
                    'type': 'string',
                    'enum': ['query'],
                  }),
                  parameter('__proto__', 'header', {
                    'type': 'string',
                    'enum': ['header'],
                  }),
                  parameter('q', 'query', {
                    'type': 'array',
                    'minItems': 2,
                    'maxItems': 2,
                    'items': {
                      'type': 'integer',
                      'enum': ['EXACT_VALUE', 0],
                    },
                  }),
                ],
                'responses': {
                  '204': {'description': 'Accepted'},
                },
              },
            },
            '/empty': {
              'post': {
                'parameters': [
                  {
                    ...parameter('', 'query', {
                      'type': 'string',
                      'enum': [''],
                    }),
                    if (legacy) 'allowEmptyValue': true,
                  },
                ],
                'responses': {
                  '204': {'description': 'Accepted'},
                },
              },
            },
          },
        };
        final source = File('${temp.path}/api.json');
        final original = jsonEncode(value)
            .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
        await source.writeAsString(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(source.path, engine);
        addTearDown(project.close);
        final checked = await project.check(source.uri.toString());
        expect(checked['complete'], true, reason: '$checked');
        expect(
          (checked['findings'] as List).whereType<Map>().where(
            (finding) => finding['severity'] == 'error',
          ),
          isEmpty,
        );
        final operation = (checked['projection']['operations'] as List)
            .whereType<Map>()
            .where((operation) => operation['path'] == '/p')
            .single;
        final plan = await project.prepareRequest(
          source.uri.toString(),
          resource: operation['resource'] as String,
          pointer: operation['pointer'] as String,
          occurrence: operation['occurrence'] as String,
        );
        addTearDown(plan.close);
        final requestValues = {
          OperationRequestDraft.parameterKey('query', ''):
              const RequestValue.text('empty name'),
          OperationRequestDraft.parameterKey('query', '__proto__'):
              const RequestValue.text('query'),
          OperationRequestDraft.parameterKey('header', '__proto__'):
              const RequestValue.text('header'),
          OperationRequestDraft.parameterKey('query', 'q'):
              const RequestValue.json('[9007199254740993,0]'),
        };
        final result = await const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: requestValues,
          ),
          resolveSecret: (_) async => null,
        );
        addTearDown(result.close);
        expect(result.response.status, 204);
        expect(result.outgoing.complete, true);
        expect(
          result.outgoing.valid,
          true,
          reason: '${result.outgoing.findings}',
        );
        expect(seen, hasLength(1));
        expect(seen.single.$1, 'POST');
        expect(
          seen.single.$2,
          '/v1/p?=empty%20name&__proto__=query&q=9007199254740993${legacy ? '%2C' : ','}0',
        );
        expect(seen.single.$3, 'header');
        expect(seen.single.$4, isEmpty);
        if (legacy) {
          await expectLater(
            const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                parameters: {
                  ...requestValues,
                  OperationRequestDraft.parameterKey('query', ''):
                      const RequestValue.text(''),
                },
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'request.parameter.empty',
              ),
            ),
          );
          expect(
            seen,
            hasLength(1),
            reason: 'A forbidden empty query cannot dispatch',
          );
        }
        final emptyOperation = (checked['projection']['operations'] as List)
            .whereType<Map>()
            .singleWhere((operation) => operation['path'] == '/empty');
        final emptyPlan = await project.prepareRequest(
          source.uri.toString(),
          resource: emptyOperation['resource'] as String,
          pointer: emptyOperation['pointer'] as String,
          occurrence: emptyOperation['occurrence'] as String,
        );
        addTearDown(emptyPlan.close);
        final emptyResult = await const ContractRequestExecutor().execute(
          emptyPlan,
          OperationRequestDraft(
            planIdentity: emptyPlan.identity,
            parameters: {
              OperationRequestDraft.parameterKey('query', ''):
                  const RequestValue.text(''),
            },
          ),
          resolveSecret: (_) async => null,
        );
        addTearDown(emptyResult.close);
        expect(emptyResult.response.status, 204);
        expect(emptyResult.outgoing.complete, true);
        expect(emptyResult.outgoing.valid, true);
        expect(seen, hasLength(2));
        expect(seen.last.$2, '/v1/empty?=');
        expect(seen.last.$4, isEmpty);
        expect(await source.readAsString(), original);
      },
    );
  }
}
