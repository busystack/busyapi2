import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/governance_dialog.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';
import 'workspace_io_trace.dart';

void main() {
  for (final json in [false, true]) {
    for (final selectorOnly in [false, true]) {
      testWidgets(
        'native code review inspects source before one-run approval ${json ? 'JSON 3.2' : 'YAML 3.1'} selector-only=$selectorOnly',
        (tester) async {
          for (final name in ['yaru_window', 'yaru_window/events']) {
            final channel = MethodChannel(name);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (_) async => null,
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, null),
            );
          }
          tester.view.physicalSize = const Size(1280, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-policy-controls 雪 ',
          );
          final root = File('${temp.path}/root.${json ? 'json' : 'yaml'}')
            ..writeAsStringSync(
              json
                  ? '{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"tags":[{"name":"one"}]}'
                  : 'openapi: 3.1.2\ninfo: {title: Review, version: "1"}\npaths: {}\ntags: [{name: one}]\n',
            );
          final policy = File('${temp.path}/.spectral.yaml')
            ..writeAsStringSync(
              selectorOnly
                  ? 'rules:\n  custom-rule:\n    given: \$.tags[?(@.name === "one")]\n    then: {field: description, function: truthy}\n'
                  : 'functions: [custom]\nrules:\n  custom-rule:\n    given: \$.info.title\n    then: {function: custom}\n',
            );
          Directory('${temp.path}/functions').createSync();
          final code = File('${temp.path}/functions/custom.js')
            ..writeAsStringSync(
              '// inspected 😀\r\nmodule.exports=async()=>[{message:"local custom rule"}];',
            );
          final before = {
            for (final file in [root, policy, code])
              file.path: file.readAsBytesSync(),
          };
          final trace = WorkspaceIoTrace(), engine = TracedEngineProcess(trace);
          final c = TracedWorkspaceController(
            engine,
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
            trace,
          );
          Map<String, dynamic>? revealed;
          try {
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(root.path);
              await c.analyse();
            }, describeState: () => trace.describe(c));
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: Colors.orange,
                ),
                darkTheme: buildBusyApiTheme(
                  brightness: Brightness.dark,
                  accentColor: Colors.orange,
                ),
                themeMode: json ? ThemeMode.dark : ThemeMode.light,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () async {
                        revealed = await showGovernance(context, c);
                      },
                      child: const Text('Inspect code governance'),
                    ),
                  ),
                ),
              ),
            );
            Future<void> openReview() async {
              await tester.tap(find.text('Inspect code governance'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('Review executable rules'));
              await tester.pump();
              await runWidgetIo(tester, () async {
                while (find
                    .textContaining('One-run trust identity:')
                    .evaluate()
                    .isEmpty) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                }
              }, describeState: () => trace.describe(c));
              await tester.pumpAndSettle();
            }

            await openReview();
            expect(c.analysis?['categories']?['policy']?['status'], 'not-run');
            final inspected = selectorOnly ? policy : code;
            final source = find.byWidgetPredicate(
              (value) =>
                  value is BusyApiActionRow &&
                  value.title == inspected.uri.toString(),
            );
            await tester.ensureVisible(source);
            await tester.tap(source);
            await tester.pump();
            await runWidgetIo(tester, () async {
              while (revealed == null) {
                await Future<void>.delayed(const Duration(milliseconds: 20));
              }
            });
            await tester.pumpAndSettle();
            expect(revealed?['resource'], inspected.uri.toString());
            expect(
              revealed?['identity'],
              contentIdentity(inspected.readAsBytesSync()),
            );
            expect(c.analysis?['categories']?['policy']?['status'], 'not-run');
            await openReview();
            await tester.tap(find.text('Approve and run once'));
            await tester.pump();
            await runWidgetIo(tester, () async {
              while (c.analysis?['categories']?['policy']?['coverage']
                      ?.contains('reviewed-isolated-code') !=
                  true) {
                await Future<void>.delayed(const Duration(milliseconds: 20));
              }
            }, describeState: () => trace.describe(c));
            await tester.pumpAndSettle();
            expect(c.analysis?['categories']?['policy']?['complete'], true);
            expect(
              (c.analysis?['findings'] as List).any(
                (value) => value['code'] == 'policy.rule.custom-rule',
              ),
              true,
            );
            expect(find.text('Approve and run once'), findsNothing);
            await tester.tap(find.text('Run governance'));
            await tester.pump();
            await runWidgetIo(tester, () async {
              while (c.governanceRunning ||
                  c.analysis?['categories']?['policy']?['coverage']?.contains(
                        'reviewed-isolated-code',
                      ) ==
                      true) {
                await Future<void>.delayed(const Duration(milliseconds: 20));
              }
            }, describeState: () => trace.describe(c));
            await tester.pumpAndSettle();
            expect(c.analysis?['categories']?['policy']?['complete'], false);
            for (final entry in before.entries) {
              expect(File(entry.key).readAsBytesSync(), entry.value);
            }
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            await runWidgetIo(
              tester,
              c.shutdown,
              describeState: () => trace.describe(c),
            );
            c.dispose();
            await tester.runAsync(engine.close);
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
