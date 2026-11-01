import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _body = '{"n":9007199254740993.000,"children":[{"n":0}]}';

Map<String, String> _documents(String version, String format, int port) {
  final swagger = version == '2.0';
  final schemaPath = swagger ? '/definitions/Node' : '/components/schemas/Node';
  Map<String, Object?> document(Map<String, Object?> fields) => {
    if (swagger) 'swagger': version else 'openapi': version,
    'info': {'title': 'Keep', 'version': 'api-version'},
    'paths': <String, Object?>{},
    ...fields,
  };
  Map<String, Object?> api(String name, bool primary) {
    final schema = {
      r'$ref': primary
          ? 'other.$format#${swagger ? '/definitions/Forward' : '/components/schemas/Forward'}'
          : 'alias.$format#/Node~1~0',
    };
    final parameters = <Object?>[
      if (swagger)
        {
          'name': 'q',
          'in': 'query',
          'type': 'array',
          'items': {'type': 'integer'},
          'collectionFormat': 'multi',
        }
      else
        {
          'name': 'q',
          'in': 'query',
          'schema': {
            'type': 'array',
            'items': {'type': 'integer'},
          },
        },
      if (swagger)
        {'name': 'payload', 'in': 'body', 'required': true, 'schema': schema},
    ];
    final forward = {
      'Forward': {r'$ref': 'alias.$format#/Node~1~0'},
    };
    return document({
      if (swagger) ...{
        'host': '127.0.0.1:$port',
        'basePath': '/$name',
        'schemes': ['http'],
        'consumes': ['application/json'],
        'produces': ['application/json'],
      } else
        'servers': [
          {'url': 'http://127.0.0.1:$port/$name'},
        ],
      'paths': {
        '/items': {
          'post': {
            'parameters': parameters,
            if (!swagger)
              'requestBody': {
                'required': true,
                'content': {
                  'application/json': {'schema': schema},
                },
              },
            'responses': {
              '200': {
                'description': 'Value',
                if (swagger)
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
      if (!primary)
        if (swagger)
          'definitions': forward
        else
          'components': {'schemas': forward},
    });
  }

  final node = {
    'type': 'object',
    'required': ['n'],
    'additionalProperties': false,
    'properties': {
      'n': {
        'type': 'integer',
        'enum': ['EXACT', 0],
      },
      'children': {
        'type': 'array',
        'items': {r'$ref': '#$schemaPath'},
      },
    },
  };
  final objects = {
    'api.$format': api('a', true),
    'other.$format': api('b', false),
    'models.$format': document({
      if (swagger)
        'definitions': {'Node': node}
      else
        'components': {
          'schemas': {'Node': node},
        },
    }),
    'alias.$format': {
      'Node/~': {r'$ref': 'models.$format#$schemaPath'},
    },
  };
  return {
    for (final entry in objects.entries)
      entry.key:
          '${format == 'yaml' ? '# Keep source 雪\r\n' : ''}${jsonEncode(entry.value).replaceAll('"EXACT"', '9007199254740993.000')}\r\n',
  };
}

void main() {
  for (final (version, target) in [
    ('2.0', '3.2.1'),
    ('3.0.4', '3.2.1'),
    ('3.1.2', '3.2.1'),
    ('3.2.1', '3.2.1'),
    ('3.2.1', '3.0.4'),
    ('3.2.1', '2.0'),
  ]) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version to $target $format coordinates unsaved API resources and actual HTTP behavior',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-migration-owners-',
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
          final sources = _documents(version, format, server.port);
          for (final entry in sources.entries) {
            await File('${temp.path}/${entry.key}').writeAsString(entry.value);
          }
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(
            '${temp.path}/api.$format',
            engine,
          );
          addTearDown(project.close);
          final buffers = <String, DocumentBuffer>{};
          for (final name in sources.keys) {
            final buffer = await project.buffer(
              File('${temp.path}/$name').uri.toString(),
            );
            buffers[name] = buffer;
          }
          final root = buffers['api.$format']!.id;
          project.store.replace(
            buffers['other.$format']!.id,
            buffers['other.$format']!.text.replaceFirst(
              '"title":"Keep"',
              '"title":"Unsaved"',
            ),
          );
          final working = {
            for (final entry in buffers.entries) entry.key: entry.value.text,
          };
          Future<void> send(
            BusyProject owner,
            String root,
            String expectedPath,
          ) async {
            final checked = await owner.check(root);
            expect(checked['complete'], true, reason: '$checked');
            final operation = (checked['projection']['operations'] as List)
                .whereType<Map>()
                .single;
            final plan = await owner.prepareRequest(
              root,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            addTearDown(plan.close);
            final result = await const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                parameters: {
                  OperationRequestDraft.parameterKey('query', 'q'):
                      const RequestValue.json('[0,9007199254740993]'),
                },
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
              reason:
                  '${result.outgoing.findings}\n${result.received.findings}',
            );
            expect(result.outgoing.complete && result.received.complete, true);
            expect(await result.response.bytes(), utf8.encode(_body));
            expect(seen.last.$1, 'POST');
            expect(seen.last.$2, '$expectedPath?q=0&q=9007199254740993');
            expect(seen.last.$3, 'application/json');
            expect(seen.last.$4, utf8.encode(_body));
          }

          await send(project, root, '/a/items');
          await send(project, buffers['other.$format']!.id, '/b/items');
          final destination = '${temp.path}/migrated';
          final review = await project.prepareMigration(
            root,
            destination,
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(review.publishable, true, reason: '${review.result}');
          expect(review.result['producerVersion'], '33');
          expect(review.unsaved, true);
          expect(review.changes, hasLength(4));
          expect((review.result['manifest'] as Map)['roots'], hasLength(3));
          await expectLater(
            review.publish(cancelled: () => true),
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
            ),
          );
          expect(Directory(destination).existsSync(), false);
          await review.publish();
          final output = await BusyProject.open(destination, engine);
          addTearDown(output.close);
          expect(output.roots, hasLength(3));
          for (final (name, path) in [
            ('api.$format', '/a/items'),
            ('other.$format', '/b/items'),
          ]) {
            final change = review.changes.singleWhere(
              (change) => change.resource == buffers[name]!.id,
            );
            await send(output, change.destination, path);
            final reopened = await BusyProject.open(
              Uri.parse(change.destination).toFilePath(),
              engine,
            );
            addTearDown(reopened.close);
            await send(reopened, change.destination, path);
            final declaration = await output.inspectObject(
              change.destination,
              change.destination,
              '',
            );
            expect(
              declaration['value'][target == '2.0' ? 'swagger' : 'openapi'],
              target,
            );
            final info = await output.inspectObject(
              change.destination,
              change.destination,
              '/info',
            );
            expect(
              info['value']['title'],
              name.startsWith('other') ? 'Unsaved' : 'Keep',
            );
          }
          expect(seen, hasLength(6));
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', destination, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
          final stale = await project.prepareMigration(
            root,
            '${temp.path}/stale',
            targetVersion: target,
          );
          addTearDown(stale.close);
          final alias = buffers['alias.$format']!;
          project.store.replace(alias.id, '${alias.text}\n');
          await expectLater(
            stale.publish(),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'migration.stale',
              ),
            ),
          );
          expect(Directory(stale.destination).existsSync(), false);
          project.store.replace(alias.id, working['alias.$format']!);
          for (final entry in sources.entries) {
            expect(
              await File('${temp.path}/${entry.key}').readAsString(),
              entry.value,
            );
            expect(buffers[entry.key]!.text, working[entry.key]);
          }
        },
      );
    }
  }
}
