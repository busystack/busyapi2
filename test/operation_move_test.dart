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
    for (final channel in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'owned operation controls $version $json review exact consumers and preserve drafts/history/publication',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temporary = Directory.systemTemp.createTempSync(
            'busyapi-operation-controls-',
          );
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temporary.path}/config',
              state: '${temporary.path}/state',
              cache: '${temporary.path}/cache',
            ),
          );
          final failures = <Object>[];
          Future<void>? pending;
          Future<void> waitFor(bool Function() ready) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!ready() &&
                failures.isEmpty &&
                clock.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(
              ready(),
              true,
              reason:
                  'Current native operation control must become ready: ${c.error}',
            );
            await tester.pumpAndSettle();
          }

          Finder field(String label) => find.descendant(
            of: find.byType(BusyApiDialogShell),
            matching: find.widgetWithText(TextFormField, label),
          );
          Future<void> press(String label) => tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, label)),
          );
          Future<void> finishAction() async {
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await waitFor(() => done);
          }

          try {
            final extension = json ? 'json' : 'yaml',
                source = File(
                  '${temporary.path}/root.${json ? 'json' : 'yaml'}',
                );
            final links = File('${temporary.path}/links.json');
            final value = {
              'openapi': version,
              'info': {'title': 'Controls', 'version': '1'},
              'paths': {
                '/old': {
                  'get': {
                    'operationId': 'moveMe',
                    'summary': 'Before',
                    'responses': {
                      '204': {'description': 'Bodyless'},
                    },
                  },
                },
                '/new': {
                  'post': {
                    'operationId': 'sibling',
                    'responses': {
                      '204': {'description': 'Sibling'},
                    },
                  },
                },
              },
              'components': {
                'links': {
                  'Usage': {r'$ref': 'links.json#/Usage'},
                },
              },
              'x-kept': {'n': 111, r'$ref': '#/paths/~1old/get'},
            };
            final text = json
                ? const JsonEncoder.withIndent('  ')
                      .convert(value)
                      .replaceAll('111', '9007199254740993.00')
                : '# preserved 雪😀\r\nopenapi: $version\r\ninfo: {title: Controls, version: \'1\'}\r\npaths:\r\n  /old:\r\n    get:\r\n      operationId: moveMe\r\n      summary: \'Before\'\r\n      responses: {204: {description: Bodyless}}\r\n  /new:\r\n    post: {operationId: sibling, responses: {204: {description: Sibling}}}\r\ncomponents:\r\n  links:\r\n    Usage: {\$ref: "links.json#/Usage"}\r\nx-kept: {n: 9007199254740993.00, \$ref: "#/paths/~1old/get"}';
            final linkText =
                '{"Usage":{"operationRef":"root.$extension#/paths/~1old/get"}}';
            await tester.runAsync(() async {
              await source.writeAsString('\uFEFF$text');
              await links.writeAsString(linkText);
              await c.initialize();
              await c.open(source.path);
              await c.analyse();
              await c.selectObject(
                Map<String, dynamic>.from(
                  (c.projection!['operations'] as List).firstWhere(
                    (operation) => operation['method'] == 'get',
                  ),
                ),
              );
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
                      run: (action) =>
                          pending = action().catchError((Object error) {
                            failures.add(error);
                          }),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            final before = c.buffer!.bytes();
            Future<void> capture({bool invalidAndComposing = false}) async {
              final action = find.widgetWithText(
                BusyApiActionRow,
                'Method / Path',
              );
              await waitFor(
                () => action.evaluate().any(
                  (element) =>
                      (element.widget as BusyApiActionRow).onTap != null,
                ),
              );
              await tester.runAsync(() => tester.tap(action));
              await waitFor(() => c.form != null);
              final method = tester.widget<BusyApiComboRow<String>>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is BusyApiComboRow<String> &&
                      widget.title == 'Method',
                ),
              );
              expect(
                method.values.contains('query'),
                version.startsWith('3.2'),
              );
              if (version.startsWith('3.2')) {
                final choice = method.values.singleWhere(
                  (value) => method.labelFor(value) == 'Additional method',
                );
                method.onSelected(choice);
                await tester.pump();
                final token = field('Additional token (when selected above)');
                await tester.runAsync(
                  () => tester.enterText(
                    token,
                    invalidAndComposing ? 'GET' : 'COPY',
                  ),
                );
                if (invalidAndComposing) {
                  await press('Apply');
                  await waitFor(
                    () => find
                        .textContaining('Additional methods are case-sensitive')
                        .evaluate()
                        .isNotEmpty,
                  );
                  expect(c.form, isNotNull);
                  expect(c.buffer!.bytes(), before);
                  await tester.runAsync(() => tester.showKeyboard(token));
                  await tester.runAsync(
                    () async => tester.testTextInput.updateEditingValue(
                      const TextEditingValue(
                        text: 'CO',
                        selection: TextSelection.collapsed(offset: 2),
                        composing: TextRange(start: 0, end: 2),
                      ),
                    ),
                  );
                  final editor = tester
                      .widget<TextField>(
                        find.descendant(
                          of: token,
                          matching: find.byType(TextField),
                        ),
                      )
                      .controller!;
                  expect(
                    editor.value.composing,
                    const TextRange(start: 0, end: 2),
                  );
                  await press('Apply');
                  await tester.pump();
                  expect(c.form, isNotNull);
                  expect(c.buffer!.bytes(), before);
                  expect(
                    tester
                        .widget<TextField>(
                          find.descendant(
                            of: token,
                            matching: find.byType(TextField),
                          ),
                        )
                        .controller,
                    same(editor),
                  );
                  await tester.runAsync(
                    () async => tester.testTextInput.updateEditingValue(
                      const TextEditingValue(
                        text: 'COPY',
                        selection: TextSelection.collapsed(offset: 4),
                      ),
                    ),
                  );
                }
              } else {
                method.onSelected('patch');
                await tester.pump();
                expect(
                  field('Additional token (when selected above)'),
                  findsNothing,
                );
              }
              await tester.runAsync(
                () => tester.enterText(field('Path'), '/new'),
              );
              await press('Apply');
              await waitFor(
                () => find
                    .text('Review operation relocation')
                    .evaluate()
                    .isNotEmpty,
              );
              expect(c.buffer!.bytes(), before);
              expect(
                (await tester.runAsync(
                  () => c.project!.buffer(links.uri.toString()),
                ))!.text,
                linkText,
              );
              expect(find.text('root.$extension'), findsWidgets);
            }

            await capture(invalidAndComposing: true);
            await press('Cancel');
            await finishAction();
            expect(c.buffer!.bytes(), before);
            expect(links.readAsStringSync(), linkText);
            await capture();
            await press('Apply');
            await finishAction();
            final destination =
                '/paths/~1new/${version.startsWith('3.2') ? 'additionalOperations/COPY' : 'patch'}';
            expect(c.selectedPointer, destination);
            final moved = c.buffer!.bytes();
            final linkBuffer = await tester.runAsync(
              () => c.project!.buffer(links.uri.toString()),
            );
            expect(linkBuffer!.text, contains(destination));
            expect(c.buffer!.text, contains('9007199254740993.00'));
            expect(c.buffer!.text, contains('#/paths/~1old/get'));
            await tester.runAsync(c.undo);
            await tester.pump();
            expect(c.buffer!.bytes(), before);
            expect(linkBuffer.text, linkText);
            await tester.runAsync(c.redo);
            await tester.pump();
            expect(c.buffer!.bytes(), moved);
            expect(linkBuffer.text, contains(destination));
            await tester.runAsync(c.saveAll);
            expect(source.readAsBytesSync(), moved);
            expect(links.readAsBytesSync(), linkBuffer.bytes());
            final response = await tester.runAsync(
              () => c.project!.inspectObject(
                c.root!,
                c.root!,
                '$destination/responses/204',
              ),
            );
            expect(
              (response!['fields'] as List)
                  .where((field) => field['name'] == 'content')
                  .single['present'],
              false,
            );
            await tester.runAsync(() => c.open(source.path));
            expect(c.buffer!.bytes(), moved);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            temporary.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
