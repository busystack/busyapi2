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
import '../packages/busyapi_core/test/static_dynamicref_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final keyword in [r'$defs', 'definitions']) {
    _registerMigrationTests(keyword);
  }
}

void _registerMigrationTests(String definitionKeyword) {
  for (final (from, format, target, blocked) in [
    for (final (from, format) in [('3.1.2', 'yaml'), ('3.2.1', 'json')])
      for (final target in ['3.0.4', '2.0'])
        for (final blocked in [false, true]) (from, format, target, blocked),
  ]) {
    testWidgets(
      '$from $format → $target dynamic-anchor=$blocked reviews $definitionKeyword static schema conversion before safe publication',
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
              'busyapi-static-ref-review-',
            ),
            file = File('${temp.path}/api.$format'),
            model = File('${temp.path}/model.yaml');
        final original = staticDynamicRefApi(from, format);
        final modelOriginal = blocked
            ? staticDynamicRefModel(definitionKeyword: definitionKeyword)
                  .replaceFirst(r'"$anchor"', r'"$dynamicAnchor"')
            : staticDynamicRefModel(definitionKeyword: definitionKeyword);
        file.writeAsStringSync(original);
        model.writeAsStringSync(modelOriginal);
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
              original.replaceFirst('Original API 雪', 'Unsaved API 雪'),
            );
            final shared = await c.project!.buffer(model.uri.toString());
            c.sourceEdit(
              shared.id,
              shared.text.replaceFirst('Original model', 'Unsaved model'),
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
                    (widget) => widget is BusyApiActionRow && widget.title == 'This reference starts at a dynamic anchor; a faithful older-family dynamic-scope mapping is not implemented',
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
            expect(comparison.before, contains('Unsaved API 雪'));
            expect(comparison.after, contains(target));
            expect(comparison.after, contains('allOf'));
            expect(comparison.after, contains(r'$ref'));
            expect(comparison.after, contains('9007199254740993.00'));
            expect(
              tester.widget<BusyApiDialogButton>(publish).onPressed,
              isNotNull,
            );
            await tester.runAsync(() => tester.tap(publish));
            await ready(
              () =>
                  File('$path/openapi.$format').existsSync() &&
                  find
                      .text(
                        'The migrated copy was created. Original documents are preserved.',
                      )
                      .evaluate()
                      .isNotEmpty,
            );
            final output = File('$path/openapi.$format').readAsStringSync();
            expect(output, contains('Unsaved API 雪'));
            await tester.runAsync(() async {
              final copy = await BusyProject.open(path, c.engine);
              try {
                final checked = await copy.check(copy.roots.single.id);
                expect(checked['status'], 'complete', reason: '$checked');
                final subject = await copy.inspectObject(
                  copy.roots.single.id,
                  copy.roots.single.id,
                  target == '2.0'
                      ? '/definitions/Subject'
                      : '/components/schemas/Subject',
                );
                expect(subject['family'], target == '2.0' ? '2.0' : '3.0');
                final entries = subject['entries'] as List;
                expect(
                  entries.where((entry) => entry['name'] == r'$dynamicRef'),
                  isEmpty,
                );
                expect(
                  entries.singleWhere(
                    (entry) => entry['name'] == 'allOf',
                  )['count'],
                  2,
                );
                final composition = await copy.inspectObject(
                  copy.roots.single.id,
                  copy.roots.single.id,
                  '${subject['pointer']}/allOf',
                );
                for (final entry in composition['entries'] as List) {
                  final branch = await copy.inspectObject(
                    copy.roots.single.id,
                    copy.roots.single.id,
                    entry['pointer'] as String,
                  );
                  final reference = (branch['references'] as List).single;
                  expect(reference['keyword'], r'$ref');
                  expect(reference['resolution'], 'resolved');
                }
              } finally {
                copy.close();
              }
            });
            expect(output, contains(target));
            expect(output, contains('9007199254740993.00'));
          }
          expect(file.readAsStringSync(), original);
          expect(model.readAsStringSync(), modelOriginal);
          expect(
            c.buffer!.text,
            original.replaceFirst('Original API 雪', 'Unsaved API 雪'),
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
