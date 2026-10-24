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
  for (final policy in [false, true]) {
    testWidgets(
      'opaque native file controls disclose ownership and policy impacts policy=$policy',
      (tester) async {
        // Widget transport only, not a native GTK window integration pass.
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final name in ['yaru_window', 'yaru_window/events']) {
          messenger.setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => null,
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
          );
        }
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-opaque-controls-',
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
        Future<void> until(bool Function() ready) async {
          final elapsed = Stopwatch()..start();
          await tester.pump();
          while (!ready() &&
              errors.isEmpty &&
              elapsed.elapsed < const Duration(seconds: 12)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(errors, isEmpty);
          expect(
            ready(),
            true,
            reason: 'error=${c.error} storage=${c.storageError}',
          );
          await tester.pumpAndSettle();
        }

        Future<void> button(String name) => tester.runAsync(
          () => tester.tap(find.widgetWithText(BusyApiDialogButton, name)),
        );
        try {
          final root = File('${temp.path}/root.yaml'),
              source = File(
                '${temp.path}/${policy ? '.spectral' : 'payload'}.yaml',
              ),
              destination = File('${temp.path}/moved 雪.yaml');
          const opaque =
              '\ufeffopenapi: payload data\r\n\$ref: literal only\ninvalid: [ 900719925474099312345678901 雪😀';
          await tester.runAsync(() async {
            await root.writeAsString(
              'openapi: 3.2.1\ninfo: {title: Controls, version: "1"}\npaths: {}\ncomponents: {examples: {External: {externalValue: payload.yaml}}}\n',
            );
            await source.writeAsString(policy ? 'rules: {}\n' : opaque);
            await c.initialize();
            await c.open(root.path);
            await c.openFile(source.uri.toString());
            c.setMode('Source');
          });
          final b = c.buffer!;
          b.selection = const SourceSelection(2, 10);
          b.scroll = 42;
          final original = b.bytes();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => BusyApiActionRow(
                    title: 'Move file…',
                    onTap: () => pending =
                        showFileMove(
                          context,
                          c,
                          source.uri.toString(),
                        ).catchError((Object error) {
                          errors.add(error);
                        }),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Move file…'));
          await until(
            () => find
                .widgetWithText(BusyApiGroupedTextEntry, 'Destination path')
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
          await tester.enterText(field, 'moved 雪.yaml');
          await button('Apply');
          await until(
            () => find.text('Review file move').evaluate().isNotEmpty,
          );
          expect(find.textContaining('Keep its bytes opaque'), findsOneWidget);
          expect(destination.existsSync(), false);
          expect(b.id, source.uri.toString());
          final apply = tester.widget<BusyApiDialogButton>(
            find.widgetWithText(BusyApiDialogButton, 'Apply'),
          );
          if (policy) {
            expect(
              find.textContaining('Governance depends on this source'),
              findsOneWidget,
            );
            expect(apply.onPressed, isNull);
            await button('Cancel');
          } else {
            expect(apply.onPressed, isNotNull);
            await button('Apply');
          }
          var done = false;
          pending!.then((_) => done = true);
          await until(() => done);
          expect(b.bytes(), original);
          expect(c.root, root.uri.toString());
          if (!policy) {
            expect(c.active, destination.uri.toString());
            expect(b.selection.base, 2);
            expect(b.scroll, 42);
            expect(
              c.project!.store.get(root.uri.toString()).text,
              contains('moved%20%E9%9B%AA.yaml'),
            );
            await tester.runAsync(c.undo);
            expect(c.active, source.uri.toString());
            expect(b.bytes(), original);
            await tester.runAsync(c.redo);
            expect(c.active, destination.uri.toString());
            expect(b.bytes(), original);
            await tester.runAsync(() => c.saveBuffers(only: {b.id}));
            expect(await tester.runAsync(destination.readAsBytes), original);
            expect(source.existsSync(), false);
          } else {
            expect(c.active, source.uri.toString());
            expect(
              await tester.runAsync(source.readAsBytes),
              utf8.encode('rules: {}\n'),
            );
          }
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
