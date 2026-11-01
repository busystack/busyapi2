import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _CapturedMockEngine extends EngineProcess {
  _CapturedMockEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = true;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'deriveBundle' && armed) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  for (final failure in ['stale', 'cancelled', 'closed']) {
    test(
      'mock $failure during captured derivation is rejected before child publication',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-mock-start-owner-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/api.yaml');
        const original =
            'openapi: 3.0.4\ninfo: {title: Original, version: "1"}\npaths: {"/data": {get: {responses: {204: {description: Empty}}}}}\n';
        await file.writeAsString(original);
        final engine = _CapturedMockEngine();
        addTearDown(engine.close);
        addTearDown(() {
          if (!engine.release.isCompleted) engine.release.complete();
        });
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(file.uri.toString()),
            plan = await project.prepareMock(buffer.id);
        addTearDown(plan.close);
        final token = RunCancellation();
        final started = plan.start(
          nodeExecutable: '${temp.path}/absent-node',
          helper: '${temp.path}/absent-helper',
          cancellation: token,
        );
        final checked = expectLater(
          started,
          throwsA(
            isA<CoreFailure>().having(
              (value) => value.code,
              'code',
              failure == 'stale'
                  ? 'mock.stale'
                  : failure == 'closed'
                  ? 'mock.closed'
                  : 'cancelled',
            ),
          ),
        );
        await engine.entered.future;
        if (failure == 'stale')
          project.store.replace(
            buffer.id,
            original.replaceFirst('3.0.4', '3.1.2'),
          );
        else if (failure == 'closed')
          project.close();
        else
          token.cancel();
        if (failure == 'cancelled') {
          await checked.timeout(const Duration(seconds: 5));
          expect(engine.release.isCompleted, false);
          engine.release.complete();
        } else {
          engine.release.complete();
          await checked;
        }
        expect(await file.readAsString(), original);
      },
    );
  }
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format immutable native mock uses captured method/body semantics',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-mock-bodies-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final legacy = version == '2.0', ignored = version == '3.0.4';
          final schema = {
            'type': 'object',
            'required': ['value'],
            'properties': {
              'value': {'type': 'string'},
            },
          };
          final document = {
            legacy ? 'swagger' : 'openapi': version,
            'info': {'title': 'Original', 'version': 'api-version'},
            if (legacy) 'consumes': ['application/json'],
            'paths': {
              '/data': {
                for (final method in ['get', 'post'])
                  method: {
                    if (legacy)
                      'parameters': [
                        {
                          'name': 'payload',
                          'in': 'body',
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
            'x-number': 'EXACT_VALUE',
          };
          final json = jsonEncode(document)
              .replaceAll('"EXACT_VALUE"', '9007199254740993.00');
          final original = format == 'yaml'
              ? '# Keep original 雪\r\n$json\r\n'
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
          project.store.replace(
            buffer.id,
            original.replaceFirst('Original', 'Unsaved'),
          );
          final plan = await project.prepareMock(buffer.id);
          addTearDown(plan.close);
          final run = await plan.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(run.stop);
          expect(run.host, '127.0.0.1');
          expect(run.toolVersion, '5.15.11');
          expect(run.outdated, false);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          Future<int> send(String method, [String? text]) async {
            final request = await client.openUrl(
              method,
              run.baseUri.resolve('/data'),
            );
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

          expect(await send('GET'), ignored ? 204 : anyOf(400, 415, 422));
          expect(await send('GET', '0'), ignored ? 204 : anyOf(400, 415, 422));
          expect(await send('POST'), anyOf(400, 415, 422));
          expect(await send('POST', '{"value":"雪"}'), 204);
          expect(await file.readAsString(), original);
          expect(buffer.text, original.replaceFirst('Original', 'Unsaved'));
          if (ignored || version == '3.1.2') {
            project.store.replace(
              buffer.id,
              buffer.text.replaceFirst(version, ignored ? '3.1.2' : '3.2.1'),
            );
            expect(plan.outdated, true);
            expect(run.outdated, true);
            // A running immutable capture keeps its original rules. Pending starts
            // must not revive that capture after a version declaration changes.
            expect(await send('GET'), ignored ? 204 : anyOf(400, 415, 422));
            Future<MockRun> pendingStart() async {
              final started = await plan.start(
                nodeExecutable: runtimeNode,
                helper: '$testBundle/libexec/busyapi/mock-server.cjs',
              );
              addTearDown(started.stop);
              return started;
            }

            await expectLater(
              pendingStart(),
              throwsA(
                isA<CoreFailure>().having(
                  (failure) => failure.code,
                  'code',
                  'mock.stale',
                ),
              ),
            );
            final current = await project.prepareMock(buffer.id);
            addTearDown(current.close);
            final modern = await current.start(
              nodeExecutable: runtimeNode,
              helper: '$testBundle/libexec/busyapi/mock-server.cjs',
            );
            addTearDown(modern.stop);
            final response = await (await client.getUrl(
              modern.baseUri.resolve('/data'),
            )).close();
            await response.drain<void>();
            expect(response.statusCode, anyOf(400, 415, 422));
            expect(await file.readAsString(), original);
          }
        },
      );
    }
  }
}
