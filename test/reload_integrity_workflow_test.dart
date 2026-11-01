import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _DecisionGate extends WorkspaceController {
  _DecisionGate(super.engine, super.locations);
  bool duringRead = false;
  final entered = Completer<void>(), release = Completer<void>();
  BufferReloadResult? result;
  @override
  Future<BufferReloadResult> reloadFromDisk(
    BufferReloadCapture accepted, {
    Future<void> Function()? beforeReload,
  }) async {
    if (!duringRead) {
      entered.complete();
      await release.future;
    }
    return result = await super.reloadFromDisk(
      accepted,
      beforeReload: () async {
        if (duringRead) {
          entered.complete();
          await release.future;
        }
        await beforeReload?.call();
      },
    );
  }
}

class _RetirementGate extends RecoveryStore {
  _RetirementGate(super.directory);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> retireIfCurrent(String id, bool Function() current) async {
    entered.complete();
    await release.future;
    await super.retireIfCurrent(id, current);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final heldInput in ['source', 'form']) {
    testWidgets(
      heldInput == 'source'
          ? 'R01 Use Disk captures its accepted draft before dialog continuation'
          : 'R01-B Use Disk retains a newly typed compact response form',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1000);
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
        final temp = Directory.systemTemp.createTempSync('busyapi-reload-ui-');
        final c = _DecisionGate(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        )..duringRead = heldInput == 'form';
        Future<void> waitFor(bool Function() ready) async {
          final timer = Stopwatch()..start();
          await tester.pump();
          while (!ready() && timer.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            ready(),
            true,
            reason:
                'form=${c.form?.kind} error=${c.error} entered=${c.entered.isCompleted} conflict=${c.buffer?.externalConflict}',
          );
          await tester.pump();
        }

        try {
          await tester.runAsync(() async {
            final file = await Initializer.create(
              destination: '${temp.path}/api',
              title: 'Original',
              apiVersion: '1',
            );
            if (heldInput == 'form') {
              await File(file).writeAsString(
                'openapi: 3.2.1\ninfo: {title: Original, version: "1"}\npaths: {"/pets": {get: {responses: {"200": {description: before}}}}}\n',
              );
            }
            await c.initialize();
            await c.open(file);
            c.sourceEdit(
              c.active!,
              c.buffer!.text.replaceFirst('Original', 'Draft'),
            );
            await c.persist();
            File(file).writeAsStringSync(
              c.buffer!.baseline.replaceFirst('Original', 'Disk'),
            );
            await c.project!.refreshDisk(c.buffer!);
            await c.analyse();
            if (heldInput == 'form') {
              c.setMode('Design');
              await c.selectObject(
                Map<String, dynamic>.from(
                  (c.projection!['operations'] as List).single,
                ),
              );
            }
          });
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: WorkspaceScreen(
                    controller: c,
                    themeMode: ThemeMode.light,
                    setTheme: (_) async {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          late Future<void> conflict;
          await tester.runAsync(() async {
            conflict = tester
                .state<WorkspaceScreenState>(find.byType(WorkspaceScreen))
                .resolveConflict();
          });
          await waitFor(
            () => find
                .widgetWithText(
                  BusyApiDialogButton,
                  'Discard draft and load disk',
                )
                .evaluate()
                .isNotEmpty,
          );
          await tester.runAsync(() async {
            tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(
                    BusyApiDialogButton,
                    'Discard draft and load disk',
                  ),
                )
                .onPressed!();
          });
          await waitFor(() => c.entered.isCompleted);
          var persisted = false, finished = false;
          final generation = c.buffer!.generation;
          if (heldInput == 'source') {
            await tester.runAsync(() async {
              c.sourceEdit(
                c.active!,
                c.buffer!.text.replaceFirst('Draft', 'Later'),
              );
            });
          } else {
            await waitFor(
              () => find.byType(BusyApiDialogShell).evaluate().isEmpty,
            );
            await tester.pumpAndSettle();
            final row = find.widgetWithText(BusyApiActionRow, '200');
            await waitFor(() => row.evaluate().isNotEmpty);
            await tester.runAsync(() => tester.ensureVisible(row));
            await tester.runAsync(() => tester.tap(row));
            await waitFor(() => c.form != null);
            await tester.pumpAndSettle();
            await tester.runAsync(
              () => tester.enterText(
                find.descendant(
                  of: find.byType(BusyApiDialogShell),
                  matching: find.widgetWithText(TextFormField, 'Description'),
                ),
                'Late form',
              ),
            );
            expect(c.form!.pending, true);
            expect(c.buffer!.generation, generation);
          }
          await tester.runAsync(() async {
            c.persist().then((_) => persisted = true);
          });
          await waitFor(() => persisted);
          await tester.runAsync(() async {
            c.release.complete();
            conflict.then((_) => finished = true);
          });
          await waitFor(() => finished);
          expect(c.result!.status, BufferReloadStatus.stale);
          if (heldInput == 'source') {
            expect(c.buffer!.text, contains('Later'));
          } else {
            c.form!.verify(c.buffer!, c.root!);
            await tester.runAsync(c.analyse);
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            await waitFor(
              () => c.form == null && c.buffer!.text.contains('Late form'),
            );
            expect(c.buffer!.text, contains('Late form'));
          }
          expect(c.buffer!.externalConflict, true);
          expect(c.store!.canUndo, true);
        } finally {
          if (!c.release.isCompleted) c.release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          await tester.runAsync(c.engine.close);
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
  test(
    'R01 input after reload applies survives delayed recovery retirement',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-reload-cleanup-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final recovery = _RetirementGate('${temp.path}/recovery');
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
        recovery: recovery,
      );
      addTearDown(() async {
        if (!recovery.release.isCompleted) recovery.release.complete();
        await c.shutdown();
        c.dispose();
        await c.engine.close();
      });
      final file = await Initializer.create(
        destination: '${temp.path}/api',
        title: 'Original',
        apiVersion: '1',
      );
      await c.initialize();
      await c.open(file);
      c.sourceEdit(c.active!, c.buffer!.text.replaceFirst('Original', 'Draft'));
      await c.persist();
      final pending = c.reloadFromDisk(c.project!.captureReload(c.buffer!));
      await recovery.entered.future;
      c.sourceEdit(c.active!, c.buffer!.text.replaceFirst('Original', 'Later'));
      await c.persist();
      recovery.release.complete();
      expect((await pending).status, BufferReloadStatus.applied);
      final records = await Directory(recovery.directory)
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .toList();
      final retained =
          jsonDecode(await File(records.single.path).readAsString()) as Map;
      expect(retained['text'], contains('Later'));
      expect(retained['generation'], c.buffer!.generation);
      expect(c.store!.canUndo, true);
    },
  );

  test('R01 project replacement cannot inherit an old reload or recovery retirement', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-reload-switch-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final c = WorkspaceController(
      EngineProcess(executable: runtimeNode, helper: runtimeHelper),
      StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      ),
    );
    addTearDown(() async {
      await c.shutdown();
      c.dispose();
      await c.engine.close();
    });
    final first = await Initializer.create(
          destination: '${temp.path}/a',
          title: 'First',
          apiVersion: '1',
        ),
        second = await Initializer.create(
          destination: '${temp.path}/b',
          title: 'Second',
          apiVersion: '1',
        );
    await c.initialize();
    await c.open(first);
    final old = c.buffer!;
    c.sourceEdit(old.id, old.text.replaceFirst('First', 'Draft'));
    await c.persist();
    final entered = Completer<void>(), release = Completer<void>();
    final pending = c.reloadFromDisk(
      c.project!.captureReload(old),
      beforeReload: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    await c.open(second);
    c.sourceEdit(c.active!, c.buffer!.text.replaceFirst('Second', 'New draft'));
    await c.persist();
    final generation = c.buffer!.generation;
    release.complete();
    expect((await pending).status, BufferReloadStatus.stale);
    expect(old.text, contains('Draft'));
    expect(c.buffer!.text, contains('New draft'));
    expect(c.buffer!.generation, generation);
    expect(c.store!.canUndo, true);
    final records = await Directory(c.recovery.directory)
        .list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .asyncMap(
          (f) async => jsonDecode(await File(f.path).readAsString()) as Map,
        )
        .toList();
    expect(
      records.any(
        (r) => r['id'] == c.buffer!.id && r['text'] == c.buffer!.text,
      ),
      true,
    );
  });
  for (final phase in ['read', 'cleanup']) {
    for (final kind in ['form', 'property']) {
      test(
        'R01-B $kind input during reload $phase retains applicability and recovery',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-form-reload-',
          );
          final retirement = _RetirementGate('${temp.path}/recovery');
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
            recovery: phase == 'cleanup' ? retirement : null,
          );
          final entered = Completer<void>(), release = Completer<void>();
          Future<BufferReloadResult>? pending;
          try {
            final file = File('${temp.path}/openapi.yaml');
            await file.writeAsString(
              'openapi: 3.2.1\ninfo: {title: Original, version: "1"}\npaths: {"/pets": {get: {responses: {"200": {description: before}}}}}\n',
            );
            await c.initialize();
            await c.open(file.path);
            c.sourceEdit(
              c.active!,
              c.buffer!.text.replaceFirst('Original', 'Draft'),
            );
            await c.persist();
            await file.writeAsString(
              c.buffer!.baseline.replaceFirst('Original', 'Disk'),
            );
            final owner = c.project!, b = c.buffer!, root = c.root!;
            Map<String, dynamic> item = Map.from(
              await owner.inspectObject(root, b.id, '/paths/~1pets/get'),
            );
            final capture = owner.captureReload(b);
            pending = c.reloadFromDisk(
              capture,
              beforeReload: phase == 'read'
                  ? () async {
                      entered.complete();
                      await release.future;
                    }
                  : null,
            );
            if (phase == 'read') {
              await entered.future;
            } else {
              await retirement.entered.future;
              item = Map.from(
                await owner.inspectObject(root, b.id, '/paths/~1pets/get'),
              );
            }
            final generation = b.generation;
            if (kind == 'form') {
              c
                  .beginForm(
                    'response',
                    item,
                    {'status': '200'},
                    {'status': '200', 'description': 'before', 'media': ''},
                  )
                  .edit('description', 'Late form');
            } else {
              c.bind(item)
                ..bind('description', 'before')
                ..edit('description', 'Late form');
            }
            await c.persist();
            expect(b.generation, generation);
            release.complete();
            if (!retirement.release.isCompleted) retirement.release.complete();
            final result = await pending;
            expect(
              result.status,
              phase == 'read'
                  ? BufferReloadStatus.stale
                  : BufferReloadStatus.applied,
            );
            if (kind == 'form') c.form!.verify(b, root);
            final records = await Directory(c.recovery.directory)
                .list()
                .where((e) => e is File && e.path.endsWith('.json'))
                .asyncMap(
                  (e) async =>
                      jsonDecode(await File(e.path).readAsString()) as Map,
                )
                .toList();
            expect(
              records.any((r) => jsonEncode(r).contains('Late form')),
              true,
            );
            if (kind == 'form') {
              await c.analyse();
              expect(c.scopeSafe(item), true);
              final form = c.form!;
              await c.applyForm(
                form,
                () => c.mutate(item, [
                  {
                    'kind': 'set',
                    'pointer': '${item['pointer']}/responses/200/description',
                    'value': 'Late form',
                  },
                ]),
              );
              expect(b.text, contains('Late form'));
            }
          } finally {
            if (!release.isCompleted) release.complete();
            if (!retirement.release.isCompleted) retirement.release.complete();
            await pending;
            await c.shutdown();
            c.dispose();
            await c.engine.close();
            await temp.delete(recursive: true);
          }
        },
      );
    }
  }
}
