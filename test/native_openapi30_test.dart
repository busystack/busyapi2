import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    testWidgets(
      '3.0 $format native schema edits preserve source and exclude modern choices',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-native30-widget-',
        );
        final file = File('${temp.path}/root.$format');
        const pointer = '/components/schemas/Pet';
        final original = format == 'yaml'
            ? '# Keep 雪😀\r\nopenapi: 3.0.4\r\ninfo: {title: Native, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Pet: {type: string, nullable: true} # keep\r\nx-number: 9007199254740993.00'
            : '{"openapi":"3.0.4","info":{"title":"Native","version":"1"},"paths":{},"components":{"schemas":{"Pet":{"type":"string","nullable":true}}},"x-number":9007199254740993.00}';
        file.writeAsStringSync(original);
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        final failures = <Object>[];
        Future<void>? pending;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel('busyapi/native_menus');
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'show') return null;
          final entries = (call.arguments as Map)['entries'] as List;
          final choice = entries.indexWhere(
            (entry) => entry['label'] == 'false',
          );
          expect(choice, greaterThanOrEqualTo(0));
          return choice;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        Future<void> ready(bool Function() condition) async {
          final watch = Stopwatch()..start();
          await tester.pump();
          while (!condition() &&
              failures.isEmpty &&
              watch.elapsed < const Duration(seconds: 12)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(failures, isEmpty);
          expect(condition(), true, reason: '${c.error}');
          await tester.pumpAndSettle();
        }

        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': pointer,
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
                  builder: (_, _) => Designer(
                    controller: c,
                    run: (action) => pending = action().catchError((Object e) {
                      failures.add(e);
                    }),
                    reveal: (_) {},
                  ),
                ),
              ),
            ),
          );
          final nullable = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiComboRow<String> &&
                widget.title.contains('nullable'),
          );
          await ready(() => nullable.evaluate().isNotEmpty);
          expect(
            tester.widget<BusyApiComboRow<String>>(nullable).enabled,
            true,
          );
          final type = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiComboRow<String> && widget.title == 'Type',
          );
          expect(type, findsOneWidget);
          expect(
            tester.widget<BusyApiComboRow<String>>(type).values,
            isNot(contains('"null"')),
          );
          expect(find.text('Type union'), findsNothing);
          expect(c.buffer!.text, original);
          await tester.runAsync(() => tester.ensureVisible(nullable));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(nullable);
            await pending;
          });
          final changed = original.replaceFirst(
            format == 'yaml' ? 'nullable: true' : '"nullable":true',
            format == 'yaml' ? 'nullable: false' : '"nullable":false',
          );
          await ready(() => c.buffer!.text == changed && !c.checking);
          expect(file.readAsStringSync(), original);
          await tester.runAsync(() async {
            await c.undo();
            await c.analyse();
          });
          expect(c.buffer!.text, original);
          await tester.runAsync(() async {
            await c.redo();
            await c.analyse();
            await c.saveBuffers();
          });
          expect(c.buffer!.text, changed);
          expect(file.readAsStringSync(), changed);
          expect(failures, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
