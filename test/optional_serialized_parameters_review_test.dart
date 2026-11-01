import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format omitted example diagnostics follow native Design and Source history',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final name in ['yaru_window', 'yaru_window/events']) {
            final channel = MethodChannel(name);
            messenger.setMockMethodCallHandler(channel, (_) async => null);
            addTearDown(
              () => messenger.setMockMethodCallHandler(channel, null),
            );
          }
          final temp = Directory.systemTemp.createTempSync(
                'busyapi-omission-review-',
              ),
              file = File('${temp.path}/api.$format');
          final source =
              '${format == 'yaml' ? '# Keep native source\r\n' : ''}${jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Original', 'version': 'business-version'},
                    'paths': {
                      '/items': {
                        'get': {
                          'parameters': [
                            {
                              'name': 'ids',
                              'in': 'query',
                              'required': false,
                              'schema': {
                                'type': 'array',
                                'items': {'type': 'integer'},
                                'maxItems': 0,
                              },
                              'examples': {
                                'Empty': {'dataValue': [], 'serializedValue': ''},
                              },
                            },
                          ],
                          'responses': {
                            '204': {'description': 'No content'},
                          },
                        },
                      },
                    },
                    'x-literal': {'value': 'EXACT', 'serializedValue': '', 'flag': false},
                  })}\r\n'
                  .replaceAll('"EXACT"', '9007199254740993.00');
          file.writeAsStringSync(source);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          Future<void>? pending;
          void run(Future<void> Function() action) => pending = action();
          List<SourceDiagnostic> diagnostics() {
            final buffer = c.buffer;
            if (buffer == null) return [];
            return [
              for (final value in c.analysis?['findings'] as List? ?? [])
                if (value['resource'] == buffer.id && value['range'] is List)
                  SourceDiagnostic(
                    resource: buffer.id,
                    generation: buffer.generation,
                    start: value['range'][0] as int,
                    end: value['range'][1] as int,
                    code: value['code'] as String,
                    severity: value['severity'] as String,
                    message: value['message'] as String,
                  ),
            ];
          }

          void expectExample(bool valid) {
            expect(c.analysis?['complete'], true, reason: '${c.analysis}');
            final examples =
                c.analysis?['categories']['openapi']['schema']['serializedExamples']
                    as List;
            expect(examples, hasLength(1));
            expect(examples.single['complete'], true);
            expect(examples.single['valid'], valid);
            expect(
              examples.single['omission'],
              valid ? 'empty-collection' : null,
            );
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/info',
              });
              await c.analyse();
              await c.saveAll();
            });
            expectExample(true);
            expect(file.readAsStringSync(), source);
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
                    builder: (_, _) => c.mode == 'Source'
                        ? SourceEditor(
                            buffer: c.buffer!,
                            onChanged: (text) =>
                                c.sourceEdit(c.buffer!.id, text),
                            diagnostics: diagnostics(),
                            undo: () => run(c.undo),
                            redo: () => run(c.redo),
                          )
                        : Designer(controller: c, run: run, reveal: (_) {}),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final title = find.byWidgetPredicate(
              (widget) => widget is DraftField && widget.label == 'Title',
            );
            final field = tester.widget<DraftField>(title);
            expect(field.readOnly, false);
            await tester.runAsync(() async {
              field.onChanged('Native changed 雪', false);
              field.onCommit();
              expect(pending, isNotNull);
              await pending;
              await c.analyse();
            });
            await tester.pumpAndSettle();
            expectExample(true);
            final designed = source.replaceFirst(
              'Original',
              'Native changed 雪',
            );
            expect(c.buffer!.text, designed);
            expect(file.readAsStringSync(), source);
            c.setMode('Source');
            await tester.pumpAndSettle();
            final editor = tester.widget<SourceEditor>(
              find.byType(SourceEditor),
            );
            expect(editor.diagnostics, isEmpty);
            editor.onChanged(
              designed.replaceFirst('"required":false', '"required":true'),
            );
            await tester.runAsync(c.analyse);
            await tester.pumpAndSettle();
            expectExample(false);
            final diagnostic = tester
                .widget<SourceEditor>(find.byType(SourceEditor))
                .diagnostics
                .singleWhere(
                  (value) => value.code == 'example.serialization.incompatible',
                );
            expect(
              c.buffer!.text.substring(diagnostic.start, diagnostic.end),
              '""',
            );
            await tester.runAsync(() async {
              await c.undo();
              await c.analyse();
            });
            await tester.pumpAndSettle();
            expectExample(true);
            expect(c.buffer!.text, designed);
            await tester.runAsync(() async {
              await c.redo();
              await c.analyse();
            });
            await tester.pumpAndSettle();
            expectExample(false);
            await tester.runAsync(() async {
              await c.undo();
              await c.analyse();
              await c.saveAll();
            });
            await tester.pumpAndSettle();
            expectExample(true);
            expect(file.readAsStringSync(), designed);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(c.shutdown);
            c.dispose();
            await tester.runAsync(() => temp.delete(recursive: true));
          }
        },
      );
    }
  }
}
