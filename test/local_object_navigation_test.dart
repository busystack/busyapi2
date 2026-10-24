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
    for (final format in ['yaml', 'json']) {
      for (final scenario in [
        'composed-parameter',
        'reference-parameter',
        'reference-response',
      ]) {
        final parameterCase = scenario != 'reference-response';
        final reference = scenario != 'composed-parameter';
        testWidgets('$scenario opens its complete native editor $version $format', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1200, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-local-object-',
          );
          final root = File('${directory.path}/api.$format'),
              part = File(
                '${directory.path}/${parameterCase ? 'parameters' : 'responses'}.$format',
              );
          final definitionName = parameterCase ? 'Limit' : 'Shared';
          final parameter = reference
              ? '{"\$ref":"parameters.$format#/Limit"}'
              : '{"name":"limit","in":"query","description":"preserved","schema":{"oneOf":[{"type":"string"},{"type":"integer"}]}}';
          final operation = parameterCase
              ? '"parameters":[$parameter],"responses":{"204":{"description":"Bodyless"}}'
              : '"responses":{"204":{"\$ref":"responses.$format#/Shared"}}';
          final source = format == 'json'
              ? '\ufeff{\r\n"openapi":"$version","info":{"title":"Native object","version":"1"},\n"paths":{"/value":{"get":{$operation}}},"x-kept":9007199254740993.00}'
              : '\ufeffopenapi: $version\r\ninfo: {title: "Native object", version: "1"}\npaths: {"/value": {get: {$operation}}}\r\nx-kept: 9007199254740993.00';
          final definition = parameterCase
              ? '{"name":"limit","in":"query","description":"preserved","schema":{"type":"integer"}}'
              : '{"description":"preserved","headers":{"X-Trace":{"schema":{"type":"string"}}}}';
          final partSource = format == 'json'
              ? '\ufeff{"$definitionName":$definition,"x-kept":1.000}'
              : '\ufeff$definitionName: $definition\r\nx-kept: 1.000';
          root.writeAsStringSync(source);
          if (reference) part.writeAsStringSync(partSource);
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
            final clock = Stopwatch()..start();
            while (!condition() &&
                errors.isEmpty &&
                clock.elapsed < const Duration(seconds: 10)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump();
            }
            expect(errors, isEmpty);
            expect(condition(), true);
            await tester.pumpAndSettle();
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(root.path);
              await c.analyse();
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/paths/~1value/get',
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
                      run: (action) => actions.add(
                        action().catchError((Object error) {
                          errors.add(error);
                        }),
                      ),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            final occurrence =
                '/paths/~1value/get/${parameterCase ? 'parameters/0' : 'responses/204'}';
            final row = find.byWidgetPredicate(
              (w) =>
                  w is BusyApiActionRow &&
                  w.title ==
                      (parameterCase
                          ? (reference ? 'parameters.$format#/Limit' : 'limit')
                          : '204'),
            );
            await tester.runAsync(() => tester.ensureVisible(row));
            await tester.pumpAndSettle();
            await tester.runAsync(() => tester.tap(row));
            await ready(
              () =>
                  c.selectedPointer == occurrence &&
                  c.selectedResource == root.uri.toString(),
            );
            if (reference) {
              final definition = find.widgetWithText(
                BusyApiActionRow,
                'Edit Definition',
              );
              await ready(() => definition.evaluate().isNotEmpty);
              await tester.runAsync(() => tester.ensureVisible(definition));
              await tester.pumpAndSettle();
              await tester.runAsync(() => tester.tap(definition));
              await ready(
                () =>
                    c.selectedResource == part.uri.toString() &&
                    c.selectedPointer == '/$definitionName',
              );
            }
            final field = find.descendant(
              of: find.widgetWithText(BusyApiGroupedTextEntry, 'Description'),
              matching: find.byType(TextField),
            );
            await ready(
              () =>
                  field.evaluate().length == 1 &&
                  !tester.widget<TextField>(field).readOnly &&
                  tester.widget<TextField>(field).controller!.text ==
                      'preserved' &&
                  c.draft?.buffer == (reference ? part : root).uri.toString() &&
                  c.draft?.pointer ==
                      (reference ? '/$definitionName' : occurrence),
            );
            await tester.runAsync(
              () => tester.enterText(field, 'Edited parameter'),
            );
            expect(c.hasPendingFields, true);
            await tester.runAsync(() async {
              expect(await c.flush(), true);
              await c.analyse();
            });
            await tester.pump();
            final target = c.project!.store.get(
              (reference ? part : root).uri.toString(),
            );
            final original = reference ? partSource : source;
            final expected = original.replaceFirst(
              'preserved',
              'Edited parameter',
            );
            expect(target.bytes(), utf8.encode(expected));
            if (reference) {
              expect(
                c.project!.store.get(root.uri.toString()).bytes(),
                utf8.encode(source),
              );
            }
            await tester.runAsync(() async {
              await c.undo();
              expect(target.bytes(), utf8.encode(original));
              await c.redo();
              expect(target.bytes(), utf8.encode(expected));
              await c.saveAll();
              expect(
                (reference ? part : root).readAsBytesSync(),
                utf8.encode(expected),
              );
              if (reference) {
                expect(root.readAsBytesSync(), utf8.encode(source));
              }
            });
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            directory.deleteSync(recursive: true);
          }
        });
      }
    }
  }
}
