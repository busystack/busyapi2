import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['json', 'yaml']) {
      test(
        '$version $format packaged mock checks captured native scalar bodies',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-native-mock-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final legacy = version == '2.0';
          final schemas = <String, Object?>{
            'zero': {
              'type': 'integer',
              'enum': [0],
            },
            'false': {
              'type': 'boolean',
              'enum': [false],
            },
            'empty': {
              'type': 'string',
              'enum': [''],
            },
            'null': version == '3.0.4'
                ? {
                    'type': 'string',
                    'nullable': true,
                    'enum': [null],
                  }
                : {
                    'enum': [null],
                  },
            'exact': {
              'type': 'integer',
              'enum': ['EXACT_VALUE'],
            },
            if (!legacy)
              'direction': {
                'type': 'object',
                'required': ['read', 'write'],
                'properties': {
                  'read': {'type': 'string', 'readOnly': true},
                  'write': {'type': 'string', 'writeOnly': true},
                },
              },
            if (version == '3.0.4')
              'composition': {
                'type': 'string',
                'nullable': true,
                'allOf': [
                  {'type': 'string'},
                ],
              },
          };
          final document = {
            if (legacy) 'swagger': version else 'openapi': version,
            'info': {'title': 'Captured native mock', 'version': 'api-version'},
            if (legacy) 'consumes': ['application/json'],
            'paths': {
              for (final entry in schemas.entries)
                '/${entry.key}': {
                  'post': {
                    if (legacy)
                      'parameters': [
                        {
                          'name': 'payload',
                          'in': 'body',
                          'required': true,
                          'schema': entry.value,
                        },
                      ]
                    else
                      'requestBody': {
                        'required': true,
                        'content': {
                          'application/json': {'schema': entry.value},
                        },
                      },
                    'responses': {
                      '204': {'description': 'Empty'},
                    },
                  },
                },
            },
          };
          final json = jsonEncode(document)
              .replaceAll('"EXACT_VALUE"', '9007199254740992.00');
          final original = format == 'yaml'
              ? '# Retain comment 雪\r\n$json\r\n'
              : json;
          final file = File('${temp.path}/api.$format');
          await file.writeAsString(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          final unsaved = original.replaceFirst(
            '9007199254740992.00',
            '9007199254740993.00',
          );
          project.store.replace(buffer.id, unsaved);
          final plan = await project.prepareMock(buffer.id);
          addTearDown(plan.close);
          final run = await plan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(run.stop);
          expect(run.nativeValidation.name, 'hyperjump+busyapi-exact');
          expect(run.nativeValidation.configuration, contains('exact-cst'));
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          Future<int> send(String name, String? text) async {
            final request = await client.postUrl(run.baseUri.resolve('/$name'));
            if (text != null) {
              final bytes = utf8.encode(text);
              request.headers.contentType = ContentType.json;
              request.contentLength = bytes.length;
              request.add(bytes);
            }
            final response = await request.close();
            await response.drain<void>();
            return response.statusCode;
          }

          for (final (name, text) in [
            ('zero', '0'),
            ('false', 'false'),
            ('empty', '""'),
            ('null', 'null'),
            ('exact', '9007199254740993.000'),
            if (!legacy) ('direction', '{"read":"old","write":"雪"}'),
          ]) {
            expect(await send(name, text), 204, reason: '$name: $text');
          }
          if (!legacy) {
            // OAS 3.0 changes directional requiredness. Modern readOnly is an
            // annotation and leaves the JSON Schema required assertion intact.
            expect(
              await send('direction', '{"write":"雪"}'),
              version == '3.0.4' ? 204 : 422,
            );
          }
          for (final (name, text) in [
            ('zero', null),
            ('zero', 'false'),
            ('false', '0'),
            ('empty', 'null'),
            ('exact', '9007199254740992'),
            ('exact', '{broken'),
            if (!legacy) ('direction', '{"read":"雪"}'),
            if (version == '3.0.4') ('composition', 'null'),
          ]) {
            expect(await send(name, text), 422, reason: '$name: $text');
          }
          expect(await file.readAsString(), original);
          expect(buffer.text, unsaved);
          project.store.replace(buffer.id, original);
          expect(run.outdated, true);
          expect(await send('exact', '9007199254740993'), 204);
          expect(await send('exact', '9007199254740992'), 422);
        },
      );
    }
    test(
      '$version installed CLI reports the native mock producer and validates wire numbers',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-native-mock-cli-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final schema = {
          'type': 'integer',
          'enum': ['EXACT_VALUE'],
        };
        final document = {
          if (version == '2.0') 'swagger': version else 'openapi': version,
          'info': {'title': 'Native CLI mock', 'version': 'api-version'},
          if (version == '2.0') 'consumes': ['application/json'],
          'paths': {
            '/data': {
              'post': {
                if (version == '2.0')
                  'parameters': [
                    {
                      'in': 'body',
                      'name': 'payload',
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
                  '204': {'description': 'Empty'},
                },
              },
            },
          },
        };
        final original = jsonEncode(document)
            .replaceAll('"EXACT_VALUE"', '9007199254740993');
        final file = File('${temp.path}/api.json');
        await file.writeAsString(original);
        final process = await Process.start('$testBundle/busyapi', [
          'mock',
          file.path,
          '--json',
          '--port',
          '0',
        ]);
        final ready = Completer<Map<String, dynamic>>();
        final errors = process.stderr.transform(utf8.decoder).join();
        final lines = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (ready.isCompleted) return;
              try {
                final value = jsonDecode(line);
                if (value is Map<String, dynamic>) ready.complete(value);
              } on FormatException catch (error) {
                ready.completeError(error);
              }
            });
        unawaited(
          process.exitCode.then((code) async {
            if (!ready.isCompleted)
              ready.completeError(
                StateError('CLI exited $code: ${await errors}'),
              );
          }),
        );
        addTearDown(() async {
          process.kill(ProcessSignal.sigterm);
          try {
            await process.exitCode.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode;
          }
          await lines.cancel();
          await errors;
        });
        final message = await ready.future.timeout(const Duration(seconds: 30));
        expect(message['status'], 'ready');
        expect(message['complete'], true);
        expect(
          (message['nativeValidation'] as Map)['name'],
          'hyperjump+busyapi-exact',
        );
        final base = Uri(
          scheme: 'http',
          host: message['host'] as String,
          port: message['port'] as int,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        for (final (text, status) in [
          ('9007199254740993', 204),
          ('9007199254740992', 422),
        ]) {
          final request = await client.postUrl(base.resolve('/data'));
          request.headers.contentType = ContentType.json;
          request.write(text);
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, status);
        }
        expect(await file.readAsString(), original);
        process.kill(ProcessSignal.sigterm);
        expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
      },
    );
  }
}
