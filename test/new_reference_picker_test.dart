import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final family in ['parameters', 'responses']) {
        testWidgets('new $family chooses a reviewed definition $version $json', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-new-reference-',
          );
          final definition = family == 'parameters'
              ? '{"name":"limit","in":"query","schema":{"type":"integer"}}'
              : '{"description":"Bodyless","headers":{"X-Trace":{"schema":true}}}';
          final original = json
              ? '{\r\n"openapi":"$version","info":{"title":"New reference","version":"1"},\n"paths":{},"components":{"$family":{"Use":{},"Target":$definition}},"x-kept":9007199254740993.00}'
              : '# keep 雪😀\r\nopenapi: $version\r\ninfo: {title: "New reference", version: "1"}\npaths: {}\r\ncomponents:\r\n  $family:\r\n    Use: {}\r\n    Target: $definition\r\nx-kept: 9007199254740993.00';
          final file = File('${directory.path}/api.${json ? 'json' : 'yaml'}');
          final originalBytes = [239, 187, 191, ...utf8.encode(original)];
          file.writeAsBytesSync(originalBytes);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final errors = <Object>[], actions = <Future<void>>[];
          Future<void> ready(bool Function() condition) async {
            final watch = Stopwatch()..start();
            while (!condition() &&
                errors.isEmpty &&
                watch.elapsed < const Duration(seconds: 10)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(condition(), true);
            await tester.pumpAndSettle();
          }

          Future<void> tap(String label) async {
            final finder = find.text(label).last;
            await tester.ensureVisible(finder);
            await tester.pumpAndSettle();
            await tester.runAsync(() => tester.tap(finder));
            await tester.pump();
          }

          Future<void> review() async {
            final picker = find.widgetWithText(
              BusyApiActionRow,
              'Choose reference target',
            );
            await ready(() => picker.evaluate().length == 1);
            await tap('Choose reference target');
            await ready(
              () => find.byType(BusyApiSearchField).evaluate().isNotEmpty,
            );
            await ready(() => find.text('Target').evaluate().length == 1);
            await tap('Target');
            await ready(
              () => find.text('Review reference change').evaluate().isNotEmpty,
            );
          }

          try {
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/$family/Use',
              });
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
                    builder: (_, _) => Designer(
                      controller: c,
                      run: (action) => actions.add(
                        action().catchError(
                          (Object error) => errors.add(error),
                        ),
                      ),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await review();
            expect(c.buffer!.bytes(), originalBytes);
            await tap('Cancel');
            await ready(
              () => find.text('Review reference change').evaluate().isEmpty,
            );
            expect(c.buffer!.bytes(), originalBytes);
            await review();
            await tap('Apply');
            await ready(
              () =>
                  c.buffer!.text.contains('#/components/$family/Target') &&
                  find.text('Review reference change').evaluate().isEmpty,
            );
            await runWidgetIo(tester, () => Future.wait(actions));
            final accepted = c.buffer!.text;
            final useOffset = original.indexOf(
              '{}',
              original.indexOf(json ? '"Use"' : 'Use:'),
            );
            expect(accepted.startsWith(original.substring(0, useOffset)), true);
            expect(accepted.endsWith(original.substring(useOffset + 2)), true);
            expect(file.readAsBytesSync(), originalBytes);
            await runWidgetIo(tester, () async {
              await c.undo();
              expect(c.buffer!.bytes(), originalBytes);
              await c.redo();
              expect(c.buffer!.text, accepted);
              await c.saveAll();
              expect(file.readAsBytesSync(), [
                239,
                187,
                191,
                ...utf8.encode(accepted),
              ]);
              await c.open(file.path);
              expect(c.buffer!.text, accepted);
            });
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await runWidgetIo(tester, c.shutdown);
            c.dispose();
            directory.deleteSync(recursive: true);
          }
        });
      }
    }
  }
}
