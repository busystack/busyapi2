import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/api_navigator.dart';
import 'package:busyapi/src/workspace/api_tree_row.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'semantic tree $version ${json ? 'JSON' : 'YAML'} preserves shared occurrences and per-root expansion',
        (tester) async {
          final semantics = tester.ensureSemantics();
          tester.view.physicalSize = const Size(1400, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            const MethodChannel('yaru_window'),
            (_) async => null,
          );
          messenger.setMockMethodCallHandler(
            const MethodChannel('yaru_window/events'),
            (_) async => null,
          );
          final temp = Directory.systemTemp.createTempSync('busyapi-api-tree-');
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final errors = <Object>[];
          Future<void>? pending;
          void run(Future<void> Function() action) {
            pending = action().catchError((Object error) {
              errors.add(error);
            });
          }

          Future<void> waitFor(bool Function() condition) async {
            await tester.pump();
            final clock = Stopwatch()..start();
            while (!condition() &&
                errors.isEmpty &&
                clock.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(
              condition(),
              true,
              reason:
                  'checking=${c.checking}; error=${c.error}; form=${c.form?.kind}; status=${find.byType(BusyApiStatusBox).evaluate().map((e) => (e.widget as BusyApiStatusBox).message).toList()}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> settleAction() async {
            var done = false;
            await tester.runAsync(() async {
              pending?.then((_) => done = true);
            });
            await waitFor(() => done);
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              final extension = json ? 'json' : 'yaml';
              final value = {
                'openapi': version,
                'info': {'title': 'Tree', 'version': '1'},
                'paths': {
                  '/one': {r'$ref': 'part.json#/Shared'},
                  '/two': {r'$ref': 'part.json#/Shared'},
                  '/empty': {},
                },
              };
              final text =
                  (json ? '' : '# kept\r\n') +
                  const JsonEncoder.withIndent('  ').convert(value);
              for (final name in ['a', 'b']) {
                await File('${temp.path}/$name.$extension').writeAsString(text);
              }
              await File('${temp.path}/busyapi.yaml').writeAsString(
                'version: 1\nroots:\n  - name: first\n    path: a.$extension\n  - name: second\n    path: b.$extension\n',
              );
              await File('${temp.path}/part.json').writeAsString(
                jsonEncode({
                  'Shared': {
                    'get': {
                      'summary': 'Shared',
                      'tags': ['group'],
                    },
                    if (version.startsWith('3.2'))
                      'additionalOperations': {
                        'COPY': {
                          'tags': ['group'],
                        },
                      },
                  },
                }),
              );
              await c.open(temp.path);
              await c.selectRoot(c.project!.roots.first.id);
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
                home: Scaffold(
                  body: ListenableBuilder(
                    listenable: c,
                    builder: (context, _) => Row(
                      children: [
                        SizedBox(
                          width: 340,
                          child: ApiNavigator(
                            key: ValueKey((c.project, c.root)),
                            controller: c,
                            projection: c.projection,
                            filter: '',
                            run: run,
                          ),
                        ),
                        Expanded(
                          child: Designer(
                            controller: c,
                            run: run,
                            reveal: (_) {},
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await waitFor(() => find.text('GET /one').evaluate().isNotEmpty);
            expect(
              tester.getSemantics(find.bySemanticsLabel('Schemas')),
              matchesSemantics(
                label: 'Schemas',
                isButton: true,
                isFocusable: true,
                hasSelectedState: true,
                isSelected: false,
                hasTapAction: true,
                hasFocusAction: true,
              ),
            );
            expect(find.text('/empty'), findsOneWidget);
            final treeOne = find.widgetWithText(BusyApiTreeRow, 'GET /one');
            await tester.runAsync(() => tester.tap(treeOne));
            await settleAction();
            final part = c.buffer!;
            expect(c.selectedOccurrence, endsWith('#/paths/~1one/get'));
            expect(part.id, endsWith('/part.json'));
            expect(
              find.textContaining('This is a shared or referenced occurrence'),
              findsOneWidget,
            );
            await tester.runAsync(
              () => tester.tap(find.widgetWithText(BusyApiTreeRow, 'GET /two')),
            );
            await settleAction();
            expect(identical(c.buffer, part), true);
            expect(c.store!.buffers, hasLength(2));
            expect(c.selectedOccurrence, endsWith('#/paths/~1two/get'));
            final staleRow = tester.widget<BusyApiTreeRow>(
              find.widgetWithText(BusyApiTreeRow, 'GET /two'),
            );
            tester
                .widget<BusyApiComboRow<String>>(
                  find.widgetWithText(
                    BusyApiComboRow<String>,
                    'Group operations',
                  ),
                )
                .onSelected('tag');
            await tester.pumpAndSettle();
            expect(find.text('group'), findsOneWidget);
            expect(find.text('GET /two'), findsOneWidget);
            final operationFocus = tester
                .widget<InkWell>(
                  find.descendant(
                    of: find.widgetWithText(BusyApiTreeRow, 'GET /two'),
                    matching: find.byType(InkWell),
                  ),
                )
                .focusNode!;
            operationFocus.requestFocus();
            await tester.pump();
            await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
            await tester.pump();
            expect(
              operationFocus.hasFocus,
              true,
              reason: 'The tree must not consume the existing Alt+Left workspace shortcut',
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            final groupFocus = tester
                .widget<InkWell>(
                  find.descendant(
                    of: find.widgetWithText(BusyApiTreeRow, 'group'),
                    matching: find.byType(InkWell),
                  ),
                )
                .focusNode!;
            expect(groupFocus.hasFocus, true);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pumpAndSettle();
            expect(find.text('GET /two'), findsNothing);
            await tester.runAsync(c.analyse);
            await tester.pumpAndSettle();
            expect(
              find.text('GET /two'),
              findsNothing,
              reason: 'An unrelated reparse must not expand the manually collapsed group',
            );
            final first = c.root;
            await tester.runAsync(() => c.selectRoot(c.project!.roots.last.id));
            await tester.pumpAndSettle();
            staleRow.onTap();
            await tester.pumpAndSettle();
            expect(c.root, isNot(first));
            expect(c.selectedPointer, '/info');
            expect(errors, isEmpty);
            await tester.runAsync(() => c.selectRoot(first!));
            await tester.pumpAndSettle();
            await waitFor(
              () => find.text('Group operations').evaluate().isNotEmpty,
            );
            expect(
              tester
                  .widget<BusyApiComboRow<String>>(
                    find.widgetWithText(
                      BusyApiComboRow<String>,
                      'Group operations',
                    ),
                  )
                  .selected,
              'tag',
            );
            expect(
              find.text('GET /two'),
              findsNothing,
              reason: 'Per-root collapsed state survives returning to a selected occurrence',
            );
            await tester.runAsync(
              () => tester.tap(find.widgetWithText(BusyApiTreeRow, 'Schemas')),
            );
            await settleAction();
            await waitFor(
              () => find.text('Not authored').evaluate().isNotEmpty,
            );
            expect(
              jsonDecode(
                json
                    ? c.buffer!.text
                    : c.buffer!.text.substring('# kept\r\n'.length),
              ).containsKey('components'),
              false,
            );
            await tester.runAsync(() => tester.tap(find.text('Add entry')));
            await settleAction();
            await waitFor(
              () => find.text('0 authored entries').evaluate().isNotEmpty,
            );
            expect(c.selectedPointer, '/components/schemas');
            expect(
              jsonDecode(
                json
                    ? c.buffer!.text
                    : c.buffer!.text.substring('# kept\r\n'.length),
              )['components'],
              {'schemas': {}},
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            temp.deleteSync(recursive: true);
            messenger.setMockMethodCallHandler(
              const MethodChannel('yaru_window'),
              null,
            );
            messenger.setMockMethodCallHandler(
              const MethodChannel('yaru_window/events'),
              null,
            );
          }
        },
      );
    }
  }
}
