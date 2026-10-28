import '../packages/busyapi_core/test/test_support.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/app/busyapi_toast.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi/src/workspace/api_tree_row.dart';
import 'package:busyapi/src/workspace/workspace_tab_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:busyapi/src/platform/gtk_animation_settings_service.dart';
import 'package:busyapi/src/platform/gtk_window_preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget body) => MaterialApp(
  theme: buildBusyApiTheme(
    brightness: Brightness.light,
    accentColor: Colors.blue,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

class HeldAnalysisEngine extends EngineProcess {
  HeldAnalysisEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? release, entered;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final held = release;
    if (method == 'analyse' && held != null) {
      if (!(entered?.isCompleted ?? true)) entered!.complete();
      await held.future;
    }
    return super.request(method, params, requestId: requestId);
  }
}

class _ObservedSaveController extends WorkspaceController {
  _ObservedSaveController(
    super.engine,
    super.locations,
    this.trace, {
    super.publications,
  });
  final void Function(String) trace;
  @override
  Future<void> saveAll() async {
    trace('save:start');
    try {
      await super.saveAll();
    } finally {
      trace('save:end');
    }
  }

  @override
  Future<bool> flush() async {
    trace('flush:start:$hasPendingFields');
    try {
      return await super.flush();
    } finally {
      trace('flush:end');
    }
  }
}

