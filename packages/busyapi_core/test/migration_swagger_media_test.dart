import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _targets = [
  '3.0.0',
  '3.0.1',
  '3.0.2',
  '3.0.3',
  '3.0.4',
  '3.1.0',
  '3.1.1',
  '3.1.2',
  '3.2.0',
  '3.2.1',
];

void main() {
  for (final target in _targets) {
    for (final format in ['yaml', 'json']) {
      test(
        'Swagger $format to $target preserves shared media on the wire and through installed CLI publication',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-migration-media-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(() async {
            await engine.close();
            await temp.delete(recursive: true);
          });
          final seen = <List<String>>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, part) => all..addAll(part),
            );
            final media = request.headers.value(HttpHeaders.contentTypeHeader)!;
            seen.add([
              request.method,
              request.uri.toString(),
              media,
              base64Encode(bytes),
            ]);
            request.response.headers.set(HttpHeaders.contentTypeHeader, media);
            request.response.headers.set('X-Values', '0,9007199254740993');
            request.response.add(bytes);
            await request.response.close();
          });
          final reference = {r'$ref': 'body-chain.$format'};
          final response = {r'$ref': 'response-chain.$format'};
          final declarations = <String, Map<String, Object?>>{
            'api.$format': {
              'swagger': '2.0',
              'info': {'title': 'Original', 'version': '1'},
              'host': '127.0.0.1:${server.port}',
              'basePath': '/v1',
              'schemes': ['http'],
              'consumes': ['application/json'],
              'produces': ['application/json'],
              'paths': {
                '/json': {
                  'parameters': [reference],
                  'post': {
                    'responses': {'200': response},
                  },
                },
                '/vendor': {
                  'post': {
                    'consumes': ['application/vnd.busy+json'],
                    'produces': ['application/vnd.busy+json'],
                    'parameters': [reference],
                    'responses': {'200': response},
                  },
                },
              },
              'x-exact': [9007199254740993, false, null, 0, '雪'],
            },
            'body-chain.$format': {
              r'$ref': 'body.$format#/body%20~1~0%3F%23%E9%9B%AA',
            },
            'body.$format': {
              'body /~?#雪': {
                'in': 'body',
                'name': 'payload',
                'required': true,
                'description': 'Original body',
                'schema': {
                  'type': 'integer',
                  'enum': [9007199254740993, 0],
                },
                'x-data': {r'$ref': 'literal', 'empty': ''},
              },
            },
            'response-chain.$format': {r'$ref': 'response.$format'},
            'response.$format': {
              'description': 'Shared response',
              'schema': {'type': 'integer'},
              'headers': {
                'X-Values': {
                  'type': 'array',
                  'items': {'type': 'integer'},
                  'collectionFormat': 'csv',
                },
              },
              'examples': {'application/json': 9007199254740993},
            },
          };
          final originals = <String, List<int>>{};
          for (final entry in declarations.entries) {
            // JSON is also a YAML flow representation. The .yaml fixture adds
            // authored comments, BOM and CRLF without normalizing any live file.
            final text =
                (format == 'yaml' ? '# Keep ${entry.key}\r\n' : '') +
                const JsonEncoder.withIndent('  ')
                    .convert(entry.value)
                    .replaceAll('\n', '\r\n') +
                '\r\n';
            final bytes = [239, 187, 191, ...utf8.encode(text)];
            await File('${temp.path}/${entry.key}').writeAsBytes(bytes);
            originals[entry.key] = bytes;
          }
          final file = File('${temp.path}/api.$format');
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString(), buffer = await project.buffer(root);
          project.store.replace(
            root,
            buffer.text.replaceFirst('Original', 'Unsaved'),
          );
          final body = await project.buffer(
            File('${temp.path}/body.$format').uri.toString(),
          );
          project.store.replace(
            body.id,
            body.text.replaceFirst('Original body', 'Unsaved body'),
          );

          Future<void> send(BusyProject owner) async {
            final root = owner.roots.single.id, check = await owner.check(root);
            expect(check['complete'], isTrue, reason: '$check');
            final operations = (check['projection']['operations'] as List)
                .cast<Map>();
            expect(operations, hasLength(2));
            for (final operation in operations) {
              final plan = await owner.prepareRequest(
                root,
                resource: operation['resource'] as String,
                pointer: operation['pointer'] as String,
                occurrence: operation['occurrence'] as String,
              );
              addTearDown(plan.close);
              final media = operation['path'] == '/json'
                  ? 'application/json'
                  : 'application/vnd.busy+json';
              if (plan.result case {'requestBody': {'content': List content}}) {
                expect(
                  content.map(
                    (item) => switch (item) {
                      {'mediaType': String type} => type,
                      _ => throw StateError('Missing captured request media'),
                    },
                  ),
                  [media],
                );
              } else {
                fail('Missing captured request body');
              }
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(
                  planIdentity: plan.identity,
                  body: RequestBodyDraft.raw(
                    mediaType: media,
                    text: '9007199254740993',
                  ),
                ),
                resolveSecret: (_) async => null,
              );
              try {
                expect(
                  result.outgoing.complete,
                  isTrue,
                  reason: '${result.outgoing.findings}',
                );
                expect(
                  result.outgoing.valid,
                  isTrue,
                  reason: '${result.outgoing.findings}',
                );
                expect(
                  result.received.complete,
                  isTrue,
                  reason: '${result.received.findings}',
                );
                expect(
                  result.received.valid,
                  isTrue,
                  reason: '${result.received.findings}',
                );
              } finally {
                await result.close();
              }
            }
          }

          await send(project);
          final review = await project.prepareMigration(
            root,
            '${temp.path}/migrated',
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.result['producerVersion'], '39');
          expect(review.unsaved, isTrue);
          expect(review.changes, hasLength(5));
          expect(await Directory(review.destination).exists(), isFalse);
          await expectLater(
            review.publish(cancelled: () => true),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'cancelled',
              ),
            ),
          );
          expect(await Directory(review.destination).exists(), isFalse);
          await review.publish();
          expect(buffer.dirty, isTrue);
          expect(body.dirty, isTrue);

          final cliDestination = '${temp.path}/cli-copy';
          Future<ProcessResult> command(List<String> arguments) => Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              target,
              '--output',
              cliDestination,
              '--json',
              ...arguments,
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final cliReview = await command([]);
          expect(
            cliReview.exitCode,
            0,
            reason: '${cliReview.stdout}\n${cliReview.stderr}',
          );
          final report = jsonDecode(cliReview.stdout as String) as Map;
          expect(report['status'], 'faithfully-convertible');
          expect(report['published'], false);
          expect(report['producerVersion'], '39');
          expect(await Directory(cliDestination).exists(), isFalse);
          final applied = await command([
            '--apply',
            report['reviewIdentity'] as String,
          ]);
          expect(
            applied.exitCode,
            0,
            reason: '${applied.stdout}\n${applied.stderr}',
          );
          expect(
            (jsonDecode(applied.stdout as String) as Map)['published'],
            true,
          );
          for (final entry in originals.entries) {
            final original = File('${temp.path}/${entry.key}');
            expect(await original.readAsBytes(), entry.value);
            await original.rename('${temp.path}/original-${entry.key}');
          }
          final copy = await BusyProject.open(review.destination, engine);
          addTearDown(copy.close);
          expect(
            (await copy.check(
              copy.roots.single.id,
            ))['projection']['specification']['declaredVersion'],
            target,
          );
          expect(
            (await copy.buffer(copy.roots.single.id)).text,
            contains('Unsaved'),
          );
          await send(copy);
          final cliCopy = await BusyProject.open(cliDestination, engine);
          addTearDown(cliCopy.close);
          expect(
            (await cliCopy.buffer(cliCopy.roots.single.id)).text,
            contains('Original'),
          );
          await send(cliCopy);
          final standalone = await Directory('${temp.path}/standalone')
              .create();
          for (final output in (review.result['outputs'] as List).cast<Map>()) {
            final path = output['path'] as String;
            final target = File('${standalone.path}/$path');
            await target.parent.create(recursive: true);
            await File('${review.destination}/$path').copy(target.path);
          }
          expect(
            await File('${standalone.path}/busyapi.yaml').exists(),
            isFalse,
          );
          final standalonePath = '${standalone.path}/${review.result['entry']}';
          final independent = await BusyProject.open(standalonePath, engine);
          addTearDown(independent.close);
          expect(
            (await independent.buffer(independent.roots.single.id)).text,
            contains('Unsaved'),
          );
          await send(independent);
          final standaloneCheck = await Process.run(
            '$testBundle/busyapi',
            ['check', standalonePath, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            standaloneCheck.exitCode,
            0,
            reason: '${standaloneCheck.stdout}\n${standaloneCheck.stderr}',
          );
          expect(seen, hasLength(8));
          expect(seen.sublist(0, 2), seen.sublist(2, 4));
          expect(seen.sublist(0, 2), seen.sublist(4, 6));
          expect(seen.sublist(0, 2), seen.sublist(6, 8));
          expect(seen.map((request) => request[0]), everyElement('POST'));
          expect(seen.map((request) => request[1]), [
            '/v1/json',
            '/v1/vendor',
            '/v1/json',
            '/v1/vendor',
            '/v1/json',
            '/v1/vendor',
            '/v1/json',
            '/v1/vendor',
          ]);
          expect(
            seen.map((request) => utf8.decode(base64Decode(request[3]))),
            everyElement('9007199254740993'),
          );
        },
      );
    }
  }
}
