import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
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
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'native string actions $version $json distinguish absent, empty, cancel and removal',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-field-presence-',
          );
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final failures = <Object>[];
          Future<void>? pending;
          Future<void> waitFor(
            bool Function() condition, {
            String phase = 'field state',
          }) async {
            await tester.pump();
            final timer = Stopwatch()..start();
            while (!condition() &&
                failures.isEmpty &&
                timer.elapsed < const Duration(seconds: 8)) {
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
                  '$phase; form=${c.form?.kind}, applying=${c.formApplying}, '
                  'error=${c.error}, storageError=${c.storageError}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> settleAction(String phase) async {
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await waitFor(() => done, phase: phase);
          }

          Future<void> openValue() async {
            final menu = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiHeaderPopupMenuButton<String> &&
                  widget.tooltip == 'Value actions for email',
            );
            await waitFor(() => menu.evaluate().isNotEmpty);
            await tester.runAsync(() => tester.tap(menu));
            await waitFor(
              () => find
                  .text('Edit value or remove field…')
                  .evaluate()
                  .isNotEmpty,
            );
            await tester.runAsync(
              () => tester.tap(find.text('Edit value or remove field…')),
            );
            await waitFor(() => c.form != null);
          }

          try {
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final original =
                '${json ? '' : '# retained 😀\r\n'}{"openapi":"$version","info":{"title":"T","version":"1","contact":{}},"paths":{},"x-number":9007199254740993.00}';
            await tester.runAsync(() async {
              await file.writeAsString(original);
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/info/contact',
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
            await waitFor(
              () => find
                  .widgetWithText(BusyApiGroupedTextEntry, 'email')
                  .evaluate()
                  .isNotEmpty,
            );
            expect(c.buffer!.text, original);
            await openValue();
            expect(
              find.widgetWithText(BusyApiDialogButton, 'Remove'),
              findsNothing,
            );
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiDialogButton, 'Cancel'),
              ),
            );
            await settleAction('cancel absent value');
            expect(c.buffer!.text, original);
            await openValue();
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            await settleAction('apply empty value');
            final withEmpty = c.buffer!.text;
            expect(withEmpty, contains('"email": ""'));
            expect(withEmpty, contains('9007199254740993.00'));
            expect(withEmpty.endsWith('\n'), false);
            await waitFor(
              () => find.text('Authored empty string').evaluate().isNotEmpty,
            );
            expect(find.text('Authored empty string'), findsOneWidget);
            await openValue();
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            await settleAction('apply unchanged value');
            expect(
              c.buffer!.text,
              withEmpty,
              reason: 'An unchanged string dialog must be byte-identical',
            );
            await tester.runAsync(c.undo);
            expect(
              c.buffer!.text,
              original,
              reason: 'No-op Apply must not add another history step',
            );
            await tester.runAsync(c.redo);
            await waitFor(
              () => find.text('Authored empty string').evaluate().isNotEmpty,
            );
            await openValue();
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiDialogButton, 'Remove'),
              ),
            );
            await settleAction('remove value');
            expect(c.buffer!.text, isNot(contains('"email"')));
            await tester.runAsync(c.undo);
            expect(c.buffer!.text, withEmpty);
            await tester.runAsync(() async {
              await c.project!.save(c.buffer!);
            });
            expect(file.readAsStringSync(), withEmpty);
            await tester.runAsync(() async {
              await c.open(file.path);
              expect(c.buffer!.text, withEmpty);
            });
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
  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'native object pages $version preserve occurrence ownership and author absent collections deliberately',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-object-page-',
        );
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        Future<void>? pending;
        final actionErrors = <Object>[];
        Future<void> waitFor(bool Function() condition) async {
          final clock = Stopwatch()..start();
          // Observe the rebuild requested by the preceding action before
          // deciding an old, still-mounted control is ready for activation.
          await tester.pump();
          while (!condition() &&
              actionErrors.isEmpty &&
              clock.elapsed < const Duration(seconds: 8)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(actionErrors, isEmpty);
          expect(
            condition(),
            true,
            reason: 'Current native action did not complete; ${c.error}',
          );
          await tester.pumpAndSettle();
        }

        Future<void> settleAction() async {
          final action = pending;
          if (action == null) return;
          var completed = false;
          await tester.runAsync(() async {
            action.then((_) => completed = true);
          });
          await waitFor(() => completed);
        }

        try {
          await tester.runAsync(() async {
            await c.initialize();
            await Initializer.create(
              destination: '${temp.path}/api',
              title: 'Native',
              apiVersion: '1',
              openapi: version,
              format: 'json',
            );
            final root = File('${temp.path}/api/openapi.json');
            final data =
                jsonDecode(await root.readAsString()) as Map<String, dynamic>;
            data['components'] = {
              'schemas': {
                'Model': {r'$ref': 'model.json#/Model'},
                'Alias': {r'$ref': '#/components/schemas/Model'},
              },
              'securitySchemes': {
                'Key': {'type': 'apiKey', 'name': 'x-key', 'in': 'header'},
                'Other': {'type': 'http', 'scheme': 'bearer'},
              },
            };
            data['paths'] = {
              '/items': {
                'get': {
                  'tags': ['original'],
                },
              },
              '/suggest': {
                'post': {
                  'requestBody': {
                    'content': {
                      'application/json': {
                        'example': {'name': '😀 sample', 'id': 1},
                      },
                    },
                  },
                  'responses': {
                    '204': {'description': 'Bodyless'},
                  },
                },
              },
            };
            await root.writeAsString(
              const JsonEncoder.withIndent('  ').convert(data),
            );
            await File('${temp.path}/api/model.json').writeAsString(
              '{ "Model": { "type": "object", "description": "Original", "properties": { "name": { "type": "string" } }, "default": { "name": "sample" }, "x-kept": 1.00 } }\r\n',
            );
            await c.open('${temp.path}/api');
            await c.analyse();
            await c.selectObject(
              Map<String, dynamic>.from(
                (c.projection!['components'] as List).firstWhere(
                  (v) => v['group'] == 'schemas',
                ),
              ),
            );
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
                    run: (action) =>
                        pending = action().catchError((Object error) {
                          actionErrors.add(error);
                        }),
                    reveal: (_) {},
                  ),
                ),
              ),
            ),
          );
          await waitFor(
            () => find.text('Reference occurrence').evaluate().isNotEmpty,
          );
          expect(find.text('Reference occurrence'), findsOneWidget);
          expect(c.selectedResource, c.root);
          await tester.runAsync(() => tester.tap(find.text('Edit Definition')));
          await settleAction();
          await tester.pumpAndSettle();
          await waitFor(
            () => find
                .widgetWithText(BusyApiGroupedTextEntry, 'Description')
                .evaluate()
                .isNotEmpty,
          );
          expect(c.selectedPointer, '/Model');
          expect(c.selectedResource, endsWith('model.json'));
          final description = find.descendant(
            of: find.widgetWithText(BusyApiGroupedTextEntry, 'Description'),
            matching: find.byType(TextField),
          );
          expect(description, findsOneWidget);
          await tester.runAsync(
            () => tester.enterText(description, 'Native definition'),
          );
          expect(c.draft!.pending, true);
          await tester.runAsync(
            () => tester.ensureVisible(find.text('default')),
          );
          await tester.runAsync(() => tester.tap(find.text('default')));
          await waitFor(() => c.form != null);
          expect(find.text('JSON-compatible data value'), findsOneWidget);
          expect(c.buffer!.text, contains('Native definition'));
          await tester.runAsync(
            () =>
                tester.tap(find.widgetWithText(BusyApiDialogButton, 'Cancel')),
          );
          await tester.pumpAndSettle();
          await settleAction();
          await waitFor(
            () => find.text('JSON-compatible data value').evaluate().isEmpty,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(c.form, isNull);
          expect(jsonDecode(c.buffer!.text)['Model']['default'], {
            'name': 'sample',
          });
          expect(c.buffer!.text, contains('Native definition'));
          expect(c.buffer!.text, contains('1.00'));
          expect(c.buffer!.text, endsWith('\r\n'));
          expect(File(c.buffer!.path).readAsStringSync(), contains('Original'));
          final modelId = c.buffer!.id;
          final beforeRequired = c.buffer!.text;
          await tester.runAsync(() async {
            await c.analyse();
            await c.selectObject({
              'root': c.root,
              'resource': modelId,
              'pointer': '/Model/properties',
            });
          });
          await tester.pumpAndSettle();
          await waitFor(
            () => find
                .widgetWithText(BusyApiSwitchRow, 'Required')
                .evaluate()
                .isNotEmpty,
          );
          final requiredRow = find.widgetWithText(BusyApiSwitchRow, 'Required');
          expect(requiredRow, findsOneWidget);
          expect(
            tester.widget<BusyApiSwitchRow>(requiredRow).enabled,
            true,
            reason:
                'checking=${c.checking}; analysis=${c.analysis?['resources']}; buffer=${c.buffer!.generation}; error=${c.error}',
          );
          await tester.runAsync(
            () => tester.tap(
              find.descendant(
                of: requiredRow,
                matching: find.byType(BusyApiSwitch),
              ),
            ),
          );
          await tester.pump();
          await waitFor(
            () => (jsonDecode(c.buffer!.text)['Model'] as Map).containsKey(
              'required',
            ),
          );
          await settleAction();
          expect(jsonDecode(c.buffer!.text)['Model']['required'], ['name']);
          c.store!.undo();
          expect(c.buffer!.text, beforeRequired);
          await tester.runAsync(() async {
            await c.analyse();
            await c.selectObject({
              'root': c.root,
              'resource': modelId,
              'pointer': '/Model/properties/name',
            });
          });
          await waitFor(
            () => find.text('Rename property').evaluate().isNotEmpty,
          );
          final beforeProperty = c.buffer!.text;
          await tester.runAsync(() => tester.tap(find.text('Rename property')));
          await waitFor(() => c.form != null);
          final propertyName = find.descendant(
            of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
            matching: find.byType(TextField),
          );
          await tester.runAsync(
            () => tester.enterText(propertyName, 'wire/😀'),
          );
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await waitFor(
            () => find.text('Review refactoring').evaluate().isNotEmpty,
          );
          expect(c.buffer!.text, beforeProperty);
          expect(
            find.textContaining('This changes an authored wire-property name'),
            findsOneWidget,
          );
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          expect(c.selectedPointer, '/Model/properties/wire~1😀');
          expect(jsonDecode(c.buffer!.text)['Model']['properties']['wire/😀'], {
            'type': 'string',
          });
          expect(jsonDecode(c.buffer!.text)['Model']['default'], {
            'name': 'sample',
          });
          await tester.runAsync(c.undo);
          expect(c.selectedPointer, '/Model/properties/name');
          expect(c.buffer!.text, beforeProperty);
          await tester.runAsync(c.redo);
          expect(c.selectedPointer, '/Model/properties/wire~1😀');
          await tester.runAsync(c.undo);
          expect(c.buffer!.text, beforeProperty);
          await tester.runAsync(() async {
            await c.analyse();
            await c.selectObject({
              ...Map<String, dynamic>.from(c.projection!['info']),
              'pointer': '/servers',
            });
          });
          await tester.pumpAndSettle();
          await waitFor(() => find.text('Not authored').evaluate().isNotEmpty);
          expect(find.text('Not authored'), findsOneWidget);
          expect(c.store!.get(c.root!).text, isNot(contains('"servers"')));
          await tester.runAsync(() => tester.tap(find.text('Add entry')));
          await settleAction();
          expect(
            jsonDecode(c.store!.get(c.root!).text)['servers'],
            <Object?>[],
          );
          await waitFor(
            () =>
                find.text('Not authored').evaluate().isEmpty &&
                find.text('Add entry').evaluate().isNotEmpty,
          );
          await tester.runAsync(() => tester.tap(find.text('Add entry')));
          await waitFor(() => c.form != null);
          final serverUrl = find.descendant(
            of: find.widgetWithText(
              BusyApiGroupedTextEntry,
              'Server URL template',
            ),
            matching: find.byType(TextField),
          );
          await tester.runAsync(
            () => tester.enterText(serverUrl, 'https://{host}/v1'),
          );
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          expect(c.form, isNull);
          expect(c.selectedPointer, '/servers/0');
          expect(jsonDecode(c.store!.get(c.root!).text)['servers'], [
            {'url': 'https://{host}/v1'},
          ]);
          await tester.runAsync(c.undo);
          expect(
            jsonDecode(c.store!.get(c.root!).text)['servers'],
            <Object?>[],
          );
          c.store!.undo();
          expect(
            jsonDecode(c.store!.get(c.root!).text).containsKey('servers'),
            false,
          );
          await tester.runAsync(() async {
            await c.analyse();
            await c.selectObject({
              ...Map<String, dynamic>.from(c.projection!['info']),
              'pointer': '/security',
            });
          });
          await tester.pumpAndSettle();
          await waitFor(() => find.text('Not authored').evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(find.text('Add entry')));
          await settleAction();
          await tester.pumpAndSettle();
          await waitFor(
            () => find
                .text(
                  'Explicit empty security declaration: no security requirement is declared for this API.',
                )
                .evaluate()
                .isNotEmpty,
          );
          expect(
            find.text(
              'Explicit empty security declaration: no security requirement is declared for this API.',
            ),
            findsOneWidget,
          );
          await tester.runAsync(
            () => tester.tap(find.text('Add scheme alternative (OR)')),
          );
          await waitFor(() => c.form != null);
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          expect(jsonDecode(c.store!.get(c.root!).text)['security'], [
            {'Key': []},
          ]);
          await tester.runAsync(() async {
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': '/security/0',
            });
          });
          await tester.pumpAndSettle();
          await waitFor(
            () => find.text('Add combined scheme (AND)').evaluate().isNotEmpty,
          );
          expect(find.text('Add combined scheme (AND)'), findsOneWidget);
          await tester.runAsync(
            () => tester.tap(find.text('Add combined scheme (AND)')),
          );
          await waitFor(() => c.form != null);
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          expect(jsonDecode(c.store!.get(c.root!).text)['security'], [
            {'Key': [], 'Other': []},
          ]);
          await tester.runAsync(() async {
            await c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': '/security',
            });
          });
          await tester.pumpAndSettle();
          await waitFor(
            () => find.text('Add anonymous alternative').evaluate().isNotEmpty,
          );
          await tester.runAsync(
            () => tester.tap(find.text('Add anonymous alternative')),
          );
          await settleAction();
          expect(jsonDecode(c.store!.get(c.root!).text)['security'], [
            {'Key': [], 'Other': []},
            {},
          ]);
          expect(
            jsonDecode(c.store!.get(c.root!).baseline).containsKey('security'),
            false,
          );
          await tester.runAsync(
            () => c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': '/paths/~1items/get/tags',
            }),
          );
          await waitFor(() => find.text('Text values').evaluate().isNotEmpty);
          expect(find.text('original'), findsOneWidget);
          final beforeTags = c.buffer!.text;
          await tester.runAsync(() => tester.tap(find.text('Add entry')));
          await waitFor(() => c.form != null);
          expect(find.text('JSON-compatible data value'), findsNothing);
          final textValue = find.descendant(
            of: find.widgetWithText(BusyApiGroupedTextEntry, 'Text value'),
            matching: find.byType(TextField),
          );
          await tester.runAsync(
            () => tester.enterText(textValue, r'literal $ref 😀'),
          );
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          expect(c.form, isNull);
          expect(c.selectedPointer, '/paths/~1items/get/tags');
          expect(jsonDecode(c.buffer!.text)['paths']['/items']['get']['tags'], [
            'original',
            r'literal $ref 😀',
          ]);
          await tester.runAsync(c.undo);
          expect(c.buffer!.text, beforeTags);
          await tester.runAsync(c.redo);
          await waitFor(
            () => find
                .widgetWithText(BusyApiActionRow, r'literal $ref 😀')
                .evaluate()
                .any(
                  (element) =>
                      (element.widget as BusyApiActionRow).onTap != null,
                ),
          );
          final beforeListEdit = pending;
          await tester.runAsync(
            () => tester.tap(
              find.widgetWithText(BusyApiActionRow, r'literal $ref 😀'),
            ),
          );
          expect(
            identical(pending, beforeListEdit),
            false,
            reason: 'List row must start a native action',
          );
          final listEditAction = pending;
          var listEditReturned = false;
          await tester.runAsync(() async {
            listEditAction?.then((_) => listEditReturned = true);
          });
          await waitFor(() => c.form != null || listEditReturned);
          expect(
            c.form,
            isNotNull,
            reason:
                'List edit returned=$listEditReturned; mode=${c.mode}; pointer=${c.selectedPointer}; error=${c.error}',
          );
          await waitFor(() => c.form != null);
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          final tagsSaved = c.buffer!.bytes();
          await tester.runAsync(() => c.project!.save(c.buffer!));
          expect(File(c.buffer!.path).readAsBytesSync(), tagsSaved);
          const media =
              '/paths/~1suggest/post/requestBody/content/application~1json';
          await tester.runAsync(
            () => c.selectObject({
              'root': c.root,
              'resource': c.root,
              'pointer': media,
            }),
          );
          await waitFor(
            () =>
                find.text('Suggest schema from example').evaluate().isNotEmpty,
          );
          final beforeSuggestion = c.buffer!.text;
          Future<void> openSuggestion() async {
            final suggestion = find.widgetWithText(
              BusyApiActionRow,
              'Suggest schema from example',
            );
            // An object row can be visible while current-source checking
            // temporarily disables its action. Visibility is not readiness.
            await waitFor(
              () => suggestion.evaluate().any(
                (element) => (element.widget as BusyApiActionRow).onTap != null,
              ),
            );
            expect(c.selectedPointer, media);
            final previousAction = pending;
            await tester.runAsync(() => tester.tap(suggestion));
            expect(
              identical(pending, previousAction),
              false,
              reason: 'The enabled current suggestion must start an action',
            );
            await waitFor(() => c.form != null);
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            await waitFor(
              () => find.text('Review schema suggestion').evaluate().isNotEmpty,
            );
            expect(c.buffer!.text, beforeSuggestion);
            expect(
              find.textContaining('Object properties stay optional'),
              findsOneWidget,
            );
          }

          await openSuggestion();
          await tester.runAsync(
            () =>
                tester.tap(find.widgetWithText(BusyApiDialogButton, 'Cancel')),
          );
          await settleAction();
          expect(c.buffer!.text, beforeSuggestion);
          await openSuggestion();
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          final suggested =
              (jsonDecode(
                    c.buffer!.text,
                  )['paths']['/suggest']['post']['requestBody']['content']['application/json']
                  as Map);
          expect(suggested['example'], {'name': '😀 sample', 'id': 1});
          expect(suggested['schema']['properties']['name']['type'], 'string');
          expect(suggested['schema'].containsKey('required'), false);
          expect(
            jsonDecode(
              c.buffer!.text,
            )['paths']['/suggest']['post']['responses']['204'],
            {'description': 'Bodyless'},
          );
          await tester.runAsync(c.undo);
          expect(c.buffer!.text, beforeSuggestion);
          await tester.runAsync(c.redo);
          await tester.runAsync(() async {
            await c.analyse();
            await c.selectObject({
              'resource': c.root,
              'pointer': '/components/schemas/Model',
            });
          });
          await waitFor(
            () => find.text('Rename component').evaluate().isNotEmpty,
          );
          final beforeRename = c.buffer!.text;
          final oldTreeKey = jsonEncode([
            c.root,
            c.root,
            '/components/schemas/Model',
          ]);
          final newTreeKey = jsonEncode([
            c.root,
            c.root,
            '/components/schemas/Renamed',
          ]);
          c.layoutState = {
            ...c.layoutState,
            'schemaTrees': {
              oldTreeKey: {
                'expanded': ['/components/schemas/Model'],
                'counts': {'/components/schemas/Model': 0},
                'scroll': 0.0,
              },
            },
          };
          await tester.runAsync(
            () => tester.tap(find.text('Rename component')),
          );
          await waitFor(() => c.form != null);
          final nameField = find.descendant(
            of: find.widgetWithText(BusyApiGroupedTextEntry, 'Name'),
            matching: find.byType(TextField),
          );
          await tester.runAsync(() => tester.enterText(nameField, 'Renamed'));
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await waitFor(
            () => find.text('Review refactoring').evaluate().isNotEmpty,
          );
          expect(c.buffer!.text, beforeRename);
          await tester.runAsync(
            () => tester.tap(find.text('Inspect surrounding source')),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.textContaining(
              '#/components/schemas/Renamed',
              findRichText: true,
            ),
            100,
            scrollable: find
                .descendant(
                  of: find.byType(BusyApiReviewComparison),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.textContaining(
              '#/components/schemas/Renamed',
              findRichText: true,
            ),
            findsWidgets,
          );
          await tester.runAsync(
            () => tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
          );
          await settleAction();
          expect(c.selectedPointer, '/components/schemas/Renamed');
          expect(
            (c.layoutState['schemaTrees'] as Map).containsKey(oldTreeKey),
            false,
          );
          expect(
            (c.layoutState['schemaTrees'] as Map)[newTreeKey]['expanded'],
            contains('/components/schemas/Renamed'),
          );
          expect(
            jsonDecode(
              c.buffer!.text,
            )['components']['schemas']['Alias'][r'$ref'],
            '#/components/schemas/Renamed',
          );
          await tester.runAsync(c.undo);
          await tester.pumpAndSettle();
          expect(c.selectedPointer, '/components/schemas/Model');
          expect(
            (c.layoutState['schemaTrees'] as Map)[oldTreeKey]['expanded'],
            contains('/components/schemas/Model'),
          );
          expect(c.buffer!.text, beforeRename);
          await tester.runAsync(c.redo);
          await tester.pumpAndSettle();
          expect(c.selectedPointer, '/components/schemas/Renamed');
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
