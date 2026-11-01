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
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.0', '3.2.1']) {
    for (final uri in [false, if (version.startsWith('3.2.')) true]) {
      for (final format in ['yaml', 'json']) {
        testWidgets(
          'Design security rename $version $format URI=$uri reviews configuration and saves linked sources',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final directory = Directory.systemTemp.createTempSync(
              'busyapi-security-design-',
            );
            final controller = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${directory.path}/config',
                state: '${directory.path}/state',
                cache: '${directory.path}/cache',
              ),
            );
            final failures = <Object>[];
            Future<void>? pending;
            Future<void> waitFor(bool Function() condition) async {
              final timer = Stopwatch()..start();
              await tester.pump();
              while (!condition() &&
                  failures.isEmpty &&
                  timer.elapsed < const Duration(seconds: 12)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(failures, isEmpty);
              expect(
                condition(),
                true,
                reason:
                    'pointer=${controller.selectedPointer}, error=${controller.error}, form=${controller.form?.kind}',
              );
              await tester.pumpAndSettle();
            }

            Future<void> button(String label) => tester.runAsync(
              () => tester.tap(find.widgetWithText(BusyApiDialogButton, label)),
            );
            Future<void> settleAction() async {
              var completed = false;
              await tester.runAsync(() async {
                pending!.then((_) => completed = true);
              });
              await waitFor(() => completed);
            }

            try {
              final swagger = version == '2.0';
              final pointer =
                  '${swagger ? '/securityDefinitions' : '/components/securitySchemes'}/Old';
              final binding = uri ? '#/components/securitySchemes/Old' : 'Old';
              final nextBinding = uri
                  ? '#/components/securitySchemes/__proto__'
                  : '__proto__';
              final definition = {
                'type': 'apiKey',
                'in': 'header',
                'name': 'X-Key',
              };
              final source =
                  '${format == 'yaml' ? '# retained security 雪\r\n' : ''}${const JsonEncoder.withIndent('  ').convert({
                    if (swagger) 'swagger': version else 'openapi': version,
                    'info': {'title': 'Native security', 'version': '1'},
                    'paths': <String, Object?>{},
                    'security': [
                      {binding: <String>[]},
                    ],
                    if (swagger) 'securityDefinitions': {'Old': definition} else 'components': {
                        'securitySchemes': {'Old': definition},
                      },
                  })}\r\n';
              final file = File('${directory.path}/api.$format')
                ..writeAsStringSync(source);
              final root = file.uri.toString();
              final configuration =
                  '''version: 1
roots: [{name: api, path: api.$format}]
environments:
  manual:
    authentication:
      schemes:
        ${jsonEncode(binding)}: {secretRef: '11111111-1111-4111-8111-111111111111'} # retained
''';
              final manifest = File('${directory.path}/busyapi.yaml')
                ..writeAsStringSync(configuration);
              await tester.runAsync(() async {
                await controller.initialize();
                await controller.open(directory.path);
                await controller.selectObject({
                  'root': root,
                  'resource': root,
                  'pointer': pointer,
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
              Future<void> beginRename() async {
                final action = find.widgetWithText(
                  BusyApiActionRow,
                  'Rename component',
                );
                await waitFor(
                  () => action.evaluate().any(
                    (element) =>
                        (element.widget as BusyApiActionRow).onTap != null,
                  ),
                );
                await tester.runAsync(() => tester.tap(action));
                await waitFor(() => controller.form != null);
                final name = find.descendant(
                  of: find.descendant(
                    of: find.byType(BusyApiDialogShell),
                    matching: find.widgetWithText(
                      BusyApiGroupedTextEntry,
                      'Name',
                    ),
                  ),
                  matching: find.byType(TextField),
                );
                expect(name, findsOneWidget);
                await tester.runAsync(
                  () => tester.enterText(name, '__proto__'),
                );
                await button('Apply');
              }

              Future<void> review() async {
                await beginRename();
                await waitFor(
                  () => find.text('Review refactoring').evaluate().isNotEmpty,
                );
                expect(controller.store!.get(root).text, source);
                expect(
                  controller.store!.buffers[manifest.uri.toString()]?.text,
                  anyOf(isNull, configuration),
                );
                expect(file.readAsStringSync(), source);
                expect(manifest.readAsStringSync(), configuration);
                expect(find.text('busyapi.yaml'), findsOneWidget);
              }

              if (version == '3.0.4' && format == 'yaml' ||
                  version == '2.0' && format == 'json') {
                final conflict = configuration.replaceFirst(
                  ' # retained\n',
                  ' # retained\n        ${jsonEncode(nextBinding)}: {secretRef: different-reference}\n',
                );
                await tester.runAsync(() async {
                  final buffer = await controller.project!.buffer(
                    manifest.uri.toString(),
                  );
                  controller.sourceEdit(buffer.id, conflict);
                });
                await beginRename();
                final message = AppLocalizations.of(
                  tester.element(find.byType(Designer)),
                )!.securityRefactoringSettingsConflict;
                await waitFor(
                  () => find.textContaining(message).evaluate().isNotEmpty,
                );
                expect(controller.form!.values['name'], '__proto__');
                expect(controller.store!.get(root).text, source);
                expect(
                  controller.store!.get(manifest.uri.toString()).text,
                  conflict,
                );
                expect(file.readAsStringSync(), source);
                expect(manifest.readAsStringSync(), configuration);
                await button('Cancel');
                await settleAction();
                await tester.runAsync(controller.undo);
                expect(
                  controller.store!.get(manifest.uri.toString()).text,
                  configuration,
                );
              }
              await review();
              await button('Cancel');
              await settleAction();
              expect(controller.store!.get(root).text, source);
              await review();
              await button('Apply');
              await settleAction();
              final accepted = controller.store!.get(root).text;
              final acceptedConfiguration = controller.store!
                  .get(manifest.uri.toString())
                  .text;
              expect(accepted, contains('__proto__'));
              expect(acceptedConfiguration, contains(nextBinding));
              expect(acceptedConfiguration, contains('# retained'));
              expect(
                acceptedConfiguration,
                contains('${jsonEncode(binding)}: {secretRef:'),
              );
              await tester.runAsync(controller.undo);
              expect(controller.store!.get(root).text, source);
              expect(
                controller.store!.get(manifest.uri.toString()).text,
                configuration,
              );
              await tester.runAsync(controller.redo);
              expect(controller.store!.get(root).text, accepted);
              expect(
                controller.store!.get(manifest.uri.toString()).text,
                acceptedConfiguration,
              );
              await tester.runAsync(
                () => controller.saveBuffers(
                  only: {format == 'json' ? manifest.uri.toString() : root},
                ),
              );
              expect(file.readAsStringSync(), accepted);
              expect(manifest.readAsStringSync(), acceptedConfiguration);
              expect(controller.store!.get(root).dirty, false);
              expect(
                controller.store!.get(manifest.uri.toString()).dirty,
                false,
              );
              expect(controller.storageError, isNull);
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.runAsync(controller.shutdown);
              controller.dispose();
              directory.deleteSync(recursive: true);
            }
          },
        );
      }
    }
  }
}
