import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final invalidField in [
        'parameters',
        'responses',
        'inheritedParameters',
        'media',
      ]) {
        testWidgets(
          'invalid $invalidField preserves scoped metadata authoring $version json=$json',
          (tester) async {
            tester.view.physicalSize = const Size(1200, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final temp = Directory.systemTemp.createTempSync(
                  'busyapi-scoped-metadata-',
                ),
                file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final text =
                (json ? '' : '# retained 雪😀\r\n') +
                jsonEncode({
                  'openapi': version,
                  'info': {'title': 'Scoped edits', 'version': '1'},
                  'paths': {
                    '/value': {
                      if (invalidField == 'inheritedParameters')
                        'parameters': null,
                      'get': {
                        'summary': 'Safe original',
                        'responses': {
                          '204': {'description': 'Bodyless'},
                          'x-literal-response': {
                            'content': {
                              'application/json': {
                                'schema': false,
                                'example': {r'$ref': 'literal payload'},
                              },
                            },
                          },
                          if (invalidField == 'media')
                            '200': {
                              'description': 'Current response',
                              'content': {'application/json': false},
                            },
                        },
                        if (const [
                          'parameters',
                          'responses',
                        ].contains(invalidField))
                          invalidField: 'temporarily invalid',
                      },
                    },
                  },
                  'x-kept': {'n': 111, r'$ref': 'literal data'},
                }).replaceFirst('"n":111', '"n":9007199254740993.00');
            file.writeAsStringSync(text);
            final c = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${temp.path}/config',
                state: '${temp.path}/state',
                cache: '${temp.path}/cache',
              ),
            );
            final errors = <Object>[];
            Future<void> ready(bool Function() condition) async {
              await tester.pump();
              final watch = Stopwatch()..start();
              while (!condition() &&
                  errors.isEmpty &&
                  watch.elapsed < const Duration(seconds: 10)) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              expect(errors, isEmpty);
              expect(condition(), true, reason: 'Current error=${c.error}');
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }

            try {
              await tester.runAsync(() async {
                await c.initialize();
                await c.open(file.path);
                await c.selectObject({
                  'root': c.root,
                  'resource': c.root,
                  'pointer': '/paths/~1value/get',
                });
                await c.analyse();
              });
              expect(c.analysis!['status'], isNot('complete'));
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
                        run: (action) => action().catchError((Object error) {
                          errors.add(error);
                        }),
                        reveal: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              final summary = find.descendant(
                of: find.widgetWithText(BusyApiGroupedTextEntry, 'Summary'),
                matching: find.byType(TextField),
              );
              expect(
                summary,
                findsOneWidget,
                reason: 'An unrelated invalid child must not replace every safe native metadata control',
              );
              expect(tester.widget<TextField>(summary).enabled, isNot(false));
              if (invalidField == 'inheritedParameters') {
                expect(
                  find.text('Path Item parameter declarations'),
                  findsOneWidget,
                  reason: 'An authored null parent collection must be identified, not displayed as absent or empty',
                );
              }
              expect(
                find.text('x-literal-response'),
                findsNothing,
                reason: 'Extension payloads must not become Response rows or media/schema previews',
              );
              await tester.runAsync(
                () => tester.enterText(summary, 'Native safe summary'),
              );
              expect(c.draft!.pending, true);
              await tester.runAsync(() async {
                expect(await c.flush(), true);
                await c.analyse();
              });
              await ready(() => !c.checking);
              final changed = text.replaceFirst(
                'Safe original',
                'Native safe summary',
              );
              expect(c.buffer!.text, changed);
              expect(
                c.analysis!['status'],
                isNot('complete'),
                reason: 'Editing a safe field does not silently repair or clear invalid source',
              );
              await tester.runAsync(() async {
                await c.undo();
                await c.analyse();
              });
              expect(c.buffer!.text, text);
              await tester.runAsync(() async {
                await c.redo();
                await c.analyse();
                await c.saveBuffers();
              });
              expect(c.buffer!.text, changed);
              expect(file.readAsStringSync(), changed);
              expect(tester.takeException(), isNull);
              expect(errors, isEmpty);
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
}
