import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    testWidgets(
      '3.2 $format creating an additional operation opens its editable page',
      (tester) async {
        for (final name in ['yaru_window', 'yaru_window/events']) {
          final channel = MethodChannel(name);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (_) async => <String, Object?>{},
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
        }
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-additional-authoring-',
        );
        final file = File('${temp.path}/api.$format');
        final json = jsonEncode({
          'openapi': '3.2.1',
          'info': {'title': 'Additional methods', 'version': '1'},
          'paths': {
            '/native': {'additionalOperations': {}},
          },
        });
        final original = format == 'yaml' ? '# Preserve 雪\r\n$json\r\n' : json;
        file.writeAsStringSync(original);
        final controller = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        final failures = <Object>[];
        Future<void>? pending;
        Future<void> ready(bool Function() condition) async {
          final watch = Stopwatch()..start();
          await tester.pump();
          while (!condition() &&
              failures.isEmpty &&
              watch.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(failures, isEmpty);
          expect(
            condition(),
            true,
            reason:
                'pointer=${controller.selectedPointer}; occurrence=${controller.selectedOccurrence}; checking=${controller.checking}; generation=${controller.buffer?.generation}/${controller.projection?['info']?['generation']}; operations=${controller.projection?['operations']}',
          );
          await tester.pumpAndSettle();
        }

        try {
          await tester.runAsync(() async {
            await controller.initialize();
            await controller.open(file.path);
            await controller.selectObject({
              'root': controller.root,
              'resource': controller.root,
              'pointer': '/paths/~1native/additionalOperations',
            });
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
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) => Designer(
                    controller: controller,
                    run: (action) => pending = action().catchError((Object e) {
                      failures.add(e);
                    }),
                    reveal: (_) {},
                  ),
                ),
              ),
            ),
          );
          final add = find.widgetWithText(BusyApiActionRow, 'Add entry');
          await ready(() => add.evaluate().length == 1);
          await tester.runAsync(() => tester.tap(add));
          await ready(() => controller.form != null);
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Name'),
            'COPY',
          );
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await ready(
            () =>
                controller.form == null &&
                !controller.formApplying &&
                controller.selectedPointer.endsWith('/COPY') &&
                !controller.checking,
          );
          await tester.runAsync(() => pending!);
          final summary = find.byWidgetPredicate(
            (w) => w is BusyApiGroupedTextEntry && w.label == 'Summary',
          );
          await ready(() => summary.evaluate().length == 1);
          final heading = find.byElementPredicate(
            (element) =>
                element.widget is Text &&
                (element.widget as Text).data == 'COPY /native' &&
                (element.widget as Text).style ==
                    Theme.of(element).textTheme.headlineSmall,
          );
          expect(heading, findsOneWidget);
          expect(
            find.byWidgetPredicate(
              (w) => w is BusyApiActionRow && w.subtitle == 'COPY /native',
            ),
            findsOneWidget,
          );
          expect(
            tester.widget<BusyApiGroupedTextEntry>(summary).readOnly,
            false,
          );
          expect(
            controller.draft?.pointer,
            '/paths/~1native/additionalOperations/COPY',
          );
          expect(file.readAsStringSync(), original);
          expect(controller.buffer!.text, contains('COPY'));
          final created = controller.buffer!.text;
          await tester.runAsync(() async {
            await tester.enterText(
              find.descendant(of: summary, matching: find.byType(EditableText)),
              'Case preserved',
            );
            expect(await controller.flush(), true);
            await controller.analyse();
          });
          final changed = controller.buffer!.text;
          expect(changed, isNot(created));
          expect(changed, contains('COPY'));
          expect(changed, contains('Case preserved'));
          await tester.runAsync(() async {
            await controller.undo();
            await controller.analyse();
          });
          expect(controller.buffer!.text, created);
          await tester.runAsync(() async {
            await controller.redo();
            await controller.analyse();
          });
          expect(controller.buffer!.text, changed);
          expect(file.readAsStringSync(), original);
          await tester.runAsync(controller.saveAll);
          expect(file.readAsBytesSync(), controller.buffer!.bytes());
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(controller.shutdown);
          controller.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
