import 'dart:async';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/workspace/project_import.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _NativeHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  WorkspaceController workspace(Directory temp) => WorkspaceController(
    EngineProcess(executable: runtimeNode, helper: runtimeHelper),
    StateLocations(
      config: '${temp.path}/config',
      state: '${temp.path}/state',
      cache: '${temp.path}/cache',
    ),
  );

  testWidgets(
    'native import capture retains entered paths after an input failure and cancels cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-import-widget-',
      );
      final owner = workspace(temp);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showProjectImport(context, owner),
                  child: const Text('Import'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).at(1),
          '${temp.path}/new 雪',
        );
        await tester.tap(find.text('Acquire and review'));
        await tester.pumpAndSettle();
        expect(find.textContaining('import.input'), findsOneWidget);
        expect(find.text('${temp.path}/new 雪'), findsOneWidget);
        expect(
          await tester.runAsync(() => Directory('${temp.path}/new 雪').exists()),
          false,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Import Project…'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        owner.dispose();
        await tester.runAsync(() async {
          await owner.engine.close();
          await temp.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'retiring the import owner cancels an actual pending HTTP acquisition',
    (tester) async {
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-import-owner-',
          );
          final owner = workspace(temp),
              controller = ProjectImportController(owner);
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final reached = Completer<void>();
          final subscription = server.listen((request) {
            unawaited(
              request.response.done.then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {},
              ),
            );
            reached.complete(); // Deliberately never send response headers.
          });
          try {
            final future = controller.prepare(
              kind: ProjectImportKind.url,
              source: 'http://127.0.0.1:${server.port}/api.yaml',
              destination: '${temp.path}/retired',
            );
            await reached.future.timeout(const Duration(seconds: 10));
            controller.workspace.dispose();
            controller.dispose();
            await future.timeout(const Duration(seconds: 5));
            expect(controller.plan, isNull);
            expect(controller.phase, 'cancelled');
            expect(await Directory('${temp.path}/retired').exists(), false);
          } finally {
            if (!owner.disposed) owner.dispose();
            await owner.engine.close();
            await subscription.cancel();
            await server.close(force: true);
            await temp.delete(recursive: true);
          }
        }, _NativeHttp()),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
