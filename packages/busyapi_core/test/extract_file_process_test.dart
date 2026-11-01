import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final phase in ['draft', 'root', 'definition']) {
    for (final changed in [
      'none',
      if (phase != 'draft') ...['root', 'definition'],
    ]) {
      test('SIGKILL extraction after $phase with later $changed', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-extract-kill-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final root = File('${temp.path}/root.json'),
            definition = File('${temp.path}/definition 雪.json');
        const original =
            '\ufeff{"openapi":"3.2.1","info":{"title":"Process 雪😀","version":"1"},"paths":{},"components":{"schemas":{"Owner":{"properties":{"child":{"type":"integer","examples":[900719925474099312345678901],"x-data":{"\$ref":"literal payload"}}}}}}}\r\n';
        await root.writeAsString(original);
        final before = await root.readAsBytes();
        final mode = 'extract-file-$phase',
            child = await Process.start('$testBundle/file-move-child', [
              root.path,
              '${temp.path}/state',
              mode,
            ]);
        addTearDown(() async {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
        });
        final errors = child.stderr.transform(utf8.decoder).join();
        String checkpoint;
        try {
          checkpoint = await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 30));
        } on Object catch (failure) {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
          fail(
            'The termination fixture did not reach its boundary: $failure; ${await errors}',
          );
        }
        expect(
          checkpoint,
          '$mode-${phase == 'draft' ? 'durable' : 'before-receipt'}',
        );
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        expect(await errors, isEmpty);
        if (phase == 'draft') {
          expect(await root.readAsBytes(), before);
          expect(await definition.exists(), false);
        }
        if (changed != 'none') {
          await (changed == 'root' ? root : definition).writeAsString(
            changed == 'root'
                ? '{"openapi":"3.2.1","info":{"title":"Newer external 雪😀","version":"2"},"paths":{}}'
                : 'newer external definition 雪😀',
          );
        }
        final frozen = {
          for (final file in [root, definition])
            file.path: await file.exists() ? await file.readAsBytes() : null,
        };
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final publications = PublicationStore('${temp.path}/state'),
            recovery = RecoveryStore('${temp.path}/state/drafts'),
            records = await publications.inspect(project);
        expect(records, hasLength(phase == 'draft' ? 0 : 1));
        if (records.isNotEmpty) {
          expect(records.single['outcomes'], hasLength(2));
          await publications.recoverFileMoves(project, records.single);
        }
        final drafts = await recovery.available();
        expect(drafts, hasLength(1));
        await recovery.adoptFileMoves(drafts.single, project.recoveryOwner);
        final created = project.store.fileBuffer(definition.uri.toString()),
            owner = project.store.get(root.uri.toString());
        expect(created.present, true);
        expect(created.text, contains('900719925474099312345678901'));
        expect(created.text, contains('literal payload'));
        expect(owner.text, contains('/components/schemas/Stored'));
        expect(owner.hasBom, true);
        for (final file in [root, definition]) {
          expect(
            await file.exists() ? await file.readAsBytes() : null,
            frozen[file.path],
            reason:
                'Recovery cannot publish or overwrite either captured version',
          );
        }
        final saved = await publications.save(project, [created]);
        expect(saved.complete, changed == 'none', reason: '${saved.failed}');
        if (changed == 'none') {
          expect(await root.readAsBytes(), owner.bytes());
          expect(await definition.readAsBytes(), created.bytes());
          expect((await project.check(root.uri.toString()))['complete'], true);
        } else {
          for (final file in [root, definition]) {
            expect(
              await file.exists() ? await file.readAsBytes() : null,
              frozen[file.path],
              reason: 'A conflicting member blocks speculative publication of the group',
            );
          }
          expect(
            project.store
                .fileBuffer(
                  (changed == 'root' ? root : definition).uri.toString(),
                )
                .externalConflict,
            true,
          );
        }
        publications.releaseProject(project);
      });
    }
  }
}
