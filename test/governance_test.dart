import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/governance_dialog.dart';
import 'package:busyapi/src/workspace/problems_panel.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';
import 'workspace_io_trace.dart';

class _PolicyEngine extends TracedEngineProcess {
  _PolicyEngine(super.trace);
  int calls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) {
    if (method == 'govern') calls++;
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'native governance $version $json runs explicitly, shows effective rules and original configuration',
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
            'busyapi-governance-widget-',
          );
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}')
            ..writeAsStringSync(
              json
                  ? '{"openapi":"$version", "info":{"title":"Policy","version":"1"}, "paths":{"/p":{"get":{"responses":{"204":{"description":"No body"}}}}},"x-number":9007199254740993.00}'
                  : '# preserve 雪😀\r\nopenapi: $version\r\ninfo: {title: Policy, version: "1"}\npaths: {/p: {get: {responses: {204: {description: No body}}}}}\nx-number: 9007199254740993.00',
            );
          final rules = File('${temp.path}/.spectral.yaml')
            ..writeAsStringSync(
              '# policy\nextends: [busyapi:recommended]\nrules: {operation-summary: error}\n',
            );
          final before = {
            for (final source in [file, rules])
              source.path: source.readAsBytesSync(),
          };
          final trace = WorkspaceIoTrace();
          final engine = _PolicyEngine(trace);
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
              await c.open(file.path);
              await c.analyse();
            }, describeState: () => trace.describe(c));
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: json ? Brightness.dark : Brightness.light,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(1.3)),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: Column(
                      children: [
                        TextButton(
                          onPressed: () async {
                            revealed = await showGovernance(context, c);
                          },
                          child: const Text('Inspect governance'),
                        ),
                        Expanded(
                          child: ListenableBuilder(
                            listenable: c,
                            builder: (context, _) =>
                                ProblemsPanel(controller: c, reveal: (_) {}),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('Inspect governance'));
            await tester.pumpAndSettle();
            expect(engine.calls, 0);
            expect(find.text('Not run'), findsOneWidget);
            await tester.tap(find.text('Run governance'));
            await tester.pump();
            await runWidgetIo(tester, () async {
              while (c.analysis?['categories']?['policy']?['status'] !=
                  'complete') {
                await Future<void>.delayed(const Duration(milliseconds: 20));
              }
            }, describeState: () => trace.describe(c));
            await tester.pumpAndSettle();
            expect(engine.calls, 1);
            expect(c.governanceRunning, false);
            expect(c.analysis?['status'], 'invalid');
            final row = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiActionRow &&
                  widget.title == 'operation-summary',
            );
            expect(row, findsOneWidget);
            await tester.tap(row);
            await tester.pumpAndSettle();
            expect(find.text('Rule configuration chain'), findsOneWidget);
            expect(find.text('Enabled'), findsOneWidget);
            final source = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiActionRow &&
                  widget.title.contains(
                    '.spectral.yaml/rules/operation-summary',
                  ),
            );
            await tester.ensureVisible(source);
            await tester.tap(source);
            await tester.pumpAndSettle();
            expect(revealed?['resource'], rules.uri.toString());
            expect(revealed?['pointer'], '/rules/operation-summary');
            expect(revealed?['snapshot'], c.analysis?['snapshot']);
            await runWidgetIo(tester, () async {
              await c.openFile(revealed!['resource'] as String);
            }, describeState: () => trace.describe(c));
            expect(c.buffer!.sourceIdentity, revealed?['identity']);
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
