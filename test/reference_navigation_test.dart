import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/reference/reference_object.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'Reference $version follows explicit navigation and reviewed rename without reparse retargeting',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-reference-navigation-',
        );
        final file = File('${temp.path}/root.json');
        final original = jsonEncode({
          'openapi': version,
          'info': {
            'title': 'Reading',
            'version': '1',
            'contact': {'name': 'Owner'},
          },
          'paths': {},
          'components': {
            'schemas': {
              'Model': {
                'description': List.filled(
                  100,
                  'Readable schema line',
                ).join('\n'),
                'properties': {
                  'value': {'type': 'string'},
                },
                for (var i = 0; i < 40; i++) 'x-note-$i': 'Readable note $i',
              },
              'Use': {r'$ref': '#/components/schemas/Model'},
            },
          },
        });
        file.writeAsStringSync(original);
        WorkspaceController workspace() => WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        var c = workspace();
        Widget screen() => MaterialApp(
          theme: buildBusyApiTheme(
            brightness: Brightness.light,
            accentColor: Colors.blue,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => ReferenceView(controller: c, reveal: (_) {}),
            ),
          ),
        );
        String? pointer() {
          final element = find
              .byType(ReferenceObjectView)
              .evaluate()
              .firstOrNull;
          return element == null
              ? null
              : (element.widget as ReferenceObjectView).target['pointer']
                    as String?;
        }

        Future<void> ready(bool Function() condition) async {
          await tester.pump();
          final watch = Stopwatch()..start();
          while (!condition() && watch.elapsed < const Duration(seconds: 8)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            condition(),
            true,
            reason:
                'Reference pointer=${pointer()} checking=${c.checking} error=${c.error}',
          );
          await tester.pumpAndSettle();
        }

        Future<void> select(String at) async {
          await tester.runAsync(() async {
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': at,
            });
            await c.analyse();
          });
          await ready(
            () => pointer() == at && find.text('Checking…').evaluate().isEmpty,
          );
        }

        ScrollController scroll() => tester
            .widget<ListView>(
              find
                  .descendant(
                    of: find.byType(ReferenceObjectView),
                    matching: find.byType(ListView),
                  )
                  .first,
            )
            .controller!;
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            c.mode = 'Reference';
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': '/components/schemas/Model',
            });
            await c.analyse();
          });
          await tester.pumpWidget(screen());
          // Wait for the real helper page, not just its loading widget.
          await ready(
            () => find
                .descendant(
                  of: find.byType(ReferenceObjectView),
                  matching: find.byType(ListView),
                )
                .evaluate()
                .isNotEmpty,
          );
          await tester.drag(
            find
                .descendant(
                  of: find.byType(ReferenceObjectView),
                  matching: find.byType(ListView),
                )
                .first,
            const Offset(0, -650),
          );
          await tester.pumpAndSettle();
          final offset = scroll().offset;
          expect(offset, greaterThan(200));
          final root = c.root!,
              oldKey = jsonEncode([
                root,
                root,
                '/components/schemas/Model',
                false,
              ]);
          await tester.runAsync(() async {
            c.store!.replace(
              root,
              c.buffer!.text.replaceFirst('Reading', 'Unrelated edit'),
            );
            await c.analyse();
          });
          await ready(
            () => pointer() == '/components/schemas/Model' && !c.checking,
          );
          expect(scroll().offset, closeTo(offset, 1));
          await tester.runAsync(() async {
            final object = await c.project!.inspectObject(
              root,
              root,
              '/components/schemas/Model',
            );
            final plan = await c.project!.planComponentRename({
              'resource': root,
              'pointer': object['pointer'],
              'range': object['range'],
              'generation': object['generation'],
            }, 'Renamed');
            await c.applyRefactoring(c.project!, plan);
            await c.analyse();
          });
          await ready(
            () =>
                pointer() == '/components/schemas/Renamed' &&
                find
                    .descendant(
                      of: find.byType(ReferenceObjectView),
                      matching: find.byType(ListView),
                    )
                    .evaluate()
                    .isNotEmpty,
          );
          expect(scroll().offset, closeTo(offset, 1));
          expect(
            (c.layoutState['referenceObjects'] as Map).containsKey(oldKey),
            false,
            reason: 'Disposed old pages must not resurrect their pre-rename state key',
          );
          await tester.runAsync(() async {
            await c.undo();
            await c.analyse();
          });
          await ready(
            () =>
                pointer() == '/components/schemas/Model' &&
                find
                    .descendant(
                      of: find.byType(ReferenceObjectView),
                      matching: find.byType(ListView),
                    )
                    .evaluate()
                    .isNotEmpty,
          );
          expect(scroll().offset, closeTo(offset, 1));
          await tester.runAsync(() async {
            await c.redo();
            await c.analyse();
          });
          await ready(
            () =>
                pointer() == '/components/schemas/Renamed' &&
                find
                    .descendant(
                      of: find.byType(ReferenceObjectView),
                      matching: find.byType(ListView),
                    )
                    .evaluate()
                    .isNotEmpty,
          );
          await select('/info/contact');
          await ready(() => find.text('Owner').evaluate().isNotEmpty);
          await tester.tap(
            find.widgetWithText(BusyApiActionRow, 'Go Back').first,
          );
          await tester.pump();
          await ready(
            () =>
                pointer() == '/components/schemas/Renamed' &&
                find
                    .descendant(
                      of: find.byType(ReferenceObjectView),
                      matching: find.byType(ListView),
                    )
                    .evaluate()
                    .isNotEmpty,
          );
          expect(c.selectedPointer, '/info/contact');
          await tester.runAsync(c.analyse);
          await ready(() => !c.checking);
          expect(
            pointer(),
            '/components/schemas/Renamed',
            reason: 'An unrelated reparse must not replay the last navigator command',
          );
          final current = c.buffer!.text;
          expect(file.readAsStringSync(), original);
          await tester.runAsync(() async {
            await c.project!.save(c.buffer!);
            await c.persistView();
          });
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          c = workspace();
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            await c.analyse();
          });
          await tester.pumpWidget(screen());
          await ready(
            () =>
                pointer() == '/components/schemas/Renamed' &&
                find
                    .descendant(
                      of: find.byType(ReferenceObjectView),
                      matching: find.byType(ListView),
                    )
                    .evaluate()
                    .isNotEmpty,
          );
          expect(scroll().offset, closeTo(offset, 1));
          expect(c.buffer!.text, current);
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
