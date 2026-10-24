import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

String _sidebarSelection = 'Files';
Finder sidebarViewMenu() => find.byWidgetPredicate(
  (widget) =>
      widget is BusyApiHeaderPopupMenuButton<String> &&
      widget.tooltip == 'Sidebar view',
);

class _HeldDeletionEngine extends EngineProcess {
  _HeldDeletionEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  bool hold = false;
  final entered = Completer<void>(),
      release = Completer<void>(),
      finished = Completer<void>();
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (hold && method == 'planFileDeletion') {
      entered.complete();
      await release.future;
      try {
        return await super.request(method, params, requestId: requestId);
      } finally {
        finished.complete();
      }
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _sidebarSelection = 'Files';
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
    // Exercise the real Files menu launcher and payload. GTK menu interaction
    // is qualified separately in the native application, not by this mock.
    messenger.setMockMethodCallHandler(
      const MethodChannel('busyapi/native_menus'),
      (call) async {
        if (call.method == 'dismiss') return true;
        expect(call.method, 'show');
        final entries = (call.arguments as Map)['entries'] as List;
        final labels = entries.map((entry) => entry['label']).toList();
        if (labels.contains('API')) {
          expect(labels, contains('Files'));
          final selected = labels.indexOf(_sidebarSelection);
          expect(selected, isNonNegative);
          return selected;
        }
        expect(entries.map((entry) => entry['label']), [
          'Move file…',
          'Delete file…',
        ]);
        return 1;
      },
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
    messenger.setMockMethodCallHandler(
      const MethodChannel('busyapi/native_menus'),
      null,
    );
  });
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final clock = Stopwatch()..start();
    while (!ready() && clock.elapsed < const Duration(seconds: 30)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), true);
  }

  Future<void> button(WidgetTester tester, String label) async {
    await tester.runAsync(
      () => tester.tap(find.widgetWithText(BusyApiDialogButton, label).last),
    );
    await tester.pumpAndSettle();
  }

  Future<void> deleteMenu(
    WidgetTester tester,
    String filename, {
    bool review = true,
  }) async {
    final row = find.widgetWithText(BusyApiSidebarRecordRow<String>, filename);
    expect(row, findsOneWidget);
    await tester.runAsync(
      () => tester.tap(
        find.descendant(of: row, matching: find.byTooltip('File actions')),
      ),
    );
    await tester.pumpAndSettle();
    if (review) {
      await waitFor(
        tester,
        () => find.text('Review file deletion').evaluate().isNotEmpty,
      );
    }
  }

  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'Files controls $version $json review creation/deletion, whole-file history and protected close',
        (tester) async {
          await fixture(tester, version, json, (c, root, unused) async {
            final owner = c.project!,
                rootBytes = root.readAsBytesSync(),
                sourceBytes = unused.readAsBytesSync();
            final filename = 'created.${json ? 'json' : 'yaml'}',
                destination = File(
                  '${unused.parent.path}/created.${json ? 'json' : 'yaml'}',
                );
            for (final accept in [false, true]) {
              _sidebarSelection = 'New source file…';
              await tester.runAsync(() => tester.tap(sidebarViewMenu()));
              await waitFor(
                tester,
                () => find
                    .widgetWithText(BusyApiGroupedTextEntry, 'Destination path')
                    .evaluate()
                    .isNotEmpty,
              );
              final field = find.descendant(
                of: find.widgetWithText(
                  BusyApiGroupedTextEntry,
                  'Destination path',
                ),
                matching: find.byType(TextField),
              );
              await tester.enterText(field, filename);
              await button(tester, 'Apply');
              await waitFor(
                tester,
                () => find.text('Review file creation').evaluate().isNotEmpty,
              );
              expect(find.text('Empty source file'), findsOneWidget);
              expect(
                owner.store.buffers.containsKey(destination.uri.toString()),
                false,
              );
              expect(destination.existsSync(), false);
              await button(tester, accept ? 'Apply' : 'Cancel');
              await waitFor(
                tester,
                () => find.text('Review file creation').evaluate().isEmpty,
              );
              if (!accept) {
                expect(
                  owner.store.buffers.containsKey(destination.uri.toString()),
                  false,
                );
                expect(c.active, root.uri.toString());
              }
            }
            await waitFor(tester, () => c.active == destination.uri.toString());
            expect(c.mode, 'Source');
            expect(c.buffer!.text, '');
            expect(c.buffer!.dirty, true);
            expect(destination.existsSync(), false);
            await tester.runAsync(
              () => c.saveBuffers(only: {destination.uri.toString()}),
            );
            expect(destination.readAsBytesSync(), isEmpty);
            await tester.runAsync(c.undo);
            expect(c.tabs, isNot(contains(destination.uri.toString())));
            expect(c.active, root.uri.toString());
            expect(destination.existsSync(), true);
            await tester.runAsync(c.redo);
            expect(c.active, destination.uri.toString());
            expect(c.buffer!.dirty, false);
            await tester.runAsync(() => c.openFile(unused.uri.toString()));
            c.setMode('Source');
            final b = c.buffer!, id = b.id;
            await tester.pumpAndSettle();
            final sourceInput = find.descendant(
              of: find.byType(SourceEditor),
              matching: find.byType(EditableText),
            );
            await tester.showKeyboard(sourceInput);
            tester.testTextInput.updateEditingValue(
              TextEditingValue(
                text: b.text,
                selection: const TextSelection(baseOffset: 2, extentOffset: 4),
              ),
            );
            await tester.pump();
            final caret = b.selection, scroll = b.scroll;
            final foldsKey = jsonEncode([c.root, id]);
            c.layoutState = {
              ...c.layoutState,
              'sourceFolds': {
                foldsKey: ['/Value'],
              },
            };
            for (final accept in [false, true]) {
              await deleteMenu(tester, unused.uri.pathSegments.last);
              expect(unused.readAsBytesSync(), sourceBytes);
              await button(tester, accept ? 'Apply' : 'Cancel');
              await waitFor(
                tester,
                () => find.text('Review file deletion').evaluate().isEmpty,
              );
              if (!accept) expect(owner.store.get(id), same(b));
            }
            expect(c.active, root.uri.toString());
            expect(c.tabs, isNot(contains(id)));
            expect(owner.store.buffers.containsKey(id), false);
            expect(b.dirty, true);
            expect((c.layoutState['sourceFolds'] as Map)[foldsKey], ['/Value']);
            expect(unused.readAsBytesSync(), sourceBytes);
            await tester.runAsync(c.undo);
            expect(c.active, id);
            expect(c.buffer, same(b));
            expect(b.selection.base, caret.base);
            expect(b.selection.extent, caret.extent);
            expect(b.scroll, scroll);
            await tester.runAsync(c.redo);
            expect(c.active, root.uri.toString());
            final screen = tester.state<WorkspaceScreenState>(
              find.byType(WorkspaceScreen),
            );
            for (final discard in [false, true]) {
              late Future<bool> pending;
              await tester.runAsync(() async {
                pending = screen.protect();
              });
              await waitFor(
                tester,
                () => find
                    .text('Save changes before closing?')
                    .evaluate()
                    .isNotEmpty,
              );
              await button(tester, discard ? 'Discard' : 'Cancel');
              expect(await tester.runAsync(() => pending), discard);
              expect(unused.readAsBytesSync(), sourceBytes);
              if (!discard) expect(b.present, false);
            }
            expect(b.present, true);
            expect(b.dirty, false);
            expect(c.active, id);
            expect(root.readAsBytesSync(), rootBytes);
            expect(tester.takeException(), isNull);
          });
        },
      );
    }
  }
  testWidgets(
    'deleting a file does not steal a later Source navigation when undone',
    (tester) async {
      await fixture(tester, '3.2.1', true, (c, root, unused) async {
        await tester.runAsync(() => c.openFile(unused.uri.toString()));
        await deleteMenu(tester, unused.uri.pathSegments.last);
        await button(tester, 'Apply');
        await waitFor(
          tester,
          () => !c.store!.buffers.containsKey(unused.uri.toString()),
        );
        await tester.runAsync(() => c.openFile(root.uri.toString()));
        await tester.runAsync(c.undo);
        expect(c.active, root.uri.toString());
        expect(c.tabs, contains(unused.uri.toString()));
        expect(c.store!.buffers.containsKey(unused.uri.toString()), true);
      });
    },
  );
  testWidgets(
    'configured-root deletion is visibly blocked rather than partially applied',
    (tester) async {
      await fixture(tester, '3.2.1', true, (c, root, unused) async {
        final bytes = root.readAsBytesSync();
        await deleteMenu(tester, root.uri.pathSegments.last);
        expect(
          find.textContaining('Remove its root declaration'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<BusyApiDialogButton>(
                find.widgetWithText(BusyApiDialogButton, 'Apply'),
              )
              .onPressed,
          isNull,
        );
        await button(tester, 'Cancel');
        expect(c.root, root.uri.toString());
        expect(root.readAsBytesSync(), bytes);
      });
    },
  );
  testWidgets(
    'deletion review retains an approved mapping even without a current API consumer',
    (tester) async {
      await fixture(tester, '3.2.1', true, (c, root, unused) async {
        await tester.runAsync(
          () => c.project!.approveResource(
            'https://contracts.example/unused',
            unused.uri.toString(),
          ),
        );
        final bytes = unused.readAsBytesSync();
        await deleteMenu(tester, 'unused.json');
        expect(
          find.textContaining('An approved resource mapping'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<BusyApiDialogButton>(
                find.widgetWithText(BusyApiDialogButton, 'Apply'),
              )
              .onPressed,
          isNull,
        );
        await button(tester, 'Cancel');
        expect(unused.readAsBytesSync(), bytes);
        expect(c.store!.get(unused.uri.toString()).present, true);
      });
    },
  );
  testWidgets(
    'file deletion review protects discovered policy inputs without running lint',
    (tester) async {
      await fixture(tester, '3.2.1', false, (c, root, unused) async {
        final manifest = File('${root.parent.path}/busyapi.yaml');
        await tester.runAsync(() async {
          await unused.writeAsString(
            'rules:\n  summary:\n    given: \$.info\n    then: {field: title, function: truthy}\n',
          );
          await manifest.writeAsString(
            '${await manifest.readAsString()}policy: {rulesets: [unused.yaml]}\n',
          );
        });
        final bytes = unused.readAsBytesSync();
        await deleteMenu(tester, 'unused.yaml');
        expect(
          find.textContaining('Project governance depends'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<BusyApiDialogButton>(
                find.widgetWithText(BusyApiDialogButton, 'Apply'),
              )
              .onPressed,
          isNull,
        );
        await button(tester, 'Cancel');
        expect(unused.readAsBytesSync(), bytes);
        expect(c.store!.buffers.containsKey(unused.uri.toString()), true);
      });
    },
  );
  for (final code in [false, true]) {
    testWidgets(
      'incomplete policy dependency review code=$code blocks deletion without disabling unrelated Source or Design',
      (tester) async {
        await fixture(tester, '3.2.1', true, (c, root, unused) async {
          final marker = File('${root.parent.path}/must-not-execute'),
              rules = File(
                '${root.parent.path}/.spectral.${code ? 'cjs' : 'yaml'}',
              );
          await tester.runAsync(
            () => rules.writeAsString(
              code
                  ? 'require("node:fs").writeFileSync(${jsonEncode(marker.path)}, "must not execute"); module.exports={};'
                  : 'rules: [\n',
            ),
          );
          final source = root.readAsBytesSync(),
              before = unused.readAsBytesSync();
          c.setMode('Source');
          await tester.pumpAndSettle();
          await deleteMenu(tester, 'unused.json');
          expect(
            find.textContaining('Governance dependencies are incomplete'),
            findsOneWidget,
          );
          expect(
            tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(BusyApiDialogButton, 'Apply'),
                )
                .onPressed,
            isNull,
          );
          await button(tester, 'Cancel');
          expect(c.mode, 'Source');
          expect(c.active, root.uri.toString());
          expect(find.byType(SourceEditor), findsOneWidget);
          // Planning may refresh a source and schedule current structural
          // feedback. M1 deliberately withholds Design eligibility during
          // that check; an old projection must not be treated as current.
          await waitFor(tester, () => !c.checking);
          expect(
            c.designSafe,
            true,
            reason:
                'checking=${c.checking}; status=${c.analysis?['status']}; '
                'sourceGeneration=${c.buffer?.generation}; '
                'projectionGeneration=${c.projection?['info']?['generation']}',
          );
          expect(root.readAsBytesSync(), source);
          expect(unused.readAsBytesSync(), before);
          expect(marker.existsSync(), false);
          expect(tester.takeException(), isNull);
        });
      },
    );
  }
  for (final behavior in [
    'external-reload',
    'external-fragment-reload',
    'project-switch',
    'page-disposal',
  ]) {
    testWidgets(
      'file deletion planning $behavior preserves current Source and retires late UI ownership',
      (tester) async {
        final engine = _HeldDeletionEngine();
        try {
          await fixture(tester, '3.2.1', true, (c, root, unused) async {
            final owner = c.project!, bytes = unused.readAsBytesSync();
            if (behavior == 'external-fragment-reload') {
              await tester.runAsync(() => c.openFile(unused.uri.toString()));
            }
            c.setMode('Source');
            await tester.pumpAndSettle();
            if (behavior == 'external-reload') {
              final changed = root.readAsStringSync().replaceFirst(
                'Files',
                'External reload',
              );
              await tester.runAsync(() => root.writeAsString(changed));
            } else if (behavior == 'external-fragment-reload') {
              await tester.runAsync(
                () => unused.writeAsString(
                  unused.readAsStringSync().replaceFirst('integer', 'number'),
                ),
              );
            }
            engine.hold = true;
            await deleteMenu(
              tester,
              unused.uri.pathSegments.last,
              review: false,
            );
            await waitFor(tester, () => engine.entered.isCompleted);
            if (behavior.startsWith('external-')) {
              final expected = behavior == 'external-reload'
                  ? 'External reload'
                  : 'number';
              expect(c.buffer!.text, contains(expected));
              final source = find.descendant(
                of: find.byType(SourceEditor),
                matching: find.byType(EditableText),
              );
              expect(
                tester.widget<EditableText>(source).controller.text,
                contains(expected),
              );
            } else if (behavior == 'project-switch') {
              final elsewhere = Directory(
                '${root.parent.parent.path}/replacement',
              )..createSync();
              final other = File('${elsewhere.path}/root.json')
                ..writeAsStringSync(
                  '{"openapi":"3.2.1","info":{"title":"Replacement","version":"1"},"paths":{}}',
                );
              await tester.runAsync(() => c.open(other.path));
              expect(c.project, isNot(same(owner)));
            } else {
              await tester.pumpWidget(const SizedBox.shrink());
            }
            engine.release.complete();
            await waitFor(tester, () => engine.finished.isCompleted);
            if (behavior.startsWith('external-')) {
              await waitFor(
                tester,
                () => find.text('Review file deletion').evaluate().isNotEmpty,
              );
              await button(tester, 'Cancel');
            } else {
              await tester.pump(const Duration(milliseconds: 100));
              expect(find.text('Review file deletion'), findsNothing);
              expect(find.textContaining('refactor.stale'), findsNothing);
            }
            expect(
              unused.readAsBytesSync(),
              behavior == 'external-fragment-reload'
                  ? utf8.encode(
                      utf8.decode(bytes).replaceFirst('integer', 'number'),
                    )
                  : bytes,
            );
            expect(tester.takeException(), isNull);
          }, engine: engine);
        } finally {
          if (!engine.release.isCompleted) engine.release.complete();
        }
      },
    );
  }
}

Future<void> fixture(
  WidgetTester tester,
  String version,
  bool json,
  Future<void> Function(WorkspaceController, File, File) run, {
  EngineProcess? engine,
}) async {
  tester.view.physicalSize = const Size(1400, 1050);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final temp = Directory.systemTemp.createTempSync('busyapi-presence-ui-');
  final api = Directory('${temp.path}/api')..createSync();
  final ext = json ? 'json' : 'yaml',
      root = File('${api.path}/root.${json ? 'json' : 'yaml'}'),
      unused = File('${api.path}/unused.${json ? 'json' : 'yaml'}');
  root.writeAsStringSync(
    json
        ? '{"openapi":"$version","info":{"title":"Files 雪😀","version":"1"},"paths":{}}'
        : '\ufeff# root\r\nopenapi: $version\r\ninfo: {title: "Files 雪😀", version: "1"}\r\npaths: {}',
  );
  unused.writeAsStringSync(
    json ? '{"Value":{"type":"integer","example":9007199254740993}}\r\n' : '\ufeff# exact 雪😀\r\nValue:\r\n  type: integer\r\n  example: 9007199254740993',
  );
  File(
    '${api.path}/busyapi.yaml',
  ).writeAsStringSync('version: 1\nroots: [{name: Main, path: root.$ext}]\n');
  final c = WorkspaceController(
    engine ?? EngineProcess(executable: runtimeNode, helper: runtimeHelper),
    StateLocations(
      config: '${temp.path}/config',
      state: '${temp.path}/state',
      cache: '${temp.path}/cache',
    ),
  );
  try {
    await tester.runAsync(() async {
      await c.initialize();
      await c.open(api.path);
      await c.analyse();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
        child: BusyApiApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(sidebarViewMenu()));
    await tester.pumpAndSettle();
    await run(c, root, unused);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(c.shutdown);
    c.dispose();
    await tester.runAsync(c.engine.close);
    temp.deleteSync(recursive: true);
  }
}
