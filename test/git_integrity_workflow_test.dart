import 'dart:async';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
import 'package:busyapi/src/workspace/git_workspace.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['stage', 'branches', 'disposed']) {
    final branch = scenario == 'branches', disposed = scenario == 'disposed';
    testWidgets(
      disposed
          ? 'R09 a disposed Git dialog rejects a gated reload completion'
          : branch
          ? 'R09 branch rows follow refreshed status main feature main'
          : 'R07 Git UI stages only displayed bytes for the selected path',
      (tester) async {
        tester.view.physicalSize = const Size(1500, 1100);
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
          'busyapi-git-ui-integrity-',
        );
        Future<ProcessResult> git(List<String> args) async {
          final result = await Process.run(
            '/usr/bin/git',
            args,
            workingDirectory: temp.path,
          );
          expect(result.exitCode, 0, reason: '${result.stderr}');
          return result;
        }

        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/.git/ui-config',
            state: '${temp.path}/.git/ui-state',
            cache: '${temp.path}/.git/ui-cache',
          ),
        );
        final errors = <Object>[];
        late GitRepository repo;
        final captured = Completer<void>(),
            release = Completer<void>(),
            completed = Completer<void>();
        Future<void> waitFor(bool Function() condition) async {
          final clock = Stopwatch()..start();
          await tester.pump();
          while ((!condition() ||
                  find.byType(LinearProgressIndicator).evaluate().isNotEmpty) &&
              errors.isEmpty &&
              clock.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(errors, isEmpty);
          expect(condition(), true);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          await tester.pumpAndSettle();
        }

        final file = File('${temp.path}/openapi.yaml')
          ..writeAsStringSync(
            'openapi: 3.2.1\ninfo: {title: BASE, version: "1"}\npaths: {}\n',
          );
        try {
          await tester.runAsync(() async {
            await git(['init', '-b', 'main']);
            await git(['config', 'user.name', 'BusyAPI Test']);
            await git(['config', 'user.email', 'test@example.invalid']);
            await git(['add', '.']);
            await git(['commit', '-m', 'base']);
            await git(['branch', 'feature']);
            if (!branch && !disposed) {
              file.writeAsStringSync(
                file.readAsStringSync().replaceFirst('BASE', 'REVIEWED'),
              );
            }
            await c.initialize();
            await c.open(file.path);
            repo = (await GitRepository.discover(temp.path, trusted: true))!;
            if (branch) expect((await repo.status()).clean, true);
            if (disposed) {
              repo.onPhase = (phase) async {
                if (phase == 'workspace:reload:captured') {
                  captured.complete();
                  await release.future;
                }
                if (phase == 'workspace:reload:complete') completed.complete();
              };
            }
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
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      showGitWorkspace(
                        context,
                        c,
                        repository: repo,
                      ).catchError(errors.add);
                    },
                    child: const Text('Open Git'),
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(() => tester.tap(find.text('Open Git')));
          if (disposed) {
            Future<void> gateUntil(bool Function() ready) async {
              final timer = Stopwatch()..start();
              while (!ready() && timer.elapsed < const Duration(seconds: 10)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(ready(), true);
            }

            await gateUntil(() => captured.isCompleted);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              release.complete();
            });
            await gateUntil(() => completed.isCompleted);
            expect(tester.takeException(), isNull);
            return;
          }
          await waitFor(
            () => branch
                ? find.byType(BusyApiPopupSelector<int>).evaluate().isNotEmpty
                : find
                      .byWidgetPredicate(
                        (w) =>
                            w is BusyApiCompactIconButton &&
                            w.tooltip == 'Stage reviewed disk content' &&
                            w.onPressed != null,
                      )
                      .evaluate()
                      .isNotEmpty,
          );
          if (branch) {
            tester
                .widget<BusyApiPopupSelector<int>>(
                  find.byType(BusyApiPopupSelector<int>),
                )
                .onSelected(2);
            await tester.pumpAndSettle();
            BusyApiActionRow row(String name) =>
                tester.widget<BusyApiActionRow>(
                  find.widgetWithText(BusyApiActionRow, name),
                );
            expect(row('main').onTap, isNull);
            expect(row('main').subtitle, 'Current branch');
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiActionRow, 'feature')),
            );
            await waitFor(
              () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
            );
            await tester.runAsync(() async {
              expect((await repo.status()).branch, 'feature');
            });
            expect(row('feature').subtitle, 'Current branch');
            expect(row('feature').onTap, isNull);
            expect(row('main').onTap, isNotNull);
            await tester.runAsync(
              () => tester.tap(find.widgetWithText(BusyApiActionRow, 'main')),
            );
            await waitFor(() => row('main').subtitle == 'Current branch');
            expect(row('feature').onTap, isNotNull);
            await tester.runAsync(
              () => tester.enterText(
                find.widgetWithText(TextField, 'New branch'),
                'created',
              ),
            );
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiActionRow, 'Create and switch'),
              ),
            );
            await waitFor(
              () =>
                  find
                      .widgetWithText(BusyApiActionRow, 'created')
                      .evaluate()
                      .isNotEmpty &&
                  row('created').subtitle == 'Current branch',
            );
            await tester.runAsync(() async {
              expect((await repo.status()).branch, 'created');
              await git(['branch', '-D', 'feature']);
            });
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiActionRow, 'feature')),
            );
            await waitFor(
              () => find
                  .byWidgetPredicate(
                    (w) =>
                        w is BusyApiStatusBox &&
                        w.message.contains('git.command'),
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            expect(row('created').subtitle, 'Current branch');
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Close')),
            );
            await waitFor(
              () => find.byType(BusyApiDialogShell).evaluate().isEmpty,
            );
            late String commit;
            await tester.runAsync(() async {
              await git(['switch', '--detach']);
              commit = (await git(['rev-parse', 'HEAD'])).stdout
                  .toString()
                  .trim();
            });
            await tester.runAsync(() => tester.tap(find.text('Open Git')));
            await waitFor(
              () =>
                  find.byType(BusyApiPopupSelector<int>).evaluate().isNotEmpty,
            );
            expect(
              find.byWidgetPredicate(
                (w) =>
                    w is BusyApiStatusBox &&
                    w.message.contains(commit.substring(0, 12)),
              ),
              findsOneWidget,
            );
            tester
                .widget<BusyApiPopupSelector<int>>(
                  find.byType(BusyApiPopupSelector<int>),
                )
                .onSelected(2);
            await tester.pumpAndSettle();
            expect(row('main').subtitle, isNull);
            expect(row('main').onTap, isNotNull);
            expect(row('created').subtitle, isNull);
          } else {
            await tester.runAsync(
              () =>
                  tester.tap(find.byKey(const ValueKey('openapi.yaml')).first),
            );
            await waitFor(
              () =>
                  find.byType(BusyApiRawSourceView).evaluate().isNotEmpty &&
                  tester
                      .widget<BusyApiRawSourceView>(
                        find.byType(BusyApiRawSourceView),
                      )
                      .source
                      .contains('REVIEWED'),
            );
            await tester.runAsync(() async {
              file.writeAsStringSync(
                file.readAsStringSync().replaceFirst('REVIEWED', 'UNREVIEWED'),
              );
            });
            await tester.runAsync(
              () => tester.tap(
                find.descendant(
                  of: find.byKey(const ValueKey('openapi.yaml')).first,
                  matching: find.byTooltip('Stage reviewed disk content'),
                ),
              ),
            );
            await waitFor(
              () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
            );
            late String staged;
            await tester.runAsync(() async {
              staged =
                  (await git(['diff', '--cached', '--name-only'])).stdout
                      as String;
            });
            expect(
              staged,
              '',
              reason: 'The UI must pass its displayed review, not hash new disk bytes at click time',
            );
          }
        } finally {
          if (!release.isCompleted) release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          await tester.runAsync(c.engine.close);
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
