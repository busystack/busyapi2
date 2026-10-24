import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

BufferPathEdit _move(DocumentBuffer b, String path) => BufferPathEdit(
  buffer: b.id,
  generation: b.generation,
  expectedPath: b.path,
  expectedText: b.text,
  expectedBom: b.hasBom,
  destination: Uri.file(path).toString(),
  path: path,
);

Future<List<Map<String, dynamic>>> _records(RecoveryStore recovery) async => [
  if (Directory(recovery.directory).existsSync())
    for (final file in Directory(
      recovery.directory,
    ).listSync().whereType<File>())
      if (file.path.endsWith('.json'))
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
];

void main() {
  test('a clean checkpoint retirement cannot erase recovery for input whose replacement write fails', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-recovery-retirement-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final b = DocumentBuffer.decode(
      '${temp.path}/root.yaml',
      utf8.encode('saved\n'),
    );
    var armed = false, fail = false;
    Future<Object?>? newer;
    late RecoveryStore recovery;
    recovery = RecoveryStore(
      '${temp.path}/recovery',
      onCheckpointPhase: (phase) {
        if (phase == 'retire:start' && armed) {
          armed = false;
          b.update('newest unsaved\n');
          newer = recovery
              .persist(b)
              .then<Object?>((_) => null, onError: (Object error) => error);
        }
        if (phase == 'write:start' && fail) {
          throw const FileSystemException('injected replacement failure');
        }
      },
    );
    b.update('durable unsaved\n');
    await recovery.persist(b);
    b.update(b.baseline);
    armed = true;
    fail = true;
    await expectLater(recovery.persist(b), throwsA(isA<FileSystemException>()));
    expect(await newer, isA<FileSystemException>());
    expect((await _records(recovery)).single['text'], 'durable unsaved\n');
    fail = false;
    await recovery.persist(b);
    expect((await _records(recovery)).single['text'], 'newest unsaved\n');
  });

  test('failed recovery replacements retain the preceding durable checkpoint through retries and Undo', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-recovery-transition-',
    );
    addTearDown(() => temp.delete(recursive: true));
    var failures = 0;
    final recovery = RecoveryStore(
      '${temp.path}/recovery',
      onCheckpointPhase: (phase) {
        if (phase == 'write:start' && failures > 0) {
          failures--;
          throw const FileSystemException('injected checkpoint write failure');
        }
      },
    );
    final b = DocumentBuffer.decode(
      '${temp.path}/root.yaml',
      utf8.encode('saved\n'),
    );
    final store = BufferStore()..buffers[b.id] = b;
    final owner = FileRecoveryOwner(
      boundary: temp.path,
      location: temp.path,
      store: store,
      restore: (_) async => throw UnimplementedError(),
      matches: (_) => false,
    );
    Future<void> checkpoint() async {
      if (!await recovery.persistFileMoves(owner)) {
        for (final buffer in store.fileBuffers) {
          await recovery.persist(buffer);
        }
      }
    }

    store.replace(b.id, 'unsaved 雪😀\n');
    await checkpoint();
    final original = (await _records(recovery)).single;
    store.apply(const [], paths: [_move(b, '${temp.path}/moved.yaml')]);
    failures = 2;
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(checkpoint(), throwsA(isA<FileSystemException>()));
      expect(await _records(recovery), contains(equals(original)));
    }
    await checkpoint();
    final grouped = (await _records(recovery)).single;
    expect(grouped['version'], 2);
    expect((grouped['buffers'] as List).single['text'], b.text);

    store.undo();
    expect(b.dirty, true);
    expect(b.hasFileIntent, false);
    failures = 1;
    await expectLater(checkpoint(), throwsA(isA<FileSystemException>()));
    expect(await _records(recovery), contains(equals(grouped)));
    await checkpoint();
    final restored = (await _records(recovery)).single;
    expect(restored['version'], 1);
    expect(restored['id'], b.id);
    expect(restored['text'], 'unsaved 雪😀\n');
  });

  test('Undo during move publication keeps the manifest in a selected-file inverse Save', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-move-save-undo-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Move',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id);
    final original = File(b.path), moved = File('${temp.path}/moved.yaml');
    final manifest = File('${temp.path}/busyapi.yaml');
    final originalManifest = await manifest.readAsString();
    await project.applyRefactoring(
      await project.planFileMove(b.id, moved.path),
    );
    final publication = PublicationStore('${temp.path}/publication');
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    final saving = publication.save(
      project,
      [b],
      beforePublish: (_) async {
        if (!held) {
          held = true;
          entered.complete();
          await release.future;
        }
      },
    );
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      project.store.undo();
      expect(b.hasFileIntent, false);
      expect(b.pendingFilePublication, true);
    } finally {
      release.complete();
    }
    expect((await saving).complete, true);
    expect(b.hasPathIntent, true);
    expect(await moved.exists(), true);
    expect((await publication.save(project, [b])).complete, true);
    expect(await original.exists(), true);
    expect(await moved.exists(), false);
    expect(await manifest.readAsString(), originalManifest);
    expect(project.store.fileBuffers.where((b) => b.dirty), isEmpty);
  });

  for (final bom in [false, true]) {
    test(
      'Save rejects oversized UTF-8 ${bom ? 'with BOM' : 'without BOM'} and preserves disk and dirty ownership',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-save-byte-limit-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        await Initializer.create(
          destination: temp.path,
          title: 'Bytes',
          apiVersion: '1',
        );
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final b = await project.buffer(project.roots.single.id);
        final source = File(b.path), before = await File(b.path).readAsBytes();
        b.hasBom = bom;
        project.store.replace(
          b.id,
          '${b.text}description: ${'雪' * (6 * 1024 * 1024)}\n',
        );
        final publication = PublicationStore('${temp.path}/publication');
        await expectLater(
          publication.save(project, [b]),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'limit.bytes'),
          ),
        );
        expect(await source.readAsBytes(), before);
        expect(b.dirty, true);
        expect(b.externalConflict, false);
        expect(b.baseline, utf8.decode(before));
        expect(Directory(publication.directory).existsSync(), false);
      },
    );
  }

  test('resource publication and reading share the encoded byte boundary including BOM', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-byte-boundary-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final access = await ProjectAccess.open(temp.path);
    addTearDown(access.close);
    final path = '${temp.path}/boundary.yaml';
    final bytes = [
      239,
      187,
      191,
      ...List<int>.filled(16 * 1024 * 1024 - 3, 32),
    ];
    await access.publish(path, bytes);
    expect(await access.read(path), bytes);
    await expectLater(
      access.publish(path, [...bytes, 32], expected: contentIdentity(bytes)),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'limit.bytes')),
    );
    expect(await access.read(path), bytes);
  });
}
