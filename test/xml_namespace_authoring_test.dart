import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native XML namespace repair preserves family rules and undo',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-xml-widget-',
          );
          final file = File('${temp.path}/api.$format');
          final schema = {
            'type': 'string',
            'xml': {'name': 'document', 'namespace': './relative'},
            'x-kept': 'EXACT',
          };
          final value = {
            version == '2.0' ? 'swagger' : 'openapi': version,
            'info': {'title': 'Namespaces 雪', 'version': '1'},
            'paths': {},
            version == '2.0' ? 'definitions' : 'components': version == '2.0'
                ? {'Model': schema}
                : {
                    'schemas': {'Model': schema},
                  },
          };
          final original =
              '${format == 'yaml' ? '# Keep presentation\r\n' : ''}${jsonEncode(value).replaceFirst('"EXACT"', '9007199254740993.00')}';
          file.writeAsStringSync(original);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final failures = <Object>[];
          try {
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(file.path);
              await c.analyse();
              expect(
                (c.projection!['findings'] as List).any(
                  (f) => f['code'] == 'xml.namespace.uri',
                ),
                version != '2.0',
              );
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': version == '2.0'
                    ? '/definitions/Model/xml'
                    : '/components/schemas/Model/xml',
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
                        action().catchError((Object error) {
                          failures.add(error);
                        });
                      },
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            final field = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiGroupedTextEntry &&
                  widget.label == 'namespace',
            );
            final deadline = DateTime.now().add(const Duration(seconds: 8));
            while (field.evaluate().isEmpty &&
                DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 20));
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
            }
            expect(field, findsOneWidget);
            expect(
              tester.widget<BusyApiGroupedTextEntry>(field).readOnly,
              false,
            );
            await tester.runAsync(
              () => tester.enterText(
                find.descendant(of: field, matching: find.byType(TextField)),
                'https://namespace.example.invalid/%E9%9B%AA#part',
              ),
            );
            await runWidgetIo(tester, c.flush);
            await runWidgetIo(tester, c.analyse);
            expect(failures, isEmpty);
            expect(
              (c.projection!['findings'] as List).any(
                (f) => f['code'] == 'xml.namespace.uri',
              ),
              false,
            );
            final changed = c.buffer!.text;
            expect(
              changed,
              contains('https://namespace.example.invalid/%E9%9B%AA#part'),
            );
            expect(changed, contains('9007199254740993.00'));
            expect(file.readAsStringSync(), original);
            await runWidgetIo(tester, c.undo);
            expect(c.buffer!.text, original);
            await runWidgetIo(tester, c.redo);
            expect(c.buffer!.text, changed);
            expect(tester.takeException(), null);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(c.shutdown);
            c.dispose();
            await tester.runAsync(c.engine.close);
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
