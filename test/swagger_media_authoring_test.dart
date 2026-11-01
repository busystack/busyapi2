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
      '2.0 $format global and operation media lists use native array controls',
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
          'busyapi-swagger-media-authoring-',
        );
        final file = File('${temp.path}/api.$format');
        final json =
            jsonEncode({
              'swagger': '2.0',
              'info': {'title': 'Media lists', 'version': '1'},
              'paths': {
                '/native': {
                  'post': {
                    'responses': {
                      '204': {'description': 'No content'},
                    },
                  },
                },
              },
              'x-exact': '900719925474099312345678901.00',
            }).replaceFirst(
              '"900719925474099312345678901.00"',
              '900719925474099312345678901.00',
            );
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
              'pointer': '',
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
          for (final pointer in ['', '/paths/~1native/post']) {
            for (final (field, value) in [
              ('schemes', 'https'),
              ('consumes', 'multipart/form-data'),
              ('produces', 'application/json'),
            ]) {
              await tester.runAsync(() async {
                await controller.selectObject({
                  'root': controller.root,
                  'resource': controller.root,
                  'pointer': pointer,
                });
                await controller.analyse();
              });
              final open = find.widgetWithText(BusyApiActionRow, field);
              await ready(() => open.evaluate().length == 1);
              final before = controller.buffer!.text;
              await tester.runAsync(() async {
                await tester.ensureVisible(open);
                await tester.tap(open);
              });
              final add = find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiActionRow &&
                    widget.title == 'Add entry' &&
                    widget.onTap != null,
              );
              await ready(
                () =>
                    controller.selectedPointer == '$pointer/$field' &&
                    add.evaluate().length == 1,
              );
              await tester.runAsync(() => pending!);
              final created = controller.buffer!.text;
              expect(created, isNot(before));
              expect(file.readAsStringSync(), original);
              await tester.runAsync(() async {
                await controller.undo();
                await controller.analyse();
              });
              expect(controller.buffer!.text, before);
              await tester.runAsync(() async {
                await controller.redo();
                await controller.analyse();
              });
              expect(controller.buffer!.text, created);
              await ready(() => add.evaluate().length == 1);
              await tester.runAsync(() async {
                await tester.ensureVisible(add);
                await tester.tap(add);
              });
              await ready(() => controller.form != null);
              final text = find.widgetWithText(TextFormField, 'Text value');
              expect(text, findsOneWidget);
              expect(find.widgetWithText(TextFormField, 'Name'), findsNothing);
              await tester.enterText(text, value);
              await tester.runAsync(
                () => tester.tap(
                  find.widgetWithText(BusyApiDialogButton, 'Apply'),
                ),
              );
              await ready(
                () =>
                    controller.form == null &&
                    !controller.formApplying &&
                    !controller.checking,
              );
              await tester.runAsync(() => pending!);
              final changed = controller.buffer!.text;
              expect(changed, isNot(created));
              expect(controller.selectedPointer, '$pointer/$field');
              final list = await tester.runAsync(
                () => controller.project!.inspectObject(
                  controller.root!,
                  controller.root!,
                  '$pointer/$field',
                ),
              );
              expect(list!['nodeKind'], 'array');
              expect(list['count'], 1);
              expect((list['entries'] as List).single['value'], value);
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
              expect(
                controller.buffer!.text,
                contains('900719925474099312345678901.00'),
              );
              expect(controller.analysis!['status'], 'complete');
              expect(file.readAsStringSync(), original);
            }
          }
          final changed = controller.buffer!.text;
          await tester.runAsync(controller.saveAll);
          expect(file.readAsStringSync(), changed);
          await tester.runAsync(() => controller.open(file.path));
          expect(controller.buffer!.text, changed);
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
