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
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final cross in [false, true]) {
        testWidgets(
          'native extraction and explicit inlining $version $json cross=$cross review, cancel and preserve history',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            for (final channel in ['yaru_window', 'yaru_window/events']) {
              messenger.setMockMethodCallHandler(
                MethodChannel(channel),
                (_) async => null,
              );
              addTearDown(
                () => messenger.setMockMethodCallHandler(
                  MethodChannel(channel),
                  null,
                ),
              );
            }
            const menuChannel = MethodChannel('busyapi/native_menus');
            messenger.setMockMethodCallHandler(menuChannel, (call) async {
              if (call.method != 'show') return null;
              final entries = (call.arguments['entries'] as List).cast<Map>();
              final selected = entries.indexWhere(
                (entry) =>
                    entry['label'] ==
                    'models · models.${json ? 'json' : 'yaml'}',
              );
              expect(selected, greaterThanOrEqualTo(0));
              return selected;
            });
            addTearDown(
              () => messenger.setMockMethodCallHandler(menuChannel, null),
            );
            final temp = Directory.systemTemp.createTempSync(
              'busyapi-native-copy-',
            );
            final c = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${temp.path}/config',
                state: '${temp.path}/state',
                cache: '${temp.path}/cache',
              ),
            );
            final errors = <Object>[];
            Future<void>? pending;
            Future<void> waitFor(bool Function() condition) async {
              final timer = Stopwatch()..start();
              await tester.pump();
              while (!condition() &&
                  errors.isEmpty &&
                  timer.elapsed < const Duration(seconds: 12)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(errors, isEmpty);
              expect(
                condition(),
                true,
                reason:
                    'selection=${c.selectedPointer}; checking=${c.checking}/${c.checkingSemantics}; error=${c.error}',
              );
              await tester.pumpAndSettle();
            }

            Future<void> settleAction() async {
              var done = false;
              await tester.runAsync(() async {
                pending!.then((_) => done = true);
              });
              await waitFor(() => done);
            }

            Future<void> button(String text) => tester.runAsync(
              () => tester.tap(find.widgetWithText(BusyApiDialogButton, text)),
            );
            try {
              final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
              final destination = File(
                '${temp.path}/models.${json ? 'json' : 'yaml'}',
              );
              final value = {
                'openapi': version,
                'info': {'title': 'Copies', 'version': '1'},
                'paths': <String, Object?>{},
                'components': {
                  'schemas': {
                    'Owner': {
                      'properties': {
                        'child': {
                          'type': 'object',
                          r'$defs': {
                            'Known': {'type': 'integer'},
                          },
                          'properties': {
                            'value': false,
                            'shared': {
                              r'$ref': '#/components/schemas/Owner/properties/child/\$defs/Known',
                            },
                          },
                          'examples': [
                            {'value': 'EXACT'},
                          ],
                          'x-kept': {r'$ref': 'payload data'},
                        },
                      },
                    },
                  },
                },
              };
              final original =
                  '${json ? '' : '# retained\r\n'}${const JsonEncoder.withIndent('  ').convert(value).replaceAll('"EXACT"', '900719925474099312345')}';
              const pointer = '/components/schemas/Owner/properties/child';
              await tester.runAsync(() async {
                await file.writeAsString('\ufeff$original');
                await destination.writeAsString(
                  jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Models', 'version': '1'},
                    'paths': <String, Object?>{},
                  }),
                );
                await File('${temp.path}/busyapi.yaml').writeAsString(
                  'version: 1\nroots:\n  - name: working\n    path: ${file.uri.pathSegments.last}\n  - name: models\n    path: ${destination.uri.pathSegments.last}\n',
                );
                await c.initialize();
                await c.open(temp.path);
                await c.selectRoot(file.uri.toString());
                await c.selectObject({
                  'root': c.root,
                  'resource': c.root,
                  'pointer': pointer,
                });
              });
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildBusyApiTheme(
                    brightness: Brightness.light,
                    accentColor: Colors.blue,
                  ),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Scaffold(
                    body: ListenableBuilder(
                      listenable: c,
                      builder: (_, _) => Designer(
                        controller: c,
                        run: (action) =>
                            pending = action().catchError((Object error) {
                              errors.add(error);
                            }),
                        reveal: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              final buffer = c.buffer!, originalBytes = buffer.bytes();
              if (version == '3.1.2' && !json && !cross) {
                final item = await tester.runAsync(
                  () => c.project!.inspectObject(c.root!, buffer.id, pointer),
                );
                final captured = c.beginForm(
                  'object.extract',
                  item!,
                  const {},
                  {'name': '', 'destination': buffer.id},
                );
                captured.edit('name', 'RecoveredName');
                await tester.runAsync(c.persist);
                c.form = FormSession.restore(captured.recovery());
                await tester.runAsync(() async {
                  pending = resumeCapturedForm(
                    tester.element(find.byType(Designer)),
                    c,
                  );
                });
                final recoveredField = find.descendant(
                  of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
                  matching: find.byType(TextField),
                );
                await waitFor(
                  () =>
                      recoveredField.evaluate().isNotEmpty &&
                      find.byType(BusyApiDialogShell).evaluate().isNotEmpty,
                );
                expect(
                  tester.widget<TextField>(recoveredField).controller!.text,
                  'RecoveredName',
                );
                expect(buffer.bytes(), originalBytes);
                await button('Cancel');
                await settleAction();
                expect(c.form, isNull);
                expect(c.restoringForm, isNull);
              }
              Future<void> extractionReview() async {
                await waitFor(
                  () => find
                      .widgetWithText(BusyApiActionRow, 'Extract to component…')
                      .evaluate()
                      .any((e) => (e.widget as BusyApiActionRow).onTap != null),
                );
                await tester.runAsync(
                  () => tester.tap(
                    find.widgetWithText(
                      BusyApiActionRow,
                      'Extract to component…',
                    ),
                  ),
                );
                final field = find.descendant(
                  of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
                  matching: find.byType(TextField),
                );
                await waitFor(
                  () =>
                      find.byType(BusyApiDialogShell).evaluate().isNotEmpty &&
                      field.evaluate().any(
                        (e) => ModalRoute.of(e)?.isCurrent == true,
                      ),
                );
                await tester.runAsync(
                  () => tester.enterText(field, 'Extracted'),
                );
                if (cross) {
                  await tester.runAsync(
                    () => tester.tap(find.text('Component destination')),
                  );
                  await waitFor(
                    () =>
                        tester
                            .widget<BusyApiComboRow<String>>(
                              find.widgetWithText(
                                BusyApiComboRow<String>,
                                'Component destination',
                              ),
                            )
                            .selected ==
                        destination.uri.toString(),
                  );
                }
                await button('Apply');
                await waitFor(
                  () => find
                      .text('Review component extraction')
                      .evaluate()
                      .any((e) => ModalRoute.of(e)?.isCurrent == true),
                );
              }

              await extractionReview();
              expect(buffer.bytes(), originalBytes);
              final retiredApply = tester
                  .widget<BusyApiDialogButton>(
                    find.widgetWithText(BusyApiDialogButton, 'Apply'),
                  )
                  .onPressed!;
              await button('Cancel');
              retiredApply();
              await settleAction();
              expect(buffer.bytes(), originalBytes);
              await extractionReview();
              final readingKey = jsonEncode([
                c.root,
                buffer.id,
                pointer,
                'description',
              ]);
              final destinationId = cross
                  ? destination.uri.toString()
                  : buffer.id;
              final movedReadingKey = jsonEncode([
                c.root,
                destinationId,
                '/components/schemas/Extracted',
                'description',
              ]);
              final ownerTreeKey = jsonEncode([
                c.root,
                buffer.id,
                '/components/schemas/Owner',
              ]);
              c.layoutState = {
                ...c.layoutState,
                'sourceFolds': {
                  jsonEncode([c.root, buffer.id]): [
                    pointer,
                    '/components/schemas/Owner',
                    if (!cross) '/info',
                  ],
                  if (cross) jsonEncode([c.root, destinationId]): ['/info'],
                },
                'referenceText': {
                  readingKey: {'page': 1},
                },
                'schemaTrees': {
                  ownerTreeKey: {
                    'expanded': [
                      '/components/schemas/Owner',
                      pointer,
                      '$pointer/properties',
                    ],
                    'counts': {pointer: 50},
                    'selection': pointer,
                    'scroll': 0.0,
                  },
                },
              };
              final retiredFoldRevision = c.semanticViewRevision;
              await button('Apply');
              await settleAction();
              c.rememberSourceFolds(
                c.project!,
                c.root!,
                buffer.id,
                const [],
                viewRevision: retiredFoldRevision,
              );
              expect(
                c.sourceFolds(c.root!, destinationId),
                containsAll(['/info', '/components/schemas/Extracted']),
              );
              final extracted = buffer.bytes();
              expect(c.selectedPointer, '/components/schemas/Extracted');
              expect(
                c.selectedResource,
                cross ? destination.uri.toString() : buffer.id,
              );
              final definition = c.store!.get(c.selectedResource!);
              expect(definition.text, contains('900719925474099312345'));
              expect(buffer.hasBom, true);
              expect(
                (c.layoutState['referenceText'] as Map).containsKey(readingKey),
                false,
              );
              expect(
                (c.layoutState['referenceText'] as Map).containsKey(
                  movedReadingKey,
                ),
                true,
              );
              {
                final movedTree =
                    (c.layoutState['schemaTrees'] as Map)[jsonEncode([
                          c.root,
                          destinationId,
                          '/components/schemas/Extracted',
                        ])]
                        as Map;
                expect(
                  movedTree['expanded'],
                  contains('/components/schemas/Extracted/properties'),
                );
              }
              final beforeMove = {
                for (final path in [file, destination])
                  path.uri.toString():
                      c.store!.buffers[path.uri.toString()]?.bytes() ??
                      path.readAsBytesSync(),
              };
              Future<void> moveReview() async {
                await waitFor(
                  () => find
                      .widgetWithText(BusyApiActionRow, 'Move definition…')
                      .evaluate()
                      .any((e) => (e.widget as BusyApiActionRow).onTap != null),
                );
                await tester.runAsync(
                  () => tester.tap(
                    find.widgetWithText(BusyApiActionRow, 'Move definition…'),
                  ),
                );
                final name = find.descendant(
                  of: find.widgetWithText(
                    BusyApiGroupedTextEntry,
                    'Destination component name',
                  ),
                  matching: find.byType(TextField),
                );
                await waitFor(
                  () => name.evaluate().any(
                    (e) => ModalRoute.of(e)?.isCurrent == true,
                  ),
                );
                expect(
                  tester.widget<TextField>(name).controller!.text,
                  'Extracted',
                );
                await tester.runAsync(() => tester.enterText(name, 'Stored'));
                if (!cross) {
                  await tester.runAsync(
                    () => tester.tap(find.text('Component destination')),
                  );
                  await waitFor(
                    () =>
                        tester
                            .widget<BusyApiComboRow<String>>(
                              find.widgetWithText(
                                BusyApiComboRow<String>,
                                'Component destination',
                              ),
                            )
                            .selected ==
                        destination.uri.toString(),
                  );
                }
                await button('Apply');
                await waitFor(
                  () => find
                      .text('Review definition move')
                      .evaluate()
                      .any((e) => ModalRoute.of(e)?.isCurrent == true),
                );
              }

              await moveReview();
              expect(
                find.textContaining('keep its original public component name'),
                findsOneWidget,
              );
              await button('Cancel');
              await settleAction();
              for (final entry in beforeMove.entries) {
                expect(
                  c.store!.buffers[entry.key]?.bytes() ??
                      File.fromUri(Uri.parse(entry.key)).readAsBytesSync(),
                  entry.value,
                );
              }
              await moveReview();
              await button('Apply');
              await settleAction();
              expect(c.selectedPointer, '/components/schemas/Stored');
              expect(c.selectedResource, destination.uri.toString());
              final moved = c.store!.get(destination.uri.toString()).bytes();
              expect(c.store!.get(destinationId).text, contains('Stored'));
              expect(
                c.store!.get(destination.uri.toString()).text,
                contains('900719925474099312345'),
              );
              await tester.runAsync(c.undo);
              expect(c.selectedPointer, '/components/schemas/Extracted');
              expect(c.selectedResource, destinationId);
              for (final entry in beforeMove.entries) {
                expect(c.store!.get(entry.key).bytes(), entry.value);
              }
              await tester.runAsync(c.redo);
              expect(c.store!.get(destination.uri.toString()).bytes(), moved);
              await tester.runAsync(c.undo);
              await tester.runAsync(c.undo);
              expect(buffer.bytes(), originalBytes);
              expect(c.selectedPointer, pointer);
              expect(c.selectedResource, buffer.id);
              expect(c.sourceFolds(c.root!, buffer.id), contains(pointer));
              expect(
                (c.layoutState['referenceText'] as Map).containsKey(readingKey),
                true,
              );
              final restoredTree =
                  (c.layoutState['schemaTrees'] as Map)[ownerTreeKey] as Map;
              expect(restoredTree['expanded'], contains('$pointer/properties'));
              await tester.runAsync(c.redo);
              expect(buffer.bytes(), extracted);
              expect(c.selectedPointer, '/components/schemas/Extracted');
              await tester.runAsync(
                () => c.selectObject({
                  'root': c.root,
                  'resource': buffer.id,
                  'pointer': pointer,
                }),
              );
              await waitFor(
                () => find
                    .widgetWithText(BusyApiActionRow, 'Inline this occurrence…')
                    .evaluate()
                    .any((e) => (e.widget as BusyApiActionRow).onTap != null),
              );
              await tester.runAsync(
                () => tester.tap(
                  find.widgetWithText(
                    BusyApiActionRow,
                    'Inline this occurrence…',
                  ),
                ),
              );
              await waitFor(
                () => find
                    .text('Review reference inlining')
                    .evaluate()
                    .any((e) => ModalRoute.of(e)?.isCurrent == true),
              );
              expect(buffer.bytes(), extracted);
              expect(
                find.textContaining('does not detach those dependencies'),
                findsOneWidget,
              );
              final usages = find.byType(BusyApiSwitchRow);
              expect(usages, findsOneWidget);
              await tester.runAsync(() => tester.tap(usages));
              await tester.pumpAndSettle();
              expect(
                find.textContaining(
                  'The copied reference retains this original shared target.',
                ),
                findsOneWidget,
              );
              expect(
                find.textContaining(
                  '/components/schemas/Extracted/\$defs/Known',
                ),
                findsWidgets,
              );
              await button('Apply');
              await settleAction();
              final inlined = buffer.bytes(),
                  decoded = jsonDecode(
                    buffer.text.substring(buffer.text.indexOf('{')),
                  );
              expect(
                decoded['components']['schemas']['Owner']['properties']['child']['type'],
                'object',
              );
              final definitionData = jsonDecode(
                definition.text.substring(definition.text.indexOf('{')),
              );
              expect(
                definitionData['components']['schemas']['Extracted']['type'],
                'object',
              );
              await tester.runAsync(c.undo);
              expect(buffer.bytes(), extracted);
              await tester.runAsync(c.redo);
              expect(buffer.bytes(), inlined);
              await tester.runAsync(c.saveAll);
              expect(file.readAsBytesSync(), inlined);
              if (cross) {
                expect(destination.readAsBytesSync(), definition.bytes());
              }
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
    }
  }
}
