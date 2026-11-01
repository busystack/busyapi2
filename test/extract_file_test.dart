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
  for (final version in ['2.0', '3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets('new-file extraction controls $version json=$json', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1400, 1100);
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
            () => messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              null,
            ),
          );
        }
        const menu = MethodChannel('busyapi/native_menus');
        messenger.setMockMethodCallHandler(menu, (call) async {
          if (call.method != 'show') return null;
          final entries = (call.arguments['entries'] as List).cast<Map>();
          final selected = entries.indexWhere(
            (entry) => entry['label'] == 'New source file…',
          );
          expect(selected, greaterThanOrEqualTo(0));
          return selected;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(menu, null));
        final temp = Directory.systemTemp.createTempSync('busyapi-extract-ui-');
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        Future<void>? pending;
        final errors = <Object>[];
        Future<void> waitFor(bool Function() ready) async {
          final timer = Stopwatch()..start();
          await tester.pump();
          while (!ready() && errors.isEmpty && timer.elapsed.inSeconds < 15) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(errors, isEmpty);
          expect(
            ready(),
            true,
            reason: 'owner=${c.selectedPointer}; ${c.error}',
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

        Future<void> button(String label) => tester.runAsync(
          () => tester.tap(find.widgetWithText(BusyApiDialogButton, label)),
        );
        Finder field(String label) => find.descendant(
          of: find.widgetWithText(BusyApiGroupedTextEntry, label),
          matching: find.byType(TextField),
        );
        bool currentText(String label) => find
            .text(label)
            .evaluate()
            .any((e) => ModalRoute.of(e)?.isCurrent == true);
        try {
          final ext = json ? 'json' : 'yaml',
              root = File('${temp.path}/root.$ext'),
              destination = File('${temp.path}/new 雪.$ext');
          final swagger = version == '2.0';
          final pointer = swagger
              ? '/paths/~1items/get/responses/200'
              : '/components/schemas/Owner/properties/child';
          final movedPointer = swagger ? '/Stored' : '';
          final bindingPointer = swagger
              ? '/Stored'
              : '/components/schemas/Stored';
          final modernSource = json
              ? jsonEncode({
                  'openapi': version,
                  'info': {'title': 'Extraction 雪😀', 'version': '1'},
                  'paths': <String, Object?>{},
                  'components': {
                    'schemas': {
                      'Owner': {
                        'properties': {
                          'child': {
                            'type': 'object',
                            'properties': {'n': false},
                            'examples': [
                              {'n': 'EXACT', r'$ref': 'literal payload'},
                            ],
                          },
                        },
                      },
                    },
                  },
                }).replaceAll('"EXACT"', '900719925474099312345678901')
              : '# retained 雪😀\r\nopenapi: $version\r\ninfo: {title: Extraction, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Owner:\n      properties:\n        child:\n          type: object # kept constraint\n          properties: {n: false}\n          examples: [{n: 900719925474099312345678901, \$ref: "literal payload"}]';
          final source = !swagger
              ? modernSource
              : json
              ? jsonEncode({
                  'swagger': '2.0',
                  'info': {'title': 'Extraction 雪😀', 'version': '1'},
                  'paths': {
                    '/items': {
                      'get': {
                        'responses': {
                          '200': {
                            'description': 'Native response',
                            'schema': {r'$ref': '#/definitions/Model'},
                            'examples': {
                              'application/json': {
                                'n': 'EXACT',
                                r'$ref': 'literal payload',
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                  'definitions': {
                    'Model': {
                      'type': 'object',
                      'properties': {
                        'n': {'type': 'integer'},
                        'next': {r'$ref': '#/definitions/Model'},
                      },
                    },
                  },
                }).replaceAll('"EXACT"', '900719925474099312345678901')
              : '# retained 雪😀\r\nswagger: "2.0"\r\ninfo: {title: Extraction, version: "1"}\npaths:\n  /items:\n    get:\n      responses:\n        "200":\n          description: Native response # retained\n          schema: {\$ref: "#/definitions/Model"}\n          examples: {application/json: {n: 900719925474099312345678901, \$ref: "literal payload"}}\ndefinitions:\n  Model:\n    type: object\n    properties:\n      n: {type: integer}\n      next: {\$ref: "#/definitions/Model"}';
          await tester.runAsync(() async {
            await root.writeAsString('\ufeff$source');
            await c.initialize();
            await c.open(root.path);
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
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: c,
                  builder: (_, _) => Designer(
                    controller: c,
                    run: (action) => pending = action().catchError((Object e) {
                      errors.add(e);
                    }),
                    reveal: (_) {},
                  ),
                ),
              ),
            ),
          );
          final owner = c.buffer!, original = owner.bytes();
          Future<void> captureFile() async {
            await waitFor(
              () => find
                  .widgetWithText(BusyApiActionRow, 'Extract to component…')
                  .evaluate()
                  .any((e) => (e.widget as BusyApiActionRow).onTap != null),
            );
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiActionRow, 'Extract to component…'),
              ),
            );
            await waitFor(
              () =>
                  field('Name')
                      .evaluate()
                      .any((e) => ModalRoute.of(e)?.isCurrent == true),
            );
            await tester.runAsync(
              () => tester.enterText(field('Name'), 'Stored'),
            );
            await tester.runAsync(
              () => tester.tap(find.text('Component destination')),
            );
            await waitFor(
              () => find
                  .widgetWithText(
                    BusyApiComboRow<String>,
                    'Component destination',
                  )
                  .evaluate()
                  .any(
                    (e) =>
                        (e.widget as BusyApiComboRow<String>).selected ==
                        'busyapi:new-source-file',
                  ),
            );
            await button('Apply');
            await waitFor(() => currentText('Extract to new source file'));
            expect(find.byType(BusyApiDialogShell), findsOneWidget);
            await tester.runAsync(
              () => tester.enterText(field('Destination path'), 'new 雪.$ext'),
            );
          }

          await captureFile();
          if (version == '3.1.2' && !json) {
            final recovered = FormSession.restore(c.form!.recovery());
            await tester.runAsync(c.persist);
            await button('Cancel');
            await settleAction();
            c.form = recovered;
            await tester.runAsync(() async {
              pending = resumeCapturedForm(
                tester.element(find.byType(Designer)),
                c,
              );
            });
            await waitFor(() => currentText('Extract to new source file'));
            expect(
              tester
                  .widget<TextField>(field('Destination path'))
                  .controller!
                  .text,
              'new 雪.$ext',
            );
          }
          await button('Cancel');
          await settleAction();
          expect(owner.bytes(), original);
          expect(destination.existsSync(), false);
          Future<void> review() async {
            await captureFile();
            await button('Apply');
            await waitFor(
              () => currentText('Review extraction to source file'),
            );
            expect(find.textContaining(bindingPointer), findsWidgets);
            expect(owner.bytes(), original);
            expect(destination.existsSync(), false);
          }

          await review();
          final retiredApply = tester
              .widget<BusyApiDialogButton>(
                find.widgetWithText(BusyApiDialogButton, 'Apply'),
              )
              .onPressed!;
          await button('Cancel');
          retiredApply();
          await settleAction();
          expect(owner.bytes(), original);
          expect(
            c.store!.buffers.containsKey(destination.uri.toString()),
            false,
          );
          await review();
          final reading = jsonEncode([
                c.root,
                owner.id,
                pointer,
                'description',
              ]),
              movedReading = jsonEncode([
                c.root,
                destination.uri.toString(),
                movedPointer,
                'description',
              ]);
          c.layoutState = {
            ...c.layoutState,
            'sourceFolds': {
              jsonEncode([c.root, owner.id]): [pointer, '/info'],
            },
            'referenceText': {
              reading: {'page': 1},
            },
          };
          await button('Apply');
          await settleAction();
          expect(c.selectedResource, destination.uri.toString());
          expect(c.selectedPointer, movedPointer);
          final created = c.store!.get(destination.uri.toString()),
              changed = owner.bytes();
          expect(created.text, contains('900719925474099312345678901'));
          expect(created.text, isNot(contains('openapi')));
          expect(created.present, true);
          expect(created.publishedPresent, false);
          expect(c.sourceFolds(c.root!, created.id), contains(movedPointer));
          expect((c.layoutState['referenceText'] as Map)[movedReading], {
            'page': 1,
          });
          expect(destination.existsSync(), false);
          final checked = await tester.runAsync(
            () => c.project!.check(c.root!),
          );
          expect(
            checked!['status'],
            'complete',
            reason: '${checked['findings']}',
          );
          await tester.runAsync(c.undo);
          expect(owner.bytes(), original);
          expect(c.selectedResource, owner.id);
          expect(c.selectedPointer, pointer);
          expect(c.store!.canUndo, false);
          expect(c.sourceFolds(c.root!, owner.id), contains(pointer));
          expect((c.layoutState['referenceText'] as Map)[reading], {'page': 1});
          await tester.runAsync(c.redo);
          expect(c.selectedResource, created.id);
          expect(c.selectedPointer, movedPointer);
          expect(owner.bytes(), changed);
          await tester.runAsync(c.saveAll);
          expect(root.readAsBytesSync(), changed);
          expect(destination.readAsBytesSync(), created.bytes());
          final reopened = await tester.runAsync(
            () => BusyProject.open(root.path, c.engine),
          );
          expect(
            (await tester.runAsync(() => reopened!.buffer(created.id)))!.text,
            created.text,
          );
          reopened!.close();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            c.dispose();
            await c.engine.close();
            await temp.delete(recursive: true);
          });
        }
      });
    }
  }
}