void main() {
  String? menuChoice;
  testWidgets(
    'Settings opens portable project configuration in the existing Source editor without creating files',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-config-source-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      try {
        await tester.runAsync(() async {
          await Initializer.create(
            destination: '${temp.path}/api',
            title: 'Configuration',
            apiVersion: '1',
          );
          await c.initialize();
          await c.open('${temp.path}/api');
        });
        final root = c.root!,
            config = c.project!.configurationResource!,
            original = File(Uri.parse(config).toFilePath()).readAsBytesSync();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        final screen = tester.state<WorkspaceScreenState>(
          find.byType(WorkspaceScreen),
        );
        late Future<void> settings;
        await tester.runAsync(() async {
          settings = screen.settings();
        });
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-navigation-1')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => tester.tap(
            find.widgetWithText(BusyApiActionRow, 'Open project configuration'),
          ),
        );
        final deadline = Stopwatch()..start();
        while ((c.active != config || c.mode != 'Source') &&
            deadline.elapsed < const Duration(seconds: 12)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.runAsync(() => settings);
        await tester.pumpAndSettle();
        expect(c.active, config);
        expect(c.root, root);
        expect(c.mode, 'Source');
        expect(find.byType(SourceEditor), findsOneWidget);
        expect(c.buffer!.dirty, false);
        expect(
          File(Uri.parse(config).toFilePath()).readAsBytesSync(),
          original,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        await tester.runAsync(c.engine.close);
        temp.deleteSync(recursive: true);
      }
    },
  );
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        'Source notifications retain navigation and update dirty/status and external text $version $format',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-local-source-',
          );
          final engine = HeldAnalysisEngine();
          final c = WorkspaceController(
            engine,
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          try {
            await tester.runAsync(() async {
              await c.initialize();
              await Initializer.create(
                destination: '${temp.path}/api',
                title: 'Original',
                apiVersion: '1',
                openapi: version,
                format: format,
              );
              await c.open('${temp.path}/api');
              await c.analyse();
            });
            c.mode = 'Source';
            c.preview = true;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  linuxAccentPlatformProvider.overrideWithValue(false),
                ],
                child: BusyApiApp(controller: c),
              ),
            );
            // Finish platform appearance startup before measuring Source-only
            // rebuilds. pumpAndSettle alone cannot await real asynchronous streams.
            final container = ProviderScope.containerOf(
              tester.element(find.byType(SourceEditor)),
            );
            await tester.runAsync(() async {
              await container.read(systemAccentColorProvider.future);
              await container.read(gtkAnimationsEnabledProvider.future);
              await container.read(gtkWindowPreferencesProvider.future);
            });
            await tester.pumpAndSettle();
            final navigation = find.ancestor(
              of: find.text('Overview'),
              matching: find.byType(BusyApiTreeRow),
            );
            final originalNavigation = tester.widget(navigation);
            engine.release = Completer<void>();
            final source = find.descendant(
              of: find.byType(SourceEditor),
              matching: find.byType(TextField),
            );
            await tester.runAsync(
              () => tester.enterText(
                source,
                c.buffer!.text.replaceFirst('Original', 'Edited'),
              ),
            );
            await tester.pump();
            expect(tester.widget(navigation), same(originalNavigation));
            expect(
              tester
                  .widget<BusyApiWorkspaceTabButton>(
                    find.byType(BusyApiWorkspaceTabButton),
                  )
                  .dirty,
              isTrue,
            );
            expect(find.textContaining('Problems · Checking'), findsOneWidget);
            // An external Source command must reconcile the still-mounted adapter.
            await tester.runAsync(() async {
              c.sourceEdit(
                c.buffer!.id,
                c.buffer!.text.replaceFirst('Edited', 'External'),
              );
              await c.persist();
            });
            await tester.pump();
            expect(
              tester.widget<TextField>(source).controller!.text,
              contains('External'),
            );
            expect(tester.widget(navigation), same(originalNavigation));
            engine.release!.complete();
            engine.release = null;
            await tester.runAsync(c.analyse);
            await tester.pump();
            expect(find.text('External'), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            if (engine.release != null && !engine.release!.isCompleted) {
              engine.release!.complete();
            }
            engine.release = null;
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
  testWidgets(
    'keyboard Save remains routed after leaving a focused Design field',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-mode-command-');
      final clock = Stopwatch()..start(), trace = <String>[];
      void record(String stage) =>
          trace.add('${clock.elapsedMilliseconds}:$stage');
      final c = _ObservedSaveController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
        record,
        publications: PublicationStore(
          '${temp.path}/state/publication',
          beforeCheckpoint: () async => record('checkpoint'),
          afterPublish: (_) async => record('published'),
        ),
      );
      try {
        await tester.runAsync(() async {
          await c.initialize();
          await Initializer.create(
            destination: '${temp.path}/api',
            title: 'Original',
            apiVersion: '1',
          );
          await c.open('${temp.path}/api');
          await c.analyse();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        final title = find.widgetWithText(TextFormField, 'Title');
        await tester.runAsync(() => tester.enterText(title, 'Changed'));
        await tester.runAsync(() async {
          expect(await c.flush(), true);
          await c.analyse();
        });
        await tester.pump();
        await tester.tap(title);
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: title, matching: find.byType(TextField)),
              )
              .focusNode!
              .hasFocus,
          true,
        );
        menuChoice = 'Source';
        await tester.runAsync(() => tester.tap(find.byTooltip('View mode')));
        await tester.pumpAndSettle();
        expect(find.byType(SourceEditor), findsOneWidget);
        final completed = Completer<void>();
        void observe() {
          if (!c.buffer!.dirty && !completed.isCompleted) {
            completed.complete();
          }
        }

        c.addListener(observe);
        try {
          final saveClock = Stopwatch()..start();
          await tester.runAsync(() async {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          });
          // Platform responses can resume work queued by the binding's fake
          // timers. Keep frames/timers moving while IO runs, as the native
          // application does; the real five-second gate remains unchanged.
          while (!completed.isCompleted &&
              saveClock.elapsed < const Duration(seconds: 5)) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(
            completed.isCompleted,
            true,
            reason:
                'Save did not complete: dirty=${c.buffer?.dirty}, '
                'pending=${c.hasPendingFields}, error=${c.error}, '
                'storage=${c.storageError}, '
                'focus=${FocusManager.instance.primaryFocus?.debugLabel}; trace=$trace',
          );
        } finally {
          c.removeListener(observe);
        }
        expect(File(c.buffer!.path).readAsStringSync(), c.buffer!.text);
        expect(c.buffer!.text, contains('"Changed"'));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'empty native workspace accepts Create shortcut without focusing a control',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-shell-keyboard-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(c.initialize);
      var picks = 0;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(
              controller: c,
              chooseProjectDirectory: () async {
                picks++;
                return temp.path;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(picks, 1);
        expect(
          find.widgetWithText(BusyApiDialogShell, 'Create Project'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(Directory(temp.path).listSync().whereType<File>(), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'mounted Design fields retain focus during delayed undo analysis',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-design-focus-');
      final engine = HeldAnalysisEngine();
      final c = WorkspaceController(
        engine,
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      Future<void>? delayedAnalysis;
      try {
        await tester.runAsync(() async {
          await c.initialize();
          await Initializer.create(
            destination: '${temp.path}/api',
            title: 'Original',
            apiVersion: '1',
          );
          await c.open('${temp.path}/api');
          await c.analyse();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.widgetWithText(TextFormField, 'Title');
        final originalState = tester.state(
          find.widgetWithText(DraftField, 'Title'),
        );
        await tester.runAsync(() => tester.enterText(field, 'Changed'));
        await tester.runAsync(() async {
          expect(await c.flush(), true);
          await c.analyse();
        });
        await tester.pump();
        await tester.tap(field);
        final focus = tester
            .widget<TextField>(
              find.descendant(of: field, matching: find.byType(TextField)),
            )
            .focusNode!;
        expect(focus.hasFocus, true);
        await tester.runAsync(() async {
          engine.release = Completer<void>();
          engine.entered = Completer<void>();
          await c.undo();
          delayedAnalysis = c.analyse();
          await engine.entered!.future.timeout(const Duration(seconds: 5));
        });
        await tester.pump();
        expect(c.checking, true);
        expect(c.buffer!.text, contains('"Original"'));
        expect(field, findsOneWidget);
        expect(
          tester.state(find.widgetWithText(DraftField, 'Title')),
          same(originalState),
        );
        expect(focus.hasFocus, true);
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: field, matching: find.byType(TextField)),
              )
              .readOnly,
          true,
        );
        engine.release!.complete();
        engine.release = null;
        await tester.runAsync(() => delayedAnalysis!);
        await tester.pump();
        expect(
          tester.widget<TextFormField>(field).controller!.text,
          'Original',
        );
        expect(focus.hasFocus, true);
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: field, matching: find.byType(TextField)),
              )
              .readOnly,
          false,
        );
        await tester.runAsync(c.redo);
        await tester.runAsync(c.analyse);
        await tester.pump();
        expect(tester.widget<TextFormField>(field).controller!.text, 'Changed');
        expect(
          tester.state(find.widgetWithText(DraftField, 'Title')),
          same(originalState),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (engine.release != null && !engine.release!.isCompleted) {
          engine.release!.complete();
        }
        engine.release = null;
        if (delayedAnalysis != null) {
          await tester.runAsync(() => delayedAnalysis!);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'focused Design fields route keyboard undo and redo to source history',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-design-keyboard-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Original',
          apiVersion: '1',
        );
        final file = File('${temp.path}/api/openapi.yaml');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            'paths: {}',
            'paths: {"/things": {get: {summary: "Before summary", responses: {"204": {description: "No body"}}}}}',
          ),
        );
        await c.open('${temp.path}/api');
        await c.analyse();
        await c.selectObject(
          Map<String, dynamic>.from(
            (c.projection!['operations'] as List).single,
          ),
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
          child: BusyApiApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      final design = tester.state(find.byType(Designer));
      await tester.runAsync(
        () => tester.enterText(
          find.widgetWithText(TextFormField, 'Summary'),
          'Changed',
        ),
      );
      await tester.runAsync(() async {
        expect(await c.flush(), true);
        await c.analyse();
      });
      await tester.pump();
      // Focus another mounted field with its own empty EditableText history.
      await tester.tap(find.widgetWithText(TextFormField, 'Description'));
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.widgetWithText(TextFormField, 'Description'),
                matching: find.byType(TextField),
              ),
            )
            .focusNode!
            .hasFocus,
        true,
      );
      Future<void> shortcut({bool redo = false}) async {
        await tester.runAsync(() async {
          final before = c.buffer!.generation;
          final completed = Completer<void>();
          void observe() {
            if (c.buffer!.generation > before &&
                !c.checking &&
                c.analysis != null &&
                !completed.isCompleted) {
              completed.complete();
            }
          }

          c.addListener(observe);
          try {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            if (redo) {
              await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
            if (redo) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await completed.future.timeout(const Duration(seconds: 5));
          } finally {
            c.removeListener(observe);
          }
        });
        await tester.pump();
      }

      await shortcut();
      expect(
        (c.projection!['operations'] as List).single['value']['summary'],
        'Before summary',
      );
      expect(c.store!.canRedo, true);
      await shortcut(redo: true);
      expect(
        (c.projection!['operations'] as List).single['value']['summary'],
        'Changed',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Summary'),
            )
            .controller!
            .text,
        'Changed',
      );
      expect(tester.state(find.byType(Designer)), same(design));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
  testWidgets(
    'retained Reference content updates checking, failure and accepted source',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-reference-status-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Original',
          apiVersion: '1',
        );
        await c.open('${temp.path}/api');
        await c.analyse();
      });
      await tester.pumpWidget(
        host(
          ListenableBuilder(
            listenable: c,
            builder: (_, _) => ReferenceView(controller: c, reveal: (_) {}),
          ),
        ),
      );
      expect(find.text('Original'), findsOneWidget);
      await tester.runAsync(() async {
        c.sourceEdit(
          c.active!,
          c.buffer!.text.replaceFirst('Original', 'Accepted'),
        );
      });
      await tester.pump();
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('Checking…'), findsOneWidget);
      expect(
        find.text('Outdated — source cannot currently be interpreted safely'),
        findsOneWidget,
      );
      await tester.runAsync(c.analyse);
      await tester.pump();
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('Original'), findsNothing);
      expect(
        find.text('Outdated — source cannot currently be interpreted safely'),
        findsNothing,
      );
      await tester.runAsync(() async {
        await c.engine.close();
        await c.analyse();
      });
      await tester.pump();
      expect(find.text('Accepted'), findsOneWidget);
      expect(
        find.text('Outdated — source cannot currently be interpreted safely'),
        findsOneWidget,
      );
      expect(find.textContaining('engine.closed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'keyboard Find owns query editing and returns the distant source selection',
    (tester) async {
      const needle = 'distant needle';
      final original = List.generate(
        400,
        (i) => 'field$i: ${i == 350 ? needle : 'value 😀'}\n',
      ).join();
      final b = DocumentBuffer.decode('/tmp/find.yaml', utf8.encode(original));
      final store = BufferStore()..buffers[b.id] = b;
      late StateSetter rebuild;
      var clipboard = needle;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') return {'text': clipboard};
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return SourceEditor(
                buffer: b,
                onChanged: (text) {
                  store.replace(b.id, text);
                  rebuild(() {});
                },
                undo: () {},
                redo: () {},
              );
            },
          ),
        ),
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(TextField)) + const Offset(20, 20),
      );
      Future<void> control(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await control(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      final search = find.widgetWithText(TextField, 'Find in source');
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, true);
      await control(LogicalKeyboardKey.keyV);
      expect(b.text, original);
      expect(tester.widget<TextField>(search).controller!.text, needle);
      await control(LogicalKeyboardKey.keyA);
      await control(LogicalKeyboardKey.keyC);
      expect(clipboard, needle);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(b.selection.base, original.indexOf(needle));
      expect(b.selection.extent, original.indexOf(needle) + needle.length);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(search, findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        true,
      );
      expect(b.text, original);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'overlapping file saves and Save All publish their own selected buffers',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-save-queue-');
      late Completer<void> entered, release;
      var pause = true;
      final published = <String>[];
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
        publications: PublicationStore(
          '${temp.path}/state/publication',
          beforeCheckpoint: () async {
            if (pause) {
              pause = false;
              entered.complete();
              await release.future;
            }
          },
          afterPublish: (id) async => published.add(id),
        ),
      );
      late DocumentBuffer a, b;
      late Future<void> first, second, all;
      await tester.runAsync(() async {
        entered = Completer<void>();
        release = Completer<void>();
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'a',
          apiVersion: '1',
        );
        final file = File('${temp.path}/api/b.yaml')
          ..writeAsStringSync('type: string\n');
        await c.open('${temp.path}/api');
        a = c.buffer!;
        b = await c.project!.buffer(file.uri.toString());
        c.sourceEdit(a.id, a.text.replaceFirst('"a"', '"first"'));
        c.sourceEdit(b.id, 'type: boolean\n');
        first = c.saveBuffers(only: {a.id});
        await entered.future;
        final selection = {b.id};
        second = c.saveBuffers(only: selection);
        selection.clear();
        all = c.saveAll();
        c.sourceEdit(a.id, a.text.replaceFirst('"first"', '"newer"'));
        release.complete();
        await first;
        await second;
        await all;
      });
      expect(File(b.path).readAsStringSync(), 'type: boolean\n');
      expect(File(a.path).readAsStringSync(), contains('"newer"'));
      expect(a.dirty, false);
      expect(b.dirty, false);
      expect(published.where((id) => id == a.id).length, 2);
      expect(published.where((id) => id == b.id).length, 1);
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );

  for (final pendingField in [false, true]) {
    testWidgets(
      'close protection rechecks ${pendingField ? 'pending fields' : 'newer typing'} after a frozen save',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-protect-save-',
        );
        late Completer<void> entered, release;
        var pause = true;
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
          publications: PublicationStore(
            '${temp.path}/state/publication',
            beforeCheckpoint: () async {
              if (pause) {
                pause = false;
                entered.complete();
                await release.future;
              }
            },
          ),
        );
        await tester.runAsync(() async {
          entered = Completer<void>();
          release = Completer<void>();
          await c.initialize();
          await Initializer.create(
            destination: '${temp.path}/api',
            title: 'Saved',
            apiVersion: '1',
          );
          await c.open('${temp.path}/api');
          c.sourceEdit(
            c.active!,
            c.buffer!.text.replaceFirst('Saved', 'First'),
          );
          await c.analyse();
        });
        await tester.pumpWidget(
          ProviderScope(child: BusyApiApp(controller: c)),
        );
        await tester.pumpAndSettle();
        final screen = tester.state<WorkspaceScreenState>(
          find.byType(WorkspaceScreen),
        );
        late Future<bool> protected;
        await tester.runAsync(() async {
          protected = screen.protect();
        });
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Save')),
        );
        await tester.runAsync(() => entered.future);
        await tester.runAsync(() async {
          if (pendingField) {
            c
                .bind(Map<String, dynamic>.from(c.projection!['info']))
                .edit('description', 'Late draft');
          } else {
            c.sourceEdit(
              c.active!,
              c.buffer!.text.replaceFirst('First', 'Late input'),
            );
          }
          release.complete();
          expect(await protected, false);
        });
        expect(File(c.buffer!.path).readAsStringSync(), contains('First'));
        expect(pendingField ? c.hasPendingFields : c.buffer!.dirty, true);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await c.discardDrafts();
          await c.shutdown();
        });
        c.dispose();
        temp.deleteSync(recursive: true);
      },
    );
  }

  testWidgets(
    'temporary Source shape errors cannot crash Reference or inherited Design rows',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-reference-shapes-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      late String original;
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Shapes',
          apiVersion: '1',
          format: 'json',
        );
        await c.open('${temp.path}/api');
        original = c.buffer!.text;
        await c.analyse();
      });
      final cases = <Map<String, Object?>>[
        {'get': 'temporary source scalar'},
        {
          'get': {
            'responses': {
              '200': {
                'description': 'OK',
                'content': {
                  'application/json': {
                    'schema': {
                      'properties': ['temporary'],
                    },
                  },
                },
              },
            },
          },
        },
        {
          'parameters': [false],
          'get': {
            'responses': {
              '200': {'description': 'OK'},
            },
          },
        },
        {
          'parameters': 'temporary',
          'get': {
            'responses': {
              '200': {'description': 'OK'},
            },
          },
        },
        {
          'get': {
            'responses': {
              '200': {
                'description': 'OK',
                'content': {
                  'application/json': {
                    'examples': {'bad': 'temporary'},
                  },
                },
              },
            },
          },
        },
      ];
      for (final pathItem in cases) {
        await tester.pumpWidget(
          host(
            AnimatedBuilder(
              animation: c,
              builder: (_, _) => Row(
                children: [
                  Expanded(
                    child: SourceEditor(
                      buffer: c.buffer!,
                      onChanged: (text) => c.sourceEdit(c.active!, text),
                      undo: () {},
                      redo: () {},
                    ),
                  ),
                  Expanded(
                    child: ReferenceView(controller: c, reveal: (_) {}),
                  ),
                ],
              ),
            ),
          ),
        );
        final text = jsonEncode({
          ...jsonDecode(original) as Map<String, dynamic>,
          'paths': {'/shape': pathItem},
        });
        await tester.runAsync(() async {
          await tester.enterText(
            find.descendant(
              of: find.byType(SourceEditor),
              matching: find.byType(TextField),
            ),
            text,
          );
          await c.analyse();
        });
        expect(c.analysis!['status'], isNot('complete'));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$pathItem');
        final op = Map<String, dynamic>.from(c.projection!['operations'].first);
        await tester.runAsync(() => c.selectObject(op));
        await tester.pumpWidget(
          host(
            Designer(controller: c, run: (f) => unawaited(f()), reveal: (_) {}),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'Design $pathItem');
        expect(c.buffer!.text, text);
        await tester.runAsync(() async {
          c.sourceEdit(c.active!, original);
          await c.analyse();
        });
      }
      expect(c.analysis!['complete'], true);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'an open unrelated fragment refreshes Source and conflict UI without rechecking roots',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-unrelated-refresh-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      late File fragment;
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Unrelated',
          apiVersion: '1',
        );
        fragment = File('${temp.path}/api/notes.yaml')
          ..writeAsStringSync('notes: before\n');
        await c.open('${temp.path}/api');
        await c.analyse();
        await c.openFile(fragment.uri.toString());
      });
      final snapshot = c.analysis!['snapshot'];
      await tester.pumpWidget(
        host(
          AnimatedBuilder(
            animation: c,
            builder: (_, _) => Column(
              children: [
                Text(c.buffer!.externalConflict ? 'CONFLICT' : 'CLEAN'),
                Expanded(
                  child: SourceEditor(
                    buffer: c.buffer!,
                    onChanged: (text) => c.sourceEdit(c.active!, text),
                    undo: () {},
                    redo: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        fragment.writeAsStringSync('notes: after!\n');
        await c.pollDisk();
      });
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'notes: after!\n',
      );
      expect(c.analysis!['snapshot'], snapshot);
      await tester.runAsync(() async {
        c.sourceEdit(c.active!, 'notes: draft\n');
        await c.persist();
        fragment.writeAsStringSync('notes: third\n');
        await c.pollDisk();
      });
      await tester.pump();
      expect(find.text('CONFLICT'), findsOneWidget);
      expect(c.buffer!.text, 'notes: draft\n');
      expect(fragment.readAsStringSync(), 'notes: third\n');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );

  for (final command in ['undo', 'redo', 'discard']) {
    testWidgets(
      '$command completion cannot notify a disposed or replacement workspace',
      (tester) async {
        for (final replace in [false, true]) {
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-command-owner-',
          );
          final c = PersistGateWorkspace(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          await tester.runAsync(() async {
            await c.initialize();
            for (final name in ['a', 'b']) {
              await Initializer.create(
                destination: '${temp.path}/$name',
                title: name,
                apiVersion: '1',
              );
            }
            await c.open('${temp.path}/a');
            c.sourceEdit(
              c.active!,
              c.buffer!.text.replaceFirst('"a"', '"edited"'),
            );
            await c.persist();
            if (command == 'redo') {
              await c.undo();
            }
          });
          late Future<void> pending;
          final old = c.project!;
          await tester.runAsync(() async {
            c.pause();
            pending = switch (command) {
              'undo' => c.undo(),
              'redo' => c.redo(),
              _ => c.discardBuffers(),
            };
            await c.entered!.future;
            if (replace) {
              await c.open('${temp.path}/b');
            } else {
              c.dispose();
            }
          });
          var lateNotifications = 0;
          if (replace) c.addListener(() => lateNotifications++);
          await tester.runAsync(() async {
            c.release!.complete();
            await pending;
          });
          expect(lateNotifications, 0);
          if (replace) {
            expect(c.buffer!.text, contains('"b"'));
            await tester.runAsync(c.shutdown);
            c.dispose();
          } else {
            await tester.runAsync(c.engine.close);
            old.close();
          }
          expect(tester.takeException(), isNull);
          temp.deleteSync(recursive: true);
        }
      },
    );
  }

  testWidgets('typing across a virtual window preserves the accepted input', (
    tester,
  ) async {
    final original =
        List.generate(400, (i) => 'field$i: 😀 value\r\n').join() +
        List.filled(20000, 'x').join();
    final b = DocumentBuffer.decode('/tmp/typing.yaml', [
      239,
      187,
      191,
      ...utf8.encode(original),
    ]);
    final store = BufferStore()..buffers[b.id] = b;
    final key = GlobalKey<SourceEditorState>();
    late StateSetter rebuild;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (_, setState) {
            rebuild = setState;
            return SourceEditor(
              key: key,
              buffer: b,
              onChanged: (text) {
                store.replace(b.id, text);
                rebuild(() {});
              },
              undo: () {
                store.undo();
                rebuild(() {});
              },
              redo: () {
                store.redo();
                rebuild(() {});
              },
            );
          },
        ),
      ),
    );
    Future<void> type(String text) async {
      await tester.tapAt(
        tester.getTopLeft(find.byType(TextField)) + const Offset(20, 20),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await tester.pump();
      expect(b.text, text);
      expect(b.selection.base, text.length);
      expect(b.selection.extent, text.length);
      expect(b.hasBom, true);
      store.undo();
      rebuild(() {});
      await tester.pump();
      expect(b.text, original);
      store.redo();
      rebuild(() {});
      await tester.pump();
      expect(b.text, text);
      store.undo();
      rebuild(() {});
      await tester.pump();
    }

    await type('f');
    await type('\r\n');
    await type('field😀');
    // Retain the unselected prefix and suffix of the slice for a reversed
    // selection spanning a viewport boundary; the actual input is not a diff.
    key.currentState!.select(
      SourceSelection(original.length - 10, 5),
      reveal: false,
    );
    final field = tester.widget<TextField>(find.byType(TextField)).controller!;
    final v = field.value;
    final lo = v.selection.start, hi = v.selection.end;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: v.text.replaceRange(lo, hi, '😀f'),
        selection: TextSelection.collapsed(offset: lo + 3),
      ),
    );
    await tester.pump();
    expect(b.text, original.replaceRange(5, original.length - 10, '😀f'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'whole-document keyboard Cut and Paste share exact source and core history',
    (tester) async {
      var clipboard = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': clipboard};
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final original = List.generate(
        400,
        (i) =>
            'field$i: "non-BMP 😀 and sufficiently long source value to exceed the viewport"${i % 3 == 0 ? '\r\n' : '\n'}',
      ).join();
      final b = DocumentBuffer.decode('/tmp/whole.yaml', [
        239,
        187,
        191,
        ...utf8.encode(original),
      ]);
      final store = BufferStore()..buffers[b.id] = b;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return SourceEditor(
                buffer: b,
                onChanged: (text) {
                  store.replace(b.id, text);
                  rebuild(() {});
                },
                undo: () {
                  store.undo();
                  rebuild(() {});
                },
                redo: () {
                  store.redo();
                  rebuild(() {});
                },
              );
            },
          ),
        ),
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(TextField)) + const Offset(20, 20),
      );
      await tester.pump();
      Future<void> control(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      final visibleBeforeSelectAll = tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text;
      await control(LogicalKeyboardKey.keyA);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        visibleBeforeSelectAll,
      );
      await control(LogicalKeyboardKey.keyX);
      expect(clipboard.length, original.length);
      expect(clipboard, original);
      expect(b.text, '');
      await control(LogicalKeyboardKey.keyV);
      expect(b.text, original);
      expect(b.hasBom, true);
      await control(LogicalKeyboardKey.keyZ);
      expect(b.text, '');
      await control(LogicalKeyboardKey.keyZ);
      expect(b.text, original);
      await control(LogicalKeyboardKey.keyY);
      expect(b.text, '');
      await control(LogicalKeyboardKey.keyY);
      expect(b.text, original);
      await control(LogicalKeyboardKey.keyZ);
      expect(b.text, '');
      await control(LogicalKeyboardKey.keyV);
      expect(b.text, original);
      await control(LogicalKeyboardKey.keyZ);
      expect(b.text, '');
      await control(LogicalKeyboardKey.keyY);
      expect(b.text, original);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mounted Design field acknowledges source updates without user writes or lost selection',
    (tester) async {
      var value = 'Original';
      var writes = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return DraftField(
                label: 'Title',
                value: value,
                onChanged: (_, _) {
                  writes++;
                },
                onCommit: () {},
              );
            },
          ),
        ),
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pump();
      final field = tester.widget<TextFormField>(find.byType(TextFormField));
      field.controller!.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 5,
      );
      final before = writes;
      rebuild(() => value = 'Undone title');
      await tester.pump();
      expect(field.controller!.text, 'Undone title');
      expect(writes, before);
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 2, extentOffset: 5),
      );
    },
  );
  test(
    'flush after actual controller disposal is a non-notifying refusal',
    () async {
      final c = WorkspaceController(
        EngineProcess(executable: '/missing', helper: '/missing'),
        StateLocations(
          config: '/tmp/not-used',
          state: '/tmp/not-used-state',
          cache: '/tmp/not-used-cache',
        ),
      );
      c.dispose();
      expect(await c.flush(), false);
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    menuChoice = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Only the native window boundary is faked; app, forms and engine are real.
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
    messenger.setMockMethodCallHandler(
      const MethodChannel(nativeMenuChannelName),
      (call) async {
        if (call.method != 'show' || menuChoice == null) return null;
        final entries = (call.arguments as Map)['entries'] as List;
        final index = entries.indexWhere((item) => item['label'] == menuChoice);
        expect(index, greaterThanOrEqualTo(0));
        return index;
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
      const MethodChannel(nativeMenuChannelName),
      null,
    );
  });

  testWidgets(
    'cross-window reversed selection, native menu and scrolling operate on the physical source',
    (tester) async {
      var clipboard = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'];
            }
            if (call.method == 'Clipboard.getData') return {'text': clipboard};
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final source = List.generate(
        1000,
        (i) =>
            'field$i: "😀 cross boundary ${'x' * 30}"${i % 2 == 0 ? '\r\n' : '\n'}',
      ).join();
      final b = DocumentBuffer.decode('/tmp/windows.yaml', utf8.encode(source));
      final store = BufferStore()..buffers[b.id] = b;
      final key = GlobalKey<SourceEditorState>();
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return SourceEditor(
                key: key,
                buffer: b,
                onChanged: (text) {
                  store.replace(b.id, text);
                  rebuild(() {});
                },
                undo: () {
                  store.undo();
                  rebuild(() {});
                },
                redo: () {
                  store.redo();
                  rebuild(() {});
                },
              );
            },
          ),
        ),
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(TextField)) + const Offset(20, 20),
      );
      await tester.pump();
      final start = b.lines.offsetForLine(3), end = b.lines.offsetForLine(800);
      key.currentState!.select(SourceSelection(end, start));
      await tester.pump();
      final gesture = tester
          .widgetList<GestureDetector>(find.byType(GestureDetector))
          .firstWhere((g) => g.onSecondaryTapDown != null);
      menuChoice = 'Cut';
      gesture.onSecondaryTapDown!(
        TapDownDetails(globalPosition: const Offset(40, 40)),
      );
      await tester.pumpAndSettle();
      expect(clipboard, source.substring(start, end));
      expect(b.text, source.replaceRange(start, end, ''));
      menuChoice = 'Paste';
      gesture.onSecondaryTapDown!(
        TapDownDetails(globalPosition: const Offset(40, 40)),
      );
      await tester.pumpAndSettle();
      expect(b.text, source);
      store.undo();
      rebuild(() {});
      await tester.pump();
      expect(b.text, source.replaceRange(start, end, ''));
      store.undo();
      rebuild(() {});
      await tester.pump();
      expect(b.text, source);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent * .8);
      await tester.pump();
      final visible = tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text;
      expect(visible.length, lessThanOrEqualTo(16384));
      expect(visible, contains('field800'));
      expect(visible, isNot(contains('field0:')));
      key.currentState!.reveal(b.lines.offsetForLine(900));
      await tester.pump();
      expect(b.selection.extent, b.lines.offsetForLine(900));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        contains('field900'),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(b.selection.extent, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(b.selection.base, 0);
      expect(b.selection.extent, b.text.length);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'late clipboard completion cannot paste into a replacement tab or disposed editor',
    (tester) async {
      late Completer<Map<String, String>> clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') return clipboard.future;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final a = DocumentBuffer.decode(
        '/tmp/clipboard-a.yaml',
        utf8.encode('A'),
      );
      final b = DocumentBuffer.decode(
        '/tmp/clipboard-b.yaml',
        utf8.encode('B'),
      );
      var current = a;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return SourceEditor(
                buffer: current,
                onChanged: (text) => current.update(text),
                undo: () {},
                redo: () {},
              );
            },
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.runAsync(() async {
        clipboard = Completer<Map<String, String>>();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      rebuild(() => current = b);
      await tester.pump();
      await tester.runAsync(() async {
        clipboard.complete({'text': 'late paste'});
      });
      await tester.pump();
      expect(a.text, 'A');
      expect(b.text, 'B');
      await tester.runAsync(() async {
        clipboard = Completer<Map<String, String>>();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        clipboard.complete({'text': 'disposed paste'});
      });
      await tester.pump();
      expect(b.text, 'B');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Design remains mounted through source transactions, undo and reload with newer field input',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-mounted-');
      final engine = GateEngine();
      final c = WorkspaceController(
        engine,
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Original',
          apiVersion: '1',
        );
        await c.open('${temp.path}/api');
        await c.analyse();
      });
      await tester.pumpWidget(
        host(
          AnimatedBuilder(
            animation: c,
            builder: (_, _) => Designer(
              controller: c,
              run: (f) => unawaited(f()),
              reveal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalState = tester.state(find.byType(Designer));
      await tester.runAsync(
        () => tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          'Changed',
        ),
      );
      await tester.runAsync(() async {
        expect(await c.flush(), true);
        await c.analyse();
      });
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Title'))
            .controller!
            .text,
        'Changed',
      );
      await tester.runAsync(() async {
        await c.undo();
        await c.analyse();
      });
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Title'))
            .controller!
            .text,
        'Original',
      );
      await tester.runAsync(() async {
        await c.redo();
        await c.analyse();
      });
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Title'))
            .controller!
            .text,
        'Changed',
      );
      await tester.runAsync(() async {
        c.sourceEdit(
          c.active!,
          c.buffer!.text.replaceFirst('Changed', 'Source'),
        );
        await c.analyse();
      });
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Title'))
            .controller!
            .text,
        'Source',
      );
      await tester.runAsync(() async {
        await c.saveAll();
        File(
          c.buffer!.path,
        ).writeAsStringSync(c.buffer!.text.replaceFirst('Source', 'Reloaded'));
        await c.pollDisk();
        await c.analyse();
      });
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Title'))
            .controller!
            .text,
        'Reloaded',
      );
      await tester.runAsync(() async {
        engine.pause('propose');
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          'First field',
        );
      });
      late Future<bool> first;
      await tester.runAsync(() async {
        first = c.flush();
        await engine.entered!.future;
      });
      await tester.runAsync(
        () => tester.enterText(
          find.widgetWithText(TextFormField, 'API version'),
          '2',
        ),
      );
      await tester.runAsync(() async {
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '2',
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        );
      });
      await tester.pump();
      await tester.runAsync(() async {
        engine.release!.complete();
        await first;
        await c.analyse();
      });
      await tester.pump();
      final newer = tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'API version'),
          )
          .controller!;
      expect(newer.text, '2');
      expect(newer.value.composing.isCollapsed, false);
      expect(c.draft!.pending, true);
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Title'))
            .controller!
            .text,
        'First field',
      );
      await tester.runAsync(() async {
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '2',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
      });
      await tester.runAsync(() async {
        expect(await c.flush(), true);
        await c.analyse();
      });
      await tester.pump();
      expect(c.projection!['info']['value']['version'], '2');
      expect(tester.state(find.byType(Designer)), same(originalState));
      expect(c.projection!['info']['value']['title'], 'First field');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'current scope remains editable beside an invalid resource and advanced schemas remain source-owned',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-scopes-');
      final engine = GateEngine();
      final c = WorkspaceController(
        engine,
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Scopes',
          apiVersion: '1',
        );
        await c.open('${temp.path}/api');
        c.sourceEdit(
          c.active!,
          c.buffer!.text.replaceFirst(
            'paths: {}',
            'paths: { /ok: {get: {responses: {"200": {description: OK, content: {application/json: {schema: false}}}}}}}\ncomponents: {schemas: {Broken: {\$ref: broken.yaml}}}',
          ),
        );
        File('${temp.path}/api/broken.yaml').writeAsStringSync('type: [broken');
        await c.analyse();
      });
      expect(c.analysis!['status'], isNot('complete'));
      expect(c.designSafe, true);
      await tester.pumpWidget(
        host(
          AnimatedBuilder(
            animation: c,
            builder: (_, _) => Designer(
              controller: c,
              run: (f) => unawaited(f()),
              reveal: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          'Safe metadata',
        ),
      );
      await tester.runAsync(() async {
        expect(await c.flush(), true);
        await c.analyse();
      });
      await tester.pump();
      expect(c.projection!['info']['value']['title'], 'Safe metadata');
      final op = Map<String, dynamic>.from(c.projection!['operations'].single);
      await tester.runAsync(() => c.selectObject(op));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        host(ReferenceView(controller: c, reveal: (_) {})),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final oldBuffer = c.buffer!, before = oldBuffer.text;
      await tester.runAsync(() async {
        c.bind(op).bind('summary', '');
        c.draft!.edit('summary', 'Pending');
        await c.persist();
        engine.pause('propose');
      });
      late Future<bool> flushing;
      await tester.runAsync(() async {
        flushing = c.flush();
        await engine.entered!.future;
      });
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await tester.runAsync(() async {
        engine.release!.complete();
        expect(await flushing, false);
        await c.shutdown();
      });
      expect(oldBuffer.text, before);
      expect(tester.takeException(), isNull);
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'view state restores approved resource selection, tabs and caret without changing source',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-viewstate-');
      final locations = StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        locations,
      );
      late String path, partId;
      late List<int> before;
      await tester.runAsync(() async {
        await c.initialize();
        path = await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Views',
          apiVersion: '1',
        );
        File('${temp.path}/api/part.yaml')
            .writeAsStringSync('first\nsecond 😀\nthird\n');
        before = File(path).readAsBytesSync();
        await c.open('${temp.path}/api');
        await c.analyse();
        partId = Uri.file('${temp.path}/api/part.yaml').toString();
        await c.openFile(partId);
        c.buffer!.selection = const SourceSelection(17, 6);
        c.buffer!.scroll = 48;
        c.selectedResource = partId;
        c.selectedPointer = '/definition';
        c.selectedOccurrence = 'retained-occurrence';
        c.mode = 'Source';
        c.preview = true;
        c.layoutState = {'fraction': .64, 'sidebar': false};
        await c.shutdown();
      });
      c.dispose();
      final restored = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        locations,
      );
      await tester.runAsync(() async {
        await restored.initialize();
        await restored.open('${temp.path}/api');
        await restored.analyse();
      });
      expect(restored.active, partId);
      expect(restored.tabs, contains(partId));
      expect(restored.mode, 'Source');
      expect(restored.preview, true);
      expect(restored.selectedResource, partId);
      expect(restored.selectedOccurrence, 'retained-occurrence');
      expect(restored.buffer!.selection.base, 17);
      expect(restored.buffer!.selection.extent, 6);
      expect(restored.buffer!.scroll, 48);
      expect(File(path).readAsBytesSync(), before);
      expect(restored.layoutState['fraction'], .64);
      await tester.runAsync(restored.shutdown);
      restored.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'physical resources and occurrences distinguish identical operation pointers',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-occurrences-');
      File('${temp.path}/busyapi.yaml').writeAsStringSync(
        'version: 1\nroots:\n  - name: a\n    path: a.yaml\n  - name: b\n    path: b.yaml\n',
      );
      for (final name in ['a', 'b']) {
        File('${temp.path}/$name.yaml').writeAsStringSync(
          'openapi: 3.2.1\ninfo: {title: $name, version: "1"}\npaths:\n  /first: {\$ref: first.yaml}\n  /second: {\$ref: second.yaml}\n  /third: {\$ref: second.yaml}\n',
        );
      }
      for (final name in ['first', 'second']) {
        File('${temp.path}/$name.yaml').writeAsStringSync(
          'get: {summary: Identical, responses: {"204": {description: No body}}}\n',
        );
      }
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await c.open(temp.path);
        await c.selectRoot(c.project!.roots.first.id);
        await c.analyse();
      });
      final ops = List<Map<String, dynamic>>.from(c.projection!['operations']);
      expect(ops.map((o) => o['pointer']).toSet(), {'/get'});
      await tester.runAsync(() => c.selectObject(ops[2]));
      expect(c.isSelected(ops[2]), true);
      expect(c.isSelected(ops[1]), false);
      expect(c.isSelected(ops[0]), false);
      await tester.pumpWidget(
        host(
          Designer(controller: c, run: (f) => unawaited(f()), reveal: (_) {}),
        ),
      );
      await tester.pump();
      expect(find.text('get /third'), findsOneWidget);
      await tester.runAsync(() => c.selectRoot(c.project!.roots.last.id));
      await tester.runAsync(c.analyse);
      await tester.runAsync(() => c.selectRoot(c.project!.roots.first.id));
      await tester.runAsync(c.analyse);
      expect(c.selectedOccurrence, ops[2]['occurrence']);
      expect(c.selectedResource, ops[2]['resource']);
      expect(
        c.project!.store.buffers.keys
            .where((id) => id == ops[2]['resource'])
            .length,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'Open owns its progress route even when it completes before the first modal frame',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-fast-open-');
      final c = GateWorkspace(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Open',
          apiVersion: '1',
        );
        c.entered = Completer<void>();
        c.release = Completer<void>();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
          child: BusyApiApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      final screen = tester.state<WorkspaceScreenState>(
        find.byType(WorkspaceScreen),
      );
      late Future<void> opening;
      await tester.runAsync(() async {
        opening = screen.open('${temp.path}/api');
        await c.entered.future;
      });
      // No frame builds the progress subtree before the controlled completion.
      await tester.runAsync(() async {
        c.release.complete();
        await opening.timeout(const Duration(seconds: 2));
      });
      await tester.pumpAndSettle();
      expect(find.byType(BusyApiDialogShell), findsNothing);
      expect(c.project, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'late analysis and disk refresh cannot notify after workspace disposal',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-owner-exit-');
      final engine = GateEngine();
      final c = WorkspaceController(
        engine,
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Lifetime',
          apiVersion: '1',
        );
        await c.open('${temp.path}/api');
        await c.analyse();
        engine.pause('analyse');
      });
      late Future<void> analysis, refresh;
      await tester.runAsync(() async {
        analysis = c.analyse();
        await engine.entered!.future;
        File(c.buffer!.path)
            .writeAsStringSync(c.buffer!.text.replaceFirst('Lifetime', 'Disk'));
        refresh = c.pollDisk();
      });
      c.dispose();
      await tester.runAsync(() async {
        engine.release!.complete();
        await analysis;
        await refresh;
        await c.shutdown();
      });
      expect(tester.takeException(), isNull);
      expect(c.disposed, true);
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'failed shutdown recovery preserves an editable workspace and prior files',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-shutdown-fail-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'Saved',
          apiVersion: '1',
        );
        await c.open('${temp.path}/api');
        await c.analyse();
        File(c.recovery.directory)
            .writeAsStringSync('occupied private boundary');
        c.sourceEdit(
          c.active!,
          c.buffer!.text.replaceFirst('Saved', 'Unsaved'),
        );
        await expectLater(c.shutdown(), throwsA(anything));
        expect(c.disposed, false);
        expect(c.buffer!.text, contains('Unsaved'));
        expect(File(c.buffer!.path).readAsStringSync(), contains('Saved'));
        c.sourceEdit(
          c.active!,
          c.buffer!.text.replaceFirst('Unsaved', 'Retained typing'),
        );
        expect(c.buffer!.text, contains('Retained typing'));
        File(c.recovery.directory).deleteSync();
        await c.shutdown();
      });
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  for (final format in ['yaml', 'json']) {
    for (final (version, mode) in [
      for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
        for (final mode in InitializationMode.values) (version, mode),
    ]) {
      testWidgets(
        'actual Create command installs $format $version ${mode.name} with bundled assets and leaves modes usable',
        (tester) async {
          final temp = Directory.systemTemp.createTempSync('busyapi-create-');
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final parent = Directory('${temp.path}/testapiproject')..createSync();
          var folder = 'api';
          File? foreignManifest;
          if (mode == InitializationMode.standalone && version == '3.0.4') {
            Directory('${parent.path}/api').createSync();
            foreignManifest = File('${parent.path}/api/busyapi.yaml')
              ..writeAsStringSync('foreign: [invalid manifest\n# retained\n');
          }
          final foreignBytes = foreignManifest?.readAsBytesSync();
          // Use the production resolver for a Flutter debug layout and a
          // relocated package layout, including spaces in the bundle path.
          final bundle = format == 'yaml'
              ? '${temp.path}/build/linux/x64/debug/bundle'
              : '${temp.path}/relocated package';
          final assets = Directory('$bundle/libexec/busyapi')
            ..createSync(recursive: true);
          File(runtimeNode).copySync('${assets.path}/node');
          File(runtimeHelper).copySync('${assets.path}/engine.cjs');
          final c = WorkspaceController(
            EngineProcess.bundled(
              applicationExecutable: '$bundle/busyapi-desktop',
            ),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          await tester.runAsync(c.initialize);
          var picks = 0;
          late Completer<void> picked;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
              child: BusyApiApp(
                controller: c,
                chooseProjectDirectory: () async {
                  picks++;
                  picked.complete();
                  return parent.path;
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          final screen = tester.state<WorkspaceScreenState>(
            find.byType(WorkspaceScreen),
          );
          late Future<void> creation;
          await tester.runAsync(() async {
            picked = Completer<void>();
            creation = screen.create();
            await screen
                .create(); // Duplicate command, before picker/form completion.
            await picked.future;
          });
          await tester.pumpAndSettle();
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Title'),
            'test',
          );
          // Exercise the actual grouped choice controls, without replacing the form.
          if (format == 'json') {
            menuChoice = 'json';
            await tester.runAsync(() => tester.tap(find.text('yaml')));
            await tester.pumpAndSettle();
          }
          if (version != '3.1.2') {
            menuChoice = version;
            await tester.runAsync(() => tester.tap(find.text('3.1.2')));
            await tester.pumpAndSettle();
          }
          if (mode == InitializationMode.standalone) {
            menuChoice = 'Contract only';
            await tester.runAsync(
              () => tester.tap(
                find.descendant(
                  of: find.byWidgetPredicate(
                    (widget) =>
                        widget is BusyApiComboRow<String> &&
                        widget.title == 'Create',
                  ),
                  matching: find.text('Project'),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          if (foreignManifest != null) {
            await tester.runAsync(() async {
              tester
                  .widget<BusyApiDialogButton>(
                    find.widgetWithText(BusyApiDialogButton, 'Apply'),
                  )
                  .onPressed!();
            });
            final watch = Stopwatch()..start();
            while (find.textContaining('init.collision').evaluate().isEmpty &&
                watch.elapsed < const Duration(seconds: 20)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(find.textContaining('init.collision'), findsOneWidget);
            expect(foreignManifest.readAsBytesSync(), foreignBytes);
            expect(
              File('${parent.path}/api/openapi.$format').existsSync(),
              false,
            );
            folder = 'new-api';
            await tester.enterText(
              find.widgetWithText(TextFormField, 'Name'),
              folder,
            );
          }
          await tester.runAsync(() async {
            tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(BusyApiDialogButton, 'Apply'),
                )
                .onPressed!();
            await creation;
          });
          // Rebuild the real workspace while the dismissed modal still has fields.
          await tester.pump(const Duration(milliseconds: 20));
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
          expect(picks, 1);
          final files = Directory('${parent.path}/$folder')
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .toSet();
          expect(files, {
            'openapi.$format',
            if (mode == InitializationMode.project) 'busyapi.yaml',
          });
          if (foreignManifest != null) {
            expect(foreignManifest.readAsBytesSync(), foreignBytes);
          }
          expect(
            c.root,
            Uri.file('${parent.path}/$folder/openapi.$format').toString(),
          );
          expect(c.mode, 'Design');
          expect(c.projection!['info']['value']['title'], 'test');
          expect(c.projection!['operations'], isEmpty);
          expect(find.widgetWithText(TextFormField, 'Title'), findsOneWidget);
          final before = File('${parent.path}/$folder/openapi.$format')
              .readAsBytesSync();
          c.setMode('Source');
          await tester.pumpAndSettle();
          expect(find.byType(SourceEditor), findsOneWidget);
          c.setMode('Reference');
          await tester.pumpAndSettle();
          expect(find.byType(ReferenceView), findsOneWidget);
          await tester.runAsync(() async {
            await c.saveAll();
            await c.open(
              mode == InitializationMode.standalone
                  ? '${parent.path}/$folder/openapi.$format'
                  : '${parent.path}/$folder',
            );
            await c.analyse();
          });
          await tester.pumpAndSettle();
          expect(
            File('${parent.path}/$folder/openapi.$format').readAsBytesSync(),
            before,
          );
          expect(c.projection!['operations'], isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        },
      );
    }
  }
  for (final failure in [
    'collision',
    'permissions',
    'helper',
    'runtime',
    'partial',
  ]) {
    testWidgets(
      'Create preserves inputs and files on $failure, then explicit retry or cancel',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-create-failure-',
        );
        final parent = Directory('${temp.path}/testapiproject')..createSync();
        final destination = Directory('${parent.path}/api')..createSync();
        final contract = File('${destination.path}/openapi.yaml');
        final manifest = File('${destination.path}/busyapi.yaml');
        const original =
            'openapi: "3.1.2"\ninfo:\n  title: "test"\n  version: "1.0.0"\npaths: {}\n';
        const configuration =
            'version: 1\nroots:\n  - name: main\n    path: openapi.yaml\n';
        if (failure == 'collision') {
          contract.writeAsStringSync(original);
          manifest.writeAsStringSync(configuration);
        } else if (failure == 'permissions') {
          privatePermissions(
            destination.path,
            320,
          ); // An owned temporary directory, 0500.
        }
        final helper = failure == 'helper'
            ? '${temp.path}/helper/engine.cjs'
            : runtimeHelper;
        final runtime = failure == 'runtime'
            ? '${temp.path}/runtime/node'
            : runtimeNode;
        final c = WorkspaceController(
          EngineProcess(executable: runtime, helper: helper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        await tester.runAsync(c.initialize);
        late Completer<void> picked;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(
              controller: c,
              initializerBoundary: failure == 'partial'
                  ? (path) async {
                      if (path.endsWith('busyapi.yaml')) {
                        File(path).writeAsStringSync('concurrent manifest');
                      }
                    }
                  : null,
              chooseProjectDirectory: () async {
                picked.complete();
                return parent.path;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final screen = tester.state<WorkspaceScreenState>(
          find.byType(WorkspaceScreen),
        );
        late Future<void> creation;
        await tester.runAsync(() async {
          picked = Completer<void>();
          creation = screen.create();
          await picked.future;
        });
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(find.text('API title is required'), findsOneWidget);
        await tester.runAsync(
          () => tester.enterText(
            find.widgetWithText(TextFormField, 'Title'),
            'test',
          ),
        );
        await tester.runAsync(
          () => tester.enterText(
            find.widgetWithText(TextFormField, 'API version'),
            '',
          ),
        );
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(find.text('API version is required'), findsOneWidget);
        expect(contract.existsSync(), failure == 'collision');
        await tester.runAsync(
          () => tester.enterText(
            find.widgetWithText(TextFormField, 'API version'),
            '1.0.0',
          ),
        );
        await tester.runAsync(() async {
          final callback = tester
              .widget<BusyApiDialogButton>(
                find.widgetWithText(BusyApiDialogButton, 'Apply'),
              )
              .onPressed!;
          await Function.apply(callback, const []);
        });
        await waitForUi(
          tester,
          find.textContaining(
            failure == 'collision'
                ? 'init.collision'
                : failure == 'permissions'
                ? 'Permission denied'
                : failure == 'partial'
                ? 'init.partial'
                : 'Project created at',
          ),
        );
        expect(
          tester
              .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'Title'),
              )
              .controller!
              .text,
          'test',
        );
        BusyApiToastOverlay.show(
          screen.context,
          message: 'File outcome retained',
          duration: const Duration(milliseconds: 400),
        );
        if (failure == 'partial') {
          expect(contract.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), 'concurrent manifest');
          final stat = contract.statSync();
          await tester.runAsync(() => tester.tap(find.text('Apply')));
          await tester.pumpAndSettle();
          expect(find.textContaining('init.partial'), findsOneWidget);
          expect(contract.statSync().modified, stat.modified);
          await tester.runAsync(() async {
            tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(BusyApiDialogButton, 'Cancel'),
                )
                .onPressed!();
            await creation;
          });
          await tester.pumpAndSettle();
          expect(contract.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), 'concurrent manifest');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
          return;
        }
        if (failure == 'collision') {
          expect(contract.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), configuration);
          await tester.runAsync(
            () => tester.enterText(
              find.widgetWithText(TextFormField, 'Name'),
              'corrected',
            ),
          );
        } else if (failure == 'permissions') {
          expect(contract.existsSync(), false);
          expect(manifest.existsSync(), false);
          privatePermissions(destination.path, 448);
        } else {
          expect(contract.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), configuration);
          expect(c.analysis, isNull);
          expect(c.error, contains('engine.assets'));
          expect(find.text('Retry Opening'), findsOneWidget);
          expect(c.error, contains(failure == 'helper' ? helper : runtime));
          final contractBefore = contract.statSync();
          final manifestBefore = manifest.statSync();
          File(helper).parent.createSync(recursive: true);
          File(runtime).parent.createSync(recursive: true);
          if (failure == 'helper') File(runtimeHelper).copySync(helper);
          if (failure == 'runtime') File(runtimeNode).copySync(runtime);
          await tester.runAsync(() async {
            await tester.tap(find.text('Retry Opening'));
            await creation;
          });
          await tester.pumpAndSettle();
          expect(contract.statSync().modified, contractBefore.modified);
          expect(manifest.statSync().modified, manifestBefore.modified);
        }
        if (failure != 'helper' && failure != 'runtime') {
          await tester.runAsync(() async {
            await tester.tap(find.text('Apply'));
            await creation;
          });
        }
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(c.analysis!['status'], 'complete');
        if (failure != 'collision') {
          expect(contract.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), configuration);
        }
        final published = parent.listSync().map((entry) => entry.path).toList();
        await tester.runAsync(() async {
          picked = Completer<void>();
          creation = screen.create();
          await picked.future;
        });
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextFormField, 'Title').last);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.runAsync(() => creation);
        expect(
          parent.listSync().map((entry) => entry.path).toList(),
          published,
        );
        expect(find.text('Create Project'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      },
    );
  }
  for (final format in ['yaml', 'json']) {
    for (final version in ['3.1.2', '3.2.1']) {
      testWidgets(
        'shared owned authoring forms and native modes share undo $format $version',
        (tester) async {
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-owned-form-',
          );
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          await tester.runAsync(() async {
            await c.initialize();
            await Initializer.create(
              destination: '${temp.path}/api',
              title: 'test',
              apiVersion: '1',
              openapi: version,
              format: format,
            );
            await c.open('${temp.path}/api');
            await c.analyse();
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
              child: BusyApiApp(controller: c),
            ),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(WorkspaceScreen));
          Map<String, dynamic> operation() => Map<String, dynamic>.from(
            (c.projection!['operations'] as List).single,
          );
          Future<void> form(
            Future<void> Function() show,
            Map<String, String> inputs, {
            String action = 'Apply',
            bool review = false,
            String reviewTitle = 'Review operation relocation',
          }) async {
            late Future<void> pending;
            // Analyses use the real packaged engine outside FakeAsync.
            late Completer<void> opened;
            void check() {
              if (c.form != null && !opened.isCompleted) opened.complete();
            }

            c.addListener(check);
            try {
              await tester.runAsync(() async {
                opened = Completer<void>();
                pending = show();
                await opened.future;
              });
            } finally {
              c.removeListener(check);
            }
            await tester.pumpAndSettle();
            expect(c.form, isNotNull);
            for (final input in inputs.entries) {
              await tester.runAsync(
                () => tester.enterText(
                  find.descendant(
                    of: find.byType(BusyApiDialogShell),
                    matching: find.widgetWithText(TextFormField, input.key),
                  ),
                  input.value,
                ),
              );
            }
            final beforeReview = c.buffer!.text;
            await tester.runAsync(() async {
              tester
                  .widget<BusyApiDialogButton>(
                    find.widgetWithText(BusyApiDialogButton, action),
                  )
                  .onPressed!();
              if (!review) await pending;
            });
            if (review) {
              Future<void> framesUntil(bool Function() ready) async {
                final clock = Stopwatch()..start();
                await tester.pump();
                while (!ready() && clock.elapsed < const Duration(seconds: 8)) {
                  await tester.runAsync(
                    () =>
                        Future<void>.delayed(const Duration(milliseconds: 20)),
                  );
                  await tester.pump(const Duration(milliseconds: 20));
                }
                expect(
                  ready(),
                  true,
                  reason:
                      'The current reviewed action must finish: $reviewTitle; '
                      'error=${c.error}; storage=${c.storageError}; form=${c.form?.kind}; '
                      'status=${tester.widgetList<BusyApiStatusBox>(find.byType(BusyApiStatusBox)).map((box) => box.message).toList()}',
                );
              }

              await framesUntil(
                () => find.text(reviewTitle).evaluate().isNotEmpty,
              );
              expect(
                find.byType(BusyApiDialogShell),
                findsOneWidget,
                reason: 'Review starts only after the capture route exits',
              );
              expect(
                c.buffer!.text,
                beforeReview,
                reason: 'Capture and review must not mutate source',
              );
              var finished = false;
              await tester.runAsync(() async {
                pending.then((_) => finished = true);
              });
              await tester.runAsync(
                () => tester.tap(
                  find.widgetWithText(BusyApiDialogButton, 'Apply'),
                ),
              );
              await framesUntil(() => finished);
              await tester.runAsync(c.analyse);
            }
            await tester.pump(const Duration(milliseconds: 20));
            expect(tester.takeException(), isNull);
            await tester.pumpAndSettle();
            expect(c.form, isNull);
            expect(c.formApplying, false);
          }

          final baseline = c.buffer!.text;
          await form(() => addOperation(context, c), {'Path': '/items'});
          expect(operation()['method'], 'get');
          expect(operation()['value'], isEmpty); // No invented response/body.
          await tester.runAsync(c.undo);
          await tester.pump();
          expect(c.buffer!.text, baseline);
          await tester.runAsync(() async {
            await c.redo();
            await c.analyse();
          });
          await form(() => moveOperation(context, c, operation()), {
            'Path': '/renamed',
          }, review: true);
          expect(c.buffer!.text, contains('/renamed'));
          // Reviewed transactions schedule their projection refresh.
          await tester.runAsync(c.analyse);
          expect(operation()['path'], '/renamed');
          final moved = c.buffer!.text;
          await form(() => addOperation(context, c), {
            'Path': '/cancelled',
          }, action: 'Cancel');
          expect(c.buffer!.text, moved);
          await form(() => editResponse(context, c, operation(), null), {
            'Status': '204',
            'Description': 'No body',
          });
          expect(
            operation()['value']['responses']['204'].containsKey('content'),
            false,
          );
          final bodyless = c.buffer!.text;
          await form(() => editResponse(context, c, operation(), '204'), {});
          expect(c.buffer!.text, bodyless);
          await form(() => editResponse(context, c, operation(), '204'), {
            'Description': 'Changed only',
          });
          expect(operation()['value']['responses']['204'], {
            'description': 'Changed only',
          });
          await form(
            () => editResponse(context, c, operation(), '204'),
            {'Status': '205'},
            review: true,
            reviewTitle: 'Review refactoring',
          );
          expect(operation()['value']['responses']['205'], {
            'description': 'Changed only',
          });
          await tester.runAsync(() async {
            await c.undo();
            await c.analyse();
          });
          await tester.pump();
          expect(operation()['value']['responses']['204'], {
            'description': 'Changed only',
          });
          await tester.runAsync(() async {
            await c.redo();
            await c.analyse();
          });
          await tester.pump();
          expect(operation()['value']['responses']['205'], {
            'description': 'Changed only',
          });
          await form(
            () => editResponse(context, c, operation(), '205'),
            {},
            action: 'Remove',
            review: true,
            reviewTitle: 'Review object deletion',
          );
          // Remove the empty response container so the following no-body assertion remains exact.
          await tester.runAsync(() async {
            await c.mutate(operation(), [
              {
                'kind': 'remove',
                'pointer': '${operation()['pointer']}/responses',
              },
            ]);
          });
          await tester.pump();

          await form(() => editParameter(context, c, operation(), null), {
            'Name': 'q',
          });
          expect(operation()['value']['parameters'][0]['name'], 'q');
          final withParameter = c.buffer!.text;
          await form(() => editParameter(context, c, operation(), 0), {
            'Name': 'discarded',
          }, action: 'Cancel');
          expect(c.buffer!.text, withParameter);
          await form(
            () => editParameter(context, c, operation(), 0),
            {},
            action: 'Remove',
            review: true,
            reviewTitle: 'Review object deletion',
          );
          expect(operation()['value']['parameters'], isEmpty);
          await form(() => editResponse(context, c, operation(), null), {
            'Description': 'OK',
            'Media type': 'application/json',
          });
          final beforeResponseCancel = c.buffer!.text;
          await form(() => editResponse(context, c, operation(), '200'), {
            'Description': 'Discarded response',
          }, action: 'Cancel');
          expect(c.buffer!.text, beforeResponseCancel);
          await form(
            () => editProperty(
              context,
              c,
              operation(),
              '200',
              'application/json',
              null,
            ),
            {'Name': 'id'},
          );
          final beforePropertyCancel = c.buffer!.text;
          await form(
            () => editProperty(
              context,
              c,
              operation(),
              '200',
              'application/json',
              'id',
            ),
            {'Name': 'Discarded property'},
            action: 'Cancel',
          );
          expect(c.buffer!.text, beforePropertyCancel);
          await form(
            () =>
                editExample(context, c, operation(), '200', 'application/json'),
            {'Example': '{"id":"actual"}'},
          );
          expect(
            operation()['value']['responses']['200']['content']['application/json']['example']['id'],
            'actual',
          );
          final authored = c.buffer!.text;
          expect(c.analysis!['status'], 'complete');
          c.setMode('Reference');
          await tester.pumpAndSettle();
          // The canonical Reference projection is now requested lazily from
          // the real helper. Keep driving frames and IO; pumpAndSettle alone
          // does not await worker completion. The same full example must still
          // appear inline, without navigating through object details.
          final referenceDeadline = Stopwatch()..start();
          final referenceExample = find.descendant(
            of: find.byType(ReferenceView),
            matching: find.textContaining('actual'),
          );
          while (referenceExample.evaluate().isEmpty &&
              referenceDeadline.elapsed < const Duration(seconds: 5)) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(referenceExample, findsOneWidget);
          c.setMode('Design');
          await tester.pumpAndSettle();
          await form(
            () =>
                editExample(context, c, operation(), '200', 'application/json'),
            {'Example': '{bad'},
            action: 'Cancel',
          );
          expect(c.buffer!.text, authored);
          await form(
            () =>
                editExample(context, c, operation(), '200', 'application/json'),
            {},
            action: 'Remove',
          );
          await form(
            () => editProperty(
              context,
              c,
              operation(),
              '200',
              'application/json',
              'id',
            ),
            {},
            action: 'Remove',
            review: true,
            reviewTitle: 'Review object deletion',
          );
          await form(
            () => editResponse(context, c, operation(), '200'),
            {},
            action: 'Remove',
            review: true,
            reviewTitle: 'Review object deletion',
          );
          expect(operation()['value']['responses'], isEmpty);
          c.setMode('Source');
          await tester.pumpAndSettle();
          final input = find.descendant(
            of: find.byType(SourceEditor),
            matching: find.byType(TextField),
          );
          await tester.runAsync(
            () => tester.enterText(
              input,
              authored.replaceFirst('"test"', '"Source title"'),
            ),
          );
          await tester.runAsync(c.analyse);
          await tester.pumpAndSettle();
          expect(c.buffer!.dirty, true);
          c.setMode('Reference');
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(ReferenceView),
              matching: find.text('Source title'),
            ),
            findsOneWidget,
          );
          await tester.runAsync(() async {
            await c.undo();
            await c.analyse();
          });
          await tester.pumpAndSettle();
          expect(c.projection!['info']['value']['title'], 'test');
          await tester.runAsync(() async {
            await c.redo();
            await c.analyse();
            await c.saveAll();
            await c.open('${temp.path}/api');
            await c.analyse();
          });
          await tester.pumpAndSettle();
          expect(c.projection!['info']['value']['title'], 'Source title');
          expect(c.analysis!['status'], 'complete');
          expect(c.buffer!.dirty, false);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        },
      );
    }
  }
  testWidgets(
    'a delayed directory choice cannot replace a newer workspace or create files after host removal',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-stale-create-');
      final parent = Directory('${temp.path}/testapiproject')..createSync();
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/other',
          title: 'Other',
          apiVersion: '2',
        );
      });
      late Completer<String?> directory;
      late Completer<void> pickerStarted;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
          child: BusyApiApp(
            controller: c,
            chooseProjectDirectory: () {
              pickerStarted.complete();
              return directory.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final screen = tester.state<WorkspaceScreenState>(
        find.byType(WorkspaceScreen),
      );
      late Future<void> creation;
      await tester.runAsync(() async {
        directory = Completer<String?>();
        pickerStarted = Completer<void>();
        creation = screen.create();
        await pickerStarted.future;
        await c.open('${temp.path}/other');
        await c.analyse();
        directory.complete(parent.path);
        await creation;
      });
      await tester.pumpAndSettle();
      expect(c.project!.location, '${temp.path}/other');
      expect(parent.listSync(), isEmpty);
      expect(find.text('Create Project'), findsNothing);
      await tester.runAsync(() async {
        directory = Completer<String?>();
        pickerStarted = Completer<void>();
        creation = screen.create();
        await pickerStarted.future;
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        directory.complete(parent.path);
        await creation;
        await c.shutdown();
      });
      expect(parent.listSync(), isEmpty);
      expect(tester.takeException(), isNull);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'removing a dialog host retains its owned draft without publishing or cancelling',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-modal-draft-');
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${temp.path}/api',
          title: 'test',
          apiVersion: '1',
        );
        await c.open('${temp.path}/api');
        await c.analyse();
      });
      late BuildContext context;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (value) {
              context = value;
              return const Text('Workspace');
            },
          ),
        ),
      );
      var calls = 0;
      unawaited(
        editForm(
          context,
          'Owned form',
          const [FormFieldSpec('title', 'Title')],
          {'title': 'test'},
          controller: c,
          target: Map<String, dynamic>.from(c.projection!['info']),
          kind: 'test.owned',
          onApply: (_) async {
            calls++;
          },
        ),
      );
      await tester.pumpAndSettle();
      final owner = c.form!;
      final baseline = c.buffer!.text;
      await tester.runAsync(
        () => tester.enterText(find.byType(TextFormField), 'Retained draft'),
      );
      await tester.runAsync(c.persist);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(c.form, same(owner));
      expect(owner.values['title'], 'Retained draft');
      expect(c.buffer!.text, baseline);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'source input, gutter and undo share the core transaction history',
    (tester) async {
      final store = BufferStore();
      final b = DocumentBuffer.decode(
        '/tmp/a.yaml',
        utf8.encode('info:\n  title: original\n'),
      );
      store.buffers[b.id] = b;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SourceEditor(
                buffer: b,
                onChanged: (text) {
                  store.replace(b.id, text);
                  rebuild(() {});
                },
                undo: () {
                  store.undo();
                  rebuild(() {});
                },
                redo: () {
                  store.redo();
                  rebuild(() {});
                },
              );
            },
          ),
        ),
      );
      expect(find.text('1'), findsOneWidget);
      final unchangedLineNumber = tester.widget<Text>(find.text('1'));
      final sourceSurface = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(SourceEditor),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (sourceSurface.decoration as BoxDecoration).color,
        BusyApiSurfaceColors.of(tester.element(find.byType(SourceEditor))).view,
      );
      final sourceField = tester.widget<TextField>(find.byType(TextField));
      expect(
        sourceField.decoration!.contentPadding,
        BusyApiInsets.sourceEditor,
      );
      expect(sourceField.decoration!.isCollapsed, isTrue);
      expect(sourceField.decoration!.filled, isFalse);
      expect(sourceField.cursorWidth, BusyApiStroke.sourceCursor);
      expect(
        tester.getCenter(find.text('1')).dx,
        closeTo(
          tester.getTopLeft(find.byType(SourceEditor)).dx +
              BusyApiSizes.sourceGutterWidth / 2,
          .01,
        ),
      );
      await tester.enterText(
        find.byType(TextField),
        'info:\n  title: edited\n',
      );
      // Keep the caret's logical line unchanged while checking geometry reuse.
      // Changing the active line deliberately changes its number presentation.
      sourceField.controller!.selection = const TextSelection.collapsed(
        offset: 0,
      );
      await tester.pump();
      expect(b.dirty, true);
      expect(b.text, contains('edited'));
      expect(tester.widget<Text>(find.text('1')), same(unchangedLineNumber));
      sourceField.controller!.selection = const TextSelection.collapsed(
        offset: 9,
      );
      await tester.pump();
      final colors = BusyApiSurfaceColors.of(
        tester.element(find.byType(SourceEditor)),
      );
      expect(
        tester.widget<Text>(find.text('2')).style!.color,
        colors.foreground,
      );
      expect(
        tester.widget<Text>(find.text('1')).style!.color,
        colors.mutedForeground,
      );
      store.undo();
      rebuild(() {});
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        b.text,
      );
      expect(b.dirty, false);
      store.redo();
      rebuild(() {});
      await tester.pump();
      expect(b.text, contains('edited'));
    },
  );
  testWidgets('pending overview fields use one captured source target', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('busyapi-widget-');
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    final c = WorkspaceController(
      engine,
      StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      ),
    );
    await tester.runAsync(() async {
      await c.initialize();
      await Initializer.create(
        destination: '${temp.path}/api',
        title: 'Original',
        apiVersion: '1',
      );
      await c.open('${temp.path}/api');
      await c.analyse();
    });
    await tester.pumpWidget(
      host(
        Designer(
          controller: c,
          run: (f) {
            unawaited(f());
          },
          reveal: (_) {},
        ),
      ),
    );
    await tester.runAsync(
      () => tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Draft title',
      ),
    );
    await tester.runAsync(
      () => tester.enterText(
        find.widgetWithText(TextFormField, 'API version'),
        '2',
      ),
    );
    expect(c.draft!.pending, true);
    await tester.runAsync(() async {
      expect(await c.flush(), true);
    });
    await tester.pump();
    expect(c.buffer!.text, contains('Draft title'));
    expect(c.buffer!.text, contains('"2"'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(c.shutdown);
    c.dispose();
    temp.deleteSync(recursive: true);
  });
  testWidgets(
    'Source delta reuses core acceptance and reconciles a rejected edit',
    (tester) async {
      const original = 'title: "😀 original"\r\npaths: {}\n';
      final b = DocumentBuffer.decode(
        '/tmp/accepted.yaml',
        utf8.encode(original),
      );
      final store = BufferStore()..buffers[b.id] = b;
      final key = GlobalKey<SourceEditorState>();
      var reject = true;
      await tester.pumpWidget(
        host(
          SourceEditor(
            key: key,
            buffer: b,
            onChanged: (_) => fail('Delta must use the core'),
            onEdit: (edit) {
              if (reject) {
                throw CoreFailure('edit.stale', 'Captured edit rejected');
              }
              store.apply([edit]);
            },
            undo: store.undo,
            redo: store.redo,
          ),
        ),
      );
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump();
      key.currentState!.select(const SourceSelection(12, 12));
      final controller = tester.widget<TextField>(field).controller!;
      controller.value = controller.value.copyWith(
        text: controller.text.replaceRange(12, 12, 'x'),
        selection: const TextSelection.collapsed(offset: 13),
      );
      expect(tester.takeException(), isA<CoreFailure>());
      expect(b.text, original);
      expect(controller.text, original);
      expect(b.selection.base, 12);
      reject = false;
      controller.value = controller.value.copyWith(
        text: controller.text.replaceRange(12, 12, 'x'),
        selection: const TextSelection.collapsed(offset: 13),
      );
      await tester.pump();
      expect(b.text, original.replaceRange(12, 12, 'x'));
      expect(controller.text, b.text);
      store.undo();
      await tester.pump();
      expect(b.text, original);
      store.redo();
      await tester.pump();
      expect(b.text, original.replaceRange(12, 12, 'x'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a 1 MiB or 5 MiB source only lays out a bounded text window', (
    tester,
  ) async {
    for (final bytes in [1024 * 1024, 5 * 1024 * 1024]) {
      final text = List.filled(
        bytes ~/ 64,
        '  property: {type: string, description: representative fixture}\n',
      ).join();
      final b = DocumentBuffer.decode('/tmp/large.yaml', utf8.encode(text));
      final timings = <int>[];
      final store = BufferStore()..buffers[b.id] = b;
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SourceEditor(
                buffer: b,
                onEdit: (edit) {
                  store.apply([edit], label: 'Source');
                  rebuild(() {});
                },
                onChanged: (t) {
                  store.replace(b.id, t);
                  rebuild(() {});
                },
                undo: () {},
                redo: () {},
              );
            },
          ),
        ),
      );
      await tester.pump();
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      expect(controller.text.length, lessThan(20000));
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        await tester.enterText(
          find.byType(TextField),
          '# $i\n${controller.text}',
        );
        await tester.pump();
        watch.stop();
        timings.add(watch.elapsedMicroseconds);
      }
      timings.sort();
      debugPrint(
        'DEBUG WIDGET input/layout fixtureBytes=${utf8.encode(text).length} p95_us=${timings[(timings.length * .95).ceil() - 1]} (not a native release measurement)',
      );
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets(
    'syntax composing underline intersects token colors and UTF-16 ranges',
    (tester) async {
      final controller = SyntaxController()..json = true;
      addTearDown(controller.dispose);
      const text = '{"name": "😀é", "count": 12}';
      await tester.pumpWidget(host(TextField(controller: controller)));
      final context = tester.element(find.byType(TextField));
      const style = TextStyle(fontSize: 14, height: 1.6, color: Colors.black);
      controller.value = const TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: 13),
      );
      final baseline = controller.buildTextSpan(
        context: context,
        style: style,
        withComposing: true,
      );
      for (final range in [
        const TextRange(start: 10, end: 13),
        const TextRange(start: 3, end: 20),
        const TextRange(start: 0, end: 0),
        TextRange.empty,
      ]) {
        controller.value = controller.value.copyWith(composing: range);
        final span = controller.buildTextSpan(
          context: context,
          style: style,
          withComposing: true,
        );
        expect(span.toPlainText(), text);
        final before = spanUnits(baseline), after = spanUnits(span);
        for (var i = 0; i < text.length; i++) {
          expect(
            after[i].color,
            before[i].color,
            reason: 'Syntax color at UTF-16 unit $i',
          );
          expect(after[i].fontSize, before[i].fontSize);
          expect(after[i].height, before[i].height);
          expect(
            after[i].decoration == TextDecoration.underline,
            range.isValid &&
                !range.isCollapsed &&
                i >= range.start &&
                i < range.end,
          );
        }
        expect(
          spanUnits(
            controller.buildTextSpan(
              context: context,
              style: style,
              withComposing: false,
            ),
          ).any((v) => v.decoration == TextDecoration.underline),
          false,
        );
      }
      final untrusted = UntrustedSyntaxController()..json = true;
      addTearDown(untrusted.dispose);
      for (final range in [
        const TextRange(start: -1, end: 3),
        const TextRange(start: 4, end: 2),
        const TextRange(start: 1, end: 100),
      ]) {
        untrusted.presented = TextEditingValue(text: text, composing: range);
        final span = untrusted.buildTextSpan(
          context: context,
          style: style,
          withComposing: true,
        );
        expect(span.toPlainText(), text);
        expect(
          spanUnits(span).any((v) => v.decoration == TextDecoration.underline),
          false,
        );
      }
    },
  );

  testWidgets(
    'Source retains IM range through mounted rebuild and defers editing keys to IM',
    (tester) async {
      final b = DocumentBuffer.decode(
        '/tmp/composing.yaml',
        utf8.encode('title: "AB"\r\n'),
      );
      final store = BufferStore()..buffers[b.id] = b;
      final key = GlobalKey<SourceEditorState>();
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setState) {
              rebuild = setState;
              return SourceEditor(
                key: key,
                buffer: b,
                onChanged: (text) => store.replace(b.id, text),
                onEdit: (edit) => store.apply([edit], label: 'Source'),
                undo: store.undo,
                redo: store.redo,
              );
            },
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'title: "ABu"\r\n',
          selection: TextSelection.collapsed(offset: 11),
          composing: TextRange(start: 10, end: 11),
        ),
      );
      await tester.pump();
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      final generation = b.generation;
      expect(controller.value.composing, const TextRange(start: 10, end: 11));
      // A composing range change without a text change must update presentation.
      tester.testTextInput.updateEditingValue(
        controller.value.copyWith(
          composing: const TextRange(start: 9, end: 11),
        ),
      );
      await tester.pump();
      expect(b.generation, generation);
      key.currentState!.select(const SourceSelection(11, 11));
      rebuild(() {});
      await tester.pump();
      expect(controller.value.composing, const TextRange(start: 9, end: 11));
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(
        spanUnits(editable.renderEditable.text! as TextSpan)
            .where((v) => v.decoration == TextDecoration.underline)
            .length,
        2,
      );
      // Focus returns false to the native IM, rather than consuming a no-op.
      var handled = await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(handled, false);
      expect(b.text, 'title: "ABu"\r\n');
      handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(handled, false);
      // Simulated cancellation is a protocol test, not the real-IME gate.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'title: "AB"\r\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();
      expect(b.text, 'title: "AB"\r\n');
      expect(controller.value.composing, TextRange.empty);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(b.text, 'title: "A"\r\n');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old native client cannot edit a replacement Source owner at the same URI',
    (tester) async {
      final oldBuffer = DocumentBuffer.decode(
        '/tmp/client.yaml',
        utf8.encode('title: "AB"\n'),
      );
      final newBuffer = DocumentBuffer.decode(
        '/tmp/client.yaml',
        utf8.encode('title: "CD"\n'),
      );
      final store = BufferStore()..buffers[oldBuffer.id] = oldBuffer;
      var active = oldBuffer;
      var owner = Object();
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (_, setter) {
              rebuild = setter;
              return SourceEditor(
                buffer: active,
                owner: owner,
                onChanged: (_) => fail('Use the core transaction adapter'),
                onEdit: (edit) => store.apply([edit]),
                undo: store.undo,
                redo: store.redo,
              );
            },
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      int client() =>
          (tester.testTextInput.log
                          .lastWhere(
                            (call) => call.method == 'TextInput.setClient',
                          )
                          .arguments
                      as List)
                  .first
              as int;
      final previousClient = client();
      rebuild(() {
        active = newBuffer;
        owner = Object();
        store.buffers[newBuffer.id] = newBuffer;
      });
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(client(), isNot(previousClient));
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/textinput',
        const JSONMethodCodec().encodeMethodCall(
          MethodCall('TextInputClient.updateEditingState', [
            previousClient,
            const TextEditingValue(
              text: 'title: "ABx"\n',
              selection: TextSelection.collapsed(offset: 10),
            ).toJSON(),
          ]),
        ),
        (_) {},
      );
      await tester.pump();
      expect(oldBuffer.text, 'title: "AB"\n');
      expect(newBuffer.text, 'title: "CD"\n');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        newBuffer.text,
      );
      expect(newBuffer.generation, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final format in ['yaml', 'json']) {
    testWidgets(
      'large $format composition retains its window and cannot attach to another resource',
      (tester) async {
        final padding = List.filled(70000, 'padding 😀e\u0301\r\n').join();
        final original = format == 'yaml'
            ? 'title: "AB"\r\ndescription: |\n$padding'
            : jsonEncode({'title': 'AB', 'description': padding});
        final b = DocumentBuffer.decode(
          '/tmp/preedit-large.$format',
          utf8.encode(original),
        );
        expect(b.bytes().length, greaterThan(1024 * 1024));
        final store = BufferStore()..buffers[b.id] = b;
        final key = GlobalKey<SourceEditorState>();
        var active = b;
        late StateSetter rebuild;
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (_, setState) {
                rebuild = setState;
                return SourceEditor(
                  key: key,
                  buffer: active,
                  onChanged: (text) => store.replace(active.id, text),
                  onEdit: (edit) => store.apply([edit], label: 'Source'),
                  undo: store.undo,
                  redo: store.redo,
                );
              },
            ),
          ),
        );
        final offset = original.length - 10;
        key.currentState!.select(SourceSelection(offset, offset));
        await tester.pump();
        await tester.tap(find.byType(TextField));
        key.currentState!.select(SourceSelection(offset, offset));
        await tester.pump();
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        final old = controller.value;
        expect(old.text.length, lessThanOrEqualTo(16384));
        const preedit = '😀e\u0301';
        final local = old.selection.extentOffset;
        tester.testTextInput.updateEditingValue(
          old.copyWith(
            text: old.text.replaceRange(local, local, preedit),
            selection: TextSelection.collapsed(offset: local + preedit.length),
            composing: TextRange(start: local, end: local + preedit.length),
          ),
        );
        await tester.pump();
        expect(b.text, original.replaceRange(offset, offset, preedit));
        final accepted = controller.value;
        rebuild(() {});
        await tester.pump();
        expect(controller.value, accepted);
        expect(
          spanUnits(
            tester
                    .state<EditableTextState>(find.byType(EditableText))
                    .renderEditable
                    .text!
                as TextSpan,
          ).where((unit) => unit.decoration == TextDecoration.underline).length,
          preedit.length,
        );
        final generation = b.generation;
        key.currentState!.select(const SourceSelection(0, 0));
        await tester.pump();
        expect(controller.value.composing, TextRange.empty);
        expect(b.generation, generation);
        expect(b.text, original.replaceRange(offset, offset, preedit));
        // Explicit navigation changes the native editing coordinate space;
        // an ordinary rebuild of that same window does not.
        key.currentState!.select(
          SourceSelection(offset + preedit.length, offset + preedit.length),
        );
        await tester.pump();
        final extent = controller.selection.extentOffset;
        tester.testTextInput.updateEditingValue(
          controller.value.copyWith(
            composing: TextRange(start: extent - preedit.length, end: extent),
          ),
        );
        await tester.pump();
        // Even identical source in a new physical resource cannot inherit the
        // previous input client's presentation ownership.
        active = DocumentBuffer.decode(
          '/tmp/other.$format',
          utf8.encode(b.text),
        );
        active.selection = b.selection;
        store.buffers[active.id] = active;
        rebuild(() {});
        await tester.pump();
        expect(controller.value.composing, TextRange.empty);
        expect(active.text, b.text);
        store.undo();
        expect(b.text, original);
        expect(active.text, original.replaceRange(offset, offset, preedit));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a minified single line is windowed at a distant Unicode caret without changing source',
    (tester) async {
      final text = List.filled(100000, '😀x').join();
      final b = DocumentBuffer.decode('/tmp/minified.json', utf8.encode(text));
      b.selection = SourceSelection(240000, 240000);
      await tester.pumpWidget(
        host(
          SourceEditor(buffer: b, onChanged: (_) {}, undo: () {}, redo: () {}),
        ),
      );
      await tester.pump();
      final visible = tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text;
      expect(visible.length, lessThanOrEqualTo(16384));
      expect(utf8.decode(utf8.encode(visible)), visible);
      expect(b.text, text);
      expect(b.dirty, false);
    },
  );
}

