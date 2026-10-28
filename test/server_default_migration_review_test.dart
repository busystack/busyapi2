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

import '../packages/busyapi_core/test/server_variable_defaults_support.dart';
import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final target in ['3.1.2', '3.2.1']) {
      for (final options in [
        <String>[],
        ['known'],
      ]) {
        testWidgets(
          '3.0 $format → $target reviews default membership with $options before separate publication',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1200);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            for (final channel in ['yaru_window', 'yaru_window/events']) {
              messenger.setMockMethodCallHandler(
                MethodChannel(channel),
                (call) async =>
                    channel == 'yaru_window' && call.method == 'state'
                    ? {'active': true, 'visible': true, 'closable': true}
                    : null,
              );
              addTearDown(
                () => messenger.setMockMethodCallHandler(
                  MethodChannel(channel),
                  null,
                ),
              );
            }
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
            addTearDown(
              () => messenger.setMockMethodCallHandler(
                const MethodChannel('busyapi/native_menus'),
                null,
              ),
            );
            final temp = Directory.systemTemp.createTempSync(
              'busyapi-default-review-',
            );
            final source = serverVariableDefaultsSource(
              '3.0.4',
              format,
              1,
              'saved',
              options,
            );
            final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
            final file = File('${temp.path}/api.$format')
              ..writeAsBytesSync(original);
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
              final clock = Stopwatch()..start();
              await tester.pump();
              while (!condition() &&
                  clock.elapsed < const Duration(seconds: 20)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(condition(), true, reason: '${c.error}');
              await tester.pumpAndSettle();
            }

            try {
              await runWidgetIo(tester, () async {
                await c.initialize();
                await c.open(file.path);
                c.sourceEdit(
                  c.root!,
                  c.buffer!.text.replaceFirst('"saved"', '"雪"'),
                );
                await c.analyse();
                expect(c.analysis!['status'], 'complete');
              });
              final working = c.buffer!.text;
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildBusyApiTheme(
                    brightness: Brightness.light,
                    accentColor: Colors.blue,
                  ),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
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
              await ready(
                () =>
                    find.byType(BusyApiReviewComparison).evaluate().isNotEmpty,
              );
              final comparison = tester.widget<BusyApiReviewComparison>(
                find.byType(BusyApiReviewComparison),
              );
              expect(comparison.before, working);
              await runWidgetIo(tester, () async {
                final id = File('${temp.path}/planned.$format').uri.toString();
                final planned = await c.engine.request('requestOperation', {
                  'root': id,
                  'resource': id,
                  'snapshot': 'reviewed-output',
                  'pointer': '/paths/~1items/get',
                  'resources': [
                    {'id': id, 'text': comparison.after, 'generation': 0},
                  ],
                });
                final variable = planned['servers'][0]['variables']['suffix'];
                expect(variable['default'], '雪');
                expect(variable['enum'], [...options, '雪']);
              });
              expect(comparison.after, contains(target));
              expect(comparison.after, contains('9007199254740993.00'));
              expect(c.buffer!.text, working);
              expect(file.readAsBytesSync(), original);
              final publish = find.widgetWithText(
                BusyApiDialogButton,
                'Create migrated copy',
              );
              expect(
                tester.widget<BusyApiDialogButton>(publish).onPressed,
                isNotNull,
              );
              await tester.runAsync(() => tester.tap(publish));
              final output = File(
                '${temp.path}/busyapi-migrated/openapi.$format',
              );
              await ready(
                () =>
                    output.existsSync() &&
                    find
                        .text(
                          'The migrated copy was created. Original documents are preserved.',
                        )
                        .evaluate()
                        .isNotEmpty,
              );
              expect(output.readAsStringSync(), comparison.after);
              await runWidgetIo(tester, () async {
                final copy = await BusyProject.open(output.path, c.engine);
                try {
                  expect(
                    (await copy.check(copy.roots.single.id))['status'],
                    'complete',
                  );
                } finally {
                  copy.close();
                }
              });
              expect(c.buffer!.text, working);
              expect(file.readAsBytesSync(), original);
              expect(tester.takeException(), isNull);
              final close = find.widgetWithText(BusyApiDialogButton, 'Close');
              await ready(() => close.evaluate().isNotEmpty);
              await tester.runAsync(() => tester.tap(close));
              await tester.pumpAndSettle();
              await tester.runAsync(() => dialog!);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpAndSettle();
              await runWidgetIo(tester, c.shutdown);
              c.dispose();
              temp.deleteSync(recursive: true);
            }
          },
        );
      }
    }
  }
}
