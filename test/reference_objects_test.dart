import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/reference/reference_object.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

Future<void> ready(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(condition(), isTrue);
  await tester.pump();
}

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'Reference $version navigates authored response, physical definition and literal data without publication',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-reference-objects-',
        );
        final file = File('${temp.path}/root.json'),
            fragment = File('${temp.path}/schema.json');
        final original = jsonEncode({
          'openapi': version,
          'info': {'title': 'Read', 'version': '1'},
          'paths': {
            '/p': {
              'get': {
                'responses': {
                  '200': {'\$ref': '#/components/responses/Shared'},
                  '204': {'description': 'No body'},
                },
              },
            },
          },
          'components': {
            'responses': {
              'Shared': {
                'description': 'Shared description',
                'content': {
                  'application/json': {
                    'schema': {'\$ref': 'schema.json#/Model'},
                    'example': {
                      '\$ref': 'literal payload',
                      'n': 1,
                      'empty': null,
                      'no': false,
                    },
                  },
                },
              },
            },
          },
        }).replaceFirst('"n":1', '"n":9007199254740993');
        file.writeAsStringSync(original);
        fragment.writeAsStringSync(
          '{"Model":{"type":"object","description":"Disk schema","properties":{"real":{"type":"string"}},"additionalProperties":false}}',
        );
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
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => ReferenceView(
                controller: c,
                reveal: (target) => revealed = target,
              ),
            ),
          ),
        );
        Future<void> click(String label) async {
          final row = find.widgetWithText(BusyApiActionRow, label);
          await ready(tester, () => row.evaluate().length == 1);
          await tester.ensureVisible(row);
          await tester.tap(row);
          await tester.pump();
        }

        try {
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(file.path);
            await c.analyse();
          });
          await tester.pumpWidget(screen());
          await click('Responses');
          await click('200');
          await ready(
            tester,
            () => find.text('Read definition').evaluate().isNotEmpty,
          );
          expect(
            find.textContaining('Authored summary and description'),
            findsOneWidget,
          );
          await click('Read definition');
          await ready(
            tester,
            () => find.text('Shared description').evaluate().isNotEmpty,
          );
          await click('content');
          await click('application/json');
          await click('Example');
          await ready(
            tester,
            () => find.text('9007199254740993').evaluate().isNotEmpty,
          );
          expect(find.text('literal payload'), findsOneWidget);
          expect(find.text('null'), findsOneWidget);
          expect(find.text('false'), findsOneWidget);
          expect(find.text('Read definition'), findsNothing);
          await click('Go Back');
          await click('schema');
          await click('Read definition');
          await ready(
            tester,
            () => find.text('Disk schema').evaluate().isNotEmpty,
          );
          final target = Uri.file(fragment.path).toString();
          expect(find.textContaining('Resource: schema.json'), findsOneWidget);
          expect(
            find.textContaining('Authored schema constraints apply together'),
            findsOneWidget,
          );
          await tester.runAsync(() async {
            final buffer = await c.project!.buffer(target);
            c.sourceEdit(
              target,
              buffer.text.replaceFirst('Disk schema', 'Unsaved schema'),
            );
            await c.analyse();
          });
          await tester.pump();
          await ready(
            tester,
            () => find.text('Unsaved schema').evaluate().isNotEmpty,
          );
          await click('Reveal in Source');
          expect(revealed?['resource'], target);
          expect(revealed?['pointer'], '/Model');
          expect(file.readAsStringSync(), original);
          expect(fragment.readAsStringSync(), contains('Disk schema'));
          expect(c.hasPendingFields, isFalse);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(screen());
          await ready(
            tester,
            () => find.text('Unsaved schema').evaluate().isNotEmpty,
          );
          expect(find.byType(ReferenceObjectView), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