// Let real filesystem/helper completions run, then inspect actual painted errors.
// No form, route, initializer or buffer transaction is replaced by this helper.
Future<void> waitForUi(WidgetTester tester, Finder finding) async {
  for (var i = 0; i < 100 && finding.evaluate().isEmpty; i++) {
    await tester.runAsync(() async {
      for (var turn = 0; turn < 20; turn++) {
        await Future<void>(() {});
      }
    });
    await tester.pump();
  }
  expect(finding, findsWidgets);
  expect(tester.takeException(), isNull);
}

class GateEngine extends EngineProcess {
  GateEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  String? gate;
  Completer<void>? entered, release;
  void pause(String method) {
    gate = method;
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == gate) {
      gate = null;
      entered!.complete();
      await release!.future;
    }
    return result;
  }
}

class PersistGateWorkspace extends WorkspaceController {
  PersistGateWorkspace(super.engine, super.locations);
  Completer<void>? entered, release;
  bool _pause = false;
  void pause() {
    _pause = true;
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<void> persist() async {
    final wait = _pause;
    _pause = false;
    await super.persist();
    if (wait) {
      entered!.complete();
      await release!.future;
    }
  }
}

class GateWorkspace extends WorkspaceController {
  GateWorkspace(super.engine, super.locations);
  late Completer<void> entered, release;
  @override
  Future<void> open(
    String path, {
    bool Function()? cancelled,
    Map<String, dynamic>? recovering,
  }) async {
    await super.open(path, cancelled: cancelled, recovering: recovering);
    entered.complete();
    await release.future;
  }
}

List<TextStyle> spanUnits(
  TextSpan span, [
  TextStyle inherited = const TextStyle(),
]) {
  final style = inherited.merge(span.style);
  return [
    for (var i = 0; i < (span.text?.length ?? 0); i++) style,
    for (final child in span.children ?? const <InlineSpan>[])
      ...spanUnits(child as TextSpan, style),
  ];
}

class UntrustedSyntaxController extends SyntaxController {
  TextEditingValue presented = TextEditingValue.empty;
  @override
  TextEditingValue get value => presented;
}
