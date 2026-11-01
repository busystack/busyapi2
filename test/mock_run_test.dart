import 'dart:async';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/mock_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _MockSnapshotGate extends EngineProcess {
  _MockSnapshotGate() : super(executable: runtimeNode, helper: runtimeHelper);
  String? root;
  Completer<void> entered = Completer<void>(), release = Completer<void>();
  void arm(String value) {
    root = value;
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
    if (root != null && method == 'analyse' && params['root'] == root) {
      root = null;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  for (final preparing in [false, true]) {
    testWidgets(
      'different-version project roots retire native mock captures ${preparing ? 'during preparation' : 'after preparation'}',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-mock-roots-widget-',
        );
        final a = File('${temp.path}/a.yaml'), b = File('${temp.path}/b.json');
        const first =
            'openapi: 3.0.4\ninfo: {title: A, version: "1"}\npaths: {"/data": {get: {requestBody: {required: true, content: {application/json: {schema: {type: string}}}}, responses: {204: {description: Empty}}}}}\n';
        const second =
            '{"swagger":"2.0","info":{"title":"B","version":"1"},"consumes":["application/json"],"paths":{"/data":{"get":{"parameters":[{"name":"payload","in":"body","required":true,"schema":{"type":"string"}}],"responses":{"204":{"description":"Empty"}}}}}}';
        a.writeAsStringSync(first);
        b.writeAsStringSync(second);
        File('${temp.path}/busyapi.yaml').writeAsStringSync(
          'version: 1\nroots: [{name: a, path: a.yaml}, {name: b, path: b.json}]\n',
        );
        final engine = _MockSnapshotGate();
        final workspace = WorkspaceController(
          engine,
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        final mock = MockRunController(workspace);
        try {
          await tester.runAsync(() async {
            await workspace.initialize();
            await workspace.open(temp.path);
            expect(workspace.project!.roots.length, 2);
            expect(await workspace.selectRoot(a.uri.toString()), true);
            await mock.prepare();
          });
          expect(mock.phase, 'ready');
          expect(mock.plan!.snapshot.root, a.uri.toString());
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: MockRunPanel(controller: mock)),
            ),
          );
          await tester.pumpAndSettle();
          for (final (file, family) in [
            (b, '2.0'),
            (a, '3.0'),
            (b, '2.0'),
            (a, '3.0'),
          ]) {
            final previous = mock.plan!;
            Future<void>? pending;
            if (preparing) {
              await tester.runAsync(() async {
                engine.arm(previous.root);
                pending = mock.prepare();
                await engine.entered.future;
              });
            }
            await tester.runAsync(() async {
              expect(await workspace.selectRoot(file.uri.toString()), true);
            });
            await tester.pumpAndSettle();
            if (preparing) {
              engine.release.complete();
              await tester.runAsync(() => pending!);
              await tester.pumpAndSettle();
            }
            expect(mock.phase, 'idle');
            expect(mock.plan, isNull);
            expect(mock.run, isNull);
            expect(find.text('Start Mock'), findsNothing);
            await tester.runAsync(
              () => expectLater(
                previous.start(
                  nodeExecutable: '${temp.path}/absent-node',
                  helper: '${temp.path}/absent-helper',
                ),
                throwsA(
                  isA<CoreFailure>().having(
                    (failure) => failure.code,
                    'code',
                    'mock.closed',
                  ),
                ),
              ),
            );
            await tester.runAsync(mock.prepare);
            await tester.pumpAndSettle();
            expect(mock.phase, 'ready');
            expect(mock.plan!.snapshot.root, file.uri.toString());
            expect(
              mock.plan!.analysis['projection']['specification']['family'],
              family,
            );
          }
          expect(a.readAsStringSync(), first);
          expect(b.readAsStringSync(), second);
        } finally {
          if (!engine.release.isCompleted) engine.release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          mock.dispose();
          await tester.runAsync(workspace.shutdown);
          workspace.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
  for (final (before, after) in [('3.0.4', '3.1.2'), ('3.1.2', '3.2.1')]) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$format Source $before to $after disables stale native mock starts and retains the draft',
        (tester) async {
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-mock-version-widget-',
          );
          final file = File('${temp.path}/api.$format');
          final json =
              '{"openapi":"$before","info":{"title":"Native mock","version":"api-version"},"paths":{"/data":{"get":{"requestBody":{"required":true,"content":{"application/json":{"schema":{"type":"string"}}}},"responses":{"204":{"description":"Empty"}}}}},"x-number":9007199254740993.00}';
          final original = format == 'yaml'
              ? '# Keep original 雪\r\n$json\r\n'
              : json;
          file.writeAsStringSync(original);
          final workspace = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final mock = MockRunController(workspace);
          try {
            await tester.runAsync(() async {
              await workspace.initialize();
              await workspace.open(file.path);
              await mock.prepare();
            });
            expect(mock.phase, 'ready');
            expect(mock.plan, isNotNull);
            expect(mock.outdated, false);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(body: MockRunPanel(controller: mock)),
              ),
            );
            await tester.pumpAndSettle();
            final context = tester.element(find.byType(MockRunPanel)),
                l = AppLocalizations.of(context)!;
            BusyApiActionRow action(String title) =>
                tester.widget<BusyApiActionRow>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is BusyApiActionRow && widget.title == title,
                  ),
                );
            expect(action(l.startMock).enabled, true);
            expect(action(l.startMock).onTap, isNotNull);
            final captured = mock.plan;
            final working = original.replaceFirst(before, after);
            await tester.runAsync(() async {
              workspace.sourceEdit(workspace.root!, working);
              await workspace.analyse();
            });
            await tester.pumpAndSettle();
            expect(identical(mock.plan, captured), true);
            expect(mock.outdated, true);
            expect(mock.run, isNull);
            expect(find.text(l.requestOutdated), findsOneWidget);
            expect(action(l.startMock).enabled, false);
            expect(action(l.startMock).onTap, isNull);
            expect(action(l.startValidationProxy).enabled, false);
            expect(workspace.buffer!.text, working);
            expect(file.readAsStringSync(), original);
            await tester.runAsync(mock.prepare);
            await tester.pumpAndSettle();
            expect(mock.phase, 'ready');
            expect(mock.outdated, false);
            expect(identical(mock.plan, captured), false);
            expect(action(l.startMock).enabled, true);
            expect(
              mock
                  .plan!
                  .analysis['projection']['specification']['declaredVersion'],
              after,
            );
            expect(mock.plan!.snapshot.resources.single['text'], working);
            expect(workspace.buffer!.text, working);
            expect(file.readAsStringSync(), original);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            mock.dispose();
            await tester.runAsync(workspace.shutdown);
            workspace.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
