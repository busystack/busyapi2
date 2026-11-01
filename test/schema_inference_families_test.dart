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
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native inference reviews a valid null-only schema',
        (tester) async {
          for (final name in ['yaru_window', 'yaru_window/events']) {
            final channel = MethodChannel(name);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (_) async => <String, Object?>{},
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, null),
            );
          }
          tester.view.physicalSize = const Size(1300, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-inference-widget-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          final controller = WorkspaceController(
            engine,
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final legacy = version == '2.0';
          const responsePointer = '/paths/~1items/get/responses/200';
          final pointer = legacy
              ? responsePointer
              : '$responsePointer/content/application~1json';
          final source =
              '${format == 'yaml' ? '# Keep 雪\r\n' : ''}${jsonEncode({
                if (legacy) 'swagger': version else 'openapi': version,
                'info': {'title': 'Keep', 'version': '1'},
                if (legacy) 'produces': ['application/json'],
                'paths': {
                  '/items': {
                    'get': {
                      'responses': {
                        '200': {
                          'description': 'Read',
                          if (legacy) 'examples': {'application/json': null} else 'content': {
                              'application/json': {'example': null},
                            },
                        },
                      },
                    },
                  },
                },
                'x-exact': 'EXACT',
              }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          final file = File('${directory.path}/api.$format')
            ..writeAsStringSync(source);
          final failures = <Object>[];
          Future<void>? pending;
          Future<void> ready(bool Function() condition) async {
            final watch = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                failures.isEmpty &&
                watch.elapsed < const Duration(seconds: 15)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(
              condition(),
              isTrue,
              reason:
                  'pointer=${controller.selectedPointer}; error=${controller.error}; form=${controller.form?.kind}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> applyDialog() async {
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
          }

          try {
            await tester.runAsync(() async {
              await controller.initialize();
              await controller.open(file.path);
              await controller.selectObject({
                'root': controller.root,
                'resource': controller.root,
                'pointer': pointer,
              });
              await controller.analyse();
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
            final action = find.byWidgetPredicate(
              (w) =>
                  w is BusyApiActionRow &&
                  w.title == 'Suggest schema from example' &&
                  w.onTap != null,
            );
            await ready(() => action.evaluate().length == 1);
            await tester.runAsync(() async {
              await tester.ensureVisible(action);
              await tester.tap(action);
            });
            await ready(() => controller.form != null);
            expect(find.text('Root nullability assumption'), findsOneWidget);
            if (legacy) expect(find.text('application/json'), findsWidgets);
            await applyDialog();
            await ready(
              () => find.text('Review schema suggestion').evaluate().isNotEmpty,
            );
            expect(controller.buffer!.text, source);
            expect(file.readAsStringSync(), source);
            await applyDialog();
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await ready(() => done);
            final accepted = controller.buffer!.text;
            expect(accepted, contains('9007199254740993.00'));
            final body = jsonDecode(accepted.substring(accepted.indexOf('{')));
            final response = body['paths']['/items']['get']['responses']['200'];
            final schema = legacy
                ? response['schema']
                : response['content']['application/json']['schema'];
            expect(
              schema,
              legacy
                  ? {'type': 'null'}
                  : version == '3.0.4'
                  ? {
                      'type': 'string',
                      'nullable': true,
                      'enum': [null],
                    }
                  : {'type': 'null'},
            );
            expect(file.readAsStringSync(), source);
            await tester.runAsync(() async {
              await controller.undo();
              await controller.analyse();
            });
            expect(controller.buffer!.text, source);
            await tester.runAsync(() async {
              await controller.redo();
              await controller.analyse();
              await controller.saveAll();
            });
            expect(file.readAsStringSync(), accepted);
            await ready(
              () => controller.analysis != null && !controller.checking,
            );
            expect(controller.analysis!['complete'], isTrue);
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
