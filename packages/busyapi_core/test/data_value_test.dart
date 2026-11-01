import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _DataEngine extends EngineProcess {
  _DataEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  String? malformed;
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'readDataValue') {
      if (release case final gate?) {
        release = null;
        entered!.complete();
        await gate.future;
      }
      if (malformed == 'generation') result['generation'] = -1;
      if (malformed == 'range') result['range'] = [0, 1];
      if (malformed == 'type') result['value'] = 42;
      if (malformed == 'representation') result['representation'] = 'text';
    }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true]) {
      test(
        'complete captured data $version $json retains canonical source and exact numeric edits',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-form-data-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = _DataEngine();
          addTearDown(engine.close);
          final description = 'line 雪😀\n' * 4000;
          final payload =
              '{"n":9007199254740993.00,"\$ref":"literal data","text":${jsonEncode(description)}}';
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
          final original = json
              ? ' {"openapi":"$version","info":{"title":"Data","version":"1"},"paths":{},"components":{"examples":{"Data":{"value":$payload}}},"x-kept":null}'
              : '# keep 😀\r\nopenapi: $version\r\ninfo: {title: Data, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  examples:\r\n    Data:\r\n      value: $payload\r\nx-kept: null';
          await file.writeAsBytes([239, 187, 191, ...utf8.encode(original)]);
          var project = await BusyProject.open(file.path, engine);
          addTearDown(() => project.close());
          final root = project.roots.single.id,
              buffer = await project.buffer(root);
          final item = await project.inspectObject(
            root,
            root,
            '/components/examples/Data',
          );
          final field = (item['fields'] as List).singleWhere(
            (f) => f['name'] == 'value',
          ) as Map;
          expect(field.containsKey('raw'), false);
          final target = Map<String, dynamic>.from(field['target'] as Map);
          final raw = await project.readDataValue(target);
          expect(raw, payload);
          expect(buffer.text, original);
          expect(project.store.canUndo, false);
          final s = PropertySession(
            buffer: root,
            generation: buffer.generation,
            pointer: item['pointer'] as String,
            range: List<int>.from(item['range'] as List),
            root: root,
            expected: buffer.text.substring(
              item['range'][0] as int,
              item['range'][1] as int,
            ),
          );
          final changed = raw.replaceFirst(
            '9007199254740993.00',
            '9007199254740994.00',
          );
          await project.proposeAndApply(root, s, [
            {'kind': 'setData', 'pointer': target['pointer'], 'raw': changed},
          ]);
          final accepted = original.replaceFirst(
            '9007199254740993.00',
            '9007199254740994.00',
          );
          expect(buffer.text, accepted);
          project.store.undo();
          expect(buffer.text, original);
          project.store.redo();
          expect(buffer.text, accepted);
          expect(
            (await PublicationStore(
              '${temp.path}/publication',
            ).save(project, [buffer])).complete,
            true,
          );
          project.close();
          project = await BusyProject.open(file.path, engine);
          expect((await project.buffer(root)).text, accepted);
          expect(await file.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(accepted),
          ]);
        },
      );
    }
  test('malformed, cancelled and stale full-value reads do not create a new document authority', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-data-owner-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = _DataEngine();
    addTearDown(engine.close);
    final file = File('${temp.path}/root.json');
    const original =
        r'{"openapi":"3.2.1","info":{"title":"Data","version":"1"},"paths":{},"components":{"examples":{"Data":{"value":{"n":9007199254740993.00}}}}}';
    await file.writeAsString(original);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final root = project.roots.single.id, buffer = await project.buffer(root);
    final item = await project.inspectObject(
      root,
      root,
      '/components/examples/Data',
    );
    final field = (item['fields'] as List).singleWhere(
      (f) => f['name'] == 'value',
    ) as Map;
    final target = Map<String, dynamic>.from(field['target'] as Map);
    for (final kind in ['generation', 'range', 'type', 'representation']) {
      engine.malformed = kind;
      await expectLater(
        project.readDataValue(target),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'data.value.protocol',
          ),
        ),
      );
    }
    engine.malformed = null;
    await expectLater(
      project.readDataValue(target, cancelled: () => true),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    engine.entered = Completer<void>();
    final gate = Completer<void>();
    engine.release = gate;
    final held = project.readDataValue(target);
    final rejected = expectLater(
      held,
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'data.value.stale'),
      ),
    );
    await engine.entered!.future;
    // The caller cannot retarget the pending read by mutating its Map either.
    target['pointer'] = '/info/title';
    (target['range'] as List)[0] = 0;
    project.store.replace(root, '$original\n');
    gate.complete();
    await rejected;
    expect(buffer.text, '$original\n');
    expect(await file.readAsString(), original);
  });
}
