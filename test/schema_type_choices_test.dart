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

import '../packages/busyapi_core/test/schema_type_choices_test.dart'
    as fixtures;
import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        '$version ${json ? 'JSON' : 'YAML'} native type choices apply one reviewed edit',
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
          tester.view.physicalSize = const Size(1300, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-native-types-',
          );
          final file = File('${directory.path}/api.${json ? 'json' : 'yaml'}');
          final original = fixtures.render(fixtures.document(version), json);
          file.writeAsStringSync(original);
          final controller = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final failures = <Object>[];
          Future<void>? pending;
          Future<void> ready(bool Function() condition) async {
            final watch = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                failures.isEmpty &&
                watch.elapsed < const Duration(seconds: 15)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(
              condition(),
              true,
              reason: '${controller.error}; ${controller.form?.kind}',
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
                'pointer':
                    '/paths/~1value/get/responses/200/${version == '2.0' ? 'schema' : 'content/application~1json/schema'}',
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
                      run: (action) =>
                          pending = action().catchError((Object error) {
                            failures.add(error);
                          }),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            final type = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> && widget.title == 'Type',
            );
            await ready(() => type.evaluate().length == 1);
            final row = tester.widget<BusyApiComboRow<String>>(type);
            expect(row.enabled, true);
            expect(row.selected, 'string');
            expect(row.values.contains('file'), version == '2.0');
            expect(row.values.contains('null'), !version.startsWith('3.0.'));
            expect(
              find.widgetWithText(BusyApiActionRow, 'Type union'),
              version.startsWith('3.0.') ? findsNothing : findsOneWidget,
            );
            final next = version == '2.0' ? 'file' : 'integer';
            await tester.runAsync(() async {
              row.onSelected(next);
            });
            await ready(() => controller.form?.kind == 'object.type');
            expect(controller.buffer!.text, original);
            expect(file.readAsStringSync(), original);
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            final changed = original.replaceFirst(
              '"type":"string"',
              '"type":${jsonEncode(next)}',
            );
            await ready(
              () => controller.buffer!.text == changed && !controller.checking,
            );
            if (pending != null) await tester.runAsync(() => pending!);
            expect(file.readAsStringSync(), original);
            await tester.runAsync(() async {
              await controller.undo();
              await controller.analyse();
            });
            await ready(() => controller.buffer!.text == original);
            await tester.runAsync(() async {
              await controller.redo();
              await controller.analyse();
            });
            await ready(() => controller.buffer!.text == changed);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(controller.shutdown);
            controller.dispose();
            directory.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
