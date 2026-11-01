import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';
import 'workspace_io_trace.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'large example native controls $version $json capture, cancel, apply, undo and save exact source',
        (tester) async {
          for (final name in ['yaru_window', 'yaru_window/events']) {
            final channel = MethodChannel(name);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (_) async => null,
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, null),
            );
          }
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-large-value-widget-',
          );
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
          final note = 'line 雪😀\n' * 6000;
          final payload =
              '{"number":9007199254740993.00,"\$ref":"literal payload","note":${jsonEncode(note)}}';
          final original = json
              ? ' {"openapi":"$version","info":{"title":"Data","version":"1"},"paths":{},"components":{"examples":{"Data":{"value":$payload}}},"x-tail":null}'
              : '# keep 😀\r\nopenapi: $version\r\ninfo: {title: Data, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  examples:\r\n    Data:\r\n      value:\r\n        number: 9007199254740993.00 # keep scalar comment\r\n        \$ref: \'literal payload\'\r\n        note: |-\r\n${List.filled(6000, '          line 雪😀').join('\r\n')}\r\nx-tail: null';
          file.writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
          final trace = WorkspaceIoTrace();
          final c = TracedWorkspaceController(
            TracedEngineProcess(trace),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
            trace,
          );
          final errors = <Object>[];
          Future<void> waitFor(bool Function() ready) async {
            final watch = Stopwatch()..start();
            while (!ready() &&
                errors.isEmpty &&
                watch.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(
              ready(),
              true,
              reason:
                  'generation=${c.buffer?.generation} form=${c.form?.kind} applying=${c.formApplying} error=${c.error}; ${trace.describe(c)}',
            );
          }

          void run(Future<void> Function() action) {
            action().catchError((Object e) {
              errors.add(e);
            });
          }

          try {
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(file.path);
              await c.analyse();
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/examples/Data',
              });
            }, describeState: () => trace.describe(c));
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: const Color(0xffe95420),
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: AnimatedBuilder(
                    animation: c,
                    builder: (_, _) => Designer(
                      controller: c,
                      run: run,
                      reveal: (_) => fail(
                        'Ordinary large example editing must remain native',
                      ),
                    ),
                  ),
                ),
              ),
            );
            final value = find.widgetWithText(BusyApiActionRow, 'value');
            await waitFor(() => value.evaluate().isNotEmpty);
            Future<void> open() async {
              await tester.ensureVisible(value);
              await tester.tap(value);
              await tester.pump();
              await waitFor(
                () => find.byType(SourceEditor).evaluate().isNotEmpty,
              );
              expect(c.mode, 'Design');
              expect(c.buffer!.text, original);
              expect(c.project!.store.canUndo, false);
            }

            await open();
            expect(c.form?.kind, 'object.value');
            await tester.tap(
              find.widgetWithText(BusyApiDialogButton, 'Cancel'),
            );
            await tester.pump();
            await waitFor(
              () =>
                  c.form == null &&
                  find.byType(SourceEditor).evaluate().isEmpty,
            );
            expect(c.buffer!.text, original);
            expect(c.project!.store.canUndo, false);
            await open();
            final source = find.byType(SourceEditor),
                editable = find.descendant(
                  of: source,
                  matching: find.byType(EditableText),
                );
            await tester.tapAt(
              tester.getTopLeft(source) + const Offset(120, 50),
            );
            await tester.showKeyboard(editable);
            final shown = tester
                .widget<EditableText>(editable)
                .controller
                .value;
            final at = shown.text.indexOf('9007199254740993.00') + 15;
            expect(shown.text[at], '3');
            tester.testTextInput.updateEditingValue(
              shown.copyWith(
                text: shown.text.replaceRange(at, at + 1, '4'),
                selection: TextSelection.collapsed(offset: at + 1),
              ),
            );
            await tester.pump();
            expect(c.buffer!.text, original);
            expect(c.form!.values['value'], contains('9007199254740994.00'));
            await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply'));
            await tester.pump();
            await waitFor(
              () =>
                  c.form == null &&
                  !c.formApplying &&
                  find.byType(SourceEditor).evaluate().isEmpty,
            );
            final accepted = original.replaceFirst(
              '9007199254740993.00',
              '9007199254740994.00',
            );
            expect(c.buffer!.text, accepted);
            expect(c.buffer!.hasBom, true);
            await runWidgetIo(tester, c.undo);
            expect(c.buffer!.text, original);
            await runWidgetIo(tester, c.redo);
            expect(c.buffer!.text, accepted);
            await runWidgetIo(tester, c.saveAll);
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(accepted),
            ]);
            await runWidgetIo(tester, () => c.open(file.path));
            expect(c.buffer!.text, accepted);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await runWidgetIo(tester, c.shutdown);
            c.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
