import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/refactoring_review.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final deletion in [false, true]) {
      testWidgets(
        '$version saved case file review deletion=$deletion discloses owned usage and preserves cancellation',
        (tester) async {
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
            'busyapi-case-file-review-',
          );
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final root = File('${temp.path}/api.json'),
              data = File('${temp.path}/payload.json'),
              config = File('${temp.path}/busyapi.yaml');
          final errors = <Object>[];
          Future<void>? pending;
          Future<void> until(bool Function() ready) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!ready() &&
                errors.isEmpty &&
                clock.elapsed < const Duration(seconds: 20)) {
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

          try {
            late RefactoringPlan plan;
            await tester.runAsync(() async {
              await root.writeAsString(
                jsonEncode({
                  version == '2.0' ? 'swagger' : 'openapi': version,
                  'info': {'title': 'Case files', 'version': 'unrelated'},
                  'paths': {},
                }),
              );
              await data.writeAsString(
                '\ufeff{"n":9007199254740993.00,"\$ref":"opaque"}\r\n',
              );
              await config.writeAsString(
                '# Keep\r\nversion: 1\r\nroots: [{name: Main, path: api.json}]\r\ntests: [{name: Upload, operation: {method: post, path: /items}, body: {files: [{name: asset, path: "./payload.json"}]}}]\r\n',
              );
              await c.initialize();
              await c.open(temp.path);
              await c.openFile(data.uri.toString());
              c.setMode('Source');
              plan = deletion
                  ? await c.planFileDeletion(c.project!, data.uri.toString())
                  : await c.planFileMove(
                      c.project!,
                      data.uri.toString(),
                      '${temp.path}/moved 雪.json',
                    );
            });
            final originalData = data.readAsBytesSync(),
                originalConfig = config.readAsStringSync();
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
                      title: 'Review attachment',
                      onTap: () => pending =
                          showRefactoringReview(
                            context,
                            c,
                            c.project!,
                            plan,
                          ).catchError((Object error) {
                            errors.add(error);
                          }),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('Review attachment'));
            await until(
              () => find
                  .text(deletion ? 'Review file deletion' : 'Review file move')
                  .evaluate()
                  .isNotEmpty,
            );
            final apply = tester.widget<BusyApiDialogButton>(
              find.widgetWithText(BusyApiDialogButton, 'Apply'),
            );
            expect(apply.onPressed == null, deletion);
            if (deletion) {
              expect(
                find.textContaining('A saved contract case uploads this file.'),
                findsOneWidget,
              );
            }
            await tester.ensureVisible(find.byType(BusyApiSwitchRow).first);
            await tester.pumpAndSettle();
            await tester.tap(find.byType(BusyApiSwitchRow).first);
            await tester.pumpAndSettle();
            expect(
              find.textContaining('Saved case file input'),
              findsOneWidget,
            );
            expect(
              find.textContaining('/tests/0/body/files/0/path'),
              findsOneWidget,
            );
            expect(data.readAsBytesSync(), originalData);
            expect(config.readAsStringSync(), originalConfig);
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiDialogButton, 'Cancel'),
              ),
            );
            var done = false;
            pending!.then((_) => done = true);
            await until(() => done);
            expect(
              c.project!.store.get(config.uri.toString()).text,
              originalConfig,
            );
            expect(c.buffer!.id, data.uri.toString());
            expect(c.buffer!.bytes(), originalData);
            expect(File('${temp.path}/moved 雪.json').existsSync(), false);
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
