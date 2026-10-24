import 'dart:io';

import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/workspace/search_session.dart';
import 'package:busyapi/src/workspace/search_sidebar.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'support/search_test_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'semantic sidebar reaches its last lazy result and returns the original root and occurrence without replacement',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
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
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-semantic-widget-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      BusyApiSearchSession? session;
      Map<String, dynamic>? result;
      Future<void> waitFor(bool Function() predicate) async {
        final clock = Stopwatch()..start();
        while (!predicate() && clock.elapsed < const Duration(seconds: 8)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(predicate(), true);
        await tester.pumpAndSettle();
      }

      try {
        await tester.runAsync(() async {
          await c.initialize();
          await File('${temp.path}/busyapi.yaml').writeAsString(
            'version: 1\nroots:\n  - name: primary\n    path: root.yaml\n  - name: alternate\n    path: second.yaml\n',
          );
          const head =
              'openapi: 3.2.1\ninfo: {title: Test, version: "1"}\npaths:\n';
          final paths = List.generate(
            131,
            (i) => '  /item$i: {\$ref: "part.yaml#/Shared"}\n',
          ).join();
          await File('${temp.path}/root.yaml').writeAsString(head + paths);
          await File('${temp.path}/second.yaml').writeAsString(head + paths);
          await File('${temp.path}/part.yaml').writeAsString(
            'Shared: {get: {summary: Repeated, tags: [group]}}\n',
          );
          await c.open(temp.path);
          await c.selectRoot(c.project!.roots.first.id);
          await c.analyse();
          final part = await c.project!.buffer(
            Uri.file('${temp.path}/part.yaml').toString(),
          );
          c.sourceEdit(part.id, part.text.replaceFirst('Repeated', 'Unsaved'));
          await c.analyse();
        });
        final search = session = BusyApiSearchSession(c);
        search.open(BusyApiSearchCategory.project);
        await tester.pumpWidget(
          searchTestHost(search, onReveal: (value) async => result = value),
        );
        await tester.pumpAndSettle();
        tester
            .widget<BusyApiPopupSelector<BusyApiSearchCategory>>(
              find.byType(BusyApiPopupSelector<BusyApiSearchCategory>),
            )
            .onSelected(BusyApiSearchCategory.semantic);
        await tester.pumpAndSettle();
        final query = find.descendant(
          of: find.byType(BusyApiSearchField),
          matching: find.byType(TextField),
        );
        await tester.runAsync(() => tester.enterText(query, 'Unsaved'));
        expect(
          find.widgetWithText(BusyApiGroupedTextEntry, 'Replacement'),
          findsNothing,
        );
        await tester.runAsync(search.search);
        await waitFor(
          () => find
              .text('262 semantic occurrences across 2 configured roots')
              .evaluate()
              .isNotEmpty,
        );
        expect(find.text('Review replacement'), findsNothing);
        expect(
          find.textContaining('semantic index is incomplete'),
          findsNothing,
        );
        final last = search.semanticResult!.matches.last;
        expect(
          find.byType(BusyApiSidebarRecordRow<void>).evaluate().length,
          lessThan(100),
          reason: 'Large occurrence sets retain lazy result construction.',
        );
        final lastRow = find.byKey(ValueKey(last['semanticId'] as String));
        await tester.scrollUntilVisible(
          lastRow,
          250,
          maxScrolls: 120,
          scrollable: find.descendant(
            of: find.byType(BusyApiSearchResultList),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('GET · /item130 · Unsaved'), findsOneWidget);
        await tester.runAsync(() => tester.tap(lastRow));
        await waitFor(() => result != null);
        expect(result!['root'], c.project!.roots.last.id);
        expect(
          result!['resource'],
          Uri.file('${temp.path}/part.yaml').toString(),
        );
        expect(result!['pointer'], '/Shared/get');
        expect(
          result!['occurrence'],
          '${c.project!.roots.last.id}#/paths/~1item130/get',
        );
        expect(
          File('${temp.path}/part.yaml').readAsStringSync(),
          contains('Repeated'),
        );
        expect((c.layoutState['projectSearch'] as Map)['mode'], 'semantic');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        session?.dispose();
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
