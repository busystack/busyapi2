import 'dart:convert';
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
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'native Server default editing retains current errors, field ownership and exact history $version $json',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final name in ['yaru_window', 'yaru_window/events']) {
            messenger.setMockMethodCallHandler(
              MethodChannel(name),
              (_) async => null,
            );
            addTearDown(
              () =>
                  messenger.setMockMethodCallHandler(MethodChannel(name), null),
            );
          }
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-server-native-',
          );
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
          Future<void> waitFor(bool Function() condition) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                failures.isEmpty &&
                clock.elapsed < const Duration(seconds: 12)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(condition(), true, reason: '${c.error} ${c.storageError}');
            await tester.pumpAndSettle();
          }

          final row = find.widgetWithText(BusyApiGroupedTextEntry, 'default');
          final input = find.descendant(
            of: row,
            matching: find.byType(TextField),
          );
          try {
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final source = json
                ? '{"openapi":"$version","info":{"title":"Servers 🐾","version":"1"},"paths":{},"servers":[{"url":"https://example.test/{region}","variables":{"region":{"default":"west","enum":["east"]}}}],"x-exact":900719925474099312345}'
                : 'openapi: $version\r\ninfo: {title: "Servers 🐾", version: "1"}\npaths: {}\nservers:\n  - url: https://example.test/{region}\n    variables:\n      region: {default: west, enum: [east]} # preserve\nx-exact: 900719925474099312345';
            final original = [239, 187, 191, ...utf8.encode(source)];
            await tester.runAsync(() async {
              await file.writeAsBytes(original);
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/servers/0/variables/region',
              });
              await c.analyse();
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: json ? Brightness.dark : Brightness.light,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: ListenableBuilder(
                    listenable: c,
                    builder: (_, _) => Designer(
                      controller: c,
                      run: (action) => pending = action().catchError(
                        (Object e) => failures.add(e),
                      ),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await waitFor(() => input.evaluate().isNotEmpty);
            final field = tester.widget<TextField>(input).controller!;
            expect(field.text, 'west');
            expect(
              tester.widget<BusyApiGroupedTextEntry>(row).errorText,
              version == '3.0.4'
                  ? isNull
                  : contains('default must be one of its authored enum values'),
            );
            expect(
              c.analysis!['status'],
              version == '3.0.4' ? 'complete' : 'invalid',
            );
            expect(
              (c.analysis!['findings'] as List).singleWhere(
                (dynamic finding) =>
                    finding['code'] == 'server.variable.default-enum',
              )['severity'],
              version == '3.0.4' ? 'warning' : 'error',
            );
            await tester.enterText(input, 'east');
            expect(c.hasPendingFields, true);
            await tester.runAsync(
              () => tester.testTextInput.receiveAction(TextInputAction.done),
            );
            await waitFor(() => pending != null);
            var applied = false;
            await tester.runAsync(() async {
              pending!.then((_) => applied = true);
            });
            await waitFor(() => applied);
            await tester.runAsync(c.analyse);
            await waitFor(
              () =>
                  input.evaluate().isNotEmpty &&
                  tester.widget<BusyApiGroupedTextEntry>(row).errorText == null,
            );
            expect(tester.widget<TextField>(input).controller, same(field));
            expect(field.text, 'east');
            expect(c.analysis!['status'], 'complete');
            expect(file.readAsBytesSync(), original);
            await tester.runAsync(c.undo);
            await tester.runAsync(c.analyse);
            await waitFor(
              () =>
                  input.evaluate().isNotEmpty &&
                  tester.widget<TextField>(input).controller!.text == 'west',
            );
            expect(c.buffer!.bytes(), original);
            expect(
              tester.widget<BusyApiGroupedTextEntry>(row).errorText,
              version == '3.0.4' ? isNull : isNotNull,
            );
            await tester.runAsync(c.redo);
            await tester.runAsync(c.analyse);
            await waitFor(
              () =>
                  input.evaluate().isNotEmpty &&
                  tester.widget<TextField>(input).controller!.text == 'east',
            );
            await tester.runAsync(c.saveAll);
            expect(file.readAsBytesSync(), [
              239,
              187,
              191,
              ...utf8.encode(source.replaceFirst('west', 'east')),
            ]);
            await tester.runAsync(() => c.open(file.path));
            expect(c.buffer!.bytes(), file.readAsBytesSync());
            expect(c.error, isNull);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            await tester.runAsync(c.engine.close);
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
