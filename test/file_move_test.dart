import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/file_move.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final partial in [false, true]) {
    testWidgets(
      'workspace Discard preserves unrelated edits and published versions partial=$partial',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-file-discard-ui-',
        );
        var stopped = false;
        final publications = PublicationStore(
          '${temp.path}/state/publication',
          afterPublish: (_) async {
            if (partial && !stopped) {
              stopped = true;
              throw CoreFailure('test.pause', 'before receipt');
            }
          },
        );
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
          publications: publications,
        );
        try {
          await tester.runAsync(() async {
            await Initializer.create(
              destination: '${temp.path}/api',
              title: 'Discard',
              apiVersion: '1',
            );
            final notesFile = File('${temp.path}/api/notes.yaml');
            await notesFile.writeAsString('original notes\n');
            await c.initialize();
            await c.open('${temp.path}/api');
            final owner = c.project!,
                b = c.buffer!,
                source = File(b.path),
                original = await source.readAsBytes(),
                destination = File('${temp.path}/api/new.yaml');
            final notes = await owner.buffer(notesFile.uri.toString());
            owner.store.replace(notes.id, 'unrelated unsaved 🐾\n');
            await c.applyRefactoring(
              owner,
              await owner.planFileMove(b.id, destination.path),
            );
            if (partial) {
              await expectLater(
                c.saveBuffers(only: {b.id}),
                throwsA(
                  isA<CoreFailure>().having(
                    (e) => e.code,
                    'code',
                    'save.partial',
                  ),
                ),
              );
              expect(b.pendingFilePublication, true);
              expect(
                b.dirty,
                true,
                reason: 'Remaining publication cannot look clean',
              );
              expect(destination.existsSync(), true);
            }
            await c.discardBuffers(only: {b.id});
            expect(c.root, source.uri.toString());
            expect(owner.roots.single.id, c.root);
            expect(publications.hasPendingFileMoves(owner), false);
            expect(await source.readAsBytes(), original);
            expect(await notesFile.readAsString(), 'original notes\n');
            expect(notes.text, 'unrelated unsaved 🐾\n');
            expect(notes.dirty, true);
            expect(destination.existsSync(), partial);
            expect(b.pendingFilePublication, false);
            expect(c.error, isNull);
          });
          await tester.pump();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.runAsync(c.shutdown);
          c.dispose();
          await tester.runAsync(c.engine.close);
          await tester.runAsync(() => temp.delete(recursive: true));
        }
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final retainIdentity in [false, true]) {
        testWidgets(
          'file-move controls $version $json retained=$retainIdentity review/cancel/apply, root/view history and publication',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            for (final name in ['yaru_window', 'yaru_window/events']) {
              messenger.setMockMethodCallHandler(
                MethodChannel(name),
                (_) async => null,
              );
              addTearDown(
                () => messenger.setMockMethodCallHandler(
                  MethodChannel(name),
                  null,
                ),
              );
            }
            final temp = Directory.systemTemp.createTempSync(
              'busyapi-native-file-',
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
                reason: 'error=${c.error} storage=${c.storageError}',
              );
              await tester.pumpAndSettle();
            }

            Future<void> complete() async {
              var done = false;
              await tester.runAsync(() async {
                pending!.then((_) => done = true);
              });
              await waitFor(() => done);
            }

            Future<void> button(String label) => tester.runAsync(
              () => tester.tap(find.widgetWithText(BusyApiDialogButton, label)),
            );
            try {
              final ext = json ? 'json' : 'yaml';
              final root = File('${temp.path}/root.$ext'),
                  destination = File('${temp.path}/新しい.$ext');
              final text = jsonEncode({
                'openapi': version,
                'info': {'title': 'Native files', 'version': '1'},
                'paths': {},
                'components': {
                  'schemas': {
                    'Model': {'type': 'string'},
                  },
                },
              });
              final folded = version == '3.2.1' && json
                  ? <String>[]
                  : ['/components/schemas'];
              await tester.runAsync(() async {
                await root.writeAsString('\ufeff$text');
                await File('${temp.path}/busyapi.yaml').writeAsString(
                  'version: 1\nroots:\n  - name: Main\n    path: root.$ext # keep\n',
                );
                await c.initialize();
                await c.open(temp.path);
                c.layoutState = {
                  'sourceFolds': {
                    jsonEncode([root.uri.toString(), root.uri.toString()]):
                        folded,
                  },
                  'objectPages': {
                    '${root.uri}#${root.uri}#/components/schemas/Model': {
                      'search': 'needle',
                    },
                  },
                  'referenceText': {
                    jsonEncode([
                      root.uri.toString(),
                      root.uri.toString(),
                      '/components/schemas/Model',
                      'description',
                    ]): 91.0,
                  },
                };
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
                    body: Builder(
                      builder: (context) => BusyApiActionRow(
                        title: 'Move file…',
                        onTap: () => pending =
                            showFileMove(
                              context,
                              c,
                              root.uri.toString(),
                            ).catchError((Object e) {
                              errors.add(e);
                            }),
                      ),
                    ),
                  ),
                ),
              );
              final b = c.buffer!;
              b.selection = const SourceSelection(3, 11);
              b.scroll = 89;
              final original = b.bytes();
              for (final apply in [false, true]) {
                await tester.runAsync(
                  () => tester.tap(find.text('Move file…')),
                );
                await waitFor(
                  () => find
                      .widgetWithText(
                        BusyApiGroupedTextEntry,
                        'Destination path',
                      )
                      .evaluate()
                      .isNotEmpty,
                );
                final field = find.descendant(
                  of: find.widgetWithText(
                    BusyApiGroupedTextEntry,
                    'Destination path',
                  ),
                  matching: find.byType(TextField),
                );
                await tester.enterText(field, '新しい.$ext');
                if (retainIdentity) {
                  await tester.tap(
                    find.widgetWithText(
                      BusyApiSwitchRow,
                      'Retain original resource URI context',
                    ),
                  );
                }
                await tester.pump();
                expect(
                  tester
                      .widget<BusyApiSwitchRow>(
                        find.widgetWithText(
                          BusyApiSwitchRow,
                          'Retain original resource URI context',
                        ),
                      )
                      .value,
                  retainIdentity,
                );
                await button('Apply');
                await waitFor(
                  () => find.text('Review file move').evaluate().isNotEmpty,
                );
                expect(b.id, root.uri.toString());
                expect(destination.existsSync(), false);
                expect(
                  find.textContaining('need an equivalent mapping'),
                  retainIdentity ? findsOneWidget : findsNothing,
                );
                expect(
                  find.textContaining('Only the physical path changes'),
                  findsOneWidget,
                );
                await button(apply ? 'Apply' : 'Cancel');
                await complete();
                if (!apply) {
                  expect(b.id, root.uri.toString());
                  expect(b.bytes(), original);
                }
              }
              expect(b.id, destination.uri.toString());
              expect(
                c.project!.approvedResources[root.uri.toString()],
                retainIdentity ? b.id : isNull,
              );
              expect(c.root, b.id);
              expect(c.active, b.id);
              expect(c.tabs, contains(b.id));
              expect(c.tabs, isNot(contains(root.uri.toString())));
              expect(b.selection.base, 3);
              expect(b.scroll, 89);
              expect(c.sourceFolds(b.id, b.id), folded);
              expect(
                (c.layoutState['sourceFolds'] as Map).containsKey(
                  jsonEncode([b.id, b.id]),
                ),
                true,
              );
              final reading = c.layoutState['referenceText'] as Map;
              expect(
                reading[jsonEncode([
                  b.id,
                  b.id,
                  '/components/schemas/Model',
                  'description',
                ])],
                91.0,
              );
              await tester.runAsync(c.undo);
              expect(c.root, root.uri.toString());
              expect(b.id, c.root);
              expect(c.sourceFolds(c.root!, b.id), folded);
              await tester.runAsync(c.redo);
              expect(c.root, b.id);
              expect(b.id, destination.uri.toString());
              await tester.runAsync(() => c.saveBuffers(only: {b.id}));
              expect(b.dirty, false);
              expect(root.existsSync(), false);
              expect(await tester.runAsync(destination.readAsBytes), original);
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.runAsync(c.shutdown);
              c.dispose();
              await tester.runAsync(c.engine.close);
              await tester.runAsync(() => temp.delete(recursive: true));
            }
          },
        );
      }
    }
  }
}
