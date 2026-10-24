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
        'Design parameter ownership and all later collection entries $version json=$json',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1100);
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
          final temp = Directory.systemTemp.createTempSync(
                'busyapi-design-parameters-',
              ),
              suffix = json ? 'json' : 'yaml',
              file = File('${temp.path}/root.$suffix'),
              part = File('${temp.path}/part.$suffix');
          final source =
              (json ? '' : '\ufeff# retained 雪😀\r\n') +
              jsonEncode({
                'openapi': version,
                'info': {'title': 'Located authoring', 'version': '1'},
                'paths': {
                  '/local': {
                    r'$ref': 'part.$suffix#/Shared',
                    'post': {
                      'summary': 'Local operation',
                      'parameters': [
                        for (var n = 0; n < 261; n++)
                          {
                            'name': 'p$n',
                            'in': 'query',
                            'schema': {'type': 'string'},
                          },
                      ],
                      'responses': {
                        '204': {
                          'description':
                              'Bodyless ${'description '.padRight(100000, 'x')}',
                        },
                      },
                    },
                  },
                },
                'x-exact': 111,
              }).replaceFirst('"x-exact":111', '"x-exact":9007199254740993.00');
          final inheritedCount = version.startsWith('3.2') && json ? 201 : 1;
          final originalPart =
              (json ? '' : '# original parameter owner\r\n') +
              jsonEncode({
                'Shared': {
                  'parameters': [
                    for (var n = 0; n < inheritedCount; n++)
                      {
                        'name': n == 0 ? 'InheritedKey' : 'InheritedKey$n',
                        'in': 'header',
                        'description': 'Inherited original',
                        'schema': {'type': 'string'},
                      },
                  ],
                },
                'x-data': {'n': 111, r'$ref': 'literal payload'},
              }).replaceFirst('"n":111', '"n":9007199254740993.00');
          file.writeAsStringSync(source);
          part.writeAsStringSync(originalPart);
          final originalBytes = file.readAsBytesSync(),
              c = WorkspaceController(
                EngineProcess(executable: runtimeNode, helper: runtimeHelper),
                StateLocations(
                  config: '${temp.path}/config',
                  state: '${temp.path}/state',
                  cache: '${temp.path}/cache',
                ),
              );
          final errors = <Object>[];
          Future<void>? pending;
          Future<void> ready(bool Function() condition) async {
            await tester.pump();
            final watch = Stopwatch()..start();
            while (!condition() &&
                errors.isEmpty &&
                watch.elapsed < const Duration(seconds: 12)) {
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
                  'Selected ${c.selectedResource}#${c.selectedPointer}; ${c.error}',
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          Future<void> tap(Finder target) async {
            await tester.runAsync(() => tester.ensureVisible(target));
            await tester.pumpAndSettle();
            await tester.runAsync(() => tester.tap(target));
            await tester.pump();
            if (pending != null) {
              var done = false;
              pending!.whenComplete(() => done = true);
              await ready(() => done);
            }
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/paths/~1local/post',
                'occurrence': '${c.root}#/paths/~1local/post',
              });
              await c.analyse();
            });
            final root = c.root!, rootWorking = c.store!.get(root).text;
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
            expect(
              find.byType(BusyApiActionRow).evaluate().length,
              lessThan(150),
              reason:
                  'The compact page must not construct all 261 parameter rows',
            );
            expect(find.text('p260'), findsNothing);
            expect(
              find.byWidgetPredicate(
                (widget) => widget is Text && (widget.data?.length ?? 0) > 5000,
              ),
              findsNothing,
              reason: 'A large response description is bounded before native text layout',
            );
            await tap(find.widgetWithText(BusyApiActionRow, 'InheritedKey'));
            await ready(
              () =>
                  c.selectedResource == part.uri.toString() &&
                  c.selectedPointer == '/Shared/parameters/0' &&
                  find
                      .widgetWithText(BusyApiGroupedTextEntry, 'Description')
                      .evaluate()
                      .isNotEmpty,
            );
            final description = find.descendant(
              of: find.widgetWithText(BusyApiGroupedTextEntry, 'Description'),
              matching: find.byType(TextField),
            );
            await tester.runAsync(
              () => tester.enterText(description, 'Native definition'),
            );
            await tester.runAsync(() async {
              expect(await c.flush(), true);
              await c.analyse();
            });
            await ready(() => !c.checking);
            expect(c.store!.get(root).text, rootWorking);
            expect(
              c.store!.get(part.uri.toString()).text,
              originalPart.replaceFirst(
                'Inherited original',
                'Native definition',
              ),
            );
            await tester.runAsync(() async {
              await c.undo();
              await c.analyse();
            });
            expect(c.store!.get(part.uri.toString()).text, originalPart);
            await tester.runAsync(() async {
              await c.redo();
              await c.analyse();
              await c.saveBuffers();
              await c.selectObject({
                'root': root,
                'resource': root,
                'pointer': '/paths/~1local/post',
                'occurrence': '$root#/paths/~1local/post',
              });
              await c.analyse();
            });
            await ready(
              () => find
                  .widgetWithText(BusyApiActionRow, 'View all 261 entries')
                  .evaluate()
                  .isNotEmpty,
            );
            if (inheritedCount > 50) {
              await tap(
                find.widgetWithText(
                  BusyApiActionRow,
                  'View all $inheritedCount entries',
                ),
              );
              await ready(
                () =>
                    c.selectedResource == part.uri.toString() &&
                    c.selectedPointer == '/Shared/parameters' &&
                    find.text('0').evaluate().isNotEmpty,
              );
              for (var page = 1; page <= 4; page++) {
                await tap(find.widgetWithText(BusyApiDialogButton, 'Next'));
                await ready(
                  () => find
                      .widgetWithText(BusyApiActionRow, '${page * 50}')
                      .evaluate()
                      .isNotEmpty,
                );
              }
              await tap(find.widgetWithText(BusyApiActionRow, '200'));
              await ready(
                () =>
                    c.selectedPointer == '/Shared/parameters/200' &&
                    find
                        .widgetWithText(BusyApiGroupedTextEntry, 'Name')
                        .evaluate()
                        .isNotEmpty,
              );
              final lastName = find.descendant(
                of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
                matching: find.byType(TextField),
              );
              expect(
                tester.widget<TextField>(lastName).controller!.text,
                'InheritedKey200',
              );
              await tester.runAsync(() async {
                await c.selectObject({
                  'root': root,
                  'resource': root,
                  'pointer': '/paths/~1local/post',
                  'occurrence': '$root#/paths/~1local/post',
                });
                await c.analyse();
              });
              await ready(
                () => find
                    .widgetWithText(BusyApiActionRow, 'View all 261 entries')
                    .evaluate()
                    .isNotEmpty,
              );
            }
            await tap(
              find.widgetWithText(BusyApiActionRow, 'View all 261 entries'),
            );
            await ready(
              () =>
                  c.selectedPointer == '/paths/~1local/post/parameters' &&
                  find.text('0').evaluate().isNotEmpty,
            );
            for (var page = 1; page <= 5; page++) {
              await tap(find.widgetWithText(BusyApiDialogButton, 'Next'));
              await ready(
                () => find
                    .widgetWithText(BusyApiActionRow, '${page * 50}')
                    .evaluate()
                    .isNotEmpty,
              );
            }
            await tap(find.widgetWithText(BusyApiActionRow, '260'));
            await ready(
              () =>
                  c.selectedPointer == '/paths/~1local/post/parameters/260' &&
                  find
                      .widgetWithText(BusyApiGroupedTextEntry, 'Name')
                      .evaluate()
                      .isNotEmpty,
            );
            final name = find.descendant(
              of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
              matching: find.byType(TextField),
            );
            expect(tester.widget<TextField>(name).controller!.text, 'p260');
            expect(file.readAsBytesSync(), originalBytes);
            expect(
              part.readAsStringSync(),
              originalPart.replaceFirst(
                'Inherited original',
                'Native definition',
              ),
            );
            expect(c.store!.get(root).text, rootWorking);
            expect(c.store!.get(root).dirty, false);
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
