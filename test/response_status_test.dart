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
import 'widget_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        'native reviewed response status $version $format retains source, consumers and history',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
                'busyapi-response-status-design-',
              ),
              reference = '#/paths/~1items/get/responses/201';
          final original =
              '${format == 'yaml' ? '# retained status source\r\n' : ''}${const JsonEncoder.withIndent('  ').convert({
                if (version == '2.0') 'swagger': version else 'openapi': version,
                'info': {'title': 'Response status 雪😀', 'version': '1'},
                'paths': {
                  '/items': {
                    'get': {
                      'responses': {
                        '201': {'description': 'Kept response'},
                      },
                    },
                  },
                  '/consumer': {
                    'get': {
                      'responses': {
                        '200': {r'$ref': reference},
                      },
                    },
                  },
                },
                'x-literal': {r'$ref': reference, 'value': 'EXACT'},
              }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final actions = <Future<void>>[], errors = <Object>[];
          Future<void> ready(bool Function() condition) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                errors.isEmpty &&
                clock.elapsed < const Duration(seconds: 12)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(
              condition(),
              true,
              reason: 'pointer=${c.selectedPointer} error=${c.error}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> tap(String label) async {
            final target = find.text(label).last;
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            await tester.runAsync(() => tester.tap(target));
            await tester.pump();
          }

          Finder status() => find.descendant(
            of: find.widgetWithText(BusyApiGroupedTextEntry, 'Status'),
            matching: find.byType(TextField),
          );
          bool current(String label) => find
              .text(label)
              .evaluate()
              .any((element) => ModalRoute.of(element)?.isCurrent == true);
          Future<void> openRename() async {
            await ready(
              () => find
                  .widgetWithText(BusyApiActionRow, 'Rename response status…')
                  .evaluate()
                  .any(
                    (element) =>
                        (element.widget as BusyApiActionRow).onTap != null,
                  ),
            );
            await tap('Rename response status…');
            await ready(
              () => status().evaluate().any(
                (element) => ModalRoute.of(element)?.isCurrent == true,
              ),
            );
          }

          try {
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/paths/~1items/get/responses/201',
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
            await openRename();
            final invalid = version == '2.0' ? '2XX' : '099';
            await tester.runAsync(() => tester.enterText(status(), invalid));
            await tap('Apply');
            final message = version == '2.0'
                ? 'Use default or a status code from 100 to 599.'
                : 'Use default, a status code from 100 to 599, or a range from 1XX to 5XX.';
            await ready(() => current(message));
            expect(
              tester.widget<TextField>(status()).controller!.text,
              invalid,
            );
            expect(c.buffer!.text, original);
            await tap('Cancel');
            await ready(
              () =>
                  c.form == null &&
                  find.byType(BusyApiDialogShell).evaluate().isEmpty,
            );
            for (final accept in [false, true]) {
              await openRename();
              await tester.runAsync(() => tester.enterText(status(), '202'));
              await tap('Apply');
              await ready(() => current('Review refactoring'));
              expect(c.buffer!.text, original);
              expect(file.readAsBytesSync(), [
                239,
                187,
                191,
                ...utf8.encode(original),
              ]);
              await tap(accept ? 'Apply' : 'Cancel');
              await ready(() => !current('Review refactoring'));
            }
            await ready(
              () =>
                  c.selectedPointer == '/paths/~1items/get/responses/202' &&
                  c.buffer!.text != original,
            );
            await runWidgetIo(tester, () => Future.wait(actions));
            final accepted = c.buffer!.text;
            final parsed = jsonDecode(
              accepted.replaceFirst('# retained status source\r\n', ''),
            ) as Map;
            expect(
              (parsed['paths']['/items']['get']['responses'] as Map).keys,
              ['202'],
            );
            expect(
              parsed['paths']['/consumer']['get']['responses']['200'][r'$ref'],
              '#/paths/~1items/get/responses/202',
            );
            expect(parsed['x-literal'][r'$ref'], reference);
            expect(accepted, contains('9007199254740993.00'));
            await runWidgetIo(tester, () async {
              await c.undo();
              expect(c.buffer!.text, original);
              await c.redo();
              expect(c.buffer!.text, accepted);
              await c.saveAll();
              await c.open(file.path);
              expect(c.store!.get(file.uri.toString()).text, accepted);
              expect((await c.project!.check(c.root!))['status'], 'complete');
            });
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await runWidgetIo(tester, c.shutdown);
            c.dispose();
            directory.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
