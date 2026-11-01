import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final branch in [false, true]) {
        testWidgets(
          '$version $format ${branch ? 'branch' : 'root'} native schema example choice updates only the request draft',
          (tester) async {
            tester.view.physicalSize = const Size(1500, 1100);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final directory = Directory.systemTemp.createTempSync(
              'busyapi-native-schema-example-',
            );
            final file = File('${directory.path}/api.$format');
            final workspace = WorkspaceController(
              EngineProcess(executable: runtimeNode, helper: runtimeHelper),
              StateLocations(
                config: '${directory.path}/config',
                state: '${directory.path}/state',
                cache: '${directory.path}/cache',
              ),
            );
            final run = RequestRunController(workspace);
            late String source;
            try {
              await tester.runAsync(() async {
                final legacy = version == '2.0',
                    modern =
                        version.startsWith('3.1') || version.startsWith('3.2');
                final value = {
                  'n': 'EXACT',
                  'flag': false,
                  'empty': '',
                  r'$ref': 'literal.json',
                };
                final schema = {
                  'type': 'object',
                  if (modern) 'examples': [value] else 'example': value,
                };
                final requestSchema = branch
                    ? {
                        legacy ? 'allOf' : 'oneOf': [schema],
                      }
                    : schema;
                source =
                    '${format == 'yaml' ? '# Keep schema examples\r\n' : ''}${jsonEncode({
                      legacy ? 'swagger' : 'openapi': version,
                      'info': {'title': 'Schema choices', 'version': 'business'},
                      if (legacy) 'consumes': ['application/json'],
                      'paths': {
                        '/data': {
                          'post': {
                            if (legacy) 'parameters': [
                                {'in': 'body', 'name': 'payload', 'schema': requestSchema},
                              ] else 'requestBody': {
                                'content': {
                                  'application/json': {'schema': requestSchema},
                                },
                              },
                            'responses': {
                              '204': {'description': 'None'},
                            },
                          },
                        },
                      },
                    }).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
                file.writeAsStringSync(source);
                await workspace.initialize();
                await workspace.open(file.path);
                await workspace.analyse();
                expect(
                  workspace.projection,
                  isNotNull,
                  reason: workspace.error,
                );
                await run.open(
                  Map<String, dynamic>.from(
                    (workspace.projection!['operations'] as List).single as Map,
                  ),
                );
                run.bodyText = 'retained draft';
                run.refresh();
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
                  home: Scaffold(body: RequestRunPanel(run: run)),
                ),
              );
              final action = find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiActionRow &&
                    widget.title.startsWith('Examples · application/json ·'),
              );
              expect(action, findsOneWidget);
              if (branch) {
                final row = tester.widget<BusyApiActionRow>(action);
                expect(
                  row.title,
                  contains('${version == '2.0' ? 'allOf' : 'oneOf'}[0]'),
                );
              }
              await tester.ensureVisible(action);
              await tester.tap(action);
              await tester.pumpAndSettle();
              expect(run.failure, isNull, reason: run.failureMessage);
              expect(
                run.bodyText,
                r'{"n":9007199254740993.00,"flag":false,"empty":"","$ref":"literal.json"}',
              );
              expect(run.bodyKind, RequestBodyKind.raw);
              expect(run.bodyMediaType, 'application/json');
              expect(run.bodyEnabled, true);
              expect(file.readAsStringSync(), source);
              expect(workspace.buffer!.text, source);
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpWidget(
                MaterialApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Scaffold(body: RequestRunPanel(run: run)),
                ),
              );
              expect(run.bodyText, contains('9007199254740993.00'));
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.runAsync(() async {
                run.dispose();
                await workspace.shutdown();
                workspace.dispose();
                directory.deleteSync(recursive: true);
              });
            }
          },
        );
      }
    }
  }
}
