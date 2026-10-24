import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('R01 accepted reload cannot overwrite input accepted during disk acquisition', () async {
    final dir = await Directory.systemTemp.createTemp(
      'busyapi-reload-integrity-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final path = await Initializer.create(
      destination: dir.path,
      title: 'Original',
      apiVersion: '1',
    );
    final project = await BusyProject.open(dir.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id),
        baseline = b.baseline;
    project.store.replace(b.id, baseline.replaceFirst('Original', 'Draft'));
    await File(path).writeAsString(baseline.replaceFirst('Original', 'Disk'));
    await project.refreshDisk(b);
    expect(b.externalConflict, true);
    final entered = Completer<void>(), release = Completer<void>();
    final reload = project.reload(
      b,
      beforeReload: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    project.store.replace(b.id, b.text.replaceFirst('Draft', 'Later'));
    final generation = b.generation;
    release.complete();
    await reload;
    expect(b.text, contains('Later'));
    expect(b.generation, generation);
    expect(b.baseline, baseline);
    expect(b.dirty, true);
    expect(b.externalConflict, true);
    expect(project.store.canUndo, true);
    project.store.undo();
    expect(b.text, contains('Draft'));
    project.store.redo();
    expect(b.text, contains('Later'));
  });

  for (final change in [
    'baseline',
    'replacement',
    'closed',
    'overlap',
    'cancel',
  ]) {
    test('R01 reload rejects $change without retiring history', () async {
      final dir = await Directory.systemTemp.createTemp(
        'busyapi-reload-owner-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      await Initializer.create(
        destination: dir.path,
        title: 'Original',
        apiVersion: '1',
      );
      final project = await BusyProject.open(dir.path, engine);
      addTearDown(project.close);
      final b = await project.buffer(project.roots.single.id);
      project.store.replace(b.id, b.text.replaceFirst('Original', 'Draft'));
      final accepted = project.captureReload(b),
          entered = Completer<void>(),
          release = Completer<void>();
      final cancellation = RunCancellation();
      final pending = project.reload(
        b,
        accepted: accepted,
        cancellation: cancellation,
        beforeReload: () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      switch (change) {
        case 'baseline':
          b.baseline = b.text;
          b.diskIdentity = 'a concurrent save';
        case 'replacement':
          project.store.buffers.remove(b.id);
          await project.buffer(b.id);
        case 'closed':
          project.close();
        case 'overlap':
          expect((await project.reload(b)).status, BufferReloadStatus.applied);
        case 'cancel':
          cancellation.cancel();
      }
      final text = b.text,
          generation = b.generation,
          undo = project.store.canUndo;
      release.complete();
      final result = await pending;
      expect(
        result.status,
        change == 'cancel'
            ? BufferReloadStatus.cancelled
            : BufferReloadStatus.stale,
      );
      expect(b.text, text);
      expect(b.generation, generation);
      expect(project.store.canUndo, undo);
    });
  }
  test(
    'R01 normal reload and a failed read have explicit isolated outcomes',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'busyapi-reload-normal-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      await Initializer.create(
        destination: dir.path,
        title: 'Original',
        apiVersion: '1',
      );
      final project = await BusyProject.open(dir.path, engine);
      addTearDown(project.close);
      final b = await project.buffer(project.roots.single.id);
      project.store.replace(b.id, b.text.replaceFirst('Original', 'Draft'));
      await File(b.path).writeAsBytes([255]);
      expect((await project.reload(b)).status, BufferReloadStatus.failed);
      expect(b.text, contains('Draft'));
      expect(project.store.canUndo, true);
      await File(b.path)
          .writeAsString(b.baseline.replaceFirst('Original', 'Disk'));
      final failedMode = await project.reload(
        b,
        beforeReload: () => File(b.path).delete().then((_) {}),
      );
      expect(failedMode.status, BufferReloadStatus.failed);
      expect(b.text, contains('Draft'));
      expect(project.store.canUndo, true);
      await File(b.path)
          .writeAsString(b.baseline.replaceFirst('Original', 'Disk'));
      final result = await project.reload(b);
      expect(result.status, BufferReloadStatus.applied);
      expect(result.applied!.current, true);
      expect(b.text, contains('Disk'));
      expect(b.dirty, false);
      expect(b.externalConflict, false);
      expect(project.store.canUndo, false);
    },
  );

  test('R01 recovery retirement rechecks the exact applied generation during cleanup', () async {
    final dir = await Directory.systemTemp.createTemp(
      'busyapi-reload-recovery-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: dir.path,
      title: 'Original',
      apiVersion: '1',
    );
    final project = await BusyProject.open(dir.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id);
    project.store.replace(b.id, b.text.replaceFirst('Original', 'Draft'));
    var inject = false;
    Future<void>? checkpoint;
    late RecoveryStore recovery;
    recovery = RecoveryStore(
      '${dir.path}/recovery',
      onCheckpointPhase: (phase) {
        if (inject && phase == 'retire:start') {
          inject = false;
          project.store.replace(b.id, b.text.replaceFirst('Original', 'Later'));
          checkpoint = recovery.persist(b);
        }
      },
    );
    await recovery.persist(b);
    final result = await project.reload(b);
    expect(result.status, BufferReloadStatus.applied);
    final applied = result.applied!;
    inject = true;
    await recovery.retireIfCurrent(b.id, () => applied.current);
    await checkpoint;
    final record = jsonDecode(
      await Directory(recovery.directory)
          .listSync()
          .whereType<File>()
          .single
          .readAsString(),
    ) as Map;
    expect(record['text'], contains('Later'));
    expect(record['generation'], b.generation);
    expect(project.store.canUndo, true);
  });

  for (final replacement in [false, true])
    test(
      'R01-A automatic disk refresh ignores ${replacement ? 'replacement' : 'closed'} owners',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'busyapi-refresh-owner-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final file = await Initializer.create(
          destination: dir.path,
          title: 'Original',
          apiVersion: '1',
        );
        final project = await BusyProject.open(dir.path, engine);
        addTearDown(project.close);
        final old = await project.buffer(project.roots.single.id);
        project.store.replace(
          old.id,
          old.text.replaceFirst('Original', 'Saved'),
        );
        await project.save(old);
        final saved = old.text;
        await File(file).writeAsString(saved.replaceFirst('Saved', 'Disk'));
        final entered = Completer<void>(), release = Completer<void>();
        final pending = project.refreshDisk(
          old,
          beforeReload: () async {
            entered.complete();
            await release.future;
          },
        );
        await entered.future;
        DocumentBuffer? newer;
        if (replacement) {
          project.store.buffers.remove(old.id);
          newer = await project.buffer(old.id);
          project.store.replace(
            newer.id,
            newer.text.replaceFirst('Disk', 'Later'),
          );
        } else {
          project.close();
        }
        release.complete();
        await pending;
        expect(old.text, saved);
        expect(project.store.canUndo, true);
        if (newer != null) {
          expect(newer.text, contains('Later'));
          project.store.undo();
          expect(newer.text, contains('Disk'));
        }
      },
    );
}
