import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/problems_panel.dart';
import 'package:busyapi/src/workspace/document_status_bar.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _ProgressEngine extends EngineProcess {
  _ProgressEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  bool failed = false;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final gate = release;
    if (method == 'evaluateSchemas' && gate != null) {
      release = null;
      entered!.complete();
      await gate.future;
      if (failed) {
        throw CoreFailure('engine.exit', 'Synthetic schema adapter exit');
      }
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  testWidgets(
    'workspace status remains checking until pending semantic evaluation completes',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in ['yaru_window', 'yaru_window/events']) {
        messenger.setMockMethodCallHandler(
          MethodChannel(name),
          (_) async => <String, Object?>{},
        );
      }
      addTearDown(() {
        for (final name in ['yaru_window', 'yaru_window/events']) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      final dir = Directory.systemTemp.createTempSync(
        'busyapi-progress-status-',
      );
      final engine = _ProgressEngine();
      final c = WorkspaceController(
        engine,
        StateLocations(
          config: '${dir.path}/config',
          state: '${dir.path}/state',
          cache: '${dir.path}/cache',
        ),
      );
      final gate = Completer<void>();
      Future<void>? pending;
      try {
        await tester.runAsync(() async {
          final file = File('${dir.path}/api.json')
            ..writeAsStringSync(
              jsonEncode({
                'openapi': '3.1.2',
                'info': {'title': 'Progress', 'version': '1'},
                'paths': {},
                'components': {
                  'schemas': {
                    'Count': {
                      'type': 'integer',
                      'examples': [1],
                    },
                  },
                },
              }),
            );
          await c.initialize();
          await c.open(file.path);
          await c.analyse();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          engine.entered = Completer<void>();
          engine.release = gate;
          pending = c.analyse();
          await engine.entered!.future.timeout(const Duration(seconds: 8));
        });
        await tester.pumpAndSettle();
        expect(c.checking, false);
        expect(c.checkingSemantics, true);
        expect(c.analysis!['status'], 'checking');
        expect(c.analysis!['complete'], false);
        String summary() => tester
            .widget<BusyApiDocumentStatusBar>(
              find.byType(BusyApiDocumentStatusBar),
            )
            .label;
        expect(summary(), contains('Checking…'));
        expect(summary(), isNot(contains('Complete for captured scope')));
        await tester.runAsync(() async {
          gate.complete();
          await pending!.timeout(const Duration(seconds: 8));
        });
        await tester.pumpAndSettle();
        expect(c.checkingSemantics, false);
        expect(summary(), isNot(contains('Checking…')));
        expect(
          summary(),
          contains(
            c.analysis!['complete'] == true
                ? 'Complete for captured scope'
                : 'Incomplete',
          ),
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await tester.runAsync(() async {
          await pending;
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        dir.deleteSync(recursive: true);
      }
    },
  );
  for (final behavior in ['source', 'failure', 'dispose']) {
    testWidgets(
      'progressive checks $behavior retain the current source and projection owner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-progressive-checks-',
        );
        final file = File('${temp.path}/root.json');
        final value = {
          'openapi': '3.2.1',
          'info': {'title': 'Current', 'version': '1'},
          'paths': {
            '/p': {
              'get': {
                'responses': {
                  '204': {'description': 'Bodyless'},
                },
              },
            },
          },
          'components': {
            'schemas': {
              'Count': {
                'type': 'integer',
                'examples': [1],
              },
            },
          },
        };
        final original = jsonEncode(value);
        file.writeAsStringSync(original);
        final engine = _ProgressEngine();
        final c = WorkspaceController(
          engine,
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        final key = GlobalKey<SourceEditorState>();
        var disposed = false;
        Completer<void>? held;
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            await c.analyse();
          });
          c.layoutState['problemCategory'] = 'openapi';
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
                  builder: (_, _) => Row(
                    children: [
                      Expanded(
                        child: SourceEditor(
                          key: key,
                          buffer: c.buffer!,
                          owner: c.project,
                          changes: c,
                          onEdit: c.sourceDelta,
                          onChanged: (text) => c.sourceEdit(c.active!, text),
                          undo: c.undo,
                          redo: c.redo,
                        ),
                      ),
                      SizedBox(
                        width: 360,
                        child: ProblemsPanel(controller: c, reveal: (_) {}),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          if (behavior == 'failure') {
            c.store!.replace(c.buffer!.id, jsonEncode({...value, 'paths': {}}));
            engine.failed = true;
          }
          late Completer<void> gate;
          late Future<void> pending;
          await tester.runAsync(() async {
            engine.entered = Completer<void>();
            gate = Completer<void>();
            held = gate;
            engine.release = gate;
            pending = c.analyse();
            await engine.entered!.future.timeout(const Duration(seconds: 8));
          });
          await tester.pumpAndSettle();
          expect(c.checking, false);
          expect(c.checkingSemantics, true);
          expect(c.scopeSafe(c.projection!['info']), true);
          expect(c.analysis!['categories']['openapi']['complete'], false);
          expect(find.text('Checking…'), findsOneWidget);
          final projection = c.projection;
          if (behavior == 'source') {
            final input = find.descendant(
              of: find.byType(SourceEditor),
              matching: find.byType(EditableText),
            );
            await tester.runAsync(
              () => tester.enterText(
                input,
                original.replaceFirst('Current', 'Edited during evaluation'),
              ),
            );
            expect(
              c.buffer!.text,
              original.replaceFirst('Current', 'Edited during evaluation'),
            );
            expect(c.checkingSemantics, false);
          } else if (behavior == 'failure') {
            expect(c.projection!['operations'], isEmpty);
          } else {
            await tester.pumpWidget(const SizedBox());
            c.dispose();
            disposed = true;
          }
          await tester.runAsync(() async {
            gate.complete();
            await pending.timeout(const Duration(seconds: 8));
          });
          if (behavior == 'failure') {
            await tester.pumpAndSettle();
            expect(c.analysis!['status'], 'incomplete');
            expect(c.projection, same(projection));
            expect(
              c.projection!['operations'],
              isEmpty,
              reason: 'A failed semantic check cannot resurrect an operation deleted from a current structural projection',
            );
            expect(
              find.textContaining('A failed evaluation is not a clean result'),
              findsOneWidget,
            );
            expect(c.scopeSafe(c.projection!['info']), true);
          } else if (behavior == 'source') {
            await tester.pump();
            await tester.runAsync(
              () => c.analyse().timeout(const Duration(seconds: 8)),
            );
            await tester.pumpAndSettle();
            expect(
              c.projection!['info']['value']['title'],
              'Edited during evaluation',
            );
            expect(
              c.buffer!.text,
              original.replaceFirst('Current', 'Edited during evaluation'),
            );
            expect(c.checkingSemantics, false);
          }
          expect(file.readAsStringSync(), original);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.runAsync(() async {
            final gate = held;
            if (gate != null && !gate.isCompleted) gate.complete();
          });
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(c.shutdown);
          if (!disposed) c.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
