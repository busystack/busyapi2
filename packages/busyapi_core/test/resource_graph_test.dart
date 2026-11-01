import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _HeldGraphEngine extends EngineProcess {
  _HeldGraphEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'analyse') {
      calls++;
      final gate = release;
      if (gate != null) {
        release = null;
        entered?.complete();
        await gate.future;
      }
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  test('concurrent resource approvals cannot assign two retrieval bases to one buffer', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-map-race-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json');
    await root.writeAsString(
      '{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{}}',
    );
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final outcomes = await Future.wait([
      for (final identity in ['https://example.com/a', 'https://example.com/b'])
        project
            .approveResource(identity, root.uri.toString())
            .then<String>(
              (_) => 'approved',
              onError: (Object e) => e is CoreFailure ? e.code : 'failure',
            ),
    ]);
    expect(outcomes.where((s) => s == 'approved'), hasLength(1));
    expect(outcomes.where((s) => s == 'resource.base.ambiguous'), hasLength(1));
    expect(project.approvedResources, hasLength(1));
  });
  test('resource approval invalidates an in-flight saved analysis before acceptance', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-map-epoch-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = _HeldGraphEngine();
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json');
    await root.writeAsString(
      '{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{}}',
    );
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    engine.entered = Completer<void>();
    final gate = Completer<void>();
    engine.release = gate;
    final pending = project.check(root.uri.toString(), saved: true);
    await engine.entered!.future;
    await project.approveResource(
      'https://example.com/root',
      root.uri.toString(),
    );
    gate.complete();
    final result = await pending;
    expect(engine.calls, 2);
    expect(
      result['snapshot'],
      (await project.check(root.uri.toString(), saved: true))['snapshot'],
    );
  });
  test(
    'missing anchor retains its loaded dependency and precise invalid result',
    () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-anchor-');
      addTearDown(() => temp.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final root = File('${temp.path}/root.yaml');
      await root.writeAsString(
        'openapi: 3.2.1\ninfo: {title: T, version: "1"}\npaths: {}\ncomponents: {schemas: {X: {\$ref: "part.yaml#missing"}}}\n',
      );
      final part = File('${temp.path}/part.yaml');
      await part.writeAsString('type: string\n');
      final project = await BusyProject.open(root.path, engine);
      addTearDown(project.close);
      for (var i = 0; i < 2; i++) {
        final result = await project.check(root.uri.toString());
        expect(result['status'], 'invalid');
        expect(result['resources'], hasLength(2));
        expect(
          (result['findings'] as List).any(
            (f) => f['code'] == 'reference.missing',
          ),
          true,
        );
      }
    },
  );
  test('approved URI mapping keeps physical buffers, base identities and unsaved dependencies', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-resource-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json');
    await root.writeAsString(
      jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Mapped', 'version': '1'},
        'paths': {},
        'components': {
          'schemas': {
            'Thing': {r'$ref': 'https://contracts.example/schemas/thing'},
          },
        },
      }),
    );
    final part = File('${temp.path}/cached.json');
    await part.writeAsString(
      jsonEncode({
        'type': 'object',
        'properties': {
          'child': {r'$ref': 'child'},
        },
      }),
    );
    final child = File('${temp.path}/child.json');
    await child.writeAsString('false');
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final id = root.uri.toString();
    final denied = await project.check(id);
    expect(denied['status'], 'incomplete');
    expect((await project.check(id))['status'], 'incomplete');
    await project.approveResource(
      'https://contracts.example/schemas/thing',
      part.uri.toString(),
    );
    await project.approveResource(
      'https://contracts.example/schemas/child',
      child.uri.toString(),
    );
    final checked = await project.check(id);
    expect(checked['status'], 'complete');
    expect(checked['resources'], hasLength(3));
    expect(checked['references'][0]['targetResource'], part.uri.toString());
    expect(
      checked['references'][1]['base'],
      'https://contracts.example/schemas/thing',
    );
    expect(checked['references'][1]['targetResource'], child.uri.toString());
    final buffer = await project.buffer(child.uri.toString());
    project.store.replace(buffer.id, '{"type":12}');
    final edited = await project.check(id);
    expect(edited['status'], 'invalid');
    expect(edited['unsaved'], true);
    expect(
      (edited['findings'] as List).any((f) => f['resource'] == buffer.id),
      true,
    );
    expect(await child.readAsString(), 'false');
    expect(edited['snapshot'], isNot(checked['snapshot']));
    final saved = await project.check(id, saved: true);
    expect(saved['status'], 'complete');
    expect(saved['unsaved'], false);
  });

  test('resource mapping validates permissions, collisions and snapshot configuration identity', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-map-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final file = File('${temp.path}/root.json');
    await file.writeAsString(
      '{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{}}',
    );
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final id = file.uri.toString();
    final before = await project.check(id);
    for (final identity in [
      'relative',
      'https://user:secret@example.com/a',
      'https://example.com/a#part',
    ]) {
      await expectLater(
        project.approveResource(identity, id),
        throwsA(isA<CoreFailure>()),
      );
    }
    await expectLater(
      project.approveResource('https://example.com/a', 'file:///etc/passwd'),
      throwsA(isA<CoreFailure>()),
    );
    await project.approveResource('https://example.com/root', id);
    final mapped = await project.check(id);
    expect(mapped['snapshot'], isNot(before['snapshot']));
    await expectLater(
      project.approveResource('https://example.com/other', id),
      throwsA(isA<CoreFailure>()),
    );
    await project.approveResource('https://example.com/root', id);
    expect((await project.check(id))['snapshot'], mapped['snapshot']);
  });
}
