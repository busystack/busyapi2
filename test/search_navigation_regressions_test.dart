import 'dart:io';

import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/workspace/api_tree_row.dart';
import 'package:busyapi/src/workspace/search_session.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  setUp(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => <String, Object?>{},
          );
    }
  });
  tearDown(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  for (final files in [false, true]) {
    testWidgets(
      'navigation search keyboard selection activates the visible ${files ? 'Files' : 'API operation'} model',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final dir = Directory.systemTemp.createTempSync(
          'busyapi-visible-navigation-',
        );
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${dir.path}/config',
            state: '${dir.path}/state',
            cache: '${dir.path}/cache',
          ),
        );
        final root = File('${dir.path}/openapi.yaml')
          ..writeAsStringSync('''
openapi: 3.1.2
info: {title: Visible navigation, version: '1'}
paths:
  /pets:
    get: {responses: {'200': {description: OK}}}
''');
        final first = File('${dir.path}/pets-first.yaml')
          ..writeAsStringSync('first: retained\n');
        final second = File('${dir.path}/pets-second.yaml')
          ..writeAsStringSync('second: retained\n');
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(root.path);
            await c.analyse();
            c.project!.files.addAll([first.path, second.path]);
            c.project!.files.sort();
            c.mode = 'Source';
            c.layoutState = {...c.layoutState, 'files': files};
          });
          await tester.pumpWidget(
            ProviderScope(
              overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
              child: BusyApiApp(controller: c),
            ),
          );
          await tester.pumpAndSettle();
          final workspace = tester.state<WorkspaceScreenState>(
            find.byType(WorkspaceScreen),
          );
          final search = workspace.search;
          search.open(BusyApiSearchCategory.navigation);
          search.query.text = files ? 'pets' : '/pets';
          await tester.pumpAndSettle();
          final entry = find.descendant(
            of: find.byType(BusyApiSearchField),
            matching: find.byType(EditableText),
          );
          await tester.showKeyboard(entry);
          final queryFocus = tester.widget<EditableText>(entry).focusNode;
          expect(queryFocus.hasFocus, true);
          if (files) {
            BusyApiSidebarRecordRow selected() => tester
                .widgetList<BusyApiSidebarRecordRow>(
                  find.byType(BusyApiSidebarRecordRow<String>),
                )
                .singleWhere((row) => row.selected);
            expect(selected().title, 'pets-first.yaml');
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(selected().title, 'pets-second.yaml');
            expect(queryFocus.hasFocus, true);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            for (
              var i = 0;
              i < 100 && c.active != Uri.file(second.path).toString();
              i++
            ) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump();
            }
            expect(c.active, Uri.file(second.path).toString());
            expect(c.buffer!.text, 'second: retained\n');
            expect(c.mode, 'Source');
          } else {
            for (final query in ['/pets', 'pets']) {
              search.query.text = query;
              await tester.pumpAndSettle();
              String selected() => tester
                  .widgetList<BusyApiTreeRow>(find.byType(BusyApiTreeRow))
                  .singleWhere((row) => row.selected)
                  .title;
              // Ancestors remain visible and selectable, just like the actual
              // tree. The highlighted operation is the keyboard activation.
              for (var i = 0; i < 5 && selected() != 'GET /pets'; i++) {
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
                await tester.pump();
              }
              expect(selected(), 'GET /pets');
              expect(queryFocus.hasFocus, true);
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              for (
                var i = 0;
                i < 100 && c.selectedPointer != '/paths/~1pets/get';
                i++
              ) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump();
              }
              expect(c.selectedPointer, '/paths/~1pets/get');
              expect(
                c.active,
                Uri.file(root.path).toString(),
                reason: 'Matching file paths are absent from the visible API search model',
              );
            }
          }
          final heldActivation =
              workspace.searchKey.currentState!.activateSelected;
          search.close();
          await tester.runAsync(
            () => c.openFile(Uri.file(first.path).toString()),
          );
          await tester.runAsync(heldActivation);
          expect(
            c.active,
            Uri.file(first.path).toString(),
            reason: 'A retained callback cannot activate navigation after search closes',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          dir.deleteSync(recursive: true);
        }
      },
    );
  }
}
