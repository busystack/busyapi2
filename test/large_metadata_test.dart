import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  testWidgets('large metadata opens with a source link and retains its draft', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('busyapi-large-metadata-');
    final file = File('${temp.path}/openapi.json');
    final original = jsonEncode({
      'openapi': '3.2.1',
      'info': {'title': 'Large', 'version': '1', 'description': 'x' * 5242880},
      'paths': <String, Object>{},
    });
    file.writeAsStringSync(original);
    final c = WorkspaceController(
      EngineProcess(executable: runtimeNode, helper: runtimeHelper),
      StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      ),
    );
    Map<String, dynamic>? revealed;
    await tester.runAsync(() async {
      await c.initialize();
      await c.open(file.path);
      await c.analyse();
    });
    final item = Map<String, dynamic>.from(c.projection!['info']);
    Widget screen() => ProviderScope(
      child: MaterialApp(
        theme: buildBusyApiTheme(
          brightness: Brightness.light,
          accentColor: const Color(0xffe95420),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Designer(
            controller: c,
            run: (action) => action(),
            reveal: (item) => revealed = item,
          ),
        ),
      ),
    );
    try {
      // Initial opening has no description field in the captured session yet.
      // The ordinary metadata bindings must not hide the authored large value
      // from its guard; summary/terms are now authored on the same page too.
      await tester.pumpWidget(screen());
      expect(find.byType(DraftField), findsNWidgets(4));
      expect(find.widgetWithText(DraftField, 'Description'), findsNothing);
      expect(c.buffer!.text, original);
      final draft = c.bind(item)
        ..bind('description', item['value']['description']);
      draft.edit('description', '${draft.values['description']}pending');
      await tester.pumpWidget(screen());
      expect(find.byType(DraftField), findsNWidgets(4));
      expect(find.widgetWithText(DraftField, 'Description'), findsNothing);
      final link = find.byType(BusyApiActionRow).first;
      await tester.tap(link);
      expect(revealed?['resource'], c.active);
      expect(revealed?['pointer'], '/info');
      expect(identical(c.draft, draft), isTrue);
      expect(draft.pending, isTrue);
      expect(c.buffer!.text, original);
      expect(file.readAsStringSync(), original);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.shutdown);
      c.dispose();
      temp.deleteSync(recursive: true);
    }
  });
}
