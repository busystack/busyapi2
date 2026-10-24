import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('property rename preserves data, follows nested structural transitions and publishes one reviewed transaction', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-property-rename-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json'),
        part = File('${temp.path}/part.json');
    await root.writeAsString(
      r'{"openapi":"3.2.1","info":{"title":"Property","version":"1"},"paths":{},"components":{"schemas":{"Model":{"$ref":"part.json#/Model"}}}}',
    );
    const original =
        r'{"Model":{"type":"object","properties":{"old":{"type":"number"}},"required":["old"],"dependentSchemas":{"old":{"properties":{"old":{"minimum":1.00}},"required":["old"]}},"examples":[{"old":9007199254740993}],"x-kept":{"old":"literal"}}}';
    await part.writeAsString('\ufeff$original\r\n');
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final buffer = await project.buffer(part.uri.toString());
    final before = buffer.bytes();
    final plan = await project.planPropertyRename({
      'resource': buffer.id,
      'generation': buffer.generation,
      'pointer': '/Model/properties/old',
    }, 'new/😀');
    expect(plan.result['kind'], 'property-rename');
    expect(buffer.bytes(), before);
    final nested = '/Model/dependentSchemas/old/properties/old';
    var mapped = nested;
    for (final transition in plan.transitions) mapped = transition.map(mapped);
    expect(mapped, '/Model/dependentSchemas/new~1😀/properties/new~1😀');
    await project.applyRefactoring(plan);
    final accepted = buffer.bytes();
    expect(buffer.text, contains('9007199254740993'));
    expect(buffer.text, contains('minimum":1.00'));
    expect(jsonDecode(buffer.text)['Model']['x-kept'], {'old': 'literal'});
    final reversed = project.store.undo();
    expect(buffer.bytes(), before);
    for (final transition in reversed) mapped = transition.map(mapped);
    expect(mapped, nested);
    project.store.redo();
    expect(buffer.bytes(), accepted);
    expect(
      (await PublicationStore(
        '${temp.path}/publication',
      ).save(project, project.store.buffers.values)).complete,
      true,
    );
    expect(await part.readAsBytes(), accepted);
    project.close();
    final reopened = await BusyProject.open(root.path, engine);
    addTearDown(reopened.close);
    expect((await reopened.buffer(buffer.id)).bytes(), accepted);
    expect((await reopened.check(root.uri.toString()))['status'], 'complete');
  });
}
