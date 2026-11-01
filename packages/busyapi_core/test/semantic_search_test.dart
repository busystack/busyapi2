import 'dart:async';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class HeldSemanticEngine extends EngineProcess {
  HeldSemanticEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final gate = release;
    if (method == 'semanticSearch' && gate != null) {
      release = null;
      entered!.complete();
      await gate.future;
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  late Directory temp;
  late HeldSemanticEngine engine;
  late BusyProject project;
  late DocumentBuffer part;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-semantic-search-');
    engine = HeldSemanticEngine();
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots:\n  - name: first\n    path: a.yaml\n  - name: second\n    path: b.yaml\n',
    );
    for (final name in ['a', 'b']) {
      await File('${temp.path}/$name.yaml').writeAsString(
        'openapi: ${name == 'a' ? '3.1.2' : '3.2.1'}\ninfo: {title: T, version: "1"}\npaths:\n  /one: {\$ref: "part.json#/Shared"}\n  /two: {\$ref: "part.json#/Shared"}\ncomponents: {schemas: {Model: {\$ref: "part.json#/Model"}}}\n',
      );
    }
    await File('${temp.path}/part.json').writeAsString(
      '{"Shared":{"get":{"summary":"Repeated","tags":["group"]}},"Model":{"type":"object","description":"Original","x-data":{"\$ref":"literal data"}}}',
    );
    project = await BusyProject.open(temp.path, engine);
    part = await project.buffer(Uri.file('${temp.path}/part.json').toString());
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });
  test('all configured roots retain repeated operation occurrence and unsaved definition identity', () async {
    project.store.replace(
      part.id,
      part.text.replaceFirst('Original', 'Unsaved'),
    );
    final operations = await project.semanticSearch().run(
      'Repeated',
      category: 'operations',
    );
    expect(operations.complete, true);
    expect(operations.checkedRoots, project.roots.map((r) => r.id));
    expect(operations.matches, hasLength(4));
    expect(
      operations.matches.map((m) => m['semanticId']).toSet(),
      hasLength(4),
    );
    expect(
      operations.matches.map((m) => m['occurrence']).toSet(),
      hasLength(4),
    );
    expect(
      operations.matches.every(
        (m) =>
            m['resource'] == part.id &&
            m['generation'] == part.generation &&
            m['identity'] == part.sourceIdentity,
      ),
      true,
    );
    expect(await File(part.path).readAsString(), contains('Original'));
    expect(
      (await project.semanticSearch().run(
        'group',
        category: 'operations',
      )).matches,
      hasLength(4),
    );
    final definitions = await project.semanticSearch().run(
      'Model',
      category: 'definitions',
    );
    expect(definitions.matches, hasLength(2));
    expect(
      definitions.matches.every(
        (m) => m['resource'] == part.id && m['pointer'] == '/Model',
      ),
      true,
    );
    expect(
      (await project.semanticSearch().run(
        'literal data',
        category: 'usages',
      )).matches,
      isEmpty,
    );
    expect(
      () => operations.matches.first['pointer'] = 'wrong',
      throwsUnsupportedError,
    );
    project.store.replace(part.id, '${part.text}\n');
    expect(operations.current, false);
  });
  test('clean external reload notifies its mounted owner and returns current content', () async {
    await File(part.path)
        .writeAsString(part.text.replaceFirst('Repeated', 'Reloaded'));
    final refreshed = <String>[];
    final result = await project
        .semanticSearch(onResourceRefreshed: refreshed.add)
        .run('Reloaded', category: 'operations');
    expect(refreshed, [part.id]);
    expect(part.text, contains('Reloaded'));
    expect(result.matches, hasLength(4));
    expect(result.current, true);
  });
  test('unavailable resources retain useful results with explicitly incomplete indexing', () async {
    project.store.replace(
      part.id,
      part.text.replaceFirst(
        '"type":"object"',
        '"\$ref":"https://unapproved.invalid/model"',
      ),
    );
    final indexed = await project.semanticSearch().run('', category: 'usages');
    expect(indexed.complete, false);
    expect(indexed.matches, isNotEmpty);
    expect(indexed.matches.any((m) => m['resolution'] != 'resolved'), true);
  });
  test('cancellation and changed approval identity cannot return a successful empty index', () async {
    engine.entered = Completer();
    engine.release = Completer();
    final gate = engine.release!;
    final job = project.semanticSearch();
    final pending = job.run('Repeated');
    final observed = expectLater(
      pending,
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'search.cancelled'),
      ),
    );
    await engine.entered!.future;
    await job.cancel();
    gate.complete();
    await observed;
    engine.entered = Completer();
    engine.release = Completer();
    final secondGate = engine.release!;
    final stale = project.semanticSearch().run('Repeated');
    final rejected = expectLater(
      stale,
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'search.stale')),
    );
    await engine.entered!.future;
    await project.approveResource('https://approved.test/part', part.id);
    secondGate.complete();
    await rejected;
  });
}
