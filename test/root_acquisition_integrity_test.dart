import 'dart:io';

import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _ObservedRootController extends WorkspaceController {
  _ObservedRootController(super.engine, super.locations);
  String? destination;
  void Function()? afterAcquisition;

  @override
  Future<bool> flush() {
    final input = afterAcquisition;
    if (input != null && store?.buffers.containsKey(destination) == true) {
      afterAcquisition = null;
      input();
    }
    return super.flush();
  }
}

void main() {
  for (final composing in [false, true]) {
    test(
      'late root-selection input remains owned by the original root composing=$composing',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-late-root-input-',
        );
        final first = File('${temp.path}/first.yaml')
          ..writeAsStringSync(
            'openapi: 3.2.1\ninfo: {title: Original, version: "1"}\npaths: {}\n',
          );
        final second = File('${temp.path}/second.yaml')
          ..writeAsStringSync(
            'openapi: 3.2.1\ninfo: {title: Destination, version: "1"}\npaths: {}\n',
          );
        File('${temp.path}/busyapi.yaml').writeAsStringSync(
          'version: 1\nroots:\n  - {name: First, path: first.yaml}\n  - {name: Second, path: second.yaml}\n',
        );
        final c = _ObservedRootController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        try {
          await c.initialize();
          await c.open(temp.path);
          await c.selectRoot(first.uri.toString());
          await c.analyse();
          final original = c.buffer!;
          final session = c.bind(
            Map<String, dynamic>.from(c.analysis!['info'] as Map),
          );
          String? rootDuringInput, activeDuringInput;
          c.destination = second.uri.toString();
          c.afterAcquisition = () {
            rootDuringInput = c.root;
            activeDuringInput = c.active;
            session.edit('title', 'Typed after destination acquisition');
            session.composing = composing;
          };
          final selecting = c.selectRoot(second.uri.toString());
          if (composing) {
            await expectLater(
              selecting,
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'draft.pending',
                ),
              ),
            );
            expect(c.root, first.uri.toString());
            expect(c.active, original.id);
            expect(c.draft, same(session));
            session.composing = false;
            expect(await c.flush(), true);
            expect(await c.selectRoot(first.uri.toString()), true);
            expect(await c.selectRoot(second.uri.toString()), true);
          } else {
            expect(await selecting, true);
          }
          expect(rootDuringInput, first.uri.toString());
          expect(activeDuringInput, original.id);
          expect(c.root, second.uri.toString());
          expect(c.active, second.uri.toString());
          expect(
            original.text,
            contains('Typed after destination acquisition'),
          );
          expect(c.hasPendingFields, false);
        } finally {
          c.afterAcquisition = null;
          if (c.draft != null) c.draft!.composing = false;
          if (!c.disposed) await c.shutdown();
          c.dispose();
          await temp.delete(recursive: true);
        }
      },
    );
  }
}
