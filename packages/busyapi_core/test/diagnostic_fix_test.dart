import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _FixEngine extends EngineProcess {
  _FixEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  bool malformed = false;
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'planDiagnosticFix') {
      if (entered != null) {
        entered!.complete();
        await release!.future;
      }
      if (malformed) return {...result, 'fix': 'unrelated'};
    }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true]) {
      test(
        'diagnostic repair $version $json reviews both roots and preserves exact source/history/publication',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-fix-core-',
          );
          final engine = _FixEngine();
          BusyProject? project;
          try {
            final extension = json ? 'json' : 'yaml',
                root = File('${temp.path}/a.$extension'),
                other = File('${temp.path}/b.$extension'),
                part = File('${temp.path}/part.$extension');
            final text = json
                ? ' {"openapi":"$version", "info":{"title":"Repair","version":"1"},"paths":{"/p/{id}":{"parameters":[{"\$ref":"part.$extension#/Parameter"}],"get":{"responses":{"204":{"description":"No body"}}}}}}'
                : '# keep root 😀\r\nopenapi: $version\r\ninfo: {title: Repair, version: "1"}\r\npaths:\r\n  /p/{id}:\r\n    parameters: [{\$ref: "part.$extension#/Parameter"}]\r\n    get: {responses: {204: {description: No body}}}';
            final original = json
                ? ' {"Parameter":{"name":"id", "in":"path", "required":false, "schema":{"type":"string"}},"example":{"number":9007199254740993.00,"\$ref":"literal"}}'
                : '# keep parameter 😀\r\nParameter:\r\n  name: \'id\'\r\n  in: path\r\n  required: false # keep scalar comment\r\n  schema: {type: string}\r\nexample: {number: 9007199254740993.00, \$ref: literal}';
            await root.writeAsString(text);
            await other.writeAsString(text);
            await part.writeAsBytes([239, 187, 191, ...utf8.encode(original)]);
            final manifest = File('${temp.path}/busyapi.yaml'),
                manifestText =
                    '# retain configuration\nversion: 1\nroots:\n  - name: first\n    path: a.$extension\n  - name: second\n    path: b.$extension\nx-retained: true\n';
            await manifest.writeAsString(manifestText);
            project = await BusyProject.open(temp.path, engine);
            final current = project,
                buffer = await current.buffer(part.uri.toString());
            Future<(Map<String, dynamic>, String)> finding() async {
              final checked = await current.check(
                root.uri.toString(),
                schemaEvaluation: false,
              );
              return (
                Map<String, dynamic>.from(
                  (checked['findings'] as List).whereType<Map>().firstWhere(
                    (f) => f['code'] == 'parameter.path.required',
                  ),
                ),
                checked['contextSnapshot'] as String,
              );
            }

            final (diagnostic, context) = await finding();
            final review = await current.planDiagnosticFix(
              diagnostic,
              contextSnapshot: context,
              fix: 'path-parameter-required',
            );
            expect(review.checkedRoots.toSet(), {
              root.uri.toString(),
              other.uri.toString(),
            });
            expect(review.result['usages'], hasLength(2));
            expect(review.edits, hasLength(1));
            expect(buffer.text, original);
            expect(buffer.dirty, false);
            expect(current.store.canUndo, false);
            final otherBuffer = await current.buffer(other.uri.toString());
            current.store.replace(
              otherBuffer.id,
              otherBuffer.text.replaceFirst('Repair', 'Newer'),
            );
            await expectLater(
              current.applyRefactoring(review),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'refactor.stale',
                ),
              ),
            );
            expect(buffer.text, original);
            expect(otherBuffer.text, contains('Newer'));
            current.store.undo();
            final (freshDiagnostic, freshContext) = await finding();
            final accepted = await current.planDiagnosticFix(
              freshDiagnostic,
              contextSnapshot: freshContext,
              fix: 'path-parameter-required',
            );
            await current.applyRefactoring(accepted);
            final expected = original.replaceFirst('false', 'true');
            expect(buffer.text, expected);
            expect(buffer.hasBom, true);
            current.store.undo();
            expect(buffer.text, original);
            current.store.redo();
            expect(buffer.text, expected);
            expect(
              (await PublicationStore(
                '${temp.path}/state',
              ).save(current, current.store.buffers.values)).complete,
              true,
            );
            expect(await part.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(expected),
            ]);
            expect(await root.readAsString(), text);
            expect(await other.readAsString(), text);
            expect(await manifest.readAsString(), manifestText);
            current.close();
            project = await BusyProject.open(temp.path, engine);
            expect((await project.buffer(buffer.id)).text, expected);
            expect(
              ((await project.check(root.uri.toString()))['findings'] as List)
                  .whereType<Map>()
                  .where((f) => (f['code'] as String).startsWith('parameter.')),
              isEmpty,
            );
          } finally {
            project?.close();
            await engine.close();
            await temp.delete(recursive: true);
          }
        },
      );
    }
  test('diagnostic repair rejects changed snapshots, forged findings, malformed plans and late cancellation', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-fix-guards-');
    final engine = _FixEngine();
    BusyProject? project;
    try {
      final file = File('${temp.path}/root.json');
      await file.writeAsString(
        '{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{"/p/{id}":{"get":{"parameters":[{"name":"id","in":"path","required":false,"schema":{}}],"responses":{"204":{"description":"None"}}}}}}',
      );
      project = await BusyProject.open(file.path, engine);
      final current = project,
          buffer = await current.buffer(file.uri.toString()),
          before = buffer.text;
      Future<(Map<String, dynamic>, String)> finding() async {
        final checked = await current.check(buffer.id, schemaEvaluation: false);
        return (
          Map<String, dynamic>.from(
            (checked['findings'] as List).whereType<Map>().firstWhere(
              (f) => f['code'] == 'parameter.path.required',
            ),
          ),
          checked['contextSnapshot'] as String,
        );
      }

      final (diagnostic, context) = await finding();
      current.store.replace(buffer.id, before.replaceFirst('"T"', '"changed"'));
      await expectLater(
        current.planDiagnosticFix(
          diagnostic,
          contextSnapshot: context,
          fix: 'path-parameter-required',
        ),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'fix.stale')),
      );
      current.store.undo();
      final (fresh, freshContext) = await finding();
      await expectLater(
        current.planDiagnosticFix(
          {...fresh, 'code': 'response.missing'},
          contextSnapshot: freshContext,
          fix: 'invent-response',
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'fix.unsupported'),
        ),
      );
      await expectLater(
        current.planDiagnosticFix(
          {
            ...fresh,
            'range': [0, 1],
          },
          contextSnapshot: freshContext,
          fix: 'path-parameter-required',
        ),
        throwsA(isA<CoreFailure>()),
      );
      engine.malformed = true;
      await expectLater(
        current.planDiagnosticFix(
          fresh,
          contextSnapshot: freshContext,
          fix: 'path-parameter-required',
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'fix.response'),
        ),
      );
      engine.malformed = false;
      engine.entered = Completer();
      engine.release = Completer();
      var cancelled = false;
      final pending = current.planDiagnosticFix(
        fresh,
        contextSnapshot: freshContext,
        fix: 'path-parameter-required',
        cancelled: () => cancelled,
      );
      await engine.entered!.future;
      cancelled = true;
      engine.release!.complete();
      await expectLater(
        pending,
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      expect(buffer.text, before);
      expect(buffer.dirty, false);
      expect(await file.readAsString(), before);
    } finally {
      if (engine.release != null && !engine.release!.isCompleted) {
        engine.release!.complete();
      }
      project?.close();
      await engine.close();
      await temp.delete(recursive: true);
    }
  });
}
