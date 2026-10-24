import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        'committed field blur keeps the next mounted input owner $version $format',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-committed-field-',
          );
          final file = File('${directory.path}/root.$format');
          final original = format == 'json'
              ? '\ufeff{\r\n"openapi":"$version","info":{"title":"Start","version":"1"},\n"paths":{},"x-kept":9007199254740993.00}'
              : '\ufeffopenapi: $version\r\ninfo: {title: "Start", version: "1"}\npaths: {}\r\nx-kept: 9007199254740993.00';
          file.writeAsStringSync(original);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final actions = <Future<void>>[], errors = <Object>[];
          Finder field(String label) => find.descendant(
            of: find.widgetWithText(BusyApiGroupedTextEntry, label),
            matching: find.byType(TextField),
          );
          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(file.path);
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
                      run: (action) => actions.add(
                        action().catchError((Object error) {
                          errors.add(error);
                        }),
                      ),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.runAsync(() => tester.tap(field('Title')));
            await tester.runAsync(
              () => tester.enterText(field('Title'), 'Committed'),
            );
            await tester.runAsync(() async {
              expect(await c.flush(), true);
              await c.analyse();
            });
            await tester.pump();
            final bound = c.draft;
            final committedGeneration = c.buffer!.generation;
            expect(bound, isNotNull);
            expect(bound!.pending, false);
            expect(c.projection!['info']['value']['title'], 'Committed');

            // A real focus transition calls the already-committed Title's blur
            // handler before the next field sends input. Do not rebuild away
            // those mounted input callbacks or replace this with another bind.
            await tester.runAsync(() => tester.tap(field('API version')));
            await tester.pump();
            await tester.runAsync(() async {
              await Future.wait(actions);
            });
            expect(c.draft, same(bound));
            expect(c.buffer!.generation, committedGeneration);
            await tester.runAsync(() async {
              await c.persist();
              final records = await Directory(c.recovery.directory)
                  .list()
                  .where(
                    (entry) => entry is File && entry.path.endsWith('.json'),
                  )
                  .cast<File>()
                  .toList();
              expect(records, hasLength(1));
              expect(
                (jsonDecode(await records.single.readAsString())
                    as Map)['draft'],
                isNull,
              );
            });
            await tester.runAsync(
              () => tester.enterText(field('API version'), '2'),
            );
            expect(c.hasPendingFields, true);
            expect(c.draft!.values['version'], '2');
            await tester.runAsync(() async {
              await c.persist();
              final records = await Directory(c.recovery.directory)
                  .list()
                  .where(
                    (entry) => entry is File && entry.path.endsWith('.json'),
                  )
                  .cast<File>()
                  .toList();
              expect(
                (jsonDecode(await records.single.readAsString())
                    as Map)['draft']['values']['version'],
                '2',
              );
              expect(await c.flush(), true);
              await c.analyse();
            });
            await tester.pump();
            expect(errors, isEmpty);
            expect(c.projection!['info']['value']['version'], '2');
            final expected = original
                .replaceFirst('Start', 'Committed')
                .replaceFirst('"1"', '"2"');
            expect(c.buffer!.hasBom, true);
            expect(c.buffer!.text, expected.substring(1));
            await tester.runAsync(() async {
              c.sourceEdit(
                c.buffer!.id,
                c.buffer!.text.replaceFirst(
                  '9007199254740993.00',
                  '9007199254740993.000',
                ),
              );
              await c.persist();
              final records = await Directory(c.recovery.directory)
                  .list()
                  .where(
                    (entry) => entry is File && entry.path.endsWith('.json'),
                  )
                  .cast<File>()
                  .toList();
              expect(
                (jsonDecode(await records.single.readAsString())
                    as Map)['draft'],
                isNull,
              );
              await c.undo();
              expect(c.buffer!.text, expected.substring(1));
              await c.undo();
              expect(
                c.buffer!.text,
                original.replaceFirst('Start', 'Committed').substring(1),
              );
              await c.redo();
              await c.saveAll();
              expect(file.readAsBytesSync(), utf8.encode(expected));
            });
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              await c.open(file.path);
              expect(c.buffer!.text, expected.substring(1));
              expect(c.buffer!.hasBom, true);
            });
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            directory.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
