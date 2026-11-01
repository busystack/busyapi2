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

import '../packages/busyapi_core/test/discriminator_reference_support.dart';
import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native discriminator repair retains inherited requirements and Source version ownership',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-discriminator-native-',
          );
          final rootFile = File('${temp.path}/api.$format'),
              model = File('${temp.path}/model.yaml');
          final text = discriminatorApi(
            version,
            format,
            'dynamic-anchor',
            property: 'other',
            schemaExamples: true,
          );
          final original = [0xef, 0xbb, 0xbf, ...utf8.encode(text)],
              modelBytes = [
                0xef,
                0xbb,
                0xbf,
                ...utf8.encode(discriminatorModel()),
              ];
          rootFile.writeAsBytesSync(original);
          model.writeAsBytesSync(modelBytes);
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
          final row = find.widgetWithText(
            BusyApiGroupedTextEntry,
            'propertyName',
          );
          final input = find.descendant(
            of: row,
            matching: find.byType(TextField),
          );
          List<Object?> findings(String code) =>
              (c.analysis?['findings'] as List? ?? [])
                  .where((finding) => finding['code'] == code)
                  .toList();
          Future<void> ready(bool Function() condition) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                failures.isEmpty &&
                clock.elapsed < const Duration(seconds: 12)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(failures, isEmpty);
            expect(condition(), isTrue, reason: '${c.error} ${c.storageError}');
            await tester.pumpAndSettle();
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(rootFile.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/schemas/Subject/discriminator',
              });
              await c.analyse();
            });
            expect(
              findings('discriminator.default-mapping.required'),
              version.startsWith('3.2.') ? hasLength(1) : isEmpty,
              reason: '${c.analysis}',
            );
            expect(findings('discriminator.required.incomplete'), isEmpty);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: format == 'yaml'
                      ? Brightness.light
                      : Brightness.dark,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: ListenableBuilder(
                    listenable: c,
                    builder: (_, _) => Designer(
                      controller: c,
                      run: (action) => pending = action().catchError(
                        (Object error) => failures.add(error),
                      ),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await ready(() => input.evaluate().isNotEmpty);
            final controller = tester.widget<TextField>(input).controller!;
            expect(controller.text, 'other');
            await tester.enterText(input, 'kind');
            expect(c.hasPendingFields, isTrue);
            await tester.runAsync(
              () => tester.testTextInput.receiveAction(TextInputAction.done),
            );
            await ready(() => pending != null);
            var applied = false;
            await tester.runAsync(() async {
              pending!.then((_) => applied = true);
            });
            await ready(() => applied);
            await tester.runAsync(c.analyse);
            await ready(
              () =>
                  input.evaluate().isNotEmpty &&
                  tester.widget<TextField>(input).controller!.text == 'kind',
            );
            expect(
              tester.widget<TextField>(input).controller,
              same(controller),
            );
            expect(c.analysis!['status'], 'complete', reason: '${c.analysis}');
            expect(c.analysis!['complete'], isTrue);
            expect(findings('discriminator.required.incomplete'), isEmpty);
            final changed = text.replaceFirst(
              '"propertyName":"other"',
              '"propertyName":"kind"',
            );
            expect(c.buffer!.text, changed);
            expect(rootFile.readAsBytesSync(), original);
            await tester.runAsync(c.undo);
            await tester.runAsync(c.analyse);
            expect(c.buffer!.bytes(), original);
            expect(
              findings('discriminator.default-mapping.required'),
              version.startsWith('3.2.') ? hasLength(1) : isEmpty,
              reason: '${c.analysis}',
            );
            await tester.runAsync(c.redo);
            await tester.runAsync(c.analyse);
            expect(c.buffer!.text, changed);
            expect(c.analysis!['status'], 'complete');
            final identity = c.analysis!['snapshot'];
            final switchedVersion = version.startsWith('3.2.')
                ? '3.1.2'
                : '3.2.1';
            final switched = text.replaceFirst(version, switchedVersion);
            await tester.runAsync(() async {
              c.sourceEdit(rootFile.uri.toString(), switched);
              await c.analyse();
            });
            expect(c.analysis!['snapshot'], isNot(identity));
            expect(c.buffer!.text, switched);
            expect(
              findings('discriminator.default-mapping.required'),
              switchedVersion.startsWith('3.2.') ? hasLength(1) : isEmpty,
              reason: '${c.analysis}',
            );
            expect(rootFile.readAsBytesSync(), original);
            await tester.runAsync(c.undo);
            await tester.runAsync(c.analyse);
            expect(c.buffer!.text, changed);
            expect(c.analysis!['status'], 'complete');
            await tester.runAsync(c.saveAll);
            expect(rootFile.readAsBytesSync(), [
              0xef,
              0xbb,
              0xbf,
              ...utf8.encode(changed),
            ]);
            expect(model.readAsBytesSync(), modelBytes);
            await tester.runAsync(() => c.open(rootFile.path));
            await tester.runAsync(c.analyse);
            expect(c.buffer!.bytes(), rootFile.readAsBytesSync());
            expect(c.analysis!['status'], 'complete');
            expect(tester.takeException(), isNull);
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
