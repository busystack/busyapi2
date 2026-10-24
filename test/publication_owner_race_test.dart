import 'dart:async';
import 'dart:io';

import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _HeldPublication extends PublicationStore {
  _HeldPublication(super.directory);
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = true;
  @override
  Future<PublicationBatchResult> save(
    BusyProject project,
    Iterable<DocumentBuffer> buffers, {
    PublicationBoundary? beforePublish,
  }) => super.save(
    project,
    buffers,
    beforePublish: (path) async {
      if (hold) {
        hold = false;
        entered.complete();
        await release.future;
      }
      await beforePublish?.call(path);
    },
  );
}

void main() {
  for (final deleting in [false, true]) {
    test(
      'F11 workspace Save admits virtual ${deleting ? 'deletion' : 'move'} and acknowledges its retained owner',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'busyapi-controller-publication-',
        );
        final publications = _HeldPublication('${dir.path}/publication');
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${dir.path}/config',
            state: '${dir.path}/state',
            cache: '${dir.path}/cache',
          ),
          publications: publications,
        );
        Future<void>? saving;
        try {
          final root = File('${dir.path}/openapi.json')
            ..writeAsStringSync(
              '{"openapi":"3.2.1","info":{"title":"Publication","version":"1"},"paths":{}}',
            );
          final file = File('${dir.path}/fragment.json')
            ..writeAsStringSync('{"description":"A"}');
          await c.initialize();
          await c.open(root.path);
          await c.openFile(file.uri.toString());
          final owner = c.buffer!;
          c.sourceEdit(owner.id, '{"description":"B"}');
          saving = c.saveBuffers(only: {owner.id});
          await publications.entered.future;
          final project = c.project!;
          final review = deleting
              ? await c.planFileDeletion(project, owner.id)
              : await c.planFileMove(
                  project,
                  owner.id,
                  '${dir.path}/moved.json',
                );
          await c.applyRefactoring(project, review);
          if (!deleting) c.sourceEdit(owner.id, '{"description":"C"}');
          publications.release.complete();
          await saving;
          expect(await file.readAsString(), '{"description":"B"}');
          expect(owner.baseline, '{"description":"B"}');
          expect(owner.externalConflict, false);
          await c.saveBuffers();
          expect(owner.externalConflict, false);
          expect(await file.exists(), false);
          if (!deleting) {
            expect(
              await File(owner.path).readAsString(),
              '{"description":"C"}',
            );
          }
        } finally {
          if (!publications.release.isCompleted) {
            publications.release.complete();
          }
          try {
            await saving;
          } on Object {
            /* The test reports the original failure. */
          }
          if (!c.disposed) await c.shutdown();
          c.dispose();
          await dir.delete(recursive: true);
        }
      },
    );
  }
}
