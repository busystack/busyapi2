import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/problems_panel.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  testWidgets(
    'nested-dialect validity explains ownership without inventing an identifier repair',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Text(
              problemMessage(context, {
                'code': 'schema.dialect.location',
                'message':
                    'Raw provider diagnostic must not replace localized help',
              }),
            ),
          ),
        ),
      );
      expect(
        find.textContaining('Adding an identifier changes reference meaning'),
        findsOneWidget,
      );
      expect(find.textContaining('Raw provider diagnostic'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native Problems masks security advice, retains source ranges and never changes policy through display filters',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-problems-security-',
      );
      final token =
          'ghp_${List.generate(36, (i) => 'aB3cD5eF7gH9kL2mN4pQ6rS8tU0vW1xY'[i % 32]).join()}';
      final file = File('${temp.path}/root.json');
      final text = jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Problems', 'version': '1'},
        'paths': {},
        'x-data': {'token': token},
      });
      file.writeAsStringSync(text);
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      Map<String, dynamic>? revealed;
      Widget screen() => MaterialApp(
        theme: buildBusyApiTheme(
          brightness: Brightness.light,
          accentColor: Colors.blue,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            height: 180,
            child: ProblemsPanel(
              controller: c,
              reveal: (finding) => revealed = finding,
            ),
          ),
        ),
      );
      Future<void> select(String category) async {
        tester
            .widget<BusyApiComboRow<String>>(
              find.byType(BusyApiComboRow<String>),
            )
            .onSelected(category);
        await tester.pumpAndSettle();
      }

      try {
        await tester.runAsync(() async {
          await c.initialize();
          await c.open(file.path);
          await c.analyse();
        });
        final original = jsonEncode(c.analysis);
        await tester.pumpWidget(screen());
        await select('security');
        expect(
          find.textContaining('not runtime authorization'),
          findsOneWidget,
        );
        expect(find.text('Complete for captured scope'), findsOneWidget);
        final row = find.widgetWithText(
          BusyApiActionRow,
          'Security design · security.credential-like.github',
        );
        await tester.ensureVisible(row);
        await tester.tap(row);
        expect(revealed?['resource'], c.root);
        expect(
          text.substring(
            revealed!['range'][0] as int,
            revealed!['range'][1] as int,
          ),
          contains(token),
        );
        expect(find.textContaining(token), findsNothing);
        await select('policy');
        expect(find.text('Not run'), findsOneWidget);
        await select('runtime');
        expect(find.text('Not implemented'), findsOneWidget);
        expect(jsonEncode(c.analysis), original);
        expect(file.readAsStringSync(), text);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(screen());
        expect(
          tester
              .widget<BusyApiComboRow<String>>(
                find.byType(BusyApiComboRow<String>),
              )
              .selected,
          'runtime',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
}
