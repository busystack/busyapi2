import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    final roles = version == '3.1.2' || version == '3.2.1';
    for (final format in ['yaml', 'json']) {
      for (final mode in [
        'name',
        if (version == '3.2.1') ...['uri', 'alternative', 'combined'],
      ]) {
        testWidgets(
          'Design security selection $version $format $mode reviews current source and preserves history',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final directory = Directory.systemTemp.createTempSync(
              'busyapi-security-picker-',
            );
            final uri = mode != 'name';
            const definition = {
              'type': 'apiKey',
              'in': 'header',
              'name': 'X-Key',
            };
            final data = {
              if (version == '2.0') 'swagger': version else 'openapi': version,
              'info': {'title': 'Security selection 雪😀', 'version': '1'},
              'paths': <String, Object?>{},
              if (version == '2.0')
                'securityDefinitions': {'Old': definition, 'New': definition}
              else
                'components': {
                  'securitySchemes': {
                    'Old': definition,
                    'New': definition,
                    if (uri) 'Remote': {r'$ref': 'security.json#/Remote'},
                  },
                },
              'security': [
                {
                  'Old': roles ? ['operator'] : <String>[],
                },
              ],
              'x-exact': 'EXACT',
            };
            final original =
                '${format == 'yaml' ? '# retained security 雪😀\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(data).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
            final bytes = [239, 187, 191, ...utf8.encode(original)];
            final file = File('${directory.path}/api.$format')
              ..writeAsBytesSync(bytes);
            final external = File('${directory.path}/security.json')
              ..writeAsStringSync(jsonEncode({'Remote': definition}));
            const configuration =
                'version: 1\nenvironments: {manual: {authentication: {schemes: {Old: {secretRef: old-reference}}}}}\n';
            final manifest = File('${directory.path}/busyapi.yaml')
              ..writeAsStringSync(configuration);
            final c = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${directory.path}/config',
                state: '${directory.path}/state',
                cache: '${directory.path}/cache',
              ),
            );
            final errors = <Object>[], actions = <Future<void>>[];
            Future<void> ready(bool Function() condition) async {
              final watch = Stopwatch()..start();
              await tester.pump();
              while (!condition() &&
                  errors.isEmpty &&
                  watch.elapsed < const Duration(seconds: 12)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(errors, isEmpty);
              expect(
                condition(),
                true,
                reason: 'pointer=${c.selectedPointer} error=${c.error}',
              );
              await tester.pumpAndSettle();
            }

            Future<void> tap(Finder finder) async {
              await tester.ensureVisible(finder);
              await tester.pumpAndSettle();
              await tester.runAsync(() => tester.tap(finder));
              await tester.pump();
            }

            final pointer = mode == 'alternative'
                ? '/security'
                : mode == 'combined'
                ? '/security/0'
                : '/security/0/Old';
            Future<void> review() async {
              final action = find.widgetWithText(
                BusyApiActionRow,
                mode == 'alternative' || mode == 'combined'
                    ? 'Add security scheme by URI…'
                    : 'Change security binding…',
              );
              await ready(
                () =>
                    action.evaluate().isNotEmpty &&
                    (action.evaluate().single.widget as BusyApiActionRow)
                            .onTap !=
                        null,
              );
              await tap(action);
              await ready(
                () => find.byType(BusyApiSearchField).evaluate().isNotEmpty,
              );
              await tester.enterText(
                find.descendant(
                  of: find.byType(BusyApiSearchField),
                  matching: find.byType(EditableText),
                ),
                uri ? 'Remote' : 'New',
              );
              await tester.pump(const Duration(milliseconds: 300));
              final bindingLabel = uri
                  ? 'URI binding: security.json#/Remote'
                  : 'Named binding: New';
              await ready(() => find.text(bindingLabel).evaluate().isNotEmpty);
              await tap(
                find.ancestor(
                  of: find.text(bindingLabel),
                  matching: find.byType(BusyApiActionRow),
                ),
              );
              await ready(
                () =>
                    find.text('Review reference change').evaluate().isNotEmpty,
              );
            }

            try {
              await runWidgetIo(tester, () async {
                await c.initialize();
                await c.open(file.path);
                await c.selectObject({
                  'root': c.root,
                  'resource': c.root,
                  'pointer': mode == 'name' && roles ? '/security/0' : pointer,
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
                      listenable: c,
                      builder: (_, _) => Designer(
                        controller: c,
                        run: (action) => actions.add(
                          action().catchError(
                            (Object error) => errors.add(error),
                          ),
                        ),
                        reveal: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              if (mode == 'name' && roles) {
                await ready(
                  () => find.text('Required roles: 1').evaluate().isNotEmpty,
                );
                expect(find.text('Required roles: 1'), findsOneWidget);
                await tap(find.widgetWithText(BusyApiActionRow, 'Old'));
              }
              await ready(
                () =>
                    c.selectedPointer == pointer &&
                    !c.checking &&
                    find
                        .widgetWithText(
                          BusyApiActionRow,
                          mode == 'alternative' || mode == 'combined'
                              ? 'Add security scheme by URI…'
                              : 'Change security binding…',
                        )
                        .evaluate()
                        .isNotEmpty,
              );
              if (mode == 'name' && !roles) {
                expect(
                  find.text(
                    'This security scheme requires an empty scope list.',
                  ),
                  findsOneWidget,
                );
                expect(find.text('Add security scheme by URI…'), findsNothing);
              }
              if (version == '3.1.2') {
                expect(find.text('Add security scheme by URI…'), findsNothing);
              }
              await review();
              expect(c.buffer!.bytes(), bytes);
              expect(file.readAsBytesSync(), bytes);
              await tap(find.widgetWithText(BusyApiDialogButton, 'Cancel'));
              await ready(
                () => find.text('Review reference change').evaluate().isEmpty,
              );
              expect(c.buffer!.bytes(), bytes);
              await review();
              await tap(find.widgetWithText(BusyApiDialogButton, 'Apply'));
              await ready(
                () =>
                    c.buffer!.text != original &&
                    find.text('Review reference change').evaluate().isEmpty,
              );
              await runWidgetIo(tester, () => Future.wait(actions));
              final accepted = c.buffer!.text;
              final security =
                  jsonDecode(
                        accepted.replaceFirst(
                          '# retained security 雪😀\r\n',
                          '',
                        ),
                      )['security']
                      as List;
              final binding = uri ? 'security.json#/Remote' : 'New';
              if (mode == 'alternative') {
                expect(security, [
                  {
                    'Old': ['operator'],
                  },
                  {binding: []},
                ]);
              } else if (mode == 'combined') {
                expect(security, [
                  {
                    'Old': ['operator'],
                    binding: [],
                  },
                ]);
              } else {
                expect(security, [
                  {
                    binding: roles ? ['operator'] : [],
                  },
                ]);
                expect(
                  c.selectedPointer,
                  '/security/0/${binding.replaceAll('~', '~0').replaceAll('/', '~1')}',
                );
              }
              expect(accepted, contains('9007199254740993.00'));
              expect(manifest.readAsStringSync(), configuration);
              expect(
                external.readAsStringSync(),
                jsonEncode({'Remote': definition}),
              );
              await runWidgetIo(tester, () async {
                await c.undo();
                expect(c.buffer!.bytes(), bytes);
                await c.redo();
                expect(c.buffer!.text, accepted);
                await c.saveAll();
                expect(file.readAsBytesSync(), [
                  239,
                  187,
                  191,
                  ...utf8.encode(accepted),
                ]);
                await c.open(file.path);
                expect(c.buffer!.text, accepted);
              });
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await runWidgetIo(tester, c.shutdown);
              c.dispose();
              directory.deleteSync(recursive: true);
            }
          },
        );
      }
    }
  }
}
