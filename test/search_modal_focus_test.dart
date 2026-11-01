import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_dialogs.dart';
import 'package:busyapi/src/app/command_registry.dart';
import 'package:busyapi/src/workspace/search_session.dart';
import 'package:busyapi/src/workspace/search_sidebar.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final superseded in [false, true]) {
      testWidgets(
        'palette modal keyboard ownership in ${brightness.name}, superseded=$superseded',
        (tester) async {
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-modal-search-',
          );
          final workspace = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final search = BusyApiSearchSession(workspace);
          final previous = FocusNode(), query = FocusNode();
          final sidebar = GlobalKey<BusyApiSearchSidebarState>();
          late BuildContext context;
          Future<void>? modal;
          var activated = 0;
          final registry = BusyApiCommandRegistry([
            BusyApiCommand(
              id: 'migrate',
              label: (_) => 'Migrate specification',
              category: (_) => 'Actions',
              execute: () {
                modal = showBusyApiModalDialog<void>(
                  context: context,
                  builder: (dialog) => BusyApiDialogShell(
                    title: 'Migrate specification',
                    actions: [
                      BusyApiDialogButton(
                        label: 'Close',
                        onPressed: () => Navigator.pop(dialog),
                      ),
                      BusyApiDialogButton(
                        label: 'Review migration',
                        onPressed: () {
                          activated++;
                        },
                      ),
                    ],
                    children: const [
                      Text('Review captured sources before publication'),
                    ],
                  ),
                );
                return modal!;
              },
            ),
          ]);
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: brightness,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Builder(
                  builder: (host) {
                    context = host;
                    return Scaffold(
                      body: ListenableBuilder(
                        listenable: search,
                        builder: (_, _) => Column(
                          children: [
                            TextField(focusNode: previous),
                            Offstage(
                              offstage: !search.active,
                              child: ExcludeFocus(
                                excluding: !search.active,
                                child: TextField(
                                  focusNode: query,
                                  autofocus: true,
                                  controller: search.query,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Offstage(
                                offstage: !search.active,
                                child: BusyApiSearchSidebar(
                                  key: sidebar,
                                  session: search,
                                  registry: registry,
                                  onReveal: (_) async {},
                                  run: (_) {},
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
            previous.requestFocus();
            await tester.pumpAndSettle();
            search.open(BusyApiSearchCategory.actions);
            await tester.pumpAndSettle();
            query.requestFocus();
            await tester.pumpAndSettle();
            expect(query.hasPrimaryFocus, isTrue);
            final activation = sidebar.currentState!.activateSelected();
            if (superseded) search.open(BusyApiSearchCategory.actions);
            await tester.pumpAndSettle();
            if (superseded) {
              await activation;
              expect(modal, isNull);
              expect(find.byType(BusyApiDialogShell), findsNothing);
              expect(search.active, isTrue);
              expect(activated, 0);
              return;
            }
            final focus = FocusManager.instance.primaryFocus;
            expect(focus?.context, isNotNull);
            expect(
              ModalRoute.of(focus!.context!)?.isCurrent,
              isTrue,
              reason:
                  'Modal focus: ${focus.debugLabel}; previous=${previous.hasFocus}; query=${query.hasFocus}; context=${focus.context?.widget.runtimeType}',
            );
            for (var index = 0; index < 8; index++) {
              final button = FocusManager.instance.primaryFocus?.context
                  ?.findAncestorWidgetOfExactType<BusyApiDialogButton>();
              if (button?.label == 'Review migration') break;
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
            }
            expect(
              FocusManager.instance.primaryFocus?.context
                  ?.findAncestorWidgetOfExactType<BusyApiDialogButton>()
                  ?.label,
              'Review migration',
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(activated, 1);
            Navigator.of(tester.element(find.byType(BusyApiDialogShell))).pop();
            await tester.pumpAndSettle();
            await modal;
            await activation;
            expect(previous.hasPrimaryFocus, isTrue);
            modal = null;
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            search.dispose();
            previous.dispose();
            query.dispose();
            await tester.runAsync(workspace.shutdown);
            workspace.dispose();
            directory.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
