import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/schema_role_support.dart';
import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final keyword in [r'$defs', 'definitions']) {
        testWidgets(
          '$version $format $keyword Design retains physical ownership and Source diagnostics for a second schema role',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final temp = Directory.systemTemp.createTempSync(
              'busyapi-schema-role-design-',
            );
            final original = schemaRoleSource(version, format, keyword, 1);
            final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(original)];
            final file = File('${temp.path}/api.$format')
              ..writeAsBytesSync(bytes);
            final controller = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${temp.path}/config',
                state: '${temp.path}/state',
                cache: '${temp.path}/cache',
              ),
            );
            final errors = <Object>[];
            Future<void> ready(bool Function() condition) async {
              final elapsed = Stopwatch()..start();
              await tester.pump();
              while (!condition() &&
                  elapsed.elapsed < const Duration(seconds: 12)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(
                condition(),
                true,
                reason:
                    'analysis=${controller.analysis?["status"]} error=${controller.error}',
              );
              await tester.pumpAndSettle();
            }

            try {
              await runWidgetIo(tester, () async {
                await controller.initialize();
                await controller.open(file.path);
                await controller.selectObject({
                  'root': controller.root,
                  'resource': controller.root,
                  'pointer': '/components/schemas/Envelope/$keyword/properties',
                });
              });
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildBusyApiTheme(
                    brightness: Brightness.light,
                    accentColor: Colors.blue,
                  ),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Scaffold(
                    body: ListenableBuilder(
                      listenable: controller,
                      builder: (_, _) => Designer(
                        controller: controller,
                        run: (action) {
                          action().catchError((Object e) {
                            errors.add(e);
                          });
                        },
                        reveal: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              await ready(
                () =>
                    controller.analysis?['status'] == 'complete' &&
                    find.text('Add schema keyword').evaluate().isNotEmpty,
              );
              expect(
                controller.analysis?['status'],
                'complete',
                reason: jsonEncode(controller.analysis),
              );
              expect(find.text('Rename schema definition'), findsNothing);
              expect(find.text('Add schema keyword'), findsWidgets);
              final inspected = await tester.runAsync(
                () => controller.project!.inspectObject(
                  controller.root!,
                  controller.root!,
                  controller.selectedPointer,
                ),
              );
              expect(inspected!['kind'], 'schema');
              expect(inspected['schemaDefinitionNamePolicy'], isNull);
              expect(controller.scopeSafe(inspected), true);
              await runWidgetIo(tester, () async {
                controller.sourceEdit(
                  controller.root!,
                  original.replaceFirst('"properties": {', '"type": {'),
                );
                await controller.analyse();
                await controller.selectObject({
                  'root': controller.root,
                  'resource': controller.root,
                  'pointer': '/components/schemas/Envelope/$keyword',
                });
              });
              await tester.pumpAndSettle();
              final findings = controller.analysis!['findings'] as List;
              expect(
                findings.any(
                  (dynamic finding) =>
                      finding['code'] == 'schema.keyword.invalid' &&
                      (finding['pointer'] as String).startsWith(
                        '/components/schemas/Envelope/$keyword/type',
                      ),
                ),
                true,
                reason: jsonEncode(findings),
              );
              expect(file.readAsBytesSync(), bytes);
              await runWidgetIo(tester, () async {
                await controller.undo();
                await controller.analyse();
              });
              await tester.pumpAndSettle();
              expect(controller.buffer!.text, original);
              expect(controller.analysis?['status'], 'complete');
              expect(file.readAsBytesSync(), bytes);
              expect(errors, isEmpty);
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox());
              await runWidgetIo(tester, controller.shutdown);
              controller.dispose();
              temp.deleteSync(recursive: true);
            }
          },
        );
      }
    }
  }
}
