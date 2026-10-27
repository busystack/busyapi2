import 'dart:convert';
import 'dart:io';

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
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      (call) async => call.method == 'state'
          ? {'active': true, 'visible': true, 'closable': true}
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      (_) async => null,
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      null,
    );
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native schema controls retain empty-fragment dialect and exact source',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-dialect-widget-',
          );
          final file = File('${temp.path}/api.$format');
          final uri =
              'https://spec.openapis.org/oas/${version.substring(0, 3)}/dialect/base#';
          final original =
              '${format == 'yaml' ? '# Keep comment 雪\r\n' : ''}${jsonEncode({
                'openapi': version,
                'jsonSchemaDialect': uri,
                'info': {'title': 'Native dialect', 'version': 'api-version'},
                'paths': <String, Object?>{},
                'components': {
                  'schemas': {
                    'Value': {
                      r'$schema': uri,
                      'type': 'object',
                      'properties': {
                        'n': {'type': 'integer', 'minimum': 'EXACT'},
                      },
                    },
                  },
                },
                'x-kept': {r'$schema': 'https://example.invalid/literal#', 'n': 'EXACT'},
              }).replaceAll('"EXACT"', '9007199254740993.000')}\r\n';
          file.writeAsStringSync(original);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          Future<void>? pending;
          final failures = <Object>[];
          Future<void> ready(bool Function() condition) async {
            final watch = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                failures.isEmpty &&
                watch.elapsed < const Duration(seconds: 20)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(condition(), true, reason: '${c.error}');
            await tester.pumpAndSettle();
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(file.path);
              await c.analyse();
              expect(c.analysis?['complete'], true, reason: '${c.analysis}');
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/schemas/Value/properties',
              });
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: format == 'json'
                      ? Brightness.dark
                      : Brightness.light,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: ListenableBuilder(
                    listenable: c,
                    builder: (_, _) => Designer(
                      controller: c,
                      run: (action) =>
                          pending = action().catchError((Object error) {
                            failures.add(error);
                          }),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            final required = find.widgetWithText(BusyApiSwitchRow, 'Required');
            await ready(
              () =>
                  required.evaluate().length == 1 &&
                  tester.widget<BusyApiSwitchRow>(required).enabled,
            );
            await tester.runAsync(
              () => tester.tap(
                find.descendant(
                  of: required,
                  matching: find.byType(BusyApiSwitch),
                ),
              ),
            );
            await ready(() => c.buffer!.text != original);
            await tester.runAsync(() async {
              await pending;
            });
            final changed = c.buffer!.text;
            final checked = await tester.runAsync(
              () => c.project!.check(c.root!),
            );
            expect(checked!['complete'], true, reason: '$checked');
            expect(changed, contains('9007199254740993.000'));
            expect(changed, contains(uri));
            expect(changed, contains('https://example.invalid/literal#'));
            final object = await tester.runAsync(
              () => c.project!.inspectObject(
                c.root!,
                c.root!,
                '/components/schemas/Value',
              ),
            );
            final membership = (object!['fields'] as List)
                .whereType<Map>()
                .singleWhere((field) => field['name'] == 'required');
            expect(membership['present'], true);
            expect(jsonDecode(membership['raw'] as String), ['n']);
            c.store!.undo();
            expect(c.buffer!.text, original);
            c.store!.redo();
            expect(c.buffer!.text, changed);
            expect(file.readAsStringSync(), original);
            expect(failures, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
