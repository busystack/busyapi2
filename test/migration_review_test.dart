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
  for (final (stale, ignoredBody, formVersion) in [
    (false, false, null),
    (true, false, null),
    (false, true, null),
    for (final version in ['3.0.0', '3.0.4', '3.1.2', '3.2.1'])
      (false, false, version),
  ]) {
    testWidgets(
      'native migration ${formVersion ?? 'general'} reviews captured changes and ${stale
          ? 'rejects stale source'
          : ignoredBody
          ? 'requires an ignored-body decision'
          : 'publishes a separate copy'}',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
              'busyapi-migration-widget-',
            ),
            file = File('${temp.path}/api.yaml');
        const base =
            '# Keep\nopenapi: 3.0.4\ninfo: {title: Original, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: {type: string, nullable: true}}}\n';
        final sourceVersion = formVersion ?? '3.0.4';
        final targetVersion = formVersion == null ? '3.2.1' : '2.0';
        final original = formVersion != null
            ? '# Keep\nopenapi: $sourceVersion\ninfo: {title: Original, version: "1"}\n'
                  'servers: [{url: https://fixture.invalid}]\npaths:\n  /form:\n    post:\n'
                  '      requestBody:\n        required: true\n        content:\n'
                  '          application/x-www-form-urlencoded:\n            schema: {type: object, required: [name], properties: {name: {type: string}, values: {type: array, items: {type: integer}}}}\n'
                  '            encoding: {values: {style: form}}\n'
                  '      responses: {"200": {description: Empty}}\n'
            : ignoredBody
            ? base.replaceFirst(
                'paths: {}',
                'paths: {"/data": {get: {requestBody: {required: true, content: {application/json: {schema: {type: string}, example: snow}}}, responses: {204: {description: Empty}}}}}',
              )
            : base;
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
          if (formVersion != null) {
            final target = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> &&
                  widget.title == 'Target specification',
            );
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            const channel = MethodChannel('busyapi/native_menus');
            messenger.setMockMethodCallHandler(channel, (call) async {
              if (call.method != 'show') return null;
              final entries = (call.arguments as Map)['entries'] as List;
              final index = entries.indexWhere(
                (entry) => entry['label'] == '2.0',
              );
              expect(index, greaterThanOrEqualTo(0));
              return index;
            });
            addTearDown(
              () => messenger.setMockMethodCallHandler(channel, null),
            );
            await tester.tap(target);
            await tester.pumpAndSettle();
          }

          await tester.runAsync(() => tester.tap(review));
          final destination = find.widgetWithText(
            BusyApiDialogButton,
            'Review output',
          );
          await ready(() => destination.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(destination));
          if (ignoredBody) {
            final choice = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> &&
                  widget.title == 'migration.body.ignored-activation',
            );
            await ready(() => choice.evaluate().isNotEmpty);
            final publish = find.widgetWithText(
              BusyApiDialogButton,
              'Create migrated copy',
            );
            expect(
              tester.widget<BusyApiDialogButton>(publish).onPressed,
              isNull,
            );
            expect(
              Directory('${temp.path}/busyapi-migrated').existsSync(),
              false,
            );
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            const channel = MethodChannel('busyapi/native_menus');
            messenger.setMockMethodCallHandler(channel, (call) async {
              if (call.method != 'show') return null;
              final entries = (call.arguments as Map)['entries'] as List;
              final index = entries.indexWhere(
                (entry) =>
                    entry['label'] ==
                    'Omit the ignored request-body declaration from the copy',
              );
              expect(index, greaterThanOrEqualTo(0));
              return index;
            });
            addTearDown(
              () => messenger.setMockMethodCallHandler(channel, null),
            );
            await tester.ensureVisible(choice);
            await tester.tap(choice);
            await tester.pumpAndSettle();
            expect(
              find.text(
                'Omit the ignored request-body declaration from the copy',
              ),
              findsOneWidget,
            );
            await tester.runAsync(() => tester.tap(review));
          }
          await ready(
            () => find.byType(BusyApiReviewComparison).evaluate().isNotEmpty,
          );
          final comparison = tester.widget<BusyApiReviewComparison>(
            find.byType(BusyApiReviewComparison),
          );
          expect(comparison.before, contains('Unsaved'));
          expect(comparison.after, contains(targetVersion));
          if (formVersion != null) {
            expect(comparison.after, contains('formData'));
            expect(comparison.after, isNot(contains('requestBody')));
          }
          if (ignoredBody) {
            expect(comparison.before, contains('requestBody'));
            expect(comparison.after, isNot(contains('requestBody')));
          }
          expect(file.readAsStringSync(), original);
          expect(c.buffer!.text, contains(sourceVersion));
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
            expect(
              File('$path/openapi.yaml').readAsStringSync(),
              contains(targetVersion),
            );
            expect(c.buffer!.text, contains(sourceVersion));
            expect(c.buffer!.dirty, true);
            if (ignoredBody) {
              expect(c.buffer!.text, contains('requestBody'));
              expect(
                File('$path/openapi.yaml').readAsStringSync(),
                isNot(contains('requestBody')),
              );
            }
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
