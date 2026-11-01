import 'dart:convert';
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
  for (final (from, target, flag, required, blocked) in [
    for (final (from, target) in [('3.0.4', '3.2.1'), ('3.2.1', '3.0.4')])
      for (final flag in ['readOnly', 'writeOnly'])
        for (final required in [false, true])
          (from, target, flag, required, required),
    for (final from in ['3.0.4', '3.1.2', '3.2.1'])
      (from, '2.0', 'readOnly', false, true),
  ]) {
    testWidgets(
      '$from → $target $flag required=$required reviews access semantics before creating a copy',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        messenger.setMockMethodCallHandler(
          const MethodChannel('busyapi/native_menus'),
          (call) async {
            if (call.method != 'show') return null;
            final entries = (call.arguments as Map)['entries'] as List;
            final index = entries.indexWhere(
              (entry) => entry['label'] == target,
            );
            expect(index, greaterThanOrEqualTo(0));
            return index;
          },
        );
        addTearDown(() {
          for (final name in [
            'yaru_window',
            'yaru_window/events',
            'busyapi/native_menus',
          ]) {
            messenger.setMockMethodCallHandler(MethodChannel(name), null);
          }
        });
        final temp = Directory.systemTemp.createTempSync(
              'busyapi-access-review-',
            ),
            file = File('${temp.path}/api.yaml');
        final original =
            '# Keep comments 雪\r\n${jsonEncode({
              'openapi': from,
              'info': {'title': 'Original 雪', 'version': 'api-version'},
              'paths': {},
              'components': {
                'schemas': {
                  'Model': {
                    'type': 'object',
                    if (required) 'required': ['value'],
                    'properties': {
                      'value': {'type': 'string', flag: true},
                    },
                  },
                },
              },
              'x-exact': 'EXACT',
            }).replaceFirst('"EXACT"', '9007199254740993.000')}\r\n';
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
            c.sourceEdit(
              c.root!,
              original.replaceFirst('Original 雪', 'Unsaved 雪'),
            );
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
                    onPressed: () {
                      dialog = showMigrationReview(
                        context,
                        c,
                        reveal: (_) async {},
                      );
                    },
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
          if (target != '3.2.1') {
            final choice = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> &&
                  widget.title == 'Target specification',
            );
            await tester.tap(choice);
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() => tester.tap(review));
          final destination = find.widgetWithText(
            BusyApiDialogButton,
            'Review output',
          );
          await ready(() => destination.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(destination));
          final publish = find.widgetWithText(
                BusyApiDialogButton,
                'Create migrated copy',
              ),
              path = '${temp.path}/busyapi-migrated';
          if (blocked) {
            await ready(
              () => find
                  .byWidgetPredicate(
                    (widget) => widget is BusyApiActionRow && widget.title == 'Access annotations need a direction-specific schema mapping to preserve their captured property and required-list semantics in the target family',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            expect(
              tester.widget<BusyApiDialogButton>(publish).onPressed,
              isNull,
            );
            expect(find.byType(BusyApiReviewComparison), findsNothing);
            expect(Directory(path).existsSync(), false);
          } else {
            await ready(
              () => find.byType(BusyApiReviewComparison).evaluate().isNotEmpty,
            );
            final comparison = tester.widget<BusyApiReviewComparison>(
              find.byType(BusyApiReviewComparison),
            );
            expect(comparison.before, contains('Unsaved 雪'));
            expect(comparison.after, contains(target));
            expect(comparison.after, contains('"$flag":true'));
            expect(comparison.after, contains('9007199254740993.000'));
            expect(
              tester.widget<BusyApiDialogButton>(publish).onPressed,
              isNotNull,
            );
            await tester.runAsync(() => tester.tap(publish));
            await ready(
              () =>
                  File('$path/openapi.yaml').existsSync() &&
                  find
                      .text(
                        'The migrated copy was created. Original documents are preserved.',
                      )
                      .evaluate()
                      .isNotEmpty,
            );
            final output = File('$path/openapi.yaml').readAsStringSync();
            expect(output, contains('Unsaved 雪'));
            expect(output, contains(target));
            expect(output, contains('9007199254740993.000'));
          }
          expect(file.readAsStringSync(), original);
          expect(
            c.buffer!.text,
            original.replaceFirst('Original 雪', 'Unsaved 雪'),
          );
          expect(c.buffer!.dirty, true);
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
