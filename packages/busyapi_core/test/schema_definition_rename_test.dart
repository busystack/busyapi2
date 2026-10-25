import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _escape(String value) =>
    value.replaceAll('~', '~0').replaceAll('/', '~1');

String _source(String version, String format, int port) {
  final model = './model.$format';
  final reference = {'\$ref': '$model#/Envelope/\$defs/Old'};
  final value = {
    'openapi': version,
    'info': {'title': 'Authored definitions 雪😀', 'version': '1'},
    'servers': [
      {'url': 'http://127.0.0.1:$port'},
    ],
    'paths': {
      '/items': {
        'get': {
          'responses': {
            '200': {
              'description': 'Exact object',
              'content': {
                'application/json': {'schema': reference},
              },
            },
          },
        },
      },
    },
    'components': {
      'schemas': {
        'Envelope': {'\$ref': '$model#/Envelope'},
      },
    },
    'x-literal': {
      '\$defs': {'Old': 'unchanged'},
      '\$ref': 'literal',
      'number': 'EXACT',
    },
  };
  return '${format == 'yaml' ? '# retained flow source 雪😀\r\n' : ''}'
      '${const JsonEncoder.withIndent('  ').convert(value).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
}

String _model(String format) {
  if (format == 'yaml') {
    return '''# retained block definitions 雪😀
Envelope:
  \$id: https://schemas.invalid/envelope
  type: object
  \$defs:
    'Old': # keep this binding comment
      \$anchor: value
      type: object
      required: [n]
      properties:
        n: {type: integer, enum: [9007199254740993.00]}
        next: {\$ref: '#/\$defs/Old'}
      additionalProperties: false
x-kept: &data [9007199254740993.00, '雪😀']
x-mirror: *data
'''
        .replaceAll('\n', '\r\n');
  }
  return '${const JsonEncoder.withIndent('  ').convert({
    'Envelope': {
      '\$id': 'https://schemas.invalid/envelope',
      'type': 'object',
      '\$defs': {
        'Old': {
          '\$anchor': 'value',
          'type': 'object',
          'required': ['n'],
          'properties': {
            'n': {
              'type': 'integer',
              'enum': ['EXACT'],
            },
            'next': {'\$ref': '#/\$defs/Old'},
          },
          'additionalProperties': false,
        },
      },
    },
    'x-kept': {'Old': 'unchanged', 'number': 'EXACT'},
  }).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
}

void main() {
  for (final version in ['3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        'captured schema definition rename $version $format preserves behavior and publication',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-schema-definitions-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var received = 0;
          server.listen((request) async {
            expect(request.method, 'GET');
            expect(request.uri.toString(), '/items');
            expect(
              await request.fold<List<int>>(
                [],
                (bytes, chunk) => bytes..addAll(chunk),
              ),
              isEmpty,
            );
            received++;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"n":9007199254740993.00}');
            await request.response.close();
          });
          final original = _source(version, format, server.port),
              fragment = _model(format);
          final file = File('${directory.path}/api.$format')
            ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
          final modelFile = File('${directory.path}/model.$format')
            ..writeAsBytesSync([239, 187, 191, ...utf8.encode(fragment)]);
          final originalBytes = file.readAsBytesSync(),
              modelBytes = modelFile.readAsBytesSync();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          var project = await BusyProject.open(file.path, engine);
          addTearDown(() => project.close());
          final root = project.roots.single.id,
              model = modelFile.uri.toString();
          Future<void> behavior() async {
            final checked = await project.check(root);
            expect(
              checked['status'],
              'complete',
              reason: '${checked['findings']}',
            );
            final plan = await project.prepareRequest(
              root,
              resource: root,
              pointer: '/paths/~1items/get',
            );
            try {
              final response = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async =>
                    throw StateError('No credential belongs to this fixture'),
              );
              try {
                expect(response.conforming, true);
                expect(
                  await File(response.response.bodyFile).readAsString(),
                  '{"n":9007199254740993.00}',
                );
              } finally {
                await response.close();
              }
            } finally {
              plan.close();
            }
          }

          await behavior();
          final target = await project.inspectObject(
            root,
            model,
            '/Envelope/\$defs/Old',
          );
          expect(target['componentDefinition'], false);
          final name = 'clé/雪 ~😀 #?%',
              destination = '/Envelope/\$defs/${_escape(name)}';
          expect(
            MemberNamePolicy.fromJson(target['schemaDefinitionNamePolicy'])
                .allows(name),
            true,
          );
          final plan = await project.planSchemaDefinitionRename(target, name);
          expect(plan.hasChanges, true);
          expect(file.readAsBytesSync(), originalBytes);
          expect(modelFile.readAsBytesSync(), modelBytes);
          await expectLater(
            project.applyRefactoring(plan, current: () => false),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'refactor.stale',
              ),
            ),
          );
          expect((await project.buffer(root)).text, original);
          expect((await project.buffer(model)).text, fragment);
          await project.applyRefactoring(plan);
          final accepted = {
            for (final id in [root, model]) id: project.store.get(id).text,
          };
          expect(
            (await project.inspectObject(root, model, destination))['pointer'],
            destination,
          );
          expect(accepted[model], contains('9007199254740993.00'));
          if (format == 'yaml') {
            expect(accepted[model], contains('# keep this binding comment'));
            expect(
              accepted[model],
              contains(
                "x-kept: &data [9007199254740993.00, '雪😀']\r\nx-mirror: *data\r\n",
              ),
            );
          }
          await behavior();
          project.store.undo();
          expect(project.store.get(root).text, original);
          expect(project.store.get(model).text, fragment);
          project.store.redo();
          for (final entry in accepted.entries)
            expect(project.store.get(entry.key).text, entry.value);
          expect(file.readAsBytesSync(), originalBytes);
          expect(modelFile.readAsBytesSync(), modelBytes);
          final publication = PublicationStore('${directory.path}/publication');
          expect(
            (await publication.save(
              project,
              project.store.buffers.values,
            )).complete,
            true,
          );
          for (final entry in accepted.entries) {
            expect(File(Uri.parse(entry.key).toFilePath()).readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(entry.value),
            ]);
          }
          expect(
            (await publication.save(
              project,
              project.store.buffers.values,
            )).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(file.path, engine);
          await behavior();
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stderr}');
          expect(jsonDecode(cli.stdout as String)['status'], 'complete');
          await project.buffer(model);
          final staleTarget = await project.inspectObject(
            root,
            model,
            destination,
          );
          final stale = await project.planSchemaDefinitionRename(
            staleTarget,
            'Later',
          );
          final rootBuffer = await project.buffer(root);
          project.store.replace(
            root,
            rootBuffer.text.replaceFirst('Authored definitions', 'Later input'),
          );
          final retained = {
            for (final id in [root, model]) id: project.store.get(id).text,
          };
          await expectLater(
            project.applyRefactoring(stale),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'refactor.stale',
              ),
            ),
          );
          for (final entry in retained.entries)
            expect(project.store.get(entry.key).text, entry.value);
          expect(received, 3);
        },
      );
    }
  }
}
