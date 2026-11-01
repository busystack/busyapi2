import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';

void main() {
  testWidgets(
    'real async waits cannot advance an existing fake frame timer; the IO bridge can',
    (tester) async {
      final gate = Completer<void>();
      var completed = false;
      Timer(const Duration(milliseconds: 20), () {
        completed = true;
        gate.complete();
      });
      final old = await tester.runAsync(
        () => gate.future
            .then((_) => 'completed')
            .timeout(
              const Duration(milliseconds: 30),
              onTimeout: () => 'still waiting',
            ),
      );
      expect(old, 'still waiting');
      expect(completed, false);
      await runWidgetIo(tester, () => gate.future);
      expect(completed, true);
    },
  );
  testWidgets(
    'frame-owned recovery really publishes captured bytes before IO bridge success',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-frame-recovery-',
      );
      final b = DocumentBuffer.decode(
        '${temp.path}/source.yaml',
        utf8.encode('saved'),
      )..update('captured 雪😀\r\n');
      final recovery = RecoveryStore('${temp.path}/recovery');
      late Future<void> checkpoint;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        checkpoint = recovery.persist(b);
      });
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();
      await runWidgetIo(tester, () => checkpoint);
      final file = Directory(recovery.directory)
          .listSync()
          .whereType<File>()
          .single;
      final record = jsonDecode(file.readAsStringSync()) as Map;
      expect(record['text'], 'captured 雪😀\r\n');
      expect(record['generation'], b.generation);
      await runWidgetIo(tester, () => recovery.retire(b.id));
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'IO bridge propagates failures and never treats a timeout as success',
    (tester) async {
      await expectLater(
        runWidgetIo(
          tester,
          () => Future<void>.error(
            CoreFailure('test.failure', 'failed actual operation'),
          ),
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'test.failure'),
        ),
      );
      final never = Completer<void>();
      await expectLater(
        runWidgetIo(
          tester,
          () => never.future,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TestFailure>()),
      );
    },
  );
}
