import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/designer/reference_picker.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _PickerEngine extends EngineProcess {
  _PickerEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  Completer<void>? planEntered, planRelease;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'referenceChoices') {
      if (release case final gate?) {
        release = null;
        entered!.complete();
        await gate.future;
      }
    }
    if (method == 'planReference' && planRelease != null) {
      final gate = planRelease!;
      planRelease = null;
      planEntered!.complete();
      await gate.future;
    }
    return result;
  }
}

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
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      null,
    );
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'native reference picker $version $json reviews last page and rejects stale ownership',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-native-reference-picker-',
          );
          final engine = _PickerEngine();
          Completer<void>? heldPlan;
          final c = WorkspaceController(
            engine,
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final failures = <Object>[];
          Future<void>? pending;
          Future<void> waitFor(bool Function() condition) async {
            await tester.pump();
            final timer = Stopwatch()..start();
            while (!condition() &&
                failures.isEmpty &&
                timer.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(condition(), true);
            await tester.pumpAndSettle();
          }

          Future<void> tap(String text) async {
            final finder = find.text(text).last;
            await tester.ensureVisible(finder);
            await tester.runAsync(() => tester.tap(finder));
            await tester.pump();
          }

          Future<void> openPicker() async {
            await waitFor(
              () => find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is BusyApiActionRow &&
                        widget.title == 'Choose reference target' &&
                        widget.onTap != null &&
                        widget.enabled,
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            await tap('Choose reference target');
            await waitFor(
              () => find.byType(BusyApiSearchField).evaluate().isNotEmpty,
            );
          }

          Future<void> search(String text) async {
            await tester.enterText(
              find.descendant(
                of: find.byType(BusyApiSearchField),
                matching: find.byType(EditableText),
              ),
              text,
            );
            await tester.pump(const Duration(milliseconds: 300));
          }

          try {
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final entries = {
              for (var i = 0; i < 251; i++)
                'Item${i.toString().padLeft(3, '0')}': i == 250
                    ? false
                    : {'type': 'string'},
            };
            final original = json
                ? jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Picker', 'version': '1'},
                    'paths': {},
                    'components': {
                      'schemas': {
                        'Use': {r'$ref': '#/components/schemas/Old'},
                        'Old': true,
                        ...entries,
                      },
                    },
                    'x-kept': {r'$ref': 'literal', 'text': '雪😀'},
                  })
                : '# keep 雪😀\r\nopenapi: $version\r\ninfo: {title: Picker, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Use: {\$ref: \'#/components/schemas/Old\'}\r\n    Old: true\r\n${entries.entries.map((e) => '    ${e.key}: ${e.value == false ? 'false' : '{type: string}'}').join('\r\n')}\r\nx-number: 9007199254740993.00';
            await tester.runAsync(() async {
              await file.writeAsBytes([
                239,
                187,
                191,
                ...utf8.encode(original),
              ]);
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/schemas/Use',
              });
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
                    builder: (_, _) => Designer(
                      controller: c,
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
            debugPrint('Reference picker: initial selection');
            await openPicker();
            await search('Item');
            await waitFor(
              () => find
                  .text(
                    '251 compatible target occurrences · current root and approved resources',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            expect(
              find.byType(BusyApiActionRow).evaluate().length,
              lessThan(30),
            );
            await tap('Last');
            await waitFor(() => find.text('Item250').evaluate().isNotEmpty);
            final location = tester.widget<Text>(
              find.text(
                'root.${json ? 'json' : 'yaml'}#/components/schemas/Item250',
              ),
            );
            expect(location.maxLines, 2);
            await tap('Item250');
            await waitFor(
              () => find.text('Review reference change').evaluate().isNotEmpty,
            );
            expect(c.buffer!.text, original);
            expect(
              find.textContaining('components/schemas/Use →').evaluate(),
              isNotEmpty,
            );
            await tap('Apply');
            await waitFor(
              () => c.buffer!.text.contains('#/components/schemas/Item250'),
            );
            await waitFor(
              () => find.text('Review reference change').evaluate().isEmpty,
            );
            final accepted = original.replaceFirst(
              '#/components/schemas/Old',
              '#/components/schemas/Item250',
            );
            expect(c.buffer!.text, accepted);
            expect(c.buffer!.hasBom, true);
            expect(await tester.runAsync(file.readAsBytes), [
              239,
              187,
              191,
              ...utf8.encode(original),
            ]);
            debugPrint('Reference picker: applied, undo/redo/save');
            await tester.runAsync(() => pending!);
            await runWidgetIo(tester, c.undo);
            expect(c.buffer!.text, original);
            await runWidgetIo(tester, c.redo);
            expect(c.buffer!.text, accepted);
            await runWidgetIo(tester, c.saveAll);
            expect(await tester.runAsync(file.readAsBytes), [
              239,
              187,
              191,
              ...utf8.encode(accepted),
            ]);
            debugPrint('Reference picker: saved, reopen for no-op');
            await waitFor(() => !c.checking);
            await openPicker();
            await search('Item250');
            await waitFor(
              () => find
                  .text(
                    '1 compatible target occurrences · current root and approved resources',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            final generation = c.buffer!.generation;
            await tap('Item250');
            await waitFor(
              () => find.byType(BusyApiSearchField).evaluate().isEmpty,
            );
            expect(c.buffer!.generation, generation);
            expect(c.buffer!.text, accepted);
            // A reply from the real worker may arrive after Cancel. It cannot
            // rebuild the dialog or use its disposed query controller.
            debugPrint('Reference picker: no-op complete, held reply');
            engine.entered = Completer<void>();
            final gate = Completer<void>();
            engine.release = gate;
            await openPicker();
            await waitFor(() => engine.entered!.isCompleted);
            await tap('Cancel');
            gate.complete();
            await tester.runAsync(() => pending!);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            debugPrint('Reference picker: cancellation complete, stale source');
            await openPicker();
            await search('Old');
            await waitFor(
              () => find
                  .text(
                    '1 compatible target occurrences · current root and approved resources',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            final root = c.root!;
            c.store!.replace(root, '$accepted\n');
            c.notifyListeners();
            await waitFor(
              () => find
                  .text(
                    'The captured source or resources changed. Close and reopen this selector to review current targets.',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            await tap('Old');
            expect(c.buffer!.text, '$accepted\n');
            await tap('Cancel');
            await tester.runAsync(() => pending!);
            expect(failures, isEmpty);
            // A missing reference is repairable at that occurrence without
            // enabling unrelated invalid fields or changing the definition.
            final missing = '$accepted\n'.replaceFirst(
              '#/components/schemas/Item250',
              '#/components/schemas/Missing',
            );
            c.store!.replace(root, missing);
            await tester.runAsync(c.analyse);
            await openPicker();
            await search('Old');
            await waitFor(
              () => find
                  .text(
                    '1 compatible target occurrences · current root and approved resources',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            await tap('Old');
            await waitFor(
              () => find.text('Review reference change').evaluate().isNotEmpty,
            );
            expect(c.buffer!.text, missing);
            await tap('Apply');
            await waitFor(() => c.buffer!.text == '$original\n');
            await waitFor(
              () => find.text('Review reference change').evaluate().isEmpty,
            );
            await tester.runAsync(() => pending!);
            // An invalidated owner must not trap the dialog in its planning
            // state. The held real plan is read-only and must never be applied.
            engine.planEntered = Completer<void>();
            final planGate = heldPlan = Completer<void>();
            engine.planRelease = planGate;
            await openPicker();
            await search('Item250');
            await waitFor(
              () => find
                  .text(
                    '1 compatible target occurrences · current root and approved resources',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            await tap('Item250');
            await waitFor(() => engine.planEntered!.isCompleted);
            final beforeInvalidation = c.buffer!.text;
            c.store!.replace(root, '$beforeInvalidation\n');
            c.notifyListeners();
            await tester.pump();
            final cancel = tester.widget<BusyApiDialogButton>(
              find.widgetWithText(BusyApiDialogButton, 'Cancel'),
            );
            expect(
              cancel.onPressed,
              isNotNull,
              reason: 'An invalidated reference owner must still allow Cancel',
            );
            await tap('Cancel');
            planGate.complete();
            await runWidgetIo(tester, () => pending!);
            expect(c.buffer!.text, '$beforeInvalidation\n');
          } finally {
            if (heldPlan != null && !heldPlan.isCompleted) heldPlan.complete();
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() async {
              c.dispose();
              await engine.close();
              if (temp.existsSync()) await temp.delete(recursive: true);
            });
          }
        },
      );
      testWidgets(
        'reference planning owner $version $json can cancel before a held real plan returns',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-reference-plan-owner-',
          );
          final engine = _PickerEngine();
          final gate = Completer<void>();
          final c = WorkspaceController(
            engine,
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          Future<RefactoringPlan?>? selection;
          Future<void> waitFor(bool Function() condition) async {
            final clock = Stopwatch()..start();
            while (!condition() && clock.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 10));
            }
            expect(condition(), true);
            await tester.pumpAndSettle();
          }

          try {
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final original = jsonEncode({
              'openapi': version,
              'info': {'title': 'Owner 雪😀', 'version': '1'},
              'paths': {},
              'components': {
                'schemas': {
                  'Use': {r'$ref': '#/components/schemas/Old'},
                  'Old': true,
                  'New': false,
                },
              },
            });
            late Map<String, dynamic> item;
            await tester.runAsync(() async {
              await file.writeAsString(original);
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/schemas/Use',
              });
              item = await c.project!.inspectObject(
                c.root!,
                c.root!,
                '/components/schemas/Use',
              );
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
                        selection = showReferencePicker(
                          context,
                          c,
                          c.project!,
                          item,
                          r'$ref',
                        );
                      },
                      child: const Text('Open selector'),
                    ),
                  ),
                ),
              ),
            );
            await tester.runAsync(() => tester.tap(find.text('Open selector')));
            await tester.pumpAndSettle();
            await waitFor(() => find.text('New').evaluate().isNotEmpty);
            engine.planEntered = Completer<void>();
            engine.planRelease = gate;
            await tester.runAsync(() => tester.tap(find.text('New')));
            await waitFor(() => engine.planEntered!.isCompleted);
            c.store!.replace(c.root!, '$original\n');
            c.notifyListeners();
            await tester.pump();
            final cancel = find.widgetWithText(BusyApiDialogButton, 'Cancel');
            expect(
              tester.widget<BusyApiDialogButton>(cancel).onPressed,
              isNotNull,
            );
            await tester.tap(cancel);
            expect(await runWidgetIo(tester, () => selection!), isNull);
            gate.complete();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pumpAndSettle();
            expect(find.text('Review reference change'), findsNothing);
            expect(c.buffer!.text, '$original\n');
            expect(file.readAsStringSync(), original);
            expect(tester.takeException(), isNull);
          } finally {
            if (!gate.isCompleted) gate.complete();
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() async {
              c.dispose();
              c.project?.close();
              await engine.close();
              temp.deleteSync(recursive: true);
            });
          }
        },
      );
    }
  }
}
