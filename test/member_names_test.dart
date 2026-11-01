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

class _MemberNamesEngine extends EngineProcess {
  _MemberNamesEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final trace = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'propose') {
      trace.add('actions=${params['actions']}');
    }
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'propose') {
      trace.add('edits=${result['edits']}');
    }
    return result;
  }
}

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
    messenger.setMockMethodCallHandler(
      const MethodChannel('busyapi/native_menus'),
      (call) async {
        if (call.method != 'show') return null;
        final entries = (call.arguments['entries'] as List).cast<Map>();
        final selected = entries.indexWhere(
          (entry) => entry['label'] == 'New source file…',
        );
        expect(selected, greaterThanOrEqualTo(0));
        return selected;
      },
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['yaru_window', 'yaru_window/events']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('busyapi/native_menus'),
      null,
    );
  });
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final name in [
        if (version == '2.0') ...['clé/雪 ~😀 #?%', ''] else 'clé/雪 ~😀 #?%',
      ]) {
        testWidgets(
          'native member names $version $format ${jsonEncode(name)} preserve their namespace and reviewed destinations',
          (tester) async {
            tester.view.physicalSize = const Size(1400, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final directory = Directory.systemTemp.createTempSync(
                  'busyapi-member-names-design-',
                ),
                legacy = version == '2.0';
            final data = {
              'info': {'title': 'Native names 雪😀', 'version': '1'},
              if (legacy) 'swagger': version else 'openapi': version,
              'paths': {
                '/items': {
                  'get': {
                    'responses': {
                      '200': {
                        'description': 'Model',
                        if (legacy)
                          'schema': {'type': 'string'}
                        else
                          'content': {
                            'application/json': {
                              'schema': {'type': 'string'},
                            },
                          },
                      },
                    },
                  },
                },
              },
              if (legacy)
                'definitions': <String, Object?>{}
              else
                'components': {'schemas': <String, Object?>{}},
              'x-large': 'EXACT',
            };
            final original =
                '${format == 'yaml' ? '# retained 雪😀\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(data).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
            final file = File('${directory.path}/api.$format')
                  ..writeAsBytesSync([239, 187, 191, ...utf8.encode(original)]),
                destination = File('${directory.path}/extracted.$format');
            final engine = _MemberNamesEngine();
            final c = WorkspaceController(
              engine,
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
                reason:
                    'pointer=${c.selectedPointer} error=${c.error} dirty=${c.buffer?.dirty} form=${c.form?.kind} applying=${c.formApplying} trace=${engine.trace} messages=${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().where((text) => text.contains(RegExp(r"(?:name|Name|retained|failed|changed|Invalid|entry|draft)"))).toList()}',
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

            Finder field(String label) => find.descendant(
              of: find.widgetWithText(BusyApiGroupedTextEntry, label),
              matching: find.byType(TextField),
            );
            bool current(String label) => find
                .text(label)
                .evaluate()
                .any((element) => ModalRoute.of(element)?.isCurrent == true);
            Future<void> select(String pointer) async {
              await runWidgetIo(
                tester,
                () => c.selectObject({
                  'root': c.root,
                  'resource': c.root,
                  'pointer': pointer,
                }),
              );
              await ready(() => !c.checking && c.selectedPointer == pointer);
            }

            Future<void> enterName() async {
              await ready(
                () => field('Name').evaluate().any(
                  (element) => ModalRoute.of(element)?.isCurrent == true,
                ),
              );
              if (name.isEmpty) {
                await tap('Use an empty name');
              } else {
                await tester.runAsync(
                  () => tester.enterText(field('Name'), name),
                );
              }
            }

            final map = legacy ? '/definitions' : '/components/schemas';
            try {
              await runWidgetIo(tester, () async {
                await c.initialize();
                await c.open(file.path);
                await c.selectObject({
                  'root': c.root,
                  'resource': c.root,
                  'pointer': map,
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
              await ready(
                () => find
                    .widgetWithText(BusyApiActionRow, 'Add entry')
                    .evaluate()
                    .isNotEmpty,
              );
              if (!legacy) {
                await tap('Add entry');
                await enterName();
                await tap('Apply');
                await ready(
                  () => current(
                    'Component names may contain only letters, digits, dots, hyphens and underscores.',
                  ),
                );
                expect(
                  tester.widget<TextField>(field('Name')).controller!.text,
                  name,
                );
                expect(c.buffer!.text, original);
                expect(find.text('Use an empty name'), findsNothing);
                await tap('Cancel');
                expect(file.readAsBytesSync(), [
                  239,
                  187,
                  191,
                  ...utf8.encode(original),
                ]);
              } else {
                await tap('Add entry');
                await enterName();
                await tap('Cancel');
                await ready(
                  () =>
                      c.form == null &&
                      find.byType(BusyApiDialogShell).evaluate().isEmpty,
                );
                expect(c.buffer!.text, original);
                await tap('Add entry');
                await enterName();
                await tap('Apply');
                final createdPointer =
                    '$map/${name.replaceAll('~', '~0').replaceAll('/', '~1')}';
                await ready(
                  () =>
                      c.buffer!.text != original &&
                      find.byType(BusyApiDialogShell).evaluate().isEmpty,
                );
                if (c.selectedPointer != createdPointer) {
                  await ready(
                    () => find
                        .widgetWithText(
                          BusyApiActionRow,
                          name.isEmpty ? '(empty name)' : name,
                        )
                        .evaluate()
                        .isNotEmpty,
                  );
                  await tap(name.isEmpty ? '(empty name)' : name);
                }
                await ready(
                  () =>
                      c.selectedPointer == createdPointer &&
                      find
                          .widgetWithText(BusyApiActionRow, 'Rename component')
                          .evaluate()
                          .isNotEmpty,
                );
                final created = c.buffer!.text;
                expect(
                  (jsonDecode(
                            created.replaceFirst('# retained 雪😀\r\n', ''),
                          )['definitions']
                          as Map)
                      .containsKey(name),
                  true,
                );
                expect(find.text('Move definition…'), findsOneWidget);
                for (final accept in [false, true]) {
                  await tap('Rename component');
                  await ready(
                    () => field('Name').evaluate().any(
                      (element) => ModalRoute.of(element)?.isCurrent == true,
                    ),
                  );
                  await tester.runAsync(
                    () => tester.enterText(field('Name'), 'Renamed'),
                  );
                  await tap('Apply');
                  await ready(() => current('Review refactoring'));
                  expect(c.buffer!.text, created);
                  await tap(accept ? 'Apply' : 'Cancel');
                  await ready(() => !current('Review refactoring'));
                }
                await ready(() => c.selectedPointer == '/definitions/Renamed');
                final renamed = c.buffer!.text;
                await runWidgetIo(tester, () async {
                  await c.undo();
                  expect(c.buffer!.text, created);
                  await c.undo();
                  expect(c.buffer!.text, original);
                  await c.redo();
                  await c.redo();
                  expect(c.buffer!.text, renamed);
                });
                Future<void> extractionReview() async {
                  await select('/paths/~1items/get/responses/200/schema');
                  await ready(
                    () => find
                        .widgetWithText(
                          BusyApiActionRow,
                          'Extract to component…',
                        )
                        .evaluate()
                        .isNotEmpty,
                  );
                  await tap('Extract to component…');
                  await enterName();
                  await tap('Component destination');
                  await ready(
                    () =>
                        tester
                            .widget<BusyApiComboRow<String>>(
                              find.widgetWithText(
                                BusyApiComboRow<String>,
                                'Component destination',
                              ),
                            )
                            .selected ==
                        'busyapi:new-source-file',
                  );
                  await tap('Apply');
                  await ready(() => current('Extract to new source file'));
                  expect(
                    tester
                        .widget<TextField>(field('Destination path'))
                        .controller!
                        .text,
                    'component.$format',
                  );
                  await tester.runAsync(
                    () => tester.enterText(
                      field('Destination path'),
                      'extracted.$format',
                    ),
                  );
                  await tap('Apply');
                  await ready(
                    () => current('Review extraction to source file'),
                  );
                  expect(destination.existsSync(), false);
                  expect(c.store!.get(file.uri.toString()).text, renamed);
                }

                await extractionReview();
                await tap('Cancel');
                await ready(() => !current('Review extraction to source file'));
                expect(destination.existsSync(), false);
                await extractionReview();
                await tap('Apply');
                await ready(
                  () =>
                      c.store!.buffers.containsKey(
                        destination.uri.toString(),
                      ) &&
                      !current('Review extraction to source file'),
                );
                final accepted = c.store!.get(file.uri.toString()).text;
                expect(accepted, contains('9007199254740993.00'));
                expect(destination.existsSync(), false);
                await runWidgetIo(tester, () async {
                  expect(
                    (await c.project!.check(c.root!))['status'],
                    'complete',
                  );
                  await c.saveAll();
                  expect(destination.existsSync(), true);
                  expect(file.readAsBytesSync(), [
                    239,
                    187,
                    191,
                    ...utf8.encode(accepted),
                  ]);
                  await c.open(file.path);
                  expect(c.store!.get(file.uri.toString()).text, accepted);
                  expect(
                    c.store!.get(destination.uri.toString()).text,
                    destination.readAsStringSync(),
                  );
                  expect(
                    (await c.project!.check(c.root!))['status'],
                    'complete',
                  );
                });
              }
              await runWidgetIo(tester, () => Future.wait(actions));
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
