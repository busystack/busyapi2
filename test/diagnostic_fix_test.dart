import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/diagnostic_fix.dart';
import 'package:busyapi/src/workspace/problems_panel.dart';
import 'package:busyapi/src/workspace/project_search.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';
import 'workspace_io_trace.dart';

class _HeldFix extends TracedEngineProcess {
  _HeldFix(super.trace);
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'planDiagnosticFix' && release != null) {
      entered!.complete();
      await release!.future;
    }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'Source diagnostic repair $version $json reviews current fragment, cancels and applies one history entry',
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
          tester.view.physicalSize = const Size(1280, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-fix-widget-',
          );
          final extension = json ? 'json' : 'yaml',
              root = File('${temp.path}/root.$extension'),
              part = File('${temp.path}/part.$extension');
          final original = json
              ? ' {"Parameter":{"name":"id", "in":"path", "required":false,"schema":{"type":"string"}},"number":9007199254740993.00}'
              : '# retain 雪😀\r\nParameter:\r\n  name: \'id\'\r\n  in: path\r\n  required: false # retain comment\r\n  schema: {type: string}\r\nnumber: 9007199254740993.00';
          part.writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
          final api = {
            'openapi': version,
            'info': {'title': 'Repair', 'version': '1'},
            'paths': {
              '/p/{id}': {
                'get': {
                  'parameters': [
                    {r'$ref': 'part.$extension#/Parameter'},
                  ],
                  'responses': {
                    '204': {'description': 'No body'},
                  },
                },
              },
            },
          };
          root.writeAsStringSync(
            json
                ? jsonEncode(api)
                : 'openapi: $version\ninfo: {title: Repair, version: "1"}\npaths:\n  /p/{id}:\n    get:\n      parameters: [{\$ref: "part.$extension#/Parameter"}]\n      responses: {204: {description: No body}}\n',
          );
          final trace = WorkspaceIoTrace();
          final engine = _HeldFix(trace),
              c = TracedWorkspaceController(
                engine,
                StateLocations(
                  config: '${temp.path}/config',
                  state: '${temp.path}/state',
                  cache: '${temp.path}/cache',
                ),
                trace,
              );
          final sourceKey = GlobalKey<SourceEditorState>(), errors = <Object>[];
          void run(Future<void> Function() action) {
            action().catchError((Object error) {
              errors.add(error);
            });
          }

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
                  'source=${c.buffer?.generation} checking=${c.checking}/${c.checkingSemantics} error=${c.error}; '
                  'repairBytes=${c.buffer?.text == original.replaceFirst('false', 'true')}; '
                  'storageError=${c.storageError != null}; '
                  'reviews=${find.byType(BusyApiChangeContext).evaluate().length}; '
                  '${trace.describe(c)}',
            );
          }

          Future<void> chord() async {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.period);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
          }

          try {
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(root.path);
              await c.openFile(part.uri.toString());
              await c.analyse();
            });
            c.mode = 'Source';
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: const Color(0xffe95420),
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Builder(
                    builder: (context) => AnimatedBuilder(
                      animation: c,
                      builder: (_, _) => Column(
                        children: [
                          Expanded(
                            child: SourceEditor(
                              key: sourceKey,
                              buffer: c.buffer!,
                              owner: (c.project, c.root, c.active),
                              changes: c,
                              isCurrent: () =>
                                  !c.disposed && c.mode == 'Source',
                              onEdit: c.sourceDelta,
                              onChanged: (text) =>
                                  c.sourceEdit(c.active!, text),
                              assistance: (selection) =>
                                  c.project!.sourceAssistance(
                                    c.root!,
                                    c.active!,
                                    selection,
                                  ),
                              onQuickFix: (selection) => run(
                                () => showSourceDiagnosticFixes(
                                  context,
                                  c,
                                  selection,
                                ),
                              ),
                              undo: () => run(c.undo),
                              redo: () => run(c.redo),
                            ),
                          ),
                          SizedBox(
                            height: 240,
                            child: ProblemsPanel(
                              controller: c,
                              reveal: (_) => fail(
                                'Repair does not navigate away from Source',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final caret = original.indexOf('false') + 2;
            sourceKey.currentState!.reveal(caret);
            await tester.pump();
            await chord();
            expect(find.text('Diagnostic repairs'), findsOneWidget);
            await tester.tap(
              find.descendant(
                of: find.widgetWithText(
                  BusyApiDialogShell,
                  'Diagnostic repairs',
                ),
                matching: find.widgetWithText(
                  BusyApiActionRow,
                  'Review required path-parameter repair…',
                ),
              ),
            );
            await tester.pump();
            await waitFor(
              () => find.byType(BusyApiChangeContext).evaluate().isNotEmpty,
            );
            expect(
              find.textContaining('OpenAPI requires every path Parameter'),
              findsOneWidget,
            );
            expect(c.buffer!.text, original);
            expect(c.store!.canUndo, false);
            await tester.tap(
              find.widgetWithText(BusyApiDialogButton, 'Cancel'),
            );
            await tester.pump();
            await waitFor(
              () => find.byType(BusyApiChangeContext).evaluate().isEmpty,
            );
            expect(c.buffer!.text, original);
            sourceKey.currentState!.reveal(caret);
            await tester.pump();
            // Composition owns its keys, including this newly added shortcut.
            tester.testTextInput.updateEditingValue(
              tester
                  .widget<EditableText>(
                    find.descendant(
                      of: find.byType(SourceEditor),
                      matching: find.byType(EditableText),
                    ),
                  )
                  .controller
                  .value
                  .copyWith(composing: const TextRange(start: 0, end: 1)),
            );
            await tester.pump();
            await chord();
            expect(find.text('Diagnostic repairs'), findsNothing);
            tester.testTextInput.updateEditingValue(
              tester
                  .widget<EditableText>(
                    find.descendant(
                      of: find.byType(SourceEditor),
                      matching: find.byType(EditableText),
                    ),
                  )
                  .controller
                  .value
                  .copyWith(composing: TextRange.empty),
            );
            await tester.pump();
            await chord();
            await tester.tap(
              find.descendant(
                of: find.widgetWithText(
                  BusyApiDialogShell,
                  'Diagnostic repairs',
                ),
                matching: find.widgetWithText(
                  BusyApiActionRow,
                  'Review required path-parameter repair…',
                ),
              ),
            );
            await tester.pump();
            await waitFor(
              () => find.byType(BusyApiChangeContext).evaluate().isNotEmpty,
            );
            await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply'));
            await tester.pump();
            final expected = original.replaceFirst('false', 'true');
            await waitFor(
              () =>
                  c.buffer!.text == expected &&
                  find.byType(BusyApiChangeContext).evaluate().isEmpty,
            );
            expect(c.buffer!.hasBom, true);
            await runWidgetIo(tester, c.undo);
            expect(c.buffer!.text, original);
            await runWidgetIo(tester, c.redo);
            expect(c.buffer!.text, expected);
            await runWidgetIo(tester, c.saveAll);
            expect(part.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(expected),
            ]);
            await runWidgetIo(tester, c.undo);
            await runWidgetIo(tester, c.analyse);
            engine.entered = Completer();
            engine.release = Completer();
            await tester.ensureVisible(
              find
                  .widgetWithText(
                    BusyApiActionRow,
                    'Review required path-parameter repair…',
                  )
                  .last,
            );
            await tester.pump();
            await tester.tap(
              find
                  .widgetWithText(
                    BusyApiActionRow,
                    'Review required path-parameter repair…',
                  )
                  .last,
            );
            await tester.pump();
            await waitFor(() => engine.entered!.isCompleted);
            expect(
              find.text(
                'Checking the captured finding and its source before preparing a repair…',
              ),
              findsOneWidget,
            );
            await tester.tap(
              find.widgetWithText(BusyApiDialogButton, 'Cancel'),
            );
            await tester.pump();
            engine.release!.complete();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump();
            expect(find.byType(BusyApiChangeContext), findsNothing);
            expect(c.buffer!.text, original);
            expect(errors, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            if (engine.release != null && !engine.release!.isCompleted) {
              engine.release!.complete();
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await runWidgetIo(
              tester,
              c.shutdown,
              describeState: () => trace.describe(c),
            );
            c.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
