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
  for (final (version, format) in [
    for (final version in ['2.0', '3.0.4'])
      for (final format in ['yaml', 'json']) (version, format),
  ]) {
    testWidgets(
      '$version $format native Terms URI review preserves unsaved intent',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const menu = MethodChannel('busyapi/native_menus');
        for (final name in ['yaru_window', 'yaru_window/events']) {
          messenger.setMockMethodCallHandler(
            MethodChannel(name),
            (call) async => call.method == 'state'
                ? {'active': true, 'visible': true, 'closable': true}
                : null,
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
          );
        }
        final temp = Directory.systemTemp.createTempSync(
              'busyapi-terms-review-',
            ),
            file = File('${temp.path}/api.$format');
        final original =
            '${format == 'yaml' ? '# Keep terms\r\n' : ''}${jsonEncode({
              version == '2.0' ? 'swagger' : 'openapi': version,
              if (version != '2.0') 'servers': [
                  {'url': 'https://api.example.invalid/v1/'},
                ],
              'info': {'title': 'Original', 'version': '1', 'termsOfService': version == '2.0' ? 'https://terms.example.invalid/policy' : 'terms'},
              'paths': {},
            })}';
        file.writeAsStringSync(original);
        final controller = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        Future<void>? dialog;
        Future<void> ready(bool Function() condition) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(condition(), true);
        }

        try {
          await tester.runAsync(() async {
            await controller.initialize();
            await controller.open(file.path);
            controller.sourceEdit(
              controller.root!,
              original.replaceFirst('Original', 'Unsaved terms'),
            );
            await controller.analyse();
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
                      controller,
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
          final output = find.widgetWithText(
            BusyApiDialogButton,
            'Review output',
          );
          await ready(() => output.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(output));
          final publish = find.widgetWithText(
            BusyApiDialogButton,
            'Create migrated copy',
          );
          if (version == '2.0') {
            final choice = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> &&
                  widget.title == 'migration.info.terms-uri-activation',
            );
            await ready(() => choice.evaluate().isNotEmpty);
            expect(
              tester.widget<BusyApiDialogButton>(publish).onPressed,
              isNull,
            );
            expect(
              Directory('${temp.path}/busyapi-migrated').existsSync(),
              false,
            );
            const label = 'Use this Terms of Service text as a URI in the copy';
            messenger.setMockMethodCallHandler(menu, (call) async {
              final entries = (call.arguments as Map)['entries'] as List;
              final index = entries.indexWhere(
                (entry) => entry['label'] == label,
              );
              expect(index, greaterThanOrEqualTo(0));
              return index;
            });
            addTearDown(() => messenger.setMockMethodCallHandler(menu, null));
            await tester.ensureVisible(choice);
            await tester.tap(choice);
            await tester.pumpAndSettle();
            expect(find.text(label), findsOneWidget);
            await tester.runAsync(() => tester.tap(review));
          }
          await ready(
            () => find.byType(BusyApiReviewComparison).evaluate().isNotEmpty,
          );
          final comparison = tester.widget<BusyApiReviewComparison>(
            find.byType(BusyApiReviewComparison),
          );
          expect(comparison.before, contains('Unsaved terms'));
          expect(
            comparison.after,
            contains(
              version == '2.0'
                  ? 'https://terms.example.invalid/policy'
                  : 'https://api.example.invalid/v1/terms',
            ),
          );
          expect(comparison.after, contains('3.2.1'));
          expect(
            tester.widget<BusyApiDialogButton>(publish).onPressed,
            isNotNull,
          );
          expect(file.readAsStringSync(), original);
          expect(controller.buffer!.dirty, true);
          final close = find.widgetWithText(BusyApiDialogButton, 'Close');
          await tester.runAsync(() => tester.tap(close));
          await tester.pumpAndSettle();
          await tester.runAsync(() => dialog!);
          expect(
            Directory('${temp.path}/busyapi-migrated').existsSync(),
            false,
          );
          expect(file.readAsStringSync(), original);
          expect(tester.takeException(), null);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(controller.shutdown);
          controller.dispose();
          await tester.runAsync(controller.engine.close);
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
