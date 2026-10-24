import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/designer/schema_tree.dart';
import 'package:busyapi/src/workspace/api_tree_row.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';
import 'workspace_io_trace.dart';

class _LateTreeEngine extends TracedEngineProcess {
  _LateTreeEngine(super.trace);
  Completer<void>? entered, gate, finished;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'schemaTree') {
      calls++;
    }
    final result = await super.request(method, params, requestId: requestId);
    // A superseded progressive request may be cancelled before producing a
    // result. Hold the next actual successful result, not an aborted attempt.
    final captured = method == 'schemaTree' ? gate : null;
    if (captured != null) {
      gate = null;
      entered!.complete();
      await captured.future;
      finished!.complete();
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'lazy schema tree $version $json preserves authored ownership and source',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final channel in ['yaru_window', 'yaru_window/events']) {
            messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              (_) async => null,
            );
            addTearDown(
              () => messenger.setMockMethodCallHandler(
                MethodChannel(channel),
                null,
              ),
            );
          }
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-schema-tree-',
          );
          final trace = WorkspaceIoTrace(), engine = _LateTreeEngine(trace);
          Completer<void>? held;
          final c = TracedWorkspaceController(
            engine,
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
            trace,
          );
          final errors = <Object>[];
          final views = <String>[];
          Future<void>? pending;
          Future<void> waitFor(bool Function() ready) async {
            final watch = Stopwatch()..start();
            while (!ready() &&
                errors.isEmpty &&
                watch.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump();
              if (find.byType(AuthoredSchemaTree).evaluate().isNotEmpty) {
                final dynamic view = tester.state(
                  find.byType(AuthoredSchemaTree),
                );
                final note =
                    '${view.hashCode}:${view.epoch} built=${view.builtRows}/${view.modelRevision} restored=${view.restoredScroll}/${view.restoreScroll} pending=${view.loading} counts=${view.restoredCounts} pages=${(view.pages as Map).map((key, value) => MapEntry(key, (value['entries'] as List).length))}';
                if (views.isEmpty || views.last != note) {
                  views.add(note);
                  if (views.length > 30) views.removeAt(0);
                }
              }
            }
            expect(errors, isEmpty);
            expect(
              ready(),
              true,
              reason:
                  '${c.error} ${c.checking}/${c.checkingSemantics} ${c.selectedPointer} tree=${c.layoutState['schemaTrees']} rows=${tester.widgetList<BusyApiTreeRow>(find.byType(BusyApiTreeRow)).map((r) => r.title).toList()} scroll=${tester.stateList<ScrollableState>(find.byType(Scrollable)).map((s) => '${s.position.pixels}/${s.position.maxScrollExtent}').toList()} views=$views; ${trace.describe(c)}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> finish() async {
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await waitFor(() => done);
          }

          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
          const anchor = '/components/schemas/Model';
          final value = {
            'openapi': version,
            'info': {'title': 'Tree', 'version': '1'},
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'Model': {
                  r'$dynamicAnchor': 'node',
                  'type': ['object', 'null'],
                  'required': ['flag'],
                  'properties': {
                    'flag': false,
                    'dynamicChild': {r'$dynamicRef': '#node'},
                    for (var i = 0; i < 250; i++) 'p$i': {'type': 'string'},
                  },
                  'allOf': [
                    {'not': false},
                    {r'$ref': '#/components/schemas/Model'},
                  ],
                  'examples': [
                    {
                      'properties': {'fake': false},
                      r'$ref': 'literal data',
                    },
                  ],
                  'x-kept': {'n': 9007199254740993},
                },
              },
            },
          };
          final original =
              '${json ? '' : '# retained 😀\r\n'}${const JsonEncoder.withIndent('  ').convert(value)}'
                  .replaceFirst('9007199254740993', '9007199254740993.00');
          try {
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
                'pointer': anchor,
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
                            errors.add(error);
                          }),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            final properties = find.byWidgetPredicate(
              (w) => w is BusyApiTreeRow && w.title == 'Properties',
            );
            await waitFor(() => properties.evaluate().isNotEmpty);
            final arrow = find.descendant(
              of: properties,
              matching: find.byWidgetPredicate(
                (w) => w is GestureDetector && w.child is AnimatedRotation,
              ),
            );
            await tester.tap(arrow);
            await waitFor(
              () => find.text('flag · false · Required').evaluate().isNotEmpty,
            );
            expect(find.textContaining('fake ·'), findsNothing);
            final treeScroll = find.descendant(
              of: find.byType(AuthoredSchemaTree),
              matching: find.byType(Scrollable),
            );
            Future<void> scrollTreeTo(Finder target, {bool up = false}) async {
              // Drive the tree's own viewport, as a pointer scroll does. The
              // framework's scrollUntilVisible also scrolls every ancestor,
              // which is a different action on this selection/detail page.
              for (var attempt = 0; attempt < 80; attempt++) {
                if (target.evaluate().isNotEmpty &&
                    tester
                        .getRect(treeScroll)
                        .contains(tester.getCenter(target))) {
                  return;
                }
                await tester.drag(treeScroll, Offset(0, up ? 180 : -180));
                await tester.pumpAndSettle();
              }
              fail('Tree target not reachable: $target');
            }

            for (var page = 0; page < 5; page++) {
              await scrollTreeTo(find.text('Load next schema entries'));
              await tester.tap(find.text('Load next schema entries'));
              await tester.pump();
              await waitFor(() => find.text('Checking…').evaluate().isEmpty);
            }
            await scrollTreeTo(find.text('p249 · string'));
            expect(find.byType(BusyApiTreeRow).evaluate().length, lessThan(30));
            await tester.runAsync(() => tester.tap(find.text('p249 · string')));
            await waitFor(
              () =>
                  c.selectedPointer == '$anchor/properties/p249' &&
                  !c.checking &&
                  find.textContaining('Root:').evaluate().isNotEmpty,
            );
            await finish();
            expect(c.buffer!.text, original);
            // Navigating back restores the expanded authored tree, not flattened
            // recursive references or data-shaped schema lookalikes.
            await tester.runAsync(
              () => c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': anchor,
              }),
            );
            await waitFor(
              () => find.text('p249 · string').evaluate().isNotEmpty,
            );
            await scrollTreeTo(find.text('flag · false · Required'), up: true);
            await tester.runAsync(
              () => tester.tap(find.text('flag · false · Required')),
            );
            await waitFor(
              () =>
                  c.selectedPointer == '$anchor/properties/flag' &&
                  find.text('Boolean schema').evaluate().isNotEmpty,
            );
            await finish();
            final combo = tester.widget<BusyApiComboRow<bool>>(
              find.byType(BusyApiComboRow<bool>),
            );
            combo.onSelected(true);
            await waitFor(
              () =>
                  !c.formApplying && c.buffer!.text != original && !c.checking,
            );
            await finish();
            expect(c.buffer!.text.contains('9007199254740993.00'), true);
            expect(c.buffer!.text.contains('literal data'), true);
            await runWidgetIo(tester, c.undo);
            expect(c.buffer!.text, original);
            await runWidgetIo(tester, c.redo);
            await runWidgetIo(tester, c.saveAll);
            final saved = c.buffer!.text;
            expect(saved, contains('"flag": true'));
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(saved),
            ]);
            await runWidgetIo(tester, () => c.open(file.path));
            expect(c.buffer!.text, saved);
            await tester.runAsync(
              () => c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '$anchor/properties/dynamicChild',
              }),
            );
            await waitFor(
              () => find
                  .text(
                    'This is the static anchor. Dynamic evaluation may use another anchor in its evaluation scope.',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            expect(c.buffer!.text, saved);
            expect(tester.takeException(), isNull);
            if (version == '3.1.2' && !json) {
              engine.entered = Completer<void>();
              engine.finished = Completer<void>();
              held = Completer<void>();
              engine.gate = held;
              await tester.runAsync(() async {
                c.sourceEdit(c.buffer!.id, '$saved\n');
                await c.analyse();
              });
              await waitFor(() => engine.entered!.isCompleted);
              c.setMode('Source');
              await tester.pump();
              final calls = engine.calls;
              held.complete();
              await waitFor(() => engine.finished!.isCompleted);
              expect(
                engine.calls,
                calls,
                reason: 'A hidden tree must not continue queued restoration',
              );
              c.setMode('Design');
              await tester.pump();
              await waitFor(
                () => find
                    .text(
                      'This is the static anchor. Dynamic evaluation may use another anchor in its evaluation scope.',
                    )
                    .evaluate()
                    .isNotEmpty,
              );
              await runWidgetIo(tester, c.undo);
              expect(c.buffer!.text, saved);
              expect(tester.takeException(), isNull);
            }
          } finally {
            if (held != null && !held.isCompleted) held.complete();
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
