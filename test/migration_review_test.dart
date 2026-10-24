import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
import 'package:busyapi/src/workspace/migration_review.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      (call) async => call.method == 'state'
          ? {'active': true, 'visible': true, 'closable': true}
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      (_) async => null,
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  for (final stale in [false, true]) {
    testWidgets(
      'native migration reviews captured changes and ${stale ? 'rejects stale source' : 'publishes a separate copy'}',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
              'busyapi-migration-widget-',
            ),
            file = File('${temp.path}/api.yaml');
        const original =
            '# Keep\nopenapi: 3.0.4\ninfo: {title: Original, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: {type: string, nullable: true}}}\n';
        file.writeAsStringSync(original);
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        Future<void>? dialog;
        Future<void> ready(bool Function() condition) async {
          final watch = Stopwatch()..start();
          await tester.pump();
          while (!condition() && watch.elapsed < const Duration(seconds: 20)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(condition(), true, reason: '${c.error}');
          await tester.pumpAndSettle();
        }

        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            c.sourceEdit(c.root!, original.replaceFirst('Original', 'Unsaved'));
            await c.analyse();
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => dialog = showMigrationReview(
                      context,
                      c,
                      reveal: (_) async {},
                    ),
                    child: const Text('Migrate'),
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(() => tester.tap(find.text('Migrate')));
          final review = find.widgetWithText(
            BusyApiDialogButton,
            'Review migration',
          );
          await ready(() => review.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(review));
          final destination = find.widgetWithText(
            BusyApiDialogButton,
            'Review output',
          );
          await ready(() => destination.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(destination));
          await ready(
            () => find.byType(BusyApiReviewComparison).evaluate().isNotEmpty,
          );
          final comparison = tester.widget<BusyApiReviewComparison>(
            find.byType(BusyApiReviewComparison),
          );
          expect(comparison.before, contains('Unsaved'));
          expect(comparison.after, contains('3.2.1'));
          expect(file.readAsStringSync(), original);
          expect(c.buffer!.text, contains('3.0.4'));
          final publish = find.widgetWithText(
                BusyApiDialogButton,
                'Create migrated copy',
              ),
              path = '${temp.path}/busyapi-migrated';
          expect(Directory(path).existsSync(), false);
          if (stale) {
            await tester.runAsync(() async {
              c.sourceEdit(
                c.root!,
                c.buffer!.text.replaceFirst('Unsaved', 'Changed again'),
              );
              await c.analyse();
            });
            await ready(
              () =>
                  tester.widget<BusyApiDialogButton>(publish).onPressed == null,
            );
            expect(Directory(path).existsSync(), false);
          } else {
            expect(
              tester.widget<BusyApiDialogButton>(publish).onPressed,
              isNotNull,
            );
            await tester.runAsync(() => tester.tap(publish));
            await ready(() => File('$path/openapi.yaml').existsSync());
            expect(
              File('$path/openapi.yaml').readAsStringSync(),
              contains('3.2.1'),
            );
            expect(c.buffer!.text, contains('3.0.4'));
            expect(c.buffer!.dirty, true);
          }
          final close = find.widgetWithText(BusyApiDialogButton, 'Close');
          await ready(() => close.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(close));
          await tester.pumpAndSettle();
          await tester.runAsync(() => dialog!);
          expect(file.readAsStringSync(), original);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
