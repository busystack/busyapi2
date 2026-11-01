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

class _NativeHttp extends HttpOverrides {}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native text draft and body example use declared Latin-1 bytes',
        (tester) async {
          tester.view.physicalSize = const Size(1500, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const text = 'caféÿ\u0080';
          const mediaType = 'text/plain; charset=ISO-8859-1';
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-native-charset-',
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
          HttpServer? server;
          final seen = <List<int>>[];
          late String source;
          try {
            await tester.runAsync(() async {
              server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
              server!.listen((request) async {
                expect(request.method, 'POST');
                expect(request.uri.path, '/text');
                expect(request.headers.contentType!.charset, 'iso-8859-1');
                seen.add(
                  await request.fold<List<int>>(
                    [],
                    (all, next) => all..addAll(next),
                  ),
                );
                request.response.statusCode = 204;
                await request.response.close();
              });
              final legacy = version == '2.0';
              final schema = {
                'type': 'string',
                'enum': [text, ''],
                'example': text,
              };
              final document = {
                legacy ? 'swagger' : 'openapi': version,
                'info': {'title': 'Native charset', 'version': 'business'},
                if (legacy) ...{
                  'host': '127.0.0.1:${server!.port}',
                  'schemes': ['http'],
                  'consumes': [mediaType],
                } else
                  'servers': [
                    {'url': 'http://127.0.0.1:${server!.port}'},
                  ],
                'paths': {
                  '/text': {
                    'post': {
                      if (legacy)
                        'parameters': [
                          {
                            'name': 'payload',
                            'in': 'body',
                            'required': true,
                            'schema': schema,
                          },
                        ]
                      else
                        'requestBody': {
                          'required': true,
                          'content': {
                            mediaType: {'schema': schema, 'example': text},
                          },
                        },
                      'responses': {
                        '204': {'description': 'Empty'},
                      },
                    },
                  },
                },
              };
              source =
                  '${format == 'yaml' ? '# Keep native source\r\n' : ''}${jsonEncode(document)}\r\n';
              file.writeAsStringSync(source);
              await workspace.initialize();
              await workspace.open(file.path);
              await workspace.analyse();
              expect(workspace.projection, isNotNull, reason: workspace.error);
              await run.open(
                Map<String, dynamic>.from(
                  (workspace.projection!['operations'] as List).single as Map,
                ),
              );
              run.bodyEnabled = true;
              run.bodyText = 'retained draft';
              run.refresh();
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(body: RequestRunPanel(run: run)),
              ),
            );
            if (version != '2.0') {
              final example = find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiActionRow &&
                    widget.title.startsWith('Examples · $mediaType ·'),
              );
              await tester.ensureVisible(example);
              await tester.tap(example);
              await tester.pumpAndSettle();
              expect(run.failure, isNull, reason: run.failureMessage);
              expect(run.bodyText, text);
            }
            final entry = find.byWidgetPredicate(
              (widget) =>
                  widget is RequestDraftEntry &&
                  widget.label == 'Authored text or exact JSON bytes',
            );
            final input = find.descendant(
              of: entry,
              matching: find.byType(TextFormField),
            );
            await tester.ensureVisible(input);
            await tester.enterText(input, text);
            await tester.pumpAndSettle();
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp()),
            );
            expect(run.failure, isNull, reason: run.failureMessage);
            expect(
              run.result!.outgoing.complete,
              true,
              reason: '${run.result!.outgoing.findings}',
            );
            expect(
              run.result!.outgoing.valid,
              true,
              reason: '${run.result!.outgoing.findings}',
            );
            expect(seen.single, latin1.encode(text));
            await tester.enterText(input, '€');
            await tester.pumpAndSettle();
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp()),
            );
            expect(run.failure, 'request.charset');
            expect(run.bodyText, '€');
            expect(seen, hasLength(1));
            expect(file.readAsStringSync(), source);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              run.dispose();
              await workspace.shutdown();
              workspace.dispose();
              await server?.close(force: true);
              directory.deleteSync(recursive: true);
            });
          }
        },
      );
    }
  }
}
