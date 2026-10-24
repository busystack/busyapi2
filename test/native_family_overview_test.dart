import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/api_navigator.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      'native $version Overview fields and navigation follow engine metadata',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final name in ['yaru_window', 'yaru_window/events']) {
          final channel = MethodChannel(name);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-overview-family-',
        );
        final file = File('${temp.path}/api.yaml');
        final original =
            '# Native source\n${version == '2.0' ? 'swagger: "2.0"' : 'openapi: $version'}\ninfo: {title: Original, version: "1"}\npaths: {}\n';
        file.writeAsStringSync(original);
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        Future<void>? pending;
        void run(Future<void> Function() action) => pending = action();
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': '/info',
            });
            await c.analyse();
          });
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
                      SizedBox(
                        width: 300,
                        child: ApiNavigator(
                          controller: c,
                          projection: c.projection,
                          filter: '',
                          run: run,
                        ),
                      ),
                      Expanded(
                        child: Designer(
                          controller: c,
                          run: run,
                          reveal: (_) {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final summary = find.byWidgetPredicate(
            (widget) => widget is DraftField && widget.label == 'Summary',
          );
          expect(
            summary,
            version.startsWith('3.1') || version.startsWith('3.2')
                ? findsOneWidget
                : findsNothing,
          );
          expect(
            find.text('Callbacks'),
            version == '2.0' ? findsNothing : findsOneWidget,
          );
          final title = find.byWidgetPredicate(
            (widget) => widget is DraftField && widget.label == 'Title',
          );
          final field = tester.widget<DraftField>(title);
          expect(field.readOnly, false);
          await tester.runAsync(() async {
            field.onChanged('Native changed', false);
            field.onCommit();
            expect(pending, isNotNull);
            await pending;
          });
          expect(c.buffer!.text, contains('Native changed'));
          expect(file.readAsStringSync(), original);
          expect(c.buffer!.text.contains('summary:'), false);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(c.shutdown);
          c.dispose();
          await tester.runAsync(() => temp.delete(recursive: true));
        }
      },
    );
  }
}
