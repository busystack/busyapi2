import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('R06-A semantic search reveals the authored alias occurrence', (
    tester,
  ) async {
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
        () => messenger.setMockMethodCallHandler(MethodChannel(channel), null),
      );
    }
    final dir = Directory.systemTemp.createTempSync('busyapi-alias-search-');
    final c = WorkspaceController(
      EngineProcess(executable: runtimeNode, helper: runtimeHelper),
      StateLocations(
        config: '${dir.path}/config',
        state: '${dir.path}/state',
        cache: '${dir.path}/cache',
      ),
    );
    const source =
        'openapi: 3.2.1\ninfo: {title: Alias, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Target: {type: string}\n    A: &shared {\$ref: "#/components/schemas/Target"}\n    B: *shared\n';
    final file = File('${dir.path}/openapi.yaml')..writeAsStringSync(source);
    try {
      late Map<String, dynamic> target;
      await tester.runAsync(() async {
        await c.initialize();
        await c.open(file.path);
        await c.analyse();
        final found = await c.project!.semanticSearch().run(
          'B',
          category: 'components',
        );
        target = found.matches.singleWhere(
          (m) => m['pointer'] == '/components/schemas/B',
        );
      });
      expect(target['physicalPointer'], '/components/schemas/A');
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
      await tester.runAsync(
        () => tester
            .state<WorkspaceScreenState>(find.byType(WorkspaceScreen))
            .revealSearch(target),
      );
      await tester.pump();
      expect(c.mode, 'Source');
      expect(find.byType(SourceEditor), findsOneWidget);
      expect(c.buffer!.selection.base, source.indexOf('*shared'));
      expect(c.buffer!.text, source);
      expect(c.store!.canUndo, false);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(c.shutdown);
      c.dispose();
      await tester.runAsync(c.engine.close);
      dir.deleteSync(recursive: true);
    }
  });
}
