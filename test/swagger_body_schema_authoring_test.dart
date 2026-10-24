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
  for (final format in ['yaml', 'json']) {
    testWidgets(
      '2.0 $format an absent body schema opens the native schema editor',
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
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-body-schema-authoring-',
        );
        final file = File('${temp.path}/api.$format');
        final json = jsonEncode({
          'swagger': '2.0',
          'info': {'title': 'Body schema', 'version': '1'},
          'paths': {
            '/native': {
              'post': {
                'parameters': [
                  {'name': 'payload', 'in': 'body', 'required': true},
                ],
                'responses': {
                  '204': {'description': 'No content'},
                },
              },
            },
          },
          'definitions': {
            'Payload': {'type': 'string'},
          },
          'x-exact': '@exact',
        }).replaceFirst('"@exact"', '900719925474099312345678901.00');
        final original = format == 'yaml' ? '# Preserve 雪\r\n$json\r\n' : json;
        file.writeAsStringSync(original);
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
          final watch = Stopwatch()..start();
          await tester.pump();
          while (!condition() &&
              failures.isEmpty &&
              watch.elapsed < const Duration(seconds: 10)) {
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
                'pointer=${controller.selectedPointer}; occurrence=${controller.selectedOccurrence}; checking=${controller.checking}; generation=${controller.buffer?.generation}/${controller.projection?['info']?['generation']}; operations=${controller.projection?['operations']}',
          );
          await tester.pumpAndSettle();
        }

        try {
          await tester.runAsync(() async {
            await controller.initialize();
            await controller.open(file.path);
            await controller.selectObject({
              'root': controller.root,
              'resource': controller.root,
              'pointer': '/paths/~1native/post/parameters/0',
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
                    run: (action) => pending = action().catchError((Object e) {
                      failures.add(e);
                    }),
                    reveal: (_) {},
                  ),
                ),
              ),
            ),
          );
          final open = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiActionRow &&
                widget.title == 'schema' &&
                widget.onTap != null,
          );
          await ready(() => open.evaluate().length == 1);
          expect(controller.buffer!.text, original);
          await tester.runAsync(() async {
            await tester.ensureVisible(open);
            await tester.tap(open);
          });
          final reference = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiGroupedTextEntry &&
                widget.label == r'$ref' &&
                !widget.readOnly,
          );
          await ready(
            () =>
                controller.selectedPointer ==
                    '/paths/~1native/post/parameters/0/schema' &&
                controller.form == null &&
                !controller.checking &&
                reference.evaluate().length == 1,
          );
          await tester.runAsync(() => pending!);
          final created = controller.buffer!.text;
          expect(created, isNot(original));
          expect(file.readAsStringSync(), original);
          await tester.runAsync(() async {
            await tester.enterText(
              find.descendant(
                of: reference,
                matching: find.byType(EditableText),
              ),
              '#/definitions/Payload',
            );
            expect(await controller.flush(), true);
            await controller.analyse();
          });
          final changed = controller.buffer!.text;
          expect(changed, isNot(created));
          expect(changed, contains('#/definitions/Payload'));
          expect(changed, contains('900719925474099312345678901.00'));
          expect(controller.analysis!['status'], 'complete');
          await tester.runAsync(() async {
            await controller.undo();
            await controller.analyse();
          });
          expect(controller.buffer!.text, created);
          await tester.runAsync(() async {
            await controller.undo();
            await controller.analyse();
          });
          expect(controller.buffer!.text, original);
          await tester.runAsync(() async {
            await controller.redo();
            await controller.analyse();
          });
          expect(controller.buffer!.text, created);
          await tester.runAsync(() async {
            await controller.redo();
            await controller.analyse();
          });
          expect(controller.buffer!.text, changed);
          expect(file.readAsStringSync(), original);
          await tester.runAsync(controller.saveAll);
          expect(file.readAsStringSync(), changed);
          await tester.runAsync(() => controller.open(file.path));
          expect(controller.buffer!.text, changed);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(controller.shutdown);
          controller.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
