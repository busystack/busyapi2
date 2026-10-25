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
      for (final brightness in Brightness.values) {
        for (final name in ['clé/雪 ~😀 #?%', '']) {
          testWidgets(
            'reviewed native schema definition $version $format $brightness ${jsonEncode(name)}',
            (tester) async {
              tester.view.physicalSize = const Size(1400, 1100);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final directory = Directory.systemTemp.createTempSync(
                'busyapi-schema-definition-design-',
              );
              final pointer = '/components/schemas/Envelope/\$defs/Old';
              final original =
                  '${format == 'yaml' ? '# retained schema definition 雪😀\r\n' : ''}'
                  '${const JsonEncoder.withIndent('  ').convert({
                    'openapi': version,
                    'info': {'title': 'Native definitions', 'version': '1'},
                    'paths': <String, Object?>{},
                    'components': {
                      'schemas': {
                        'Envelope': {
                          '\$defs': {'Old': false},
                        },
                        'Use': {'\$ref': '#$pointer'},
                      },
                    },
                    'x-literal': {'\$ref': '#$pointer', 'number': 'EXACT'},
                  }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
              final file = File('${directory.path}/api.$format')
                ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]);
              final c = WorkspaceController(
                EngineProcess(executable: runtimeNode, helper: runtimeHelper),
                StateLocations(
                  config: '${directory.path}/config',
                  state: '${directory.path}/state',
                  cache: '${directory.path}/cache',
                ),
              );
              final actions = <Future<void>>[], errors = <Object>[];
              Future<void> ready(bool Function() condition) async {
                final clock = Stopwatch()..start();
                await tester.pump();
                while (!condition() &&
                    errors.isEmpty &&
                    clock.elapsed < const Duration(seconds: 12)) {
                  await tester.runAsync(
                    () =>
                        Future<void>.delayed(const Duration(milliseconds: 20)),
                  );
                  await tester.pump(const Duration(milliseconds: 20));
                }
                expect(errors, isEmpty);
                expect(
                  condition(),
                  true,
                  reason:
                      'pointer=${c.selectedPointer} error=${c.error} form=${c.form?.kind}',
                );
                await tester.pumpAndSettle();
              }

              Future<void> tap(String label) async {
                final target = find.text(label).last;
                await tester.ensureVisible(target);
                await tester.pumpAndSettle();
                await tester.runAsync(() => tester.tap(target));
                await tester.pump();
              }

              Finder field() => find.descendant(
                of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
                matching: find.byType(TextField),
              );
              bool current(String label) => find
                  .text(label)
                  .evaluate()
                  .any((element) => ModalRoute.of(element)?.isCurrent == true);
              try {
                await runWidgetIo(tester, () async {
                  await c.initialize();
                  await c.open(file.path);
                  await c.selectObject({
                    'root': c.root,
                    'resource': c.root,
                    'pointer': pointer,
                  });
                });
                await tester.pumpWidget(
                  MaterialApp(
                    theme: buildBusyApiTheme(
                      brightness: brightness,
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
                await ready(
                  () => find
                      .text('Rename schema definition')
                      .evaluate()
                      .isNotEmpty,
                );
                expect(find.text('Rename component'), findsNothing);
                expect(find.text('false'), findsWidgets);
                final item = await tester.runAsync(
                  () => c.project!.inspectObject(c.root!, c.root!, pointer),
                );
                final captured = c.beginForm(
                  'object.renameSchemaDefinition',
                  item!,
                  const {},
                  {'name': 'Old'},
                );
                captured.edit('name', name);
                await tester.runAsync(c.persist);
                c.form = FormSession.restore(captured.recovery());
                await tester.runAsync(() async {
                  actions.add(
                    resumeCapturedForm(
                      tester.element(find.byType(Designer)),
                      c,
                    ).catchError((Object error) => errors.add(error)),
                  );
                });
                await ready(
                  () => field().evaluate().any(
                    (element) => ModalRoute.of(element)?.isCurrent == true,
                  ),
                );
                expect(
                  tester.widget<TextField>(field()).controller!.text,
                  name,
                );
                expect(c.buffer!.text, original);
                await tap('Cancel');
                await runWidgetIo(tester, () => Future.wait(actions));
                await ready(
                  () =>
                      c.form == null &&
                      c.restoringForm == null &&
                      find.byType(BusyApiDialogShell).evaluate().isEmpty,
                );
                expect(c.buffer!.text, original);
                for (final accept in [false, true]) {
                  await tap('Rename schema definition');
                  await ready(
                    () => field().evaluate().any(
                      (element) => ModalRoute.of(element)?.isCurrent == true,
                    ),
                  );
                  expect(
                    tester.widget<TextField>(field()).controller!.text,
                    'Old',
                  );
                  await tester.runAsync(() => tester.enterText(field(), name));
                  await tap('Apply');
                  await ready(() => current('Review refactoring'));
                  expect(c.buffer!.text, original);
                  expect(file.readAsBytesSync(), [
                    239,
                    187,
                    191,
                    ...utf8.encode(original),
                  ]);
                  await tap(accept ? 'Apply' : 'Cancel');
                  await ready(() => !current('Review refactoring'));
                  if (!accept) expect(c.buffer!.text, original);
                }
                final destination =
                    '/components/schemas/Envelope/\$defs/${name.replaceAll('~', '~0').replaceAll('/', '~1')}';
                await ready(
                  () => c.selectedPointer == destination && !c.checking,
                );
                final accepted = c.buffer!.text;
                final parsed = jsonDecode(
                  accepted.replaceFirst(
                    '# retained schema definition 雪😀\r\n',
                    '',
                  ),
                ) as Map;
                expect(
                  (parsed['components']['schemas']['Envelope']['\$defs'] as Map)
                      .containsKey(name),
                  true,
                );
                expect(
                  parsed['components']['schemas']['Envelope']['\$defs'][name],
                  false,
                );
                expect(parsed['x-literal']['\$ref'], '#$pointer');
                expect(accepted, contains('9007199254740993.00'));
                await runWidgetIo(tester, () async {
                  await c.undo();
                  expect(c.buffer!.text, original);
                  await c.redo();
                  expect(c.buffer!.text, accepted);
                  await c.saveAll();
                });
                expect(file.readAsBytesSync(), [
                  239,
                  187,
                  191,
                  ...utf8.encode(accepted),
                ]);
                expect(errors, isEmpty);
                expect(tester.takeException(), isNull);
                await runWidgetIo(tester, () => Future.wait(actions));
              } finally {
                await tester.pumpWidget(const SizedBox());
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
}
