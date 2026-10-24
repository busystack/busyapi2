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
  for (final subject in ['property', 'response', 'parameter']) {
    final response = subject == 'response', parameter = subject == 'parameter';
    for (final removing in [false, true]) {
      if (parameter && !removing) continue;
      testWidgets(
        'R04 compact $subject ${removing ? 'removal' : 'rename'} reviews consumers and all submitted edits',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
            'busyapi-compact-review-',
          );
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final errors = <Object>[];
          Future<void>? pending;
          Future<void> waitFor(bool Function() condition) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                errors.isEmpty &&
                clock.elapsed < const Duration(seconds: 10)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(
              condition(),
              true,
              reason: 'form=${c.form?.kind} error=${c.error}',
            );
            await tester.pumpAndSettle();
          }

          const propertyPointer =
              '/paths/~1pets/get/responses/200/content/application~1json/schema/properties/old';
          final value = {
            'openapi': '3.2.1',
            'info': {'title': 'Compact', 'version': '1'},
            'paths': {
              '/pets': {
                'get': {
                  'parameters': [
                    {
                      'name': 'first',
                      'in': 'query',
                      'schema': {'type': 'string'},
                    },
                    {
                      'name': 'second',
                      'in': 'query',
                      'schema': {'type': 'string'},
                    },
                  ],
                  'responses': {
                    '200': {
                      'description': 'original',
                      'content': {
                        'application/json': {
                          'schema': {
                            'type': 'object',
                            'properties': {
                              'old': {
                                'type': 'string',
                                'description': 'original',
                              },
                            },
                            'required': ['old'],
                            'dependentRequired': {
                              'other': ['old'],
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
            'components': {
              'parameters': {
                'Consumer': {'\$ref': '#/paths/~1pets/get/parameters/1'},
              },
              'schemas': {
                'Consumer': {'\$ref': '#$propertyPointer'},
              },
              'responses': {
                'Consumer': {'\$ref': '#/paths/~1pets/get/responses/200'},
              },
            },
          };
          final original = jsonEncode(value);
          final file = File('${temp.path}/openapi.json')
            ..writeAsStringSync(original);
          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(file.path);
              await c.analyse();
              await c.selectObject(
                Map<String, dynamic>.from(
                  (c.projection!['operations'] as List).single,
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
                    builder: (_, _) => SingleChildScrollView(
                      child: Designer(
                        controller: c,
                        run: (action) {
                          pending = action().catchError(errors.add);
                        },
                        reveal: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (parameter) {
              final operation = Map<String, dynamic>.from(
                (c.projection!['operations'] as List).single,
              );
              final captured = c.beginForm(
                'parameter',
                operation,
                {'index': 0},
                {
                  'name': 'first',
                  'in': 'query',
                  'description': '',
                  'required': false,
                  'type': 'string',
                },
              );
              captured.edit('description', 'recovered input');
              c.form = FormSession.restore(captured.recovery());
              await tester.runAsync(() async {
                pending = resumeCapturedForm(
                  tester.element(find.byType(Designer)),
                  c,
                ).catchError(errors.add);
              });
            } else {
              final row = find.widgetWithText(
                BusyApiActionRow,
                response ? '200' : 'old',
              );
              await waitFor(() => row.evaluate().isNotEmpty);
              await tester.runAsync(() => tester.ensureVisible(row));
              await tester.runAsync(() => tester.tap(row));
            }
            await waitFor(() => c.form != null);
            if (removing) {
              await tester.runAsync(
                () => tester.tap(
                  find.widgetWithText(BusyApiDialogButton, 'Remove'),
                ),
              );
              await waitFor(() => c.form == null);
              await waitFor(
                () =>
                    find.text('Review object deletion').evaluate().isNotEmpty ||
                    c.buffer!.text != original,
              );
              expect(c.buffer!.text, original);
              expect(find.text('Review object deletion'), findsOneWidget);
              if (parameter) {
                await tester.runAsync(
                  () => tester.tap(
                    find.widgetWithText(BusyApiDialogButton, 'Apply'),
                  ),
                );
                var done = false;
                await tester.runAsync(() async {
                  pending!.then((_) => done = true);
                });
                await waitFor(() => done);
                final accepted = c.buffer!.text,
                    parsed = jsonDecode(c.buffer!.text);
                expect(parsed['paths']['/pets']['get']['parameters'], [
                  {
                    'name': 'second',
                    'in': 'query',
                    'schema': {'type': 'string'},
                  },
                ]);
                expect(
                  parsed['components']['parameters']['Consumer']['\$ref'],
                  '#/paths/~1pets/get/parameters/0',
                );
                await tester.runAsync(c.undo);
                expect(c.buffer!.text, original);
                await tester.runAsync(c.redo);
                expect(c.buffer!.text, accepted);
                return;
              }
              expect(
                tester
                    .widget<BusyApiDialogButton>(
                      find.widgetWithText(BusyApiDialogButton, 'Apply'),
                    )
                    .onPressed,
                isNull,
              );
              await tester.runAsync(
                () => tester.tap(
                  find.widgetWithText(BusyApiDialogButton, 'Cancel'),
                ),
              );
              await tester.runAsync(() => pending!);
              expect(c.store!.canUndo, false);
              return;
            }

            await tester.runAsync(
              () => tester.enterText(
                find.widgetWithText(
                  TextFormField,
                  response ? 'Status' : 'Name',
                ),
                response ? '201' : 'new',
              ),
            );
            await tester.runAsync(
              () => tester.enterText(
                find.descendant(
                  of: find.byType(BusyApiDialogShell),
                  matching: find.widgetWithText(TextFormField, 'Description'),
                ),
                'edited together',
              ),
            );
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            // The compact action must enter the same reviewed semantic transaction as
            // the complete object page. Source stays unchanged until its second Apply.
            await waitFor(() => c.form == null);
            await waitFor(
              () =>
                  find.text('Review refactoring').evaluate().isNotEmpty ||
                  c.buffer!.text != original,
            );
            expect(
              c.buffer!.text,
              original,
              reason: 'Planning must not partially apply compact fields',
            );
            expect(find.text('Review refactoring'), findsOneWidget);
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            var finished = false;
            await tester.runAsync(() async {
              pending!.then((_) => finished = true);
            });
            await waitFor(() => finished);
            final accepted = c.buffer!.text,
                after = jsonDecode(accepted) as Map;
            if (response) {
              expect(
                after['paths']['/pets']['get']['responses']['201']['description'],
                'edited together',
              );
              expect(
                after['components']['responses']['Consumer']['\$ref'],
                '#/paths/~1pets/get/responses/201',
              );
              expect(
                after['components']['schemas']['Consumer']['\$ref'],
                contains('/responses/201/'),
              );
            } else {
              final schema =
                  after['paths']['/pets']['get']['responses']['200']['content']['application/json']['schema'];
              expect(
                schema['properties']['new']['description'],
                'edited together',
              );
              expect(schema['required'], ['new']);
              expect(schema['dependentRequired']['other'], ['new']);
              expect(
                after['components']['schemas']['Consumer']['\$ref'],
                contains('/properties/new'),
              );
            }
            await tester.runAsync(c.undo);
            expect(c.buffer!.text, original);
            await tester.runAsync(c.redo);
            expect(c.buffer!.text, accepted);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
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
