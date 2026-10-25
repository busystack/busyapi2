import 'dart:async';
import 'dart:io';

import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _PausedPublication extends PublicationStore {
  _PausedPublication(super.directory, {required this.fail});
  final bool fail;
  final entered = Completer<void>(), release = Completer<void>();
  int attempts = 0;

  @override
  Future<PublicationBatchResult> save(
    BusyProject project,
    Iterable<DocumentBuffer> buffers, {
    PublicationBoundary? beforePublish,
  }) => super.save(
    project,
    buffers,
    beforePublish: (path) async {
      attempts++;
      if (attempts == 1) {
        entered.complete();
        await release.future;
      }
      if (fail && path.endsWith('/shared.yaml')) {
        throw const FileSystemException('owned queued save failure');
      }
      await beforePublish?.call(path);
    },
  );
}

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final fail in [false, true]) {
      test(
        '$version shutdown drains accepted selected saves and retains failed publication=$fail',
        () async {
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-save-shutdown-',
          );
          final publications = _PausedPublication(
            '${directory.path}/state/publication',
            fail: fail,
          );
          final controller = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
            publications: publications,
          );
          try {
            await controller.initialize();
            await Initializer.create(
              destination: '${directory.path}/api',
              title: 'Original',
              apiVersion: 'api-version',
              openapi: version,
            );
            final shared = File('${directory.path}/api/shared.yaml')
              ..writeAsStringSync('type: string\n');
            await controller.open('${directory.path}/api');
            final root = controller.buffer!;
            final original = File(root.path).readAsStringSync();
            final fragment = await controller.project!.buffer(
              shared.uri.toString(),
            );
            final edited = original.replaceFirst('Original', 'Saved');
            controller.sourceEdit(root.id, edited);
            controller.sourceEdit(fragment.id, 'type: boolean\n');
            final first = controller.saveBuffers(only: {root.id});
            await publications.entered.future;
            final second = controller.saveBuffers(only: {fragment.id});
            final closing = controller.shutdown();
            final accepted = Future.wait([first, second, closing]);
            final result = fail
                ? expectLater(
                    accepted,
                    throwsA(
                      isA<CoreFailure>()
                          .having((error) => error.code, 'code', 'save.partial')
                          .having(
                            (error) => error.toString(),
                            'reported publication failure',
                            contains('owned queued save failure'),
                          ),
                    ),
                  )
                : expectLater(accepted, completes);
            // New work is rejected while already accepted saves retain their
            // captured workspace and selection until publication completes.
            controller.sourceEdit(
              root.id,
              'late source must not replace input',
            );
            expect(root.text, edited);
            await expectLater(
              controller.saveAll(),
              throwsA(
                isA<CoreFailure>().having(
                  (error) => error.code,
                  'code',
                  'save.owner',
                ),
              ),
            );
            expect(File(root.path).readAsStringSync(), original);
            publications.release.complete();
            await result;
            expect(File(root.path).readAsStringSync(), edited);
            expect(
              shared.readAsStringSync(),
              fail ? 'type: string\n' : 'type: boolean\n',
            );
            expect(controller.disposed, !fail);
            expect(root.dirty, false);
            expect(fragment.dirty, fail);
            expect(publications.attempts, 2);
            if (fail) {
              controller.sourceEdit(
                root.id,
                edited.replaceFirst('Saved', 'Retry'),
              );
              await controller.saveBuffers(only: {root.id});
              expect(shared.readAsStringSync(), 'type: string\n');
              expect(fragment.text, 'type: boolean\n');
              expect(fragment.dirty, true);
              expect(File(root.path).readAsStringSync(), contains('Retry'));
            }
          } finally {
            if (!publications.release.isCompleted) {
              publications.release.complete();
            }
            await controller.shutdown();
            controller.dispose();
            directory.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
