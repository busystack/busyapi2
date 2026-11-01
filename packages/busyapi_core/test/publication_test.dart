import 'dart:io';

import 'test_support.dart';

import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  for (final phase in ['before-first', 'after-first']) {
    test('linked save retains an Undo checkpoint during publication $phase', () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-linked-undo-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const rootText =
          "openapi: 3.2.1\ninfo: {title: Linked publication, version: '1'}\npaths: {/items: {\$ref: 'part.yaml#/Path'}}\ncomponents: {responses: {Old: {description: Empty}}}\n";
      const partText =
          "Path: {get: {responses: {'200': {\$ref: 'api.yaml#/components/responses/Old'}}}}\n";
      final source = File('${directory.path}/api.yaml')
        ..writeAsStringSync(rootText);
      final part = File('${directory.path}/part.yaml')
        ..writeAsStringSync(partText);
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(source.path, engine);
      addTearDown(project.close);
      final root = source.uri.toString();
      final buffer = await project.buffer(root);
      await project.applyRefactoring(
        await project.planComponentRename({
          'resource': root,
          'generation': buffer.generation,
          'pointer': '/components/responses/Old',
        }, 'Renamed'),
      );
      final accepted = {
        for (final b in project.store.buffers.values) b.id: b.text,
      };
      var paused = false;
      Future<void> undo() async {
        if (paused) return;
        paused = true;
        project.store.undo();
        expect(project.store.get(root).text, rootText);
        expect(project.store.get(part.uri.toString()).text, partText);
        await RecoveryStore('${directory.path}/drafts')
            .persistFileMoves(project.recoveryOwner);
      }

      final publications = PublicationStore(
        '${directory.path}/publication',
        beforeCheckpoint: phase == 'before-first' ? undo : null,
        afterPublish: phase == 'after-first' ? (_) => undo() : null,
      );
      expect((await publications.save(project, [buffer])).complete, true);
      expect(paused, true);
      expect(source.readAsStringSync(), accepted[root]);
      expect(part.readAsStringSync(), accepted[part.uri.toString()]);
      expect(buffer.text, rootText);
      expect(project.store.get(part.uri.toString()).text, partText);
      expect((await publications.save(project, [buffer])).complete, true);
      expect(source.readAsStringSync(), rootText);
      expect(part.readAsStringSync(), partText);
      expect((await project.check(root))['status'], 'complete');
    });
  }
  test('streamed publication cleans partial output and never replaces a destination', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-stream-export-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final target = File('${temp.path}/binary');
    Stream<List<int>> broken() async* {
      yield [0, 255, 128];
      throw const FileSystemException('controlled partial read');
    }

    await expectLater(
      const AtomicFileWriter().writeStream(
        target.path,
        broken(),
        overwrite: false,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(temp.listSync(), isEmpty);
    target.writeAsBytesSync([17, 19]);
    await expectLater(
      const AtomicFileWriter().writeStream(
        target.path,
        Stream.value([0, 255, 128]),
        overwrite: false,
      ),
      throwsA(isA<AtomicFileAlreadyExistsException>()),
    );
    expect(target.readAsBytesSync(), [17, 19]);
    expect(temp.listSync().length, 1);
  });
  test('initializer publishes a real contract then preserves a concurrent manifest on partial failure', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-init-partial-');
    addTearDown(() => temp.delete(recursive: true));
    final manifest = File('${temp.path}/api/busyapi.yaml');
    await expectLater(
      Initializer.create(
        destination: '${temp.path}/api',
        title: 'test',
        apiVersion: '1.0.0',
        beforePublish: (path) async {
          if (path.endsWith('busyapi.yaml')) {
            manifest.writeAsStringSync('concurrent manifest');
          }
        },
      ),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'init.partial')),
    );
    expect(manifest.readAsStringSync(), 'concurrent manifest');
    final contract = File('${temp.path}/api/openapi.yaml');
    const expected =
        'openapi: "3.1.2"\ninfo:\n  title: "test"\n  version: "1.0.0"\npaths: {}\n';
    expect(contract.readAsStringSync(), expected);
    await expectLater(
      Initializer.create(
        destination: '${temp.path}/api',
        title: 'retry',
        apiVersion: '2',
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'init.collision'),
      ),
    );
    expect(contract.readAsStringSync(), expected);
    expect(manifest.readAsStringSync(), 'concurrent manifest');
  });
  test('grouped saving freezes generations and returns partial outcomes with durable intent', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-group-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'API',
      apiVersion: '1',
    );
    final extra = File('${temp.path}/part.yaml')..writeAsStringSync('original');
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final a = await project.buffer(project.roots.single.id),
        b = await project.buffer(extra.uri.toString());
    project.store.replace(a.id, a.text.replaceFirst('API', 'saved'));
    project.store.replace(b.id, 'part draft');
    final third = File('${temp.path}/third.yaml')
      ..writeAsStringSync('third original');
    final c = await project.buffer(third.uri.toString());
    project.store.replace(c.id, 'third draft');
    final planned = a.text;
    final journal = PublicationStore(
      '${temp.path}/state',
      afterPublish: (id) async {
        if (id == a.id) {
          project.store.replace(
            a.id,
            a.text.replaceFirst('saved', 'later typing'),
          );
          extra.writeAsStringSync('new external');
        }
      },
    );
    final result = await journal.save(project, [a, b, c]);
    expect(result.complete, false);
    expect(result.published, [a.id]);
    expect(result.failed.keys, [b.id]);
    expect(result.notAttempted, [c.id]);
    expect(third.readAsStringSync(), 'third original');
    expect(c.dirty, true);
    expect(File(a.path).readAsStringSync(), planned);
    expect(a.baseline, planned);
    expect(a.dirty, true);
    expect(extra.readAsStringSync(), 'new external');
    expect(b.text, 'part draft');
    final records = await journal.inspect(project);
    expect(records.single['outcomes'][0]['outcome'], 'published');
    expect(records.single['outcomes'][1]['outcome'], 'conflict');
    await journal.recover(
      project,
      Map<String, dynamic>.from(records.single['outcomes'][1] as Map),
    );
    expect(b.externalConflict, true);
    expect(extra.readAsStringSync(), 'new external');
  });
  test(
    'checkpoint failure before publication writes no project files',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-journal-fail-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      await Initializer.create(
        destination: temp.path,
        title: 'API',
        apiVersion: '1',
      );
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      final b = await project.buffer(project.roots.single.id),
          original = File(project.files.first).readAsBytesSync();
      project.store.replace(b.id, b.text.replaceFirst('API', 'draft'));
      final journal = PublicationStore(
        '${temp.path}/state',
        beforeCheckpoint: () async {
          throw StateError('write denied');
        },
      );
      await expectLater(journal.save(project, [b]), throwsStateError);
      expect(File(b.path).readAsBytesSync(), original);
      expect(b.dirty, true);
    },
  );
  test('interrupted receipt retains original intent and restart inspection detects published bytes', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-receipt-fail-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'API',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id);
    project.store.replace(b.id, b.text.replaceFirst('API', 'published'));
    var checkpoints = 0;
    final journal = PublicationStore(
      '${temp.path}/state',
      beforeCheckpoint: () async {
        if (++checkpoints > 1) throw StateError('receipt unavailable');
      },
    );
    final result = await journal.save(project, [b]);
    expect(result.complete, false);
    expect(result.published, [b.id]);
    final record = File(result.journal!);
    final durable = jsonDecode(record.readAsStringSync());
    expect(durable['published'], isEmpty);
    final inspected = await journal.inspect(project);
    expect(inspected.single['outcomes'].single['outcome'], 'published');
    expect(File(b.path).readAsStringSync(), b.text);
  });

  test('a publication race retains the displaced external version without rollback', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-publication-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/api.yaml');
    await file.writeAsString('baseline');
    String? displaced;
    await expectLater(
      const AtomicFileWriter().writeBytes(
        file.path,
        utf8.encode('draft'),
        overwrite: true,
        beforePublish: () async {
          await file.writeAsString('external');
        },
        acceptReplaced: (path) async {
          displaced = await File(path).resolveSymbolicLinks();
          return false;
        },
      ),
      throwsA(isA<AtomicFileChangedException>()),
    );
    expect(await File(displaced!).readAsString(), 'external');
    expect(await file.readAsString(), 'draft');
    // A third writer after the exchange owns the current path; the retained copy remains.
    await file.writeAsString('newest');
    expect(await File(displaced!).readAsString(), 'external');
    expect(await file.readAsString(), 'newest');
  });
  test('read-only or changed permissions block publication', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-permissions-');
    addTearDown(() => temp.delete(recursive: true));
    final path = await Initializer.create(
      destination: temp.path,
      title: 'API',
      apiVersion: '1',
    );
    final access = await ProjectAccess.open(temp.path);
    addTearDown(access.close);
    final old = await access.read(path);
    privatePermissions(path, 292);
    await expectLater(
      access.publish(
        path,
        utf8.encode('changed'),
        expected: contentIdentity(old),
        mode: 420,
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(await File(path).readAsBytes(), old);
  });
  test('deletion at publication cannot recreate a removed user file', () async {
    final dir = await Directory.systemTemp.createTemp('busyapi-delete-race-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/api.yaml')..writeAsStringSync('baseline');
    await expectLater(
      const AtomicFileWriter().writeBytes(
        file.path,
        utf8.encode('draft'),
        overwrite: true,
        beforePublish: () => file.delete(),
        acceptReplaced: (_) => true,
      ),
      throwsA(isA<AtomicFileChangedException>()),
    );
    expect(await file.exists(), false);
  });
  test('staging directory replacement cannot redirect publication to foreign bytes', () async {
    final dir = await Directory.systemTemp.createTemp('busyapi-stage-race-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/api.yaml')..writeAsStringSync('baseline');
    final foreign = Directory('${dir.path}/foreign')..createSync();
    final foreignFile = File('${foreign.path}/document.bin')
      ..writeAsStringSync('foreign');
    await const AtomicFileWriter().writeBytes(
      target.path,
      utf8.encode('draft'),
      overwrite: true,
      beforePublish: () async {
        final stage = dir.listSync().whereType<Directory>().singleWhere(
          (d) => d.path.contains('busyapi-export-'),
        );
        final old = stage.path;
        await stage.rename('${dir.path}/moved-stage');
        await Link(old).create(foreign.path);
      },
      acceptReplaced: (path) async =>
          await File(path).readAsString() == 'baseline',
    );
    expect(await target.readAsString(), 'draft');
    expect(await foreignFile.readAsString(), 'foreign');
  });
  test('replaced resource parents cannot redirect reads or report a save to a moved path as success', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-parent-replacement-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final project = Directory('${temp.path}/project')..createSync();
    final child = Directory('${project.path}/parts')..createSync();
    final file = File('${child.path}/schema.yaml')
      ..writeAsStringSync('baseline');
    final access = await ProjectAccess.open(project.path);
    addTearDown(access.close);
    final baseline = await access.read(file.path);
    await child.rename('${project.path}/moved-parts');
    await Directory(child.path).create();
    final replacement = File(file.path)
      ..writeAsStringSync('new external version');
    // Current resources may be read through their new parent; saving the old
    // fingerprint cannot replace the newly installed version.
    await expectLater(
      access.publish(
        file.path,
        utf8.encode('draft'),
        expected: contentIdentity(baseline),
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(await replacement.readAsString(), 'new external version');
    expect(
      await File('${project.path}/moved-parts/schema.yaml').readAsString(),
      'baseline',
    );
    await project.rename('${temp.path}/moved-project');
    await Directory(project.path).create();
    await expectLater(access.read(file.path), throwsA(isA<CoreFailure>()));
    await expectLater(
      access.publish(
        file.path,
        utf8.encode('draft'),
        expected: contentIdentity(baseline),
      ),
      throwsA(isA<CoreFailure>()),
    );
  });
}
