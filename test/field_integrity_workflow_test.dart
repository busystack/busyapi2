import 'dart:io';
import 'dart:convert';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'remove',
    'default',
    'types',
    'block-data',
    'block-string',
    'compact-data',
    'nested-compact-data',
    'flow-map-data',
    'flow-sequence-data',
    'member-explicit-data',
    'member-valueless-data',
    'member-explicit-valueless-data',
    'pair-replace-data',
    'pair-remove-data',
    'pair-expand-data',
  ]) {
    final removal = scenario == 'remove', types = scenario == 'types';
    final blockData = scenario == 'block-data',
        blockString = scenario == 'block-string';
    final block = blockData || blockString;
    final compact = scenario.endsWith('compact-data');
    final nested = scenario == 'nested-compact-data';
    final flow = scenario.startsWith('flow-');
    final flowMap = scenario == 'flow-map-data';
    final member = scenario.startsWith('member-');
    final pair = scenario.startsWith('pair-');
    final structured = compact || flow || member || pair;
    const whitespaceValue = 'hello\n\nworld  \n\n';
    const compactRaw = '[{"value":{\n"n":9007199254740993.00\n},"keep":"yes"}]';
    final compactValue = pair
        ? scenario == 'pair-replace-data'
              ? '[7]'
              : scenario == 'pair-remove-data'
              ? '[{}]'
              : '[{"":null,"next":1}]'
        : member
        ? '[{}]'
        : flow
        ? flowMap
              ? compactRaw
              : '[["yes",{\n"n":9007199254740993.00\n}]]'
        : nested
        ? '[$compactRaw]'
        : compactRaw;
    testWidgets(
      removal
          ? 'R02 Design field removal retains its sequence item and history'
          : types
          ? 'R03-A schema type union preserves block collection source boundaries'
          : block
          ? 'R03-C R03-E Design $scenario editor preserves block-string whitespace and header comments'
          : compact
          ? 'R03-F Design $scenario edits the whole default with strict syntax and exact data'
          : flow
          ? 'R03-G Design $scenario preserves authored flow separators and history'
          : member
          ? 'R03-H Design $scenario preserves exact values through member removal and history'
          : pair
          ? 'R03-I Design $scenario retains implicit-pair comments and exact values through history'
          : 'R03 Design data action replaces implicit null and preserves its comment',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1200);
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
          'busyapi-field-integrity-',
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
        Future<void> waitFor(bool Function() ready) async {
          final timer = Stopwatch()..start();
          await tester.pump();
          while (!ready() &&
              errors.isEmpty &&
              timer.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(errors, isEmpty);
          expect(ready(), true);
          await tester.pump();
        }

        const baseSource =
            'openapi: 3.2.1\ninfo: {title: API, version: "1"}\nservers:\n  - description: First\n    url: https://first.example\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      default: # documented empty default\n      type: [string, "null"]\n      description: keep # unchanged\nx-kept: 9007199254740993.00\n';
        final original = pair
            ? baseSource
                  .replaceFirst(
                    'default: # documented empty default',
                    'default: [${scenario == 'pair-remove-data' ? ':' : '?'} # key note\n        ]',
                  )
                  .replaceFirst('type: [string, "null"]', 'type: array')
            : member
            ? baseSource
                  .replaceFirst(
                    'default: # documented empty default',
                    'default:\n        - {${scenario == 'member-explicit-data'
                        ? '? keep: yes,'
                        : scenario == 'member-valueless-data'
                        ? 'keep'
                        : '? keep'}}',
                  )
                  .replaceFirst('type: [string, "null"]', 'type: array')
            : flow
            ? baseSource
                  .replaceFirst(
                    'default: # documented empty default',
                    'default:\n        - ${flowMap ? '{keep: yes,}' : '[yes,]'}',
                  )
                  .replaceFirst('type: [string, "null"]', 'type: array')
            : compact
            ? baseSource
                  .replaceFirst(
                    'default: # documented empty default',
                    nested
                        ? 'default:\n        - - value: null\n            keep: yes'
                        : 'default:\n        - value: null\n          keep: yes',
                  )
                  .replaceFirst('type: [string, "null"]', 'type: array')
                  .replaceFirst('3.2.1', nested ? '3.2.1' : '3.1.2')
            : types
            ? baseSource.replaceFirst(
                'type: [string, "null"]',
                'type:\n        - string',
              )
            : block
            ? baseSource.replaceFirst(
                blockData
                    ? 'default: # documented empty default'
                    : 'description: keep # unchanged',
                '${blockData ? 'default' : 'description'}: |-  # preserve this user note\n        original # scalar data\n        text',
              )
            : baseSource;
        final file = File('${temp.path}/openapi.yaml')
          ..writeAsStringSync(original);
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            await c.analyse();
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': removal ? '/servers/0' : '/components/schemas/Model',
            });
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
                    run: (action) {
                      pending = action().catchError(errors.add);
                    },
                    reveal: (_) {},
                  ),
                ),
              ),
            ),
          );

          if (types) {
            final union = find.widgetWithText(BusyApiActionRow, 'Type union');
            await waitFor(() => union.evaluate().isNotEmpty);
            await tester.runAsync(() => tester.ensureVisible(union));
            await tester.runAsync(() => tester.tap(union));
            final toggle = find.byWidgetPredicate(
              (w) => w is BusyApiSwitchRow && w.title == 'null',
            );
            await waitFor(() => toggle.evaluate().isNotEmpty);
            await tester.runAsync(() async {
              tester.widget<BusyApiSwitchRow>(toggle).onChanged(true);
            });
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await waitFor(() => done);
            dynamic value;
            await tester.runAsync(() async {
              final item = await c.project!.inspectObject(
                c.root!,
                c.root!,
                '/components/schemas/Model',
              );
              final target = (item['fields'] as List).cast<Map>().singleWhere(
                (f) => f['name'] == 'type',
              )['target'];
              value = jsonDecode(
                await c.project!.readDataValue(
                  Map<String, dynamic>.from(target),
                ),
              );
            });
            expect(value, ['string', 'null']);
            final accepted = c.buffer!.text;
            expect(accepted, contains('      description: keep # unchanged\n'));
            await tester.runAsync(c.undo);
            expect(c.buffer!.text, original);
            await tester.runAsync(c.redo);
            expect(c.buffer!.text, accepted);
            return;
          }
          if (removal || blockString) {
            final menu = find.byWidgetPredicate(
              (w) =>
                  w is BusyApiHeaderPopupMenuButton<String> &&
                  w.tooltip == 'Value actions for Description',
            );
            await waitFor(() => menu.evaluate().isNotEmpty);
            await tester.runAsync(() => tester.tap(menu));
            await waitFor(
              () => find
                  .text('Edit value or remove field…')
                  .evaluate()
                  .isNotEmpty,
            );
            await tester.pumpAndSettle();
            await tester.runAsync(
              () => tester.tap(find.text('Edit value or remove field…')),
            );
          } else {
            final row = find.widgetWithText(BusyApiActionRow, 'default');
            await waitFor(() => row.evaluate().isNotEmpty);
            await tester.runAsync(() => tester.ensureVisible(row));
            await tester.runAsync(() => tester.tap(row));
          }
          await waitFor(() => c.form != null);
          if (!removal) {
            await tester.runAsync(
              () => tester.enterText(
                find.descendant(
                  of: find.byType(BusyApiDialogShell),
                  matching: find.byType(TextFormField),
                ),
                blockString
                    ? whitespaceValue
                    : structured
                    ? compactValue
                    : blockData
                    ? jsonEncode(whitespaceValue)
                    : '"hello"',
              ),
            );
          }
          await tester.runAsync(
            () => tester.tap(
              find.widgetWithText(
                BusyApiDialogButton,
                removal ? 'Remove' : 'Apply',
              ),
            ),
          );
          var done = false;
          await tester.runAsync(() async {
            pending!.then((_) => done = true);
          });
          await waitFor(() => done);
          final accepted = c.buffer!.text;
          dynamic value;
          String? exactValue;
          await tester.runAsync(() async {
            if (structured) {
              expect(
                (await c.project!.check(
                  c.root!,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
            }
            final item = await c.project!.inspectObject(
              c.root!,
              c.root!,
              removal ? '/servers' : '/components/schemas/Model',
            );
            final target = removal
                ? item
                : (item['fields'] as List).cast<Map>().singleWhere(
                    (f) =>
                        f['name'] == (blockString ? 'description' : 'default'),
                  )['target'];
            exactValue = await c.project!.readDataValue(
              Map<String, dynamic>.from(target),
            );
            value = jsonDecode(exactValue!);
          });
          if (removal) {
            expect(value, [
              {'url': 'https://first.example'},
            ]);
          } else if (structured) {
            expect(value, jsonDecode(compactValue));
            if (!member && !pair) {
              expect(exactValue, contains('9007199254740993.00'));
            }
            if (pair) expect(accepted, contains(' # key note\n'));
            expect(accepted, contains('      description: keep # unchanged\n'));
          } else {
            expect(value, block ? whitespaceValue : 'hello');
            if (block) {
              expect(accepted, contains('  # preserve this user note\n'));
            }
            if (!blockData) {
              expect(accepted, contains('# documented empty default'));
            }
          }
          expect(accepted, endsWith('x-kept: 9007199254740993.00\n'));
          await tester.runAsync(c.undo);
          expect(c.buffer!.text, original);
          await tester.runAsync(c.redo);
          expect(c.buffer!.text, accepted);
          if (structured) {
            await tester.runAsync(() async {
              expect(
                (await c.project!.check(
                  c.root!,
                  schemaEvaluation: false,
                ))['findings'],
                isEmpty,
              );
              if (pair) {
                final item = await c.project!.inspectObject(
                  c.root!,
                  c.root!,
                  '/components/schemas/Model',
                );
                final target = (item['fields'] as List).cast<Map>().singleWhere(
                  (f) => f['name'] == 'default',
                )['target'];
                final value = await c.project!.readDataValue(
                  Map<String, dynamic>.from(target as Map),
                );
                expect(jsonDecode(value), jsonDecode(compactValue));
                expect(c.buffer!.text, contains(' # key note\n'));
              }
            });
          }
        } finally {
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
