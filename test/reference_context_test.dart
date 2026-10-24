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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'Reference $version context menu preserves occurrence ownership, authored definition and restart state',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
              'busyapi-native-context-',
            ),
            file = File('${temp.path}/root.json'),
            part = File('${temp.path}/part.json');
        final modern = version.startsWith('3.2'),
            method = modern ? 'COPY' : 'get',
            suffix = modern ? '/additionalOperations/COPY' : '/get',
            pointer = '/Shared$suffix';
        final operation = {
          'summary': 'Shared authored operation',
          'responses': {
            '204': {'description': 'No content'},
          },
        };
        final text = jsonEncode({
          'openapi': version,
          'info': {'title': 'Context reading', 'version': '1'},
          'paths': {
            for (final name in [
              'one',
              'two',
              if (modern)
                for (var n = 0; n < 51; n++) 'extra-$n',
            ])
              '/$name': {
                r'$ref': 'part.json#/Shared',
                'servers': [
                  {'url': 'https://$name.invalid'},
                ],
              },
          },
        });
        final partText = jsonEncode({
          'Shared': modern
              ? {
                  'additionalOperations': {'COPY': operation},
                }
              : {'get': operation},
        });
        file.writeAsStringSync(text);
        part.writeAsStringSync(partText);
        WorkspaceController workspace() => WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        var c = workspace();
        String? nextMenuLabel;
        var menuCalls = 0;
        const menuChannel = MethodChannel('busyapi/native_menus');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(menuChannel, (call) async {
          if (call.method != 'show') return null;
          menuCalls++;
          final entries = (call.arguments as Map)['entries'] as List;
          expect(
            entries.map((entry) => entry['label']),
            contains('Authored definition'),
          );
          expect(
            entries.length,
            lessThanOrEqualTo(52),
            reason: 'The native menu contains only one lazy page and any selected off-page context',
          );
          final index = entries.indexWhere(
            (entry) => entry['label'] == nextMenuLabel,
          );
          expect(index, greaterThanOrEqualTo(0));
          return index;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(menuChannel, null),
        );
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
        BusyApiComboRow<String>? combo() => find
            .byType(BusyApiComboRow<String>)
            .evaluate()
            .map((element) => element.widget as BusyApiComboRow<String>)
            .firstOrNull;
        Future<void> ready(bool Function() condition) async {
          await tester.pump();
          final watch = Stopwatch()..start();
          while (!condition() && watch.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            condition(),
            true,
            reason: 'Context page did not settle; error=${c.error}',
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> choose(String label, String selected) async {
          await ready(() => combo()?.enabled == true);
          final previous = menuCalls;
          nextMenuLabel = label;
          await tester.tap(find.byType(BusyApiComboRow<String>));
          await tester.pump();
          await ready(
            () =>
                combo()?.selected == selected &&
                find.text('Checking…').evaluate().isEmpty,
          );
          expect(
            menuCalls,
            previous + 1,
            reason: 'The real combo trigger must route selection through the native menu service',
          );
        }

        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            c.mode = 'Reference';
            await c.selectObject({
              'root': c.root,
              'resource': part.uri.toString(),
              'pointer': pointer,
              'method': method,
              'path': '/one',
              'occurrence': '${c.root}#/paths/~1one$suffix',
            });
            await c.analyse();
          });
          await tester.pumpWidget(screen());
          final root = c.root!,
              one = '$root#/paths/~1one$suffix',
              two = '$root#/paths/~1two$suffix';
          await ready(() => combo()?.selected == one);
          final sourcePointer = c.selectedPointer;
          await choose('${modern ? 'COPY' : 'GET'} /two', two);
          expect(
            c.selectedPointer,
            sourcePointer,
            reason: 'Read-only context selection must not retarget the Source caret',
          );
          expect(
            tester
                .widget<ReferenceObjectView>(find.byType(ReferenceObjectView))
                .target['occurrence'],
            two,
          );
          if (modern) {
            final last = '$root#/paths/~1extra-50$suffix';
            expect(combo()!.values, hasLength(51));
            expect(combo()!.values, isNot(contains(last)));
            await tester.tap(find.widgetWithText(FilledButton, 'Next').first);
            await ready(
              () =>
                  combo()?.values.contains(last) == true &&
                  combo()?.enabled == true,
            );
            expect(
              combo()!.selected,
              two,
              reason: 'Paging never retargets the selected occurrence',
            );
            expect(
              combo()!.values,
              hasLength(5),
              reason: 'Three final contexts, selected off-page owner, and authored definition',
            );
            await choose('COPY /extra-50', last);
            await choose('COPY /two', two);
          }
          await choose('Authored definition', '');
          expect(
            tester
                .widget<ReferenceObjectView>(find.byType(ReferenceObjectView))
                .target
                .containsKey('occurrence'),
            false,
          );
          expect(
            find.text(
              'Definition only. Select a Path Item occurrence to inspect inherited declarations.',
            ),
            findsOneWidget,
          );
          await choose('${modern ? 'COPY' : 'GET'} /two', two);
          await tester.runAsync(() async {
            c.store!.replace(
              root,
              c.store!.buffers[root]!.text.replaceFirst(
                'Context reading',
                'Unrelated unsaved edit',
              ),
            );
            await c.analyse();
          });
          await ready(() => combo()?.selected == two && !c.checking);
          final keys = (c.layoutState['referenceObjects'] as Map).keys
              .map((key) => jsonDecode(key as String) as List)
              .where((key) => key[2] == pointer)
              .toList();
          expect(keys.any((key) => key.length == 5 && key[4] == one), true);
          expect(keys.any((key) => key.length == 5 && key[4] == two), true);
          expect(keys.any((key) => key.length == 5 && key[4] == null), true);
          expect(file.readAsStringSync(), text);
          final moved = File('${temp.path}/moved.json'),
              movedTwo = '${moved.uri}#/paths/~1two$suffix';
          await tester.runAsync(() async {
            await c.applyRefactoring(
              c.project!,
              await c.project!.planFileMove(root, moved.path),
            );
            await c.analyse();
          });
          await ready(
            () =>
                c.root == moved.uri.toString() && combo()?.selected == movedTwo,
          );
          expect(
            tester
                .widget<ReferenceObjectView>(find.byType(ReferenceObjectView))
                .target['resource'],
            part.uri.toString(),
          );
          await tester.runAsync(() async {
            await c.undo();
            await c.analyse();
          });
          await ready(() => c.root == root && combo()?.selected == two);
          await tester.runAsync(() async {
            await c.redo();
            await c.analyse();
          });
          await ready(
            () =>
                c.root == moved.uri.toString() && combo()?.selected == movedTwo,
          );
          await tester.runAsync(() async {
            await c.saveBuffers();
            await c.persistView();
          });
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          c = workspace();
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(moved.path);
            await c.analyse();
          });
          await tester.pumpWidget(screen());
          await ready(() => combo()?.selected == movedTwo);
          expect(
            tester
                .widget<ReferenceObjectView>(find.byType(ReferenceObjectView))
                .target['occurrence'],
            movedTwo,
          );
          expect(part.readAsStringSync(), partText);
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
