import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/reference/reference_object.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/swagger_server_support.dart';
import '../packages/busyapi_core/test/server_context_support.dart';
import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final (name, invalid, repaired)
          in version == '2.0'
              ? [
                  ('host', 'user@[::1]:8080', '[::1]:8080'),
                  ('basePath', '/v1/{version}', '/v1/%E9%9B%AA'),
                ]
              : [('url', 'http://[::1]:8080/%zz', 'http://[::1]:8080/v1')]) {
        testWidgets(
          '${version == '2.0' ? 'Swagger' : 'OpenAPI $version'} $format $name Design repair and Source history preserve native fields',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
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
              'busyapi-swagger-server-design-',
            );
            final source = version != '2.0'
                ? serverContextSource(version, format, invalid)
                : name == 'host'
                ? swaggerServerSource(format, invalid)
                : swaggerServerSource(
                    format,
                    '[::1]:8080',
                  ).replaceFirst('/v1', invalid);
            final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
            final file = File('${temp.path}/api.$format')
              ..writeAsBytesSync(original);
            final controller = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${temp.path}/config',
                state: '${temp.path}/state',
                cache: '${temp.path}/cache',
              ),
            );
            final failures = <Object>[];
            Future<void>? pending;
            Future<void> ready(bool Function() condition) async {
              final clock = Stopwatch()..start();
              await tester.pump();
              while (!condition() &&
                  failures.isEmpty &&
                  clock.elapsed < const Duration(seconds: 12)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(failures, isEmpty);
              expect(
                condition(),
                true,
                reason: '${controller.error} ${controller.analysis}',
              );
              await tester.pumpAndSettle();
            }

            final row = find.widgetWithText(BusyApiGroupedTextEntry, name);
            final input = find.descendant(
              of: row,
              matching: find.byType(TextField),
            );
            try {
              await runWidgetIo(tester, () async {
                await controller.initialize();
                await controller.open(file.path);
                await controller.selectObject({
                  'root': controller.root,
                  'resource': controller.root,
                  'pointer': version == '2.0' ? '' : '/servers/0',
                });
                await controller.analyse();
              });
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildBusyApiTheme(
                    brightness: format == 'json'
                        ? Brightness.dark
                        : Brightness.light,
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
                        run: (action) => pending = action().catchError(
                          (Object error) => failures.add(error),
                        ),
                        reveal: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              await ready(
                () =>
                    input.evaluate().isNotEmpty && controller.analysis != null,
              );
              final field = tester.widget<TextField>(input).controller!;
              expect(field.text, invalid);
              expect(
                tester.widget<BusyApiGroupedTextEntry>(row).errorText,
                isNotNull,
              );
              expect(controller.analysis!['status'], 'invalid');
              await tester.enterText(input, repaired);
              expect(controller.hasPendingFields, true);
              await tester.runAsync(
                () => tester.testTextInput.receiveAction(TextInputAction.done),
              );
              await ready(() => pending != null);
              var applied = false;
              await tester.runAsync(() async {
                pending!.then((_) => applied = true);
              });
              await ready(() => applied);
              await runWidgetIo(tester, controller.analyse);
              await ready(
                () =>
                    input.evaluate().isNotEmpty &&
                    tester.widget<BusyApiGroupedTextEntry>(row).errorText ==
                        null,
              );
              final working = source.replaceFirst(invalid, repaired);
              expect(controller.buffer!.text, working);
              expect(controller.analysis!['status'], 'complete');
              expect(tester.widget<TextField>(input).controller, same(field));
              expect(file.readAsBytesSync(), original);
              await runWidgetIo(tester, () async {
                await controller.undo();
                await controller.analyse();
              });
              await ready(
                () =>
                    input.evaluate().isNotEmpty &&
                    tester.widget<TextField>(input).controller!.text == invalid,
              );
              expect(controller.buffer!.bytes(), original);
              expect(
                tester.widget<BusyApiGroupedTextEntry>(row).errorText,
                isNotNull,
              );
              await runWidgetIo(tester, () async {
                await controller.redo();
                await controller.analyse();
              });
              await ready(() => controller.analysis?['status'] == 'complete');
              await runWidgetIo(tester, controller.saveAll);
              final saved = [0xef, 0xbb, 0xbf, ...utf8.encode(working)];
              expect(file.readAsBytesSync(), saved);
              await runWidgetIo(tester, () async {
                await controller.open(file.path);
                controller.sourceEdit(controller.root!, source);
                await controller.analyse();
              });
              await ready(() => controller.analysis?['status'] == 'invalid');
              expect(
                (controller.analysis!['findings'] as List).any(
                  (dynamic f) => (version == '2.0'
                      ? f['code'] == 'swagger.$name.syntax' &&
                            f['pointer'] == '/$name'
                      : (f['code'] as String).startsWith('server.url.') &&
                            f['pointer'] == '/servers/0/url'),
                ),
                true,
              );
              expect(file.readAsBytesSync(), saved);
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
                      builder: (_, _) => ReferenceObjectView(
                        controller: controller,
                        target: {
                          'root': controller.root,
                          'resource': controller.root,
                          'pointer': '/paths/~1items/get',
                          'kind': 'operation',
                          'method': 'get',
                          'occurrence': '${controller.root}#/paths/~1items/get',
                        },
                        reveal: (_) {},
                        open: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              final warning = find.text(
                'Some inherited declarations cannot be resolved unambiguously. Inspect their source contexts.',
              );
              await ready(() => warning.evaluate().isNotEmpty);
              expect(tester.takeException(), isNull);
              await runWidgetIo(tester, () async {
                await controller.undo();
                await controller.analyse();
              });
              await ready(() => controller.analysis?['status'] == 'complete');
              await ready(() => warning.evaluate().isEmpty);
              expect(controller.buffer!.text, working);
              await runWidgetIo(tester, controller.saveAll);
              expect(file.readAsBytesSync(), saved);
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
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
