import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'test_support.dart';

void main() {
  for (final phase in [
    'draft',
    'destination',
    'archive',
    'destination-newer',
  ]) {
    test(
      'SIGKILL $phase restores the whole file operation without speculative disk replay',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-file-kill-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final source = File('${temp.path}/root.json'),
            manifest = File('${temp.path}/busyapi.yaml'),
            destination = File('${temp.path}/moved.json');
        const text =
            '{"openapi":"3.2.1","info":{"title":"Process","version":"1"},"paths":{},"components":{"schemas":{"Exact":{"type":"integer","example":900719925474099312345}}}}';
        await source.writeAsString(text);
        await manifest.writeAsString(
          'version: 1\nroots:\n  - name: Main\n    path: root.json # retain\nunknown: {\$ref: data}\n',
        );
        final child = await Process.start('$testBundle/file-move-child', [
          temp.path,
          '${temp.path}/state',
          phase,
        ]);
        addTearDown(() async {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
        });
        final stderr = child.stderr.transform(utf8.decoder).join();
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 12)),
          phase == 'draft' ? 'draft-durable' : '$phase-before-receipt',
        );
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        expect(await stderr, isEmpty);
        if (phase == 'destination-newer')
          await destination.writeAsString('newer external destination 🐾');
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final diskBefore = {
          for (final f in [source, manifest, destination])
            f.path: await f.exists() ? await f.readAsBytes() : null,
        };
        final publications = PublicationStore('${temp.path}/state');
        if (phase == 'draft') {
          final recovery = RecoveryStore('${temp.path}/state');
          final record = (await recovery.available()).single;
          expect(record['version'], 2);
          await recovery.adoptFileMoves(record, project.recoveryOwner);
          expect((record['form'] as Map)['values'], {
            'value': '{"unfinished": "雪 🐾\n',
          });
          final checkpoint = Directory('${temp.path}/state')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .single;
          expect(
            (jsonDecode(await checkpoint.readAsString()) as Map)['form'],
            record['form'],
          );
          expect(source.existsSync(), true);
          expect(destination.existsSync(), false);
        } else {
          final record = (await publications.inspect(project)).single;
          expect(record['version'], 2);
          final entry = (record['outcomes'] as List).cast<Map>().singleWhere(
            (e) => e['archive'] != null,
          );
          expect(
            entry['outcome'],
            phase == 'destination-newer' ? 'conflict' : 'published',
          );
          expect(
            entry['sourceOutcome'],
            phase == 'archive' ? 'archived' : 'not-archived',
          );
          await publications.recoverFileMoves(project, record);
          final drafts = RecoveryStore('${temp.path}/state/drafts');
          await drafts.adoptFileMoves(
            (await drafts.available()).single,
            project.recoveryOwner,
          );
        }
        for (final f in [source, manifest, destination])
          expect(
            await f.exists() ? await f.readAsBytes() : null,
            diskBefore[f.path],
          );
        final b = project.store.get(destination.uri.toString());
        expect(b.text, contains('Unsaved 🐾'));
        expect(b.text, contains('900719925474099312345'));
        expect(project.roots.single.id, b.id);
        if (phase == 'destination-newer') {
          expect((await publications.save(project, [b])).complete, false);
          expect(
            await destination.readAsString(),
            'newer external destination 🐾',
          );
          expect(await source.readAsString(), text);
          expect(
            await manifest.readAsString(),
            contains('path: root.json # retain'),
          );
          expect((await publications.inspect(project)).single['version'], 2);
          return;
        }
        expect((await publications.save(project, [b])).complete, true);
        expect(source.existsSync(), false);
        expect(await destination.readAsString(), b.text);
        expect(
          await manifest.readAsString(),
          contains('path: moved.json # retain'),
        );
        expect(await publications.inspect(project), isEmpty);
      },
    );
  }
  test('grouped recovery rejects late input and retired ownership before changing any other buffer', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-file-owner-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Owner',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id), old = b.id;
    final entry = <String, dynamic>{
      'id': Uri.file('${temp.path}/new.yaml').toString(),
      'path': '${temp.path}/new.yaml',
      'sourcePath': b.path,
      'text': b.text,
      'baseline': b.baseline,
      'expected': b.diskIdentity,
      'hasBom': b.hasBom,
      'mode': b.mode,
      'generation': b.generation,
    };
    await expectLater(
      project.restoreFileSnapshot(
        [entry],
        beforeApply: () async {
          project.store.replace(b.id, '${b.text}# later 🐾\n');
        },
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'recovery.stale'),
      ),
    );
    expect(project.store.buffers.keys, [old]);
    expect(b.text, endsWith('# later 🐾\n'));
    expect(File(entry['path'] as String).existsSync(), false);
    expect(project.roots.single.id, old);
    project.store.undo();
    await expectLater(
      project.restoreFileSnapshot(
        [entry],
        beforeApply: () async {
          project.close();
        },
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'recovery.stale'),
      ),
    );
    expect(project.store.buffers.keys, [old]);
    expect(project.roots.single.id, old);
  });
  test(
    'a one-file save/discard leaves unrelated dirty files untouched',
    () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-file-scope-');
      addTearDown(() => temp.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      await Initializer.create(
        destination: temp.path,
        title: 'Scoped',
        apiVersion: '1',
      );
      final unrelated = File('${temp.path}/notes.yaml');
      await unrelated.writeAsString('original\n');
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      final notes = await project.buffer(unrelated.uri.toString());
      project.store.replace(notes.id, 'unrelated pending 🐾\n');
      final b = await project.buffer(project.roots.single.id),
          destination = File('${temp.path}/new.yaml');
      await project.applyRefactoring(
        await project.planFileMove(b.id, destination.path),
      );
      project.discardFileChanges(additionally: [b]);
      expect(b.path, '${temp.path}/openapi.yaml');
      expect(b.hasPathIntent, false);
      expect(notes.text, 'unrelated pending 🐾\n');
      expect(notes.dirty, true);
      await project.applyRefactoring(
        await project.planFileMove(b.id, destination.path),
      );
      final publication = PublicationStore('${temp.path}/state');
      expect((await publication.save(project, [b])).complete, true);
      expect(await unrelated.readAsString(), 'original\n');
      expect(notes.dirty, true);
      expect(notes.text, 'unrelated pending 🐾\n');
    },
  );
  test('saving an unrelated buffer never starts a staged file move', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-file-independent-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Independent',
      apiVersion: '1',
    );
    final notesFile = File('${temp.path}/notes.yaml');
    await notesFile.writeAsString('old notes');
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id),
        source = File(b.path),
        original = await source.readAsBytes(),
        destination = File('${temp.path}/moved.yaml');
    final notes = await project.buffer(notesFile.uri.toString());
    project.store.replace(notes.id, 'only notes');
    await project.applyRefactoring(
      await project.planFileMove(b.id, destination.path),
    );
    final pub = PublicationStore('${temp.path}/state');
    expect((await pub.save(project, [notes])).complete, true);
    expect(await notesFile.readAsString(), 'only notes');
    expect(await source.readAsBytes(), original);
    expect(destination.existsSync(), false);
    expect(b.hasPathIntent, true);
    expect(
      await File('${temp.path}/busyapi.yaml').readAsString(),
      contains('path: openapi.yaml'),
    );
  });
  test('changed source permissions cannot be bypassed by publishing to a new filename', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-file-permissions-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Read only',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id),
        source = File(b.path),
        destination = File('${temp.path}/new.yaml'),
        before = await source.readAsBytes();
    await project.applyRefactoring(
      await project.planFileMove(b.id, destination.path),
    );
    await Process.run('chmod', ['400', source.path]);
    addTearDown(() => Process.run('chmod', ['600', source.path]));
    await expectLater(
      PublicationStore('${temp.path}/state').save(project, [b]),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'save.permissions'),
      ),
    );
    expect(destination.existsSync(), false);
    expect(await source.readAsBytes(), before);
    expect(
      await File('${temp.path}/busyapi.yaml').readAsString(),
      contains('path: openapi.yaml'),
    );
  });
  test('discard after a partial move preserves all disk versions and restores configured root ownership', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-file-abandon-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Original',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id),
        source = File(b.path),
        destination = File('${temp.path}/moved.yaml');
    final original = await source.readAsBytes();
    project.store.replace(b.id, b.text.replaceFirst('Original', 'Changed'));
    await project.applyRefactoring(
      await project.planFileMove(b.id, destination.path),
    );
    var stopped = false;
    final publication = PublicationStore(
      '${temp.path}/state',
      afterPublish: (_) async {
        if (!stopped) {
          stopped = true;
          throw CoreFailure('test.stop', 'stop');
        }
      },
    );
    expect((await publication.save(project, [b])).complete, false);
    final frozen = b.text;
    await destination.writeAsString('new external destination');
    final members = publication.pendingFileBuffers(project);
    await publication.abandonFileMoves(project);
    project.discardFileChanges(additionally: members);
    project.reconcileRootConfiguration();
    expect(project.roots.single.id, source.uri.toString());
    expect(await source.readAsBytes(), original);
    expect(await destination.readAsString(), 'new external destination');
    expect(project.files, contains(source.path));
    final receipt = jsonDecode(
      await Directory('${temp.path}/state/archives')
          .listSync()
          .whereType<File>()
          .single
          .readAsString(),
    ) as Map;
    expect(
      (receipt['planned'] as List).cast<Map>().any(
        (entry) => entry['text'] == frozen,
      ),
      true,
    );
    expect(publication.hasPendingFileMoves(project), false);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'file move $version $json is virtual, one history step and safely published/reopened',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-file-move-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final extension = json ? 'json' : 'yaml';
          final root = File('${temp.path}/root.$extension'),
              other = File('${temp.path}/other.$extension');
          final manifest = File('${temp.path}/busyapi.yaml');
          final text = json
              ? '{\r\n  "openapi": "$version", "info": {"title": "Move 🐾", "version": "1"},\n  "paths": {}, "components": {"schemas": {"Number": {"type": "integer", "example": 900719925474099312345}, "Other": {"\$ref": "other.$extension#/components/schemas/Value"}}}}'
              : 'openapi: $version\r\ninfo: {title: "Move 🐾", version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Number: {type: integer, example: 900719925474099312345} # exact\n    Other: {\$ref: "other.$extension#/components/schemas/Value"}';
          final otherText = json
              ? '{"openapi":"$version","info":{"title":"Other","version":"1"},"paths":{},"components":{"schemas":{"Value":false,"Incoming":{"\$ref":"root.$extension#/components/schemas/Number"}}}}'
              : 'openapi: $version\ninfo: {title: Other, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: false, Incoming: {\$ref: "root.$extension#/components/schemas/Number"}}}\n';
          final original = [239, 187, 191, ...utf8.encode(text)];
          await root.writeAsBytes(original);
          await other.writeAsString(otherText);
          final manifestText =
              'version: 1\n# keep\nroots:\n  - name: Main\n    path: "root.$extension" # root\n  - name: Other\n    path: other.$extension\nunknown: {number: 900719925474099312345, \$ref: data}\n';
          await manifest.writeAsString(manifestText);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final b = await project.buffer(root.uri.toString());
          project.store.replace(
            b.id,
            b.text.replaceFirst('Move 🐾', 'Unsaved 🐾'),
          );
          final unsaved = b.text;
          await Directory('${temp.path}/new folder').create();
          final destination = File('${temp.path}/new folder/新しい.$extension');
          final plan = await project.planFileMove(b.id, destination.path);
          expect(plan.result['kind'], 'file-move');
          expect(plan.checkedRoots.length, 2);
          await project.applyRefactoring(plan);
          final moved = b.text;
          expect(
            identical(project.store.get(destination.uri.toString()), b),
            true,
          );
          expect(project.roots.first.id, b.id);
          expect(project.files, contains(destination.path));
          expect(project.files, isNot(contains(root.path)));
          expect(await root.readAsBytes(), original);
          expect(destination.existsSync(), false);
          expect(b.hasPathIntent, true);
          expect(b.hasBom, true);
          expect(
            (await project.check(b.id, schemaEvaluation: false))['complete'],
            true,
          );
          await expectLater(
            project.buffer(root.uri.toString()),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'file.virtual.moved',
              ),
            ),
          );
          project.store.undo();
          expect(b.id, root.uri.toString());
          expect(b.text, unsaved);
          expect(project.roots.first.id, b.id);
          expect(project.store.get(manifest.uri.toString()).text, manifestText);
          project.store.redo();
          expect(b.text, moved);
          expect(b.id, destination.uri.toString());
          final publications = PublicationStore(
            '${temp.path}/state/publications',
          );
          final saved = await publications.save(project, [b]);
          expect(saved.complete, true);
          expect(
            saved.published.length,
            3,
            reason: 'A one-file Save cannot omit required repairs',
          );
          expect(root.existsSync(), false);
          expect(await destination.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(moved),
          ]);
          expect(b.dirty, false);
          expect(b.publishedPath, destination.path);
          final archived = Directory(temp.path)
              .listSync()
              .whereType<Directory>()
              .where(
                (d) => d.path.split('/').last.startsWith('busyapi-file-move-'),
              )
              .single;
          expect(await File('${archived.path}/source').readAsBytes(), original);
          final reopened = await BusyProject.open(temp.path, engine);
          addTearDown(reopened.close);
          expect(reopened.roots.first.id, b.id);
          expect(
            reopened.files.where((path) => p.isWithin(archived.path, path)),
            isEmpty,
          );
          expect(
            (await reopened.check(b.id, schemaEvaluation: false))['complete'],
            true,
          );
          // Save does not turn undo into a fictional disk rename. It stages a
          // reverse operation, and the same grouped publisher performs it.
          project.store.undo();
          expect(b.id, root.uri.toString());
          expect(b.hasPathIntent, true);
          expect(await destination.exists(), true);
          expect(root.existsSync(), false);
          expect((await publications.save(project, [b])).complete, true);
          expect(await root.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(unsaved),
          ]);
          expect(destination.existsSync(), false);
          project.store.undo();
          expect(b.text, text);
          expect(b.dirty, true);
        },
      );
    }
  }
  test('a destination race or later affected source rejects the entire plan without any text/path edits', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-file-stale-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Race',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id),
        before = b.text,
        destination = File('${temp.path}/new.yaml');
    final plan = await project.planFileMove(b.id, destination.path);
    await destination.writeAsString('external');
    await expectLater(
      project.applyRefactoring(plan),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'file.move.collision'),
      ),
    );
    expect(b.text, before);
    expect(b.hasPathIntent, false);
    expect(project.store.canUndo, false);
    expect(await destination.readAsString(), 'external');
    await destination.delete();
    final next = await project.planFileMove(b.id, destination.path);
    final manifest = await project.buffer(
      Uri.file('${temp.path}/busyapi.yaml').toString(),
    );
    project.store.replace(manifest.id, '${manifest.text}# later 🐾\n');
    await expectLater(
      project.applyRefactoring(next),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    expect(b.text, before);
    expect(b.hasPathIntent, false);
    expect(destination.existsSync(), false);
  });
  test('a failed group is resumable but newer published output is never overwritten', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-file-partial-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Partial',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id),
        old = File(b.path),
        destination = File('${temp.path}/renamed.yaml');
    await project.applyRefactoring(
      await project.planFileMove(b.id, destination.path),
    );
    var failed = false;
    final publications = PublicationStore(
      '${temp.path}/state',
      afterPublish: (id) async {
        if (!failed) {
          failed = true;
          throw CoreFailure('test.stop', 'Before receipt');
        }
      },
    );
    final partial = await publications.save(project, [b]);
    expect(partial.complete, false);
    expect(destination.existsSync(), true);
    expect(old.existsSync(), true);
    expect(b.publishedPath, destination.path);
    expect((await publications.inspect(project)).single['version'], 2);
    await destination.writeAsString('newer external');
    final retry = await publications.save(project, [b]);
    expect(retry.complete, false);
    expect(await destination.readAsString(), 'newer external');
    expect(old.existsSync(), true);
    expect(File(partial.journal!).existsSync(), true);
  });
}
