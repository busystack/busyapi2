import 'dart:async';
import 'dart:io';

import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/app_settings.dart';
import 'package:busyapi/src/app/shortcut_binding.dart';
import 'package:busyapi/src/app/command_registry.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/app/window_control_service.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

import 'widget_io.dart';
import '../packages/busyapi_core/test/test_support.dart';

class _NativeWindow implements NativeWindowController {
  int closes = 0;
  bool prevented = false;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> setPreventClose(bool value) async {
    prevented = value;
  }

  @override
  Future<bool> isFullScreen() async => false;
  @override
  Future<void> setFullScreen(bool value) async {}
  @override
  void addListener(WindowListener listener) {}
  @override
  void removeListener(WindowListener listener) {}
}

class _PendingShutdownWorkspace extends WorkspaceController {
  _PendingShutdownWorkspace(super.engine, super.locations, {this.fail = false});
  final entered = Completer<void>();
  final release = Completer<void>();
  bool fail;

  @override
  Future<void> shutdown() async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
      if (fail) throw StateError('delayed workspace shutdown failure');
    }
    await super.shutdown();
  }
}

void main() {
  setUp(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => <String, Object?>{},
          );
    }
  });
  tearDown(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  testWidgets(
    'F11 a later successful shortcut edit clears an earlier save failure',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync(
        'busyapi-shortcut-new-edit-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: '/unused', helper: '/unused'),
        StateLocations(
          config: '${dir.path}/config',
          state: '${dir.path}/state',
          cache: '${dir.path}/cache',
        ),
      );
      final native = _NativeWindow();
      final ownedWindows = WindowControlService(nativeWindow: native);
      var writes = 0;
      try {
        await tester.runAsync(c.initialize);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              linuxAccentPlatformProvider.overrideWithValue(false),
              windowControlServiceProvider.overrideWith((ref) => ownedWindows),
            ],
            child: BusyApiApp(
              controller: c,
              saveRequestShortcut: (locations, binding) async {
                if (++writes == 1) {
                  throw const FileSystemException('injected failure');
                }
                await BusyApiRequestShortcut.save(locations, binding);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> configure(bool shift) =>
            BusyApiCommandRegistryScope.maybeOf(
              tester.element(find.byType(WorkspaceScreen)),
            )!.configureShortcut!(
              'request-send',
              BusyApiKeyBinding(
                LogicalKeyboardKey.enter,
                control: true,
                shift: shift,
              ),
            );
        await runWidgetIo(
          tester,
          () => expectLater(configure(true), throwsA(isA<CoreFailure>())),
        );
        await runWidgetIo(tester, () => configure(false));
        await runWidgetIo(tester, ownedWindows.requestClose);
        await tester.pumpAndSettle();
        expect(writes, 2);
        expect(native.closes, 1);
        expect(
          find.textContaining('The Send shortcut could not be saved.'),
          findsNothing,
        );
        expect(
          (await tester.runAsync(
            () => BusyApiRequestShortcut.load(c.locations),
          ))!.shift,
          false,
        );
      } finally {
        ownedWindows.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        dir.deleteSync(recursive: true);
      }
    },
  );
  for (final discard in [false, true]) {
    testWidgets(
      'F11 failed shortcut persistence supports ${discard ? 'discard' : 'retry'} through normal Quit',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync(
          'busyapi-shortcut-recovery-',
        );
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${dir.path}/config',
            state: '${dir.path}/state',
            cache: '${dir.path}/cache',
          ),
        );
        final native = _NativeWindow();
        // Use the same observed native owner throughout closing and recovery.
        final ownedWindows = WindowControlService(nativeWindow: native);
        var failing = true, writes = 0;
        try {
          final file = File('${dir.path}/openapi.yaml')
            ..writeAsStringSync(
              "openapi: 3.2.1\ninfo: {title: Quit, version: '1'}\npaths: {}\n",
            );
          await runWidgetIo(tester, () async {
            await c.initialize();
            await c.open(file.path);
            await c.analyse();
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                linuxAccentPlatformProvider.overrideWithValue(false),
                windowControlServiceProvider.overrideWith(
                  (ref) => ownedWindows,
                ),
              ],
              child: BusyApiApp(
                controller: c,
                saveRequestShortcut: (locations, binding) async {
                  writes++;
                  if (failing) {
                    throw const FileSystemException(
                      'injected preference write failure',
                    );
                  }
                  await BusyApiRequestShortcut.save(locations, binding);
                },
              ),
            ),
          );
          await runWidgetIo(tester, c.flush);
          await tester.pumpAndSettle();
          Future<void> configure() =>
              BusyApiCommandRegistryScope.maybeOf(
                tester.element(find.byType(WorkspaceScreen)),
              )!.configureShortcut!(
                'request-send',
                const BusyApiKeyBinding(
                  LogicalKeyboardKey.enter,
                  control: true,
                  shift: true,
                ),
              );
          await runWidgetIo(
            tester,
            () => expectLater(
              configure(),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'settings.shortcut.save',
                ),
              ),
            ),
          );
          await tester.pump();
          expect(writes, 1);
          final modified =
              '${file.readAsStringSync()}# keep this document edit\n';
          c.sourceEdit(file.uri.toString(), modified);
          final closing = ownedWindows.requestClose();
          await runWidgetIo(tester, c.flush);
          await tester.pumpAndSettle();
          // Document protection still precedes preference recovery.
          expect(find.text('Discard shortcut preference'), findsNothing);
          await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Save'));
          await runWidgetIo(tester, () async {
            while (find
                .textContaining('The Send shortcut could not be saved.')
                .evaluate()
                .isEmpty) {
              await Future<void>.delayed(Duration.zero);
            }
          });
          await tester.pumpAndSettle();
          expect(
            find.textContaining('The Send shortcut could not be saved.'),
            findsOneWidget,
          );
          expect(native.closes, 0);
          if (!discard) failing = false;
          await tester.tap(
            find.widgetWithText(
              BusyApiDialogButton,
              discard ? 'Discard shortcut preference' : 'Retry saving shortcut',
            ),
          );
          await runWidgetIo(tester, () => closing);
          await tester.pumpAndSettle();
          expect(native.closes, 1);
          expect(file.readAsStringSync(), modified);
          expect(writes, discard ? 1 : 2);
          final stored = await tester.runAsync(
            () => BusyApiRequestShortcut.load(c.locations),
          );
          expect(stored?.shift, discard ? isNull : true);
          expect(tester.takeException(), null);
        } finally {
          ownedWindows.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          dir.deleteSync(recursive: true);
        }
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'native close ${fail ? 'retains the workspace after a failed' : 'drains every pending'} appearance save',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync(
          'busyapi-close-appearance-',
        );
        final c = WorkspaceController(
          EngineProcess(executable: '/unused', helper: '/unused'),
          StateLocations(
            config: '${dir.path}/config',
            state: '${dir.path}/state',
            cache: '${dir.path}/cache',
          ),
        );
        final native = _NativeWindow();
        final windows = WindowControlService(nativeWindow: native);
        final gates = <Completer<void>>[], saved = <ThemeMode>[];
        try {
          await tester.runAsync(c.initialize);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                linuxAccentPlatformProvider.overrideWithValue(false),
                windowControlServiceProvider.overrideWith((ref) => windows),
              ],
              child: BusyApiApp(
                controller: c,
                saveAppearance: (_, mode) async {
                  final gate = Completer<void>();
                  gates.add(gate);
                  await gate.future;
                  saved.add(mode);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          final screen = tester.widget<WorkspaceScreen>(
            find.byType(WorkspaceScreen),
          );
          final first = screen.setTheme(ThemeMode.dark);
          await tester.pump();
          expect(gates, hasLength(1));
          // Both changes are accepted before closing is committed. The second
          // write cannot start until the first has completed.
          final second = fail ? null : screen.setTheme(ThemeMode.light);
          final close = windows.requestClose();
          await tester.pump();
          expect(native.closes, 0);
          expect(native.prevented, true);
          expect(c.disposed, false);

          if (fail) {
            await runWidgetIo(tester, () async {
              gates.single.completeError(
                StateError('delayed preference failure'),
              );
              await first;
              await close;
            });
            await tester.pumpAndSettle();
            expect(native.closes, 0);
            expect(c.disposed, false);
            expect(
              find.text(
                'Appearance could not be loaded or saved. Select a theme to try saving again.',
              ),
              findsOneWidget,
            );
            final retry = screen.setTheme(ThemeMode.dark);
            await tester.pump();
            await runWidgetIo(tester, () async {
              gates.last.complete();
              await retry;
            });
            await tester.pumpAndSettle();
            expect(
              find.text(
                'Appearance could not be loaded or saved. Select a theme to try saving again.',
              ),
              findsNothing,
            );
            await runWidgetIo(tester, windows.requestClose);
            expect(saved, [ThemeMode.dark]);
          } else {
            await runWidgetIo(tester, () async {
              gates.first.complete();
              await first;
            });
            await tester.pump();
            expect(gates, hasLength(2));
            expect(
              native.closes,
              0,
              reason: 'Closing waits for every preference accepted before commitment',
            );
            expect(c.disposed, false);
            await runWidgetIo(tester, () async {
              gates.last.complete();
              await second!;
              await close;
            });
            expect(saved, [ThemeMode.dark, ThemeMode.light]);
          }
          expect(native.closes, 1);
          expect(native.prevented, false);
          expect(c.disposed, true);
          expect(tester.takeException(), isNull);
        } finally {
          for (final gate in gates) {
            if (!gate.isCompleted) gate.complete();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          if (!c.disposed) await runWidgetIo(tester, c.shutdown);
          c.dispose();
          dir.deleteSync(recursive: true);
        }
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'Settings rejects appearance changes after the drain while shutdown ${fail ? 'fails and restores interaction' : 'is pending'}',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync(
          'busyapi-close-settings-',
        );
        final c = _PendingShutdownWorkspace(
          EngineProcess(executable: '/unused', helper: '/unused'),
          StateLocations(
            config: '${dir.path}/config',
            state: '${dir.path}/state',
            cache: '${dir.path}/cache',
          ),
          fail: fail,
        );
        final native = _NativeWindow();
        final windows = WindowControlService(nativeWindow: native);
        final saved = <ThemeMode>[];
        BusyApiPopupSelector<ThemeMode> theme() =>
            tester.widget(find.byType(BusyApiPopupSelector<ThemeMode>));
        try {
          await tester.runAsync(c.initialize);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                linuxAccentPlatformProvider.overrideWithValue(false),
                windowControlServiceProvider.overrideWith((ref) => windows),
              ],
              child: BusyApiApp(
                controller: c,
                saveAppearance: (_, mode) async => saved.add(mode),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester
              .state<WorkspaceScreenState>(find.byType(WorkspaceScreen))
              .settings();
          await tester.pumpAndSettle();
          final beforeClose = theme();
          beforeClose.onSelected(ThemeMode.dark);
          await tester.pumpAndSettle();
          expect(saved, [ThemeMode.dark]);
          final screen = tester.widget<WorkspaceScreen>(
            find.byType(WorkspaceScreen),
          );
          Object? closeFailure;
          var closeFinished = false;
          final close = windows.requestClose().then<void>(
            (_) => closeFinished = true,
            onError: (Object error) {
              closeFailure = error;
              closeFinished = true;
            },
          );
          await runWidgetIo(tester, () => c.entered.future);
          await tester.pumpAndSettle();
          expect(saved, [ThemeMode.dark]);
          expect(closeFinished, false);
          expect(native.closes, 0);
          expect(native.prevented, true);
          expect(c.disposed, false);
          expect(theme().enabled, false);
          final nativeTheme = tester.widget<BusyApiMenuButton<ThemeMode>>(
            find.descendant(
              of: find.byType(BusyApiPopupSelector<ThemeMode>),
              matching: find.byType(BusyApiMenuButton<ThemeMode>),
            ),
          );
          expect(nativeTheme.enabled, false);
          // A previously captured menu callback and the app-level callback
          // must reject changes too, even before a disabled frame is painted.
          theme().onSelected(ThemeMode.light);
          beforeClose.onSelected(ThemeMode.system);
          await screen.setTheme(ThemeMode.light);
          await tester.pumpAndSettle();
          expect(saved, [ThemeMode.dark]);
          expect(theme().value, ThemeMode.dark);
          expect(closeFinished, false);
          expect(native.closes, 0);
          await runWidgetIo(tester, () async {
            c.release.complete();
            await close;
          });
          await tester.pumpAndSettle();
          if (fail) {
            expect(closeFailure, isStateError);
            expect(c.disposed, false);
            expect(native.closes, 0);
            expect(native.prevented, true);
            expect(theme().enabled, true);
            theme().onSelected(ThemeMode.light);
            await tester.pumpAndSettle();
            expect(saved, [ThemeMode.dark, ThemeMode.light]);
            expect(theme().value, ThemeMode.light);
            await runWidgetIo(tester, windows.requestClose);
          } else {
            expect(closeFailure, isNull);
            expect(saved, [ThemeMode.dark]);
          }
          expect(native.closes, 1);
          expect(c.disposed, true);
          expect(tester.takeException(), isNull);
        } finally {
          if (!c.release.isCompleted) c.release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          if (!c.disposed) await runWidgetIo(tester, c.shutdown);
          c.dispose();
          dir.deleteSync(recursive: true);
        }
      },
    );
  }

  testWidgets('cancelling close keeps Settings appearance usable', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('busyapi-cancel-settings-');
    final c = WorkspaceController(
      EngineProcess(executable: runtimeNode, helper: runtimeHelper),
      StateLocations(
        config: '${dir.path}/config',
        state: '${dir.path}/state',
        cache: '${dir.path}/cache',
      ),
    );
    final native = _NativeWindow();
    final windows = WindowControlService(nativeWindow: native);
    final saved = <ThemeMode>[];
    try {
      await tester.runAsync(() async {
        await c.initialize();
        await Initializer.create(
          destination: '${dir.path}/api',
          title: 'Saved title',
          apiVersion: '1',
        );
        await c.open('${dir.path}/api');
        c.sourceEdit(
          c.active!,
          c.buffer!.text.replaceFirst('Saved title', 'Retained dirty title'),
        );
        await c.analyse();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            linuxAccentPlatformProvider.overrideWithValue(false),
            windowControlServiceProvider.overrideWith((ref) => windows),
          ],
          child: BusyApiApp(
            controller: c,
            saveAppearance: (_, mode) async => saved.add(mode),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester
          .state<WorkspaceScreenState>(find.byType(WorkspaceScreen))
          .settings();
      await tester.pumpAndSettle();
      final close = windows.requestClose();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Cancel'));
      await runWidgetIo(tester, () => close);
      await tester.pumpAndSettle();
      expect(native.closes, 0);
      expect(native.prevented, true);
      expect(c.disposed, false);
      expect(c.buffer!.dirty, true);
      expect(c.buffer!.text, contains('Retained dirty title'));
      final theme = tester.widget<BusyApiPopupSelector<ThemeMode>>(
        find.byType(BusyApiPopupSelector<ThemeMode>),
      );
      expect(theme.enabled, true);
      theme.onSelected(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(saved, [ThemeMode.dark]);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!c.disposed) await runWidgetIo(tester, c.shutdown);
      c.dispose();
      dir.deleteSync(recursive: true);
    }
  });
  for (final fail in [false, true]) {
    testWidgets(
      'F17 Settings admission stays closed during real view persistence fail=$fail',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync(
          'busyapi-close-real-persistence-',
        );
        final entered = Completer<void>(), release = Completer<void>();
        var hold = false;
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${dir.path}/config',
            state: '${dir.path}/state',
            cache: '${dir.path}/cache',
          ),
          viewStateWriter: (path, value) async {
            if (hold) {
              hold = false;
              entered.complete();
              await release.future;
              if (fail) {
                throw StateError('Controlled shutdown persistence failure');
              }
            }
            await writePrivateJson(path, value);
          },
        );
        final native = _NativeWindow(), saved = <ThemeMode>[];
        final windows = WindowControlService(nativeWindow: native);
        BusyApiPopupSelector<ThemeMode> theme() =>
            tester.widget(find.byType(BusyApiPopupSelector<ThemeMode>));
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await Initializer.create(
              destination: '${dir.path}/api',
              title: 'Synthetic shutdown',
              apiVersion: '1',
            );
            await c.open('${dir.path}/api');
            await c.analyse();
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                linuxAccentPlatformProvider.overrideWithValue(false),
                windowControlServiceProvider.overrideWith((ref) => windows),
              ],
              child: BusyApiApp(
                controller: c,
                saveAppearance: (locations, mode) async {
                  saved.add(mode);
                  await BusyApiAppearance.save(locations, mode);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester
              .state<WorkspaceScreenState>(find.byType(WorkspaceScreen))
              .settings();
          await tester.pumpAndSettle();
          final stale = theme();
          stale.onSelected(ThemeMode.dark);
          await runWidgetIo(tester, () async {
            while (saved.isEmpty) {
              await Future<void>.delayed(Duration.zero);
            }
            // Public app flush confirms appearance persistence has finished first.
            await tester
                .widget<WorkspaceScreen>(find.byType(WorkspaceScreen))
                .flushAppearance!();
          });
          expect(
            (await tester.runAsync(() => BusyApiAppearance.load(c.locations)))!
                .mode,
            ThemeMode.dark,
          );
          hold = true;
          Object? failure;
          final closing = windows.requestClose().catchError((Object e) {
            failure = e;
          });
          await runWidgetIo(tester, () => entered.future);
          await tester.pumpAndSettle();
          expect(native.closes, 0);
          expect(theme().enabled, false);
          theme().onSelected(ThemeMode.light);
          stale.onSelected(ThemeMode.system);
          await tester
              .widget<WorkspaceScreen>(find.byType(WorkspaceScreen))
              .setTheme(ThemeMode.light);
          await tester.pumpAndSettle();
          expect(saved, [ThemeMode.dark]);
          expect(theme().value, ThemeMode.dark);
          await runWidgetIo(tester, () async {
            release.complete();
            await closing;
          });
          await tester.pumpAndSettle();
          if (fail) {
            expect(failure, isStateError);
            expect(native.closes, 0);
            expect(c.disposed, false);
            expect(theme().enabled, true);
            theme().onSelected(ThemeMode.light);
            await runWidgetIo(
              tester,
              () => tester
                  .widget<WorkspaceScreen>(find.byType(WorkspaceScreen))
                  .flushAppearance!(),
            );
            await runWidgetIo(tester, windows.requestClose);
            expect(saved, [ThemeMode.dark, ThemeMode.light]);
          } else {
            expect(failure, isNull);
          }
          expect(native.closes, 1);
          final persisted = await tester.runAsync(
            () => BusyApiAppearance.load(c.locations),
          );
          expect(persisted!.mode, fail ? ThemeMode.light : ThemeMode.dark);
          expect(tester.takeException(), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          if (!c.disposed) await runWidgetIo(tester, c.shutdown);
          c.dispose();
          dir.deleteSync(recursive: true);
        }
      },
    );
  }
}
