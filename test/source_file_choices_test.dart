import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'Swagger $format $brightness Source file completion edits its captured fragment',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-file-choice-widget-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          final changes = ValueNotifier(0),
              key = GlobalKey<SourceEditorState>();
          BusyProject? project;
          final root = File('${directory.path}/api.json');
          final fragment = File('${directory.path}/types.$format');
          final original = format == 'json'
              ? '{\r\n  "File": {"type": "string"},\r\n  "x-keep": {"value": false}\r\n}\r\n'
              : "# Keep 雪 and quotes\r\nFile:\r\n  type: 'string'\r\nx-keep: &value {value: false}\r\nx-mirror: *value\r\n";
          final source = jsonEncode({
            'swagger': '2.0',
            'info': {'title': 'Source', 'version': 'unrelated'},
            'paths': {
              '/value': {
                'get': {
                  'responses': {
                    '200': {
                      'description': 'Keep',
                      'schema': {r'$ref': './types.$format#/File'},
                    },
                  },
                },
              },
            },
          });
          late DocumentBuffer buffer;
          try {
            await tester.runAsync(() async {
              await root.writeAsString(source);
              await fragment.writeAsBytes([
                0xef,
                0xbb,
                0xbf,
                ...utf8.encode(original),
              ]);
              project = await BusyProject.open(root.path, engine);
              buffer = await project!.buffer(fragment.uri.toString());
              final checked = await project!.check(root.uri.toString());
              expect(checked['status'], 'complete', reason: '$checked');
            });
            final before = buffer.bytes(),
                caret = buffer.text.indexOf('string') + 2;
            buffer.selection = SourceSelection(caret, caret);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: brightness,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: SourceEditor(
                    key: key,
                    buffer: buffer,
                    owner: project,
                    changes: changes,
                    assistance: (selection) => project!.sourceAssistance(
                      root.uri.toString(),
                      buffer.id,
                      selection,
                    ),
                    onEdit: (edit) {
                      project!.store.apply([edit], label: 'Source completion');
                      changes.value++;
                    },
                    onChanged: (_) => fail(
                      'Completion bypassed the captured edit transaction',
                    ),
                    undo: () {
                      project!.store.undo();
                      changes.value++;
                    },
                    redo: () {
                      project!.store.redo();
                      changes.value++;
                    },
                  ),
                ),
              ),
            );
            await tester.tap(find.byType(TextField));
            key.currentState!.select(
              SourceSelection(caret, caret),
              reveal: false,
            );
            await tester.pump();
            await tester.runAsync(
              () => tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft),
            );
            await tester.runAsync(
              () => tester.sendKeyEvent(LogicalKeyboardKey.space),
            );
            await tester.runAsync(
              () => tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft),
            );
            final watch = Stopwatch()..start();
            while (find.text('7 suggestions').evaluate().isEmpty &&
                watch.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(find.text('7 suggestions'), findsOneWidget);
            // The bounded popup builds visible rows lazily. Navigate its list
            // before selecting the file choice beyond the first six rows.
            for (
              var step = 0;
              step < 7 && find.text('file').evaluate().isEmpty;
              step++
            ) {
              await tester.runAsync(
                () => tester.sendKeyEvent(LogicalKeyboardKey.arrowDown),
              );
              await tester.pump();
            }
            expect(
              find.text('file'),
              findsOneWidget,
              reason: tester
                  .widgetList<Text>(find.byType(Text))
                  .map((value) => value.data)
                  .join('\n'),
            );
            expect(
              find.byKey(const ValueKey('source-assistance-popup')),
              findsOneWidget,
            );
            expect(buffer.bytes(), before);
            await tester.ensureVisible(find.text('file'));
            await tester.pumpAndSettle();
            await tester.runAsync(() => tester.tap(find.text('file')));
            await tester.pumpAndSettle();
            final expected = original.replaceFirst('string', 'file');
            expect(buffer.text, expected);
            expect(buffer.hasBom, isTrue);
            expect(
              find.byKey(const ValueKey('source-assistance-popup')),
              findsNothing,
            );
            final accepted = buffer.bytes();
            project!.store.undo();
            expect(buffer.bytes(), before);
            project!.store.redo();
            expect(buffer.bytes(), accepted);
            await tester.runAsync(() async {
              final checked = await project!.check(root.uri.toString());
              expect(checked['status'], 'complete', reason: '$checked');
              expect(checked['findings'], isEmpty);
              expect(await root.readAsString(), source);
              expect(await fragment.readAsBytes(), before);
              await project!.save(buffer);
              expect(await fragment.readAsBytes(), accepted);
            });
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              project?.close();
              await engine.close();
              await directory.delete(recursive: true);
            });
            changes.dispose();
          }
        },
      );
    }
  }
}
