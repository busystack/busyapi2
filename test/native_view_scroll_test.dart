import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/api_navigator.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  testWidgets(
    'semantic tree and object page keep independent last-live scroll after detach',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync('busyapi-owned-scroll-');
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      final failures = <Object>[];
      void run(Future<void> Function() action) {
        action().catchError((Object e) {
          failures.add(e);
        });
      }

      Future<void> waitFor(bool Function() condition) async {
        final timer = Stopwatch()..start();
        await tester.pump();
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

      Widget screen() => MaterialApp(
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
                  child: Designer(controller: c, run: run, reveal: (_) {}),
                ),
              ],
            ),
          ),
        ),
      );
      try {
        final file = File('${temp.path}/root.json');
        final original = jsonEncode({
          'openapi': '3.2.1',
          'info': {'title': 'Scroll', 'version': '1'},
          'paths': <String, Object?>{},
          'components': {
            'schemas': {
              'Model': {
                'type': 'object',
                'properties': {
                  for (var i = 0; i < 100; i++)
                    'property$i': {'type': 'string'},
                },
              },
              for (var i = 0; i < 150; i++) 'Other$i': {'type': 'string'},
            },
          },
        });
        await tester.runAsync(() async {
          await file.writeAsString(original);
          await c.initialize();
          await c.open(file.path);
          await c.selectObject({
            'root': c.root,
            'resource': c.root,
            'pointer': '/components/schemas/Model',
          });
          await c.analyse();
        });
        await tester.pumpWidget(screen());
        final treeList = find.descendant(
          of: find.byType(ApiNavigator),
          matching: find.byType(ListView),
        );
        ScrollController treeController() =>
            tester.widget<ListView>(treeList).controller!;
        await waitFor(() => treeList.evaluate().isNotEmpty);
        await tester.drag(treeList, const Offset(0, -1100));
        await tester.pumpAndSettle();
        final treeOffset = treeController().offset;
        expect(treeOffset, greaterThan(500));
        await tester.runAsync(
          () => c.selectObject({
            'root': c.root,
            'resource': c.root,
            'pointer': '/components/schemas/Model/properties',
          }),
        );
        final objectScroll = find.descendant(
          of: find.byType(Designer),
          matching: find.byWidgetPredicate(
            (w) => w is SingleChildScrollView && w.controller != null,
          ),
        );
        ScrollController objectController() =>
            tester.widget<SingleChildScrollView>(objectScroll).controller!;
        await waitFor(
          () =>
              objectScroll.evaluate().isNotEmpty &&
              objectController().hasClients &&
              objectController().position.maxScrollExtent > 1000,
        );
        await tester.drag(objectScroll, const Offset(0, -1000));
        await tester.pumpAndSettle();
        final objectOffset = objectController().offset;
        expect(objectOffset, greaterThan(500));
        expect(treeController().offset, closeTo(treeOffset, 1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(screen());
        await waitFor(
          () =>
              objectScroll.evaluate().isNotEmpty &&
              objectController().hasClients,
        );
        expect(objectController().offset, closeTo(objectOffset, 1));
        expect(treeController().offset, closeTo(treeOffset, 1));
        expect(c.buffer!.text, original);
        expect(file.readAsStringSync(), original);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
}
