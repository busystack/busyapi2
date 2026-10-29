import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final kind in ['parameter', 'header']) {
        test('$version $format shared media and $kind proofs remain independent', () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-shared-example-context-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final shared = {r'$ref': '#/components/examples/Shared'};
          final response = <String, Object?>{'description': 'Read'};
          final operation = <String, Object?>{
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {'type': 'integer'},
                  'examples': {'Shared': shared},
                },
              },
            },
            'responses': {'200': response},
          };
          if (kind == 'parameter') {
            operation['parameters'] = [
              {
                'name': 'id',
                'in': 'query',
                'schema': {'type': 'integer'},
                'examples': {'Shared': shared},
              },
            ];
          } else {
            response['headers'] = {
              'X-Id': {
                'schema': {'type': 'integer'},
                'examples': {'Shared': shared},
              },
            };
          }
          final document = {
            'openapi': version,
            'info': {'title': 'Shared 雪', 'version': 'unchanged'},
            'paths': {
              '/check': {'post': operation},
            },
            'components': {
              'examples': {
                'Shared': {'serializedValue': '0'},
              },
            },
          };
          String render() =>
              '${format == 'yaml' ? '# shared contexts\r\n' : ''}${jsonEncode(document)}\r\n';
          final original = render(),
              file = File('${directory.path}/api.$format');
          final bytes = [239, 187, 191, ...utf8.encode(original)];
          await file.writeAsBytes(bytes);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          Future<void> check(bool both) async {
            final result = await project.check(buffer.id);
            expect(result['complete'], true, reason: jsonEncode(result));
            expect(result['status'], 'complete');
            final schema = result['categories']['openapi']['schema'];
            expect(schema['coverage']['unboundExampleSerializations'], 0);
            final evaluations = schema['serializedExamples'] as List;
            expect(evaluations, hasLength(both ? 2 : 1));
            expect(
              evaluations.every((value) => value['complete'] == true),
              true,
            );
            expect(evaluations.first['valid'], true);
            if (both) expect(evaluations.last['valid'], kind == 'header');
            final findings = (result['findings'] as List)
                .where(
                  (value) =>
                      value['code'] == 'example.serialization.incompatible',
                )
                .toList();
            expect(findings, hasLength(both && kind == 'parameter' ? 1 : 0));
            if (both && kind == 'parameter')
              expect(
                findings.single['pointer'],
                '/components/examples/Shared/serializedValue',
              );
          }

          await check(true);
          final before = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(
            before.exitCode,
            0,
            reason: '${before.stdout}\n${before.stderr}',
          );
          if (kind == 'parameter')
            operation.remove('parameters');
          else
            response.remove('headers');
          final repaired = render();
          project.store.replace(buffer.id, repaired);
          await check(false);
          expect(await file.readAsBytes(), bytes);
          project.store.undo();
          expect(buffer.bytes(), bytes);
          await check(true);
          project.store.redo();
          await project.save(buffer);
          final after = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(after.exitCode, 0, reason: '${after.stdout}\n${after.stderr}');
          expect(await file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(repaired),
          ]);
        });
      }
    }
  }
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format free and associated examples retain separate coverage',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-example-context-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final document = <String, Object?>{
            'openapi': version,
            'info': {'title': 'Keep 雪', 'version': 'api-version'},
            'paths': <String, Object?>{},
            'components': {
              'examples': {
                'External': {
                  'externalValue': 'https://example.invalid/never-fetch',
                },
              },
            },
            'x-exact': 'EXACT',
          };
          String render() =>
              '${format == 'yaml' ? '# retained unbound example\r\n' : ''}${jsonEncode(document).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          final original = render();
          final file = File('${directory.path}/api.$format');
          final bytes = [239, 187, 191, ...utf8.encode(original)];
          await file.writeAsBytes(bytes);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          Future<void> checked(bool bound) async {
            final result = await project.check(buffer.id);
            expect(result['complete'], !bound, reason: jsonEncode(result));
            expect(result['status'], bound ? 'incomplete' : 'complete');
            final schema = result['categories']['openapi']['schema'];
            expect(schema['producerVersion'], '1.18.0+42');
            expect(
              schema['coverage']['unboundExampleSerializations'],
              bound ? 0 : 1,
            );
            expect(schema['serializedExamples'], isEmpty);
            expect(schema['instances'], 0);
            final findings = (result['findings'] as List)
                .where(
                  (value) =>
                      value['code'] == 'example.serialization.incomplete',
                )
                .toList();
            expect(findings, hasLength(bound ? 1 : 0));
            final unbound = (result['findings'] as List)
                .where(
                  (value) => value['code'] == 'example.serialization.unbound',
                )
                .toList();
            expect(unbound, hasLength(bound ? 0 : 1));
            if (!bound) {
              expect(
                unbound.single['pointer'],
                '/components/examples/External/externalValue',
              );
              expect(unbound.single['severity'], 'information');
            }
            if (bound)
              expect(
                findings.single['pointer'],
                '/components/examples/External/externalValue',
              );
            expect(buffer.text, contains('9007199254740993.00'));
          }

          Future<void> cli(int expected, String status) async {
            final result = await Process.run('$testBundle/busyapi', [
              'check',
              file.path,
              '--json',
            ]);
            expect(
              result.exitCode,
              expected,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(jsonDecode(result.stdout as String)['status'], status);
          }

          await checked(false);
          await cli(0, 'complete');
          (document['paths'] as Map<String, Object?>)['/check'] = {
            'get': {
              'parameters': [
                {
                  'name': 'id',
                  'in': 'query',
                  'schema': {'type': 'integer'},
                  'examples': {
                    'Bound': {r'$ref': '#/components/examples/External'},
                  },
                },
              ],
              'responses': {
                '204': {'description': 'Empty'},
              },
            },
          };
          final bound = render();
          project.store.replace(buffer.id, bound);
          await checked(true);
          expect(await file.readAsBytes(), bytes);
          await cli(0, 'complete');
          project.store.undo();
          expect(buffer.bytes(), bytes);
          await checked(false);
          project.store.redo();
          expect(buffer.text, bound);
          await checked(true);
          await project.save(buffer);
          await cli(2, 'incomplete');
          project.store.undo();
          await checked(false);
          await project.save(buffer);
          await cli(0, 'complete');
          expect(await file.readAsBytes(), bytes);
        },
      );
    }
  }
  for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final field in [
        'externalValue',
        if (version.startsWith('3.2.')) 'serializedValue',
      ]) {
        test('$version $format $field retains explicit serialization coverage', () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-example-coverage-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final example = <String, Object?>{
            field: field == 'externalValue' ? './wire.txt' : 'id=0',
            if (version.startsWith('3.2.')) 'dataValue': 0,
          };
          final document = {
            'openapi': version,
            'info': {'title': 'Keep 雪', 'version': 'api-version'},
            'paths': {
              '/check': {
                'get': {
                  'parameters': [
                    {
                      'name': 'id',
                      'in': 'query',
                      'schema': {'type': 'integer'},
                      'examples': {'Case': example},
                    },
                  ],
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
          };
          final original =
              '${format == 'yaml' ? '# retained 雪\r\n' : ''}${jsonEncode(document)}\r\n';
          final file = File('${directory.path}/api.$format');
          final bytes = [239, 187, 191, ...utf8.encode(original)];
          await file.writeAsBytes(bytes);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          final pointer =
              '/paths/~1check/get/parameters/0/examples/Case/$field';
          final supported = field == 'serializedValue';
          Future<void> verifyOriginal() async {
            final result = await project.check(buffer.id);
            expect(result['complete'], supported, reason: jsonEncode(result));
            expect(result['status'], supported ? 'complete' : 'incomplete');
            final findings = (result['findings'] as List)
                .where(
                  (value) =>
                      value['code'] == 'example.serialization.incomplete',
                )
                .toList();
            expect(findings, hasLength(supported ? 0 : 1));
            final schema = result['categories']['openapi']['schema'];
            if (supported) {
              final proof = (schema['serializedExamples'] as List).single;
              expect(proof['complete'], true);
              expect(proof['valid'], true);
              expect(proof['pointer'], pointer);
            } else {
              final finding = findings.single;
              expect(finding['resource'], buffer.id);
              expect(finding['pointer'], pointer);
              expect(finding['severity'], 'warning');
              expect(
                finding['detailCode'],
                'example.external-value.unavailable',
              );
            }
            expect(schema['producerVersion'], '1.18.0+42');
          }

          await verifyOriginal();
          final before = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(
            before.exitCode,
            supported ? 0 : 2,
            reason: '${before.stdout}\n${before.stderr}',
          );
          expect(
            jsonDecode(before.stdout as String)['status'],
            supported ? 'complete' : 'incomplete',
          );
          expect(await file.readAsBytes(), bytes);
          final repaired = version.startsWith('3.2.')
              ? original.replaceFirst(
                  '${jsonEncode(field)}:${jsonEncode(example[field])},',
                  '',
                )
              : original.replaceFirst(
                  '${jsonEncode(field)}:${jsonEncode(example[field])}',
                  '"value":0',
                );
          expect(repaired, isNot(original));
          project.store.replace(buffer.id, repaired);
          final checked = await project.check(buffer.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(checked['status'], 'complete');
          expect(await file.readAsBytes(), bytes);
          project.store.undo();
          expect(buffer.bytes(), bytes);
          await verifyOriginal();
          project.store.redo();
          expect(buffer.text, repaired);
          await project.save(buffer);
          final after = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(after.exitCode, 0, reason: '${after.stdout}\n${after.stderr}');
          expect(jsonDecode(after.stdout as String)['status'], 'complete');
          expect(await file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(repaired),
          ]);
          expect(await File('${directory.path}/wire.txt').exists(), false);
        });
      }
    }
  }
}
