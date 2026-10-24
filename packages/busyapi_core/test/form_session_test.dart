import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  FormSession capture(DocumentBuffer b) {
    final third = b.text.lastIndexOf('same');
    return FormSession(
      kind: 'parameter',
      contentIdentity: textIdentity(b.text),
      target: PropertySession(
        root: b.id,
        buffer: b.id,
        generation: b.generation,
        pointer: '/parameters/2',
        range: [third, third + 4],
        expected: 'same',
      ),
      arguments: {'index': 2},
      initial: {'name': 'same', 'description': ''},
    );
  }

  test('captured dialog survives serialization and never retargets matching occurrences', () {
    final b = DocumentBuffer.decode(
      '/tmp/form.yaml',
      utf8.encode('same same same'),
    );
    final form = capture(b)..edit('name', 'third');
    final restored = FormSession.restore(
      jsonDecode(jsonEncode(form.recovery())) as Map<String, dynamic>,
    );
    restored.verify(b, b.id);
    expect(restored.target.range, [10, 14]);
    expect(restored.values['name'], 'third');
    expect(restored.arguments['index'], 2);
    b.update('changed');
    b.update(
      'same same same',
    ); // An undo cannot revive the captured generation.
    expect(() => restored.verify(b, b.id), throwsA(isA<CoreFailure>()));
    restored.verify(
      b,
      b.id,
      restoring: true,
    ); // Explicit restore of byte-identical buffer only.
    b.update('same SAME same');
    expect(
      () => restored.verify(b, b.id, restoring: true),
      throwsA(isA<CoreFailure>()),
    );
    expect(
      () => restored.verify(b, 'file:///another.yaml', restoring: true),
      throwsA(isA<CoreFailure>()),
    );
  });
  test('IME field drafts cannot be applied until composition completes', () {
    final b = DocumentBuffer.decode(
      '/tmp/ime.yaml',
      utf8.encode('same same same'),
    );
    final form = capture(b)..edit('name', 'draft', isComposing: true);
    expect(() => form.verify(b, b.id), throwsA(isA<CoreFailure>()));
    form.edit('name', 'draft');
    form.verify(b, b.id);
  });
  test('clean source with pending dialog recovers ownership without publishing newer disk', () async {
    final dir = await Directory.systemTemp.createTemp('busyapi-form-recovery-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/api.yaml')
      ..writeAsStringSync('same same same');
    final b = DocumentBuffer.decode(file.path, file.readAsBytesSync());
    final form = capture(b)..edit('description', 'invalid pending field');
    final recovery = RecoveryStore('${dir.path}/state');
    await recovery.persist(b, form: form);
    final recordFile = Directory(recovery.directory)
        .listSync()
        .whereType<File>()
        .single;
    final record =
        jsonDecode(recordFile.readAsStringSync()) as Map<String, dynamic>;
    expect(record['text'], b.baseline);
    final restored = FormSession.restore(
      record['form'] as Map<String, dynamic>,
    );
    expect(restored.values['description'], 'invalid pending field');
    await file.writeAsString('newer external version');
    final next = DocumentBuffer.decode(file.path, await file.readAsBytes());
    record['recordPath'] = recordFile.path;
    final nextRecovery = RecoveryStore('${dir.path}/state');
    await nextRecovery.adopt(record, next, form: restored);
    expect(next.externalConflict, true);
    expect(next.generation, greaterThan(b.generation));
    restored.verify(next, next.id, restoring: true);
    expect(await file.readAsString(), 'newer external version');
    expect(
      Directory(nextRecovery.directory).listSync().whereType<File>(),
      hasLength(1),
    );
  });
  test('missing recovered resource stays in memory and cannot recreate a deleted disk file', () async {
    final dir = await Directory.systemTemp.createTemp(
      'busyapi-missing-recovery-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/api.yaml';
    final b = DocumentBuffer.decode(path, utf8.encode('same same same'));
    final form = capture(b)..edit('name', 'draft');
    final recovery = RecoveryStore('${dir.path}/state');
    await recovery.persist(b, form: form);
    final recordFile = Directory(recovery.directory)
        .listSync()
        .whereType<File>()
        .single;
    final record =
        jsonDecode(recordFile.readAsStringSync()) as Map<String, dynamic>;
    record['recordPath'] = recordFile.path;
    final engine = EngineProcess(
      executable: '/missing/node',
      helper: '/missing/engine',
    );
    final manifest = File('${dir.path}/busyapi.yaml');
    await manifest.writeAsString('version: 1\nroots: []\n');
    final project = await BusyProject.open(dir.path, engine);
    addTearDown(project.close);
    final missing = await project.buffer(b.id, recovery: record);
    final resumed = FormSession.restore(record['form'] as Map<String, dynamic>);
    await recovery.adopt(record, missing, form: resumed);
    expect(missing.externalConflict, true);
    expect(missing.text, b.text);
    await expectLater(
      project.save(missing..update('new draft')),
      throwsA(isA<CoreFailure>()),
    );
    expect(await File(path).exists(), false);
  });
}
