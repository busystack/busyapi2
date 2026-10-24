import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _TreeEngine extends EngineProcess {
  _TreeEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  String? malformed;
  int treeCalls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'schemaTree') {
      treeCalls++;
      if (release != null) {
        final gate = release!;
        release = null;
        entered!.complete();
        await gate.future;
      }
    }
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'schemaTree') {
      if (malformed == 'range') (result['node'] as Map)['range'] = [-1, 10];
      if (malformed == 'child')
        (result['entries'] as List)[0]['pointer'] =
            '${params['pointer']}/not/immediate';
      if (malformed == 'count') result['count'] = -1;
    }
    return result;
  }
}

void main() {
  test('schema tree pages share unsaved snapshots, reject stale and malformed worker data', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-core-tree-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = _TreeEngine();
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json'),
        model = File('${temp.path}/models.json');
    await root.writeAsString(
      jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Tree', 'version': '1'},
        'paths': <String, Object?>{},
        'components': {
          'schemas': {
            'Shared': {r'$ref': 'models.json#/Model'},
          },
        },
      }),
    );
    final original = jsonEncode({
      'Model': {
        'properties': {
          for (var i = 0; i < 251; i++) 'p$i': {'type': 'string'},
        },
      },
    });
    await model.writeAsString(original);
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final id = project.roots.single.id;
    await project.check(id);
    final buffer = await project.buffer(model.uri.toString());
    final changed = original.replaceFirst(
      '"p250":{"type":"string"}',
      '"p250":false',
    );
    project.store.replace(buffer.id, changed);
    final before = buffer.generation;
    final page = await project.schemaTree(
      id,
      buffer.id,
      '/Model/properties',
      offset: 250,
    );
    expect(page['offset'], 250);
    expect(page['count'], 251);
    expect((page['entries'] as List).single['boolean'], false);
    expect(page['node']['generation'], before);
    expect(buffer.text, changed);
    expect(await model.readAsString(), original);
    expect(
      await project.schemaTree(
        id,
        buffer.id,
        '/Model/properties',
        offset: 9999,
      ),
      containsPair('offset', 250),
    );
    for (final kind in ['range', 'child', 'count']) {
      engine.malformed = kind;
      await expectLater(
        project.schemaTree(id, buffer.id, '/Model/properties'),
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'schema.tree.response',
          ),
        ),
      );
      expect(buffer.text, changed);
    }
    engine.malformed = null;
    final calls = engine.treeCalls;
    await expectLater(
      project.schemaTree(id, buffer.id, '/Model', cancelled: () => true),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(engine.treeCalls, calls);
    engine.entered = Completer<void>();
    final gate = Completer<void>();
    engine.release = gate;
    final stale = project.schemaTree(id, buffer.id, '/Model');
    final rejected = expectLater(
      stale,
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'schema.tree.stale'),
      ),
    );
    await engine.entered!.future;
    project.store.replace(buffer.id, '$changed\n');
    gate.complete();
    await rejected;
    expect(buffer.text, '$changed\n');
    expect(await model.readAsString(), original);
  });
}
