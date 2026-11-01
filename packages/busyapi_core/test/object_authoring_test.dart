import 'dart:async';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class HeldInspectEngine extends EngineProcess {
  HeldInspectEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'inspect' && release != null) {
      entered!.complete();
      await release!.future;
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  test('lazy object inspection uses coherent approved fragments and rejects stale replies', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-object-core-');
    final engine = HeldInspectEngine();
    BusyProject? project;
    try {
      await File('${temp.path}/root.yaml').writeAsString(
        'openapi: 3.2.1\ninfo: {title: Root, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model: {\$ref: "part.yaml#/Model"}\n',
      );
      await File('${temp.path}/part.yaml').writeAsString(
        '# Kept\r\nModel:\r\n  type: object\r\n  description: Original\r\n  x-number: 1.00',
      );
      project = await BusyProject.open(temp.path, engine);
      await project.check(project.roots.single.id);
      final id = Uri.file('${temp.path}/part.yaml').toString();
      final first = await project.inspectObject(
        project.roots.single.id,
        id,
        '/Model',
      );
      expect(first['kind'], 'schema');
      expect(first['resource'], id);
      final buffer = await project.buffer(id);
      final range = List<int>.from(first['range'] as List);
      final session = PropertySession(
        root: project.roots.single.id,
        buffer: id,
        generation: buffer.generation,
        pointer: '/Model',
        range: range,
        expected: buffer.text.substring(range[0], range[1]),
      );
      await project.proposeAndApply(project.roots.single.id, session, [
        {'kind': 'set', 'pointer': '/Model/description', 'value': 'Native'},
      ]);
      expect(
        buffer.text,
        '# Kept\r\nModel:\r\n  type: object\r\n  description: Native\r\n  x-number: 1.00',
      );
      expect(
        (await project.inspectObject(
          project.roots.single.id,
          id,
          '/Model',
        ))['value']['description'],
        'Native',
      );
      engine.entered = Completer();
      engine.release = Completer();
      final stale = project.inspectObject(
        project.roots.single.id,
        id,
        '/Model',
      );
      await engine.entered!.future;
      project.store.replace(id, buffer.text.replaceFirst('Native', 'Later'));
      engine.release!.complete();
      await expectLater(
        stale,
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'inspect.stale'),
        ),
      );
      engine.release = null;
      expect(
        (await project.inspectObject(
          project.roots.single.id,
          id,
          '/Model',
        ))['value']['description'],
        'Later',
      );
      await expectLater(
        project.inspectObject(
          project.roots.single.id,
          Uri.file('${temp.path}/not-approved.yaml').toString(),
          '',
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'inspect.resource'),
        ),
      );
      await project.save(buffer);
      expect(await File(buffer.path).readAsBytes(), buffer.bytes());
    } finally {
      project?.close();
      await engine.close();
      await temp.delete(recursive: true);
    }
  });
  test('snapshot freshness checks source identity as well as generation for a newly opened buffer', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-snapshot-content-',
    );
    try {
      final path = '${temp.path}/root.json';
      await File(path).writeAsString('{"old": true}');
      final store = BufferStore();
      final before = DocumentBuffer.decode(
        path,
        await File(path).readAsBytes(),
      );
      final snapshot = AnalysisSnapshot(
        root: before.id,
        resources: [before.snapshot()],
      );
      await File(path).writeAsString('{"new": true}');
      store.buffers[before.id] = DocumentBuffer.decode(
        path,
        await File(path).readAsBytes(),
      );
      expect(store.get(before.id).generation, before.generation);
      expect(snapshot.current(store), false);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
