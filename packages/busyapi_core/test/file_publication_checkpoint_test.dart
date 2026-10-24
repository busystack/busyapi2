import 'dart:async';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  late BusyProject project;
  late DocumentBuffer root;
  late File original, moved, manifest;
  late String originalManifest;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-first-checkpoint-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
    await Initializer.create(
      destination: temp.path,
      title: 'Original',
      apiVersion: '1',
    );
    project = await BusyProject.open(temp.path, engine);
    root = await project.buffer(project.roots.single.id);
    original = File(root.path);
    moved = File('${temp.path}/moved.yaml');
    manifest = File('${temp.path}/busyapi.yaml');
    originalManifest = await manifest.readAsString();
    project.store.replace(
      root.id,
      root.text.replaceFirst('Original', 'Unsaved'),
    );
    await project.applyRefactoring(
      await project.planFileMove(root.id, moved.path),
    );
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });

  test('Undo during the initial checkpoint preserves the selected-file inverse manifest repair', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var held = false;
    final publication = PublicationStore(
      '${temp.path}/publication',
      beforeCheckpoint: () async {
        if (!held) {
          held = true;
          entered.complete();
          await release.future;
        }
      },
    );
    final saving = publication.save(project, [root]);
    var pendingDuringUndo = false;
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      project.store.undo();
      pendingDuringUndo = root.pendingFilePublication;
    } finally {
      release.complete();
    }
    expect((await saving).complete, true);
    expect((await publication.save(project, [root])).complete, true);
    expect(await original.exists(), true);
    expect(await moved.exists(), false);
    expect(await manifest.readAsString(), originalManifest);
    expect(project.store.fileBuffers.where((b) => b.dirty), isEmpty);
    expect(pendingDuringUndo, true);
    expect(await original.readAsString(), contains('Unsaved'));
  });

  for (final undo in [false, true]) {
    test(
      'a failed first checkpoint releases publication ownership and remains retryable undo=$undo',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        var fail = true;
        final publication = PublicationStore(
          '${temp.path}/publication',
          beforeCheckpoint: () async {
            if (fail) {
              fail = false;
              entered.complete();
              await release.future;
              throw const FileSystemException(
                'injected initial checkpoint failure',
              );
            }
          },
        );
        final saving = publication.save(project, [root]);
        final failed = expectLater(saving, throwsA(isA<FileSystemException>()));
        var pendingDuringCheckpoint = false;
        try {
          await entered.future.timeout(const Duration(seconds: 10));
          if (undo) project.store.undo();
          pendingDuringCheckpoint = root.pendingFilePublication;
        } finally {
          release.complete();
        }
        await failed;
        expect(
          project.store.fileBuffers.any((b) => b.pendingFilePublication),
          false,
        );
        expect(publication.hasPendingFileMoves(project), false);
        expect(await original.exists(), true);
        expect(await moved.exists(), false);
        expect(await manifest.readAsString(), originalManifest);
        expect(root.dirty, true);
        expect(root.hasPathIntent, !undo);
        expect((await publication.save(project, [root])).complete, true);
        expect(project.store.fileBuffers.where((b) => b.dirty), isEmpty);
        expect(await original.exists(), undo);
        expect(await moved.exists(), !undo);
        expect(
          await manifest.readAsString(),
          undo ? originalManifest : contains('path: moved.yaml'),
        );
        expect(pendingDuringCheckpoint, true);
      },
    );
  }
}
