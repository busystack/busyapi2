import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _value = '[[0,9007199254740993],[9007199254740993,0]]';
const _separators = {'csv': ',', 'ssv': ' ', 'tsv': '\t', 'pipes': '|'};

void main() {
  for (final format in ['yaml', 'json']) {
    for (final outer in ['csv', 'ssv', 'tsv', 'pipes', 'multi']) {
      test(
        'Swagger $format nested $outer Items preserve request and response wire values',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-nested-items-',
          );
          addTearDown(() => temp.delete(recursive: true));
          var validResponse = true;
          final seen = <(String, String, String?, List<int>)>[];
          final inner = outer == 'pipes' ? 'csv' : 'pipes';
          final rows = [
            '0${_separators[inner]}9007199254740993',
            '9007199254740993${_separators[inner]}0',
          ];
          final responseOuter = outer == 'multi' ? 'csv' : outer;
          final responseValue = rows.join(_separators[responseOuter]!);
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final body = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.value('n'),
              body,
            ));
            request.response.statusCode = 204;
            request.response.headers.set(
              'x-values',
              validResponse
                  ? responseValue
                  : responseValue.replaceFirst('0993', '0992'),
            );
            await request.response.close();
          });
          final items = {
            'type': 'array',
            'collectionFormat': inner,
            'minItems': 2,
            'maxItems': 2,
            'items': {
              'type': 'integer',
              'enum': [0, 'EXACT_VALUE'],
            },
          };
          final path = outer == 'multi' ? '/p' : '/p/{N}';
          final source = File('${temp.path}/api.$format');
          final original =
              '${format == 'yaml' ? '# Retain Swagger Items source\r\n' : ''}${jsonEncode({
                'swagger': '2.0',
                'info': {'title': 'Nested Items', 'version': 'api-version'},
                'host': '127.0.0.1:${server.port}',
                'basePath': '/v1',
                'schemes': ['http'],
                'paths': {
                  path: {
                    'post': {
                      'parameters': [
                        for (final location in outer == 'multi' ? ['query'] : ['path', 'query', 'header']) {'name': 'N', 'in': location, 'required': true, 'type': 'array', 'collectionFormat': outer, 'minItems': 2, 'maxItems': 2, 'items': items},
                      ],
                      'responses': {
                        '204': {
                          'description': 'No content',
                          'headers': {
                            'X-Values': {'type': 'array', 'collectionFormat': responseOuter, 'minItems': 2, 'maxItems': 2, 'items': items},
                          },
                        },
                      },
                    },
                  },
                },
              }).replaceAll('"EXACT_VALUE"', '9007199254740993.00')}\r\n';
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
              .single;
          final plan = await project.prepareRequest(
            source.uri.toString(),
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          final draft = OperationRequestDraft(
            planIdentity: plan.identity,
            parameters: {
              for (final location
                  in outer == 'multi' ? ['query'] : ['path', 'query', 'header'])
                OperationRequestDraft.parameterKey(location, 'N'):
                    const RequestValue.json(_value),
            },
          );
          final good = await const ContractRequestExecutor().execute(
            plan,
            draft,
            resolveSecret: (_) async => null,
          );
          addTearDown(good.close);
          expect(good.response.status, 204);
          expect(
            good.outgoing.complete && good.outgoing.valid,
            true,
            reason: '${good.outgoing.findings}',
          );
          expect(
            good.received.complete && good.received.valid,
            true,
            reason: '${good.received.findings}',
          );
          expect(good.response.receivedLength, 0);
          final expectedPath = outer == 'multi'
              ? '/v1/p'
              : '/v1/p/${Uri.encodeComponent(responseValue)}';
          final expectedQuery = outer == 'multi'
              ? rows.map((value) => 'N=${Uri.encodeComponent(value)}').join('&')
              : 'N=${Uri.encodeComponent(responseValue)}';
          expect(seen, hasLength(1));
          expect(seen.single.$1, 'POST');
          expect(seen.single.$2, '$expectedPath?$expectedQuery');
          expect(seen.single.$3, outer == 'multi' ? null : responseValue);
          expect(seen.single.$4, isEmpty);
          validResponse = false;
          final bad = await const ContractRequestExecutor().execute(
            plan,
            draft,
            resolveSecret: (_) async => null,
          );
          addTearDown(bad.close);
          expect(bad.response.status, 204);
          expect(bad.response.receivedLength, 0);
          expect(bad.received.complete, true);
          expect(bad.received.valid, false);
          expect(
            bad.received.findings.any(
              (finding) =>
                  finding['code'] == 'runtime.schema.incompatible' &&
                  finding['location'] == 'X-Values' &&
                  finding['schema'] is Map &&
                  (finding['schema'] as Map)['resource'] ==
                      source.uri.toString(),
            ),
            true,
            reason: '${bad.received.findings}',
          );
          expect(seen, hasLength(2));
          if (format == 'json' && outer == 'csv') {
            validResponse = true;
            final manifest = File('${temp.path}/busyapi.yaml');
            final configuration =
                '{"version":1,"roots":[{"name":"api","path":"api.json"}],"tests":[{"name":"nested","operation":{"method":"post","path":"$path"},"parameters":{"path":{"N":$_value},"query":{"N":$_value},"header":{"N":$_value}},"expect":{"status":204}}]}';
            await manifest.writeAsString(configuration);
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', 'nested', '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
            expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
            expect(seen, hasLength(3));
            expect(seen.last.$2, seen.first.$2);
            expect(seen.last.$3, seen.first.$3);
            expect(seen.last.$4, isEmpty);
            expect(await manifest.readAsString(), configuration);
          }
          expect(await source.readAsString(), original);
        },
      );
    }
  }
}
