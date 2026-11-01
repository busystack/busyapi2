import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final deletion in [false, true]) {
    for (final phase in ['draft', 'published', 'published-newer']) {
      test(
        'SIGKILL ${deletion ? 'delete' : 'create'} $phase keeps source, archives and working intent coherent',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-presence-kill-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final root = File('${temp.path}/root.json');
          const original =
              '\ufeff{"openapi":"3.2.1","info":{"title":"Process 雪😀","version":"1"},"paths":{},"x-data":{"\$ref":"literal"}}\r\n';
          await root.writeAsString(original);
          final target = File(
            '${temp.path}/${deletion ? 'fragment' : 'created'}.json',
          );
          const fragment =
              '{"Value":{"type":"integer","example":9007199254740993}}\r\n';
          if (deletion) await target.writeAsString(fragment);
          final beforeRoot = await root.readAsBytes(),
              beforeTarget = await target.exists()
                  ? await target.readAsBytes()
                  : null;
          final draft = phase == 'draft', newer = phase.endsWith('-newer');
          final mode =
              'presence-${deletion ? 'delete' : 'create'}${draft ? '-draft' : ''}';
          final child = await Process.start('$testBundle/file-move-child', [
            temp.path,
            '${temp.path}/state',
            mode,
          ]);
          addTearDown(() async {
            child.kill(ProcessSignal.sigkill);
            await child.exitCode;
          });
          final errors = child.stderr.transform(utf8.decoder).join();
          expect(
            await child.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 30)),
            '$mode-${draft ? 'durable' : 'before-receipt'}',
          );
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
          expect(await errors, isEmpty);
          if (newer) await target.writeAsString('newer external 雪😀');
          final disk = await target.exists()
              ? await target.readAsBytes()
              : null;
          if (draft) expect(disk, beforeTarget);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final publications = PublicationStore('${temp.path}/state'),
              recovery = RecoveryStore('${temp.path}/state/drafts');
          final records = await publications.inspect(project);
          if (draft) {
            expect(records, isEmpty);
          } else {
            expect(records, hasLength(1));
            expect(
              (records.single['outcomes'] as List).single['outcome'],
              newer ? 'conflict' : 'published',
            );
            await publications.recoverFileMoves(project, records.single);
          }
          final checkpoints = await recovery.available();
          expect(checkpoints, hasLength(1));
          await recovery.adoptFileMoves(
            checkpoints.single,
            project.recoveryOwner,
          );
          final b = project.store.fileBuffer(target.uri.toString());
          expect(b.present, !deletion);
          expect(b.text, fragment);
          expect(b.hasBom, !deletion);
          expect(b.externalConflict, newer);
          expect(
            await target.exists() ? await target.readAsBytes() : null,
            disk,
            reason: 'Recovery is not speculative publication',
          );
          expect(await root.readAsBytes(), beforeRoot);
          final result = await publications.save(project, [b]);
          expect(result.complete, !newer, reason: '${result.failed}');
          if (newer) {
            expect(await target.readAsString(), 'newer external 雪😀');
            expect(b.text, fragment);
          } else if (deletion) {
            expect(await target.exists(), false);
            final receipts = await Directory('${temp.path}/state/archives')
                .list()
                .where((entry) => entry is File)
                .cast<File>()
                .toList();
            final receipt = jsonDecode(await receipts.single.readAsString());
            final archive = (receipt['archives'] as List).single as Map;
            expect(
              await File(archive['archive'] as String).readAsBytes(),
              beforeTarget,
            );
            expect(archive['deletedWorkingCopy']['text'], fragment);
          } else {
            expect(await target.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(fragment),
            ]);
          }
          expect(await root.readAsBytes(), beforeRoot);
          publications.releaseProject(project);
        },
      );
    }
  }
}
