import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/designer/form_value_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native schema data forms preserve version and exact source',
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
            'busyapi-field-forms-widget-',
          );
          final source =
              '${format == 'yaml' ? '# Keep field form\r\n' : ''}${jsonEncode({
                version == '2.0' ? 'swagger' : 'openapi': version,
                'info': {'title': 'Native field', 'version': 'business'},
                'paths': {},
                version == '2.0' ? 'definitions' : 'components': version == '2.0' ? {'Record': {}} : {
                        'schemas': {'Record': {}},
                      },
                'x-number': '@exact',
                'x-payload': {r'$ref': 'literal.json', 'zero': 0},
              }).replaceFirst('"@exact"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(source);
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

          Future<void> apply() async {
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
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
                'pointer': version == '2.0'
                    ? '/definitions/Record'
                    : '/components/schemas/Record',
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
            final add = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiActionRow &&
                  widget.title == 'Add schema keyword' &&
                  widget.onTap != null,
            );
            await ready(() => add.evaluate().length == 1);
            await tester.runAsync(() async {
              await tester.ensureVisible(add);
              await tester.tap(add);
            });
            final choice = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> &&
                  widget.values.contains('items'),
            );
            await ready(() => choice.evaluate().length == 1);
            tester.widget<BusyApiComboRow<String>>(choice).onSelected('items');
            await tester.pumpAndSettle();
            await apply();
            await ready(() => controller.form?.kind == 'object.value');
            final editor = find.descendant(
              of: find.byType(FormValueEditor),
              matching: find.byType(EditableText),
            );
            expect(editor, findsOneWidget);
            await tester.enterText(editor, '[false]');
            await apply();
            expect(
              find.textContaining('Enter a JSON value of type'),
              findsOneWidget,
            );
            expect(controller.form?.values['value'], '[false]');
            expect(controller.buffer!.text, source);
            if (version == '2.0' || version.startsWith('3.0.')) {
              await tester.enterText(editor, 'false');
              await apply();
              expect(
                find.textContaining('Enter a JSON value of type'),
                findsOneWidget,
              );
              expect(controller.buffer!.text, source);
            }
            final raw = version == '2.0'
                ? '[]'
                : version.startsWith('3.0.')
                ? '{"type":"integer","minimum":9007199254740993.00}'
                : 'false';
            await tester.enterText(editor, raw);
            await apply();
            await ready(
              () =>
                  controller.form == null &&
                  !controller.checking &&
                  controller.buffer!.text != source,
            );
            await tester.runAsync(() => pending!);
            final changed = controller.buffer!.text;
            expect(changed, contains('9007199254740993.00'));
            expect(changed, contains('literal.json'));
            expect(file.readAsStringSync(), source);
            expect(controller.analysis!['status'], 'complete');
            final pointer = version == '2.0'
                ? '/definitions/Record'
                : '/components/schemas/Record';
            await tester.runAsync(() async {
              final page = await controller.project!.inspectObject(
                controller.root!,
                controller.root!,
                pointer,
              );
              expect(
                (page['fields'] as List).cast<Map>().singleWhere(
                  (field) => field['name'] == 'items',
                )['raw'],
                raw,
              );
              await controller.undo();
              expect(controller.buffer!.text, source);
              await controller.redo();
              expect(controller.buffer!.text, changed);
              await controller.saveBuffers();
            });
            expect(file.readAsStringSync(), changed);
            expect(tester.takeException(), isNull);
            expect(failures, isEmpty);
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
