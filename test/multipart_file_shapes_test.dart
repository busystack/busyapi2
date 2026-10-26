import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_disclosure.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _NativeHttp extends HttpOverrides {}

void main() {
  for (final version in ['3.0.4', '3.1.2']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format file grouping survives drafts and checks actual requests',
        (tester) async {
          tester.view.physicalSize = const Size(1500, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-file-shape-ui-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          final workspace = WorkspaceController(
            engine,
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final run = RequestRunController(workspace);
          HttpServer? server;
          final seen = <(String, String, String, List<int>)>[];
          final file = File('${directory.path}/api.$format');
          final upload = File('${directory.path}/upload.bin')
            ..writeAsBytesSync([97, 98, 99]);
          late String original;
          try {
            await tester.runAsync(() async {
              server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
              server!.listen((request) async {
                seen.add((
                  request.method,
                  request.uri.toString(),
                  request.headers.contentType.toString(),
                  await request.fold<List<int>>(
                    [],
                    (bytes, next) => bytes..addAll(next),
                  ),
                ));
                request.response.statusCode = 204;
                await request.response.close();
              });
              final scalar = <String, Object>{
                'type': 'string',
                if (version.startsWith('3.0.')) 'format': 'binary',
                'minLength': 3,
              };
              final document = {
                'openapi': version,
                'info': {'title': 'Keep 雪', 'version': '1'},
                'servers': [
                  {'url': 'http://127.0.0.1:${server!.port}'},
                ],
                'paths': {
                  '/files': {
                    'post': {
                      'requestBody': {
                        'content': {
                          'multipart/form-data': {
                            'schema': {
                              'type': 'object',
                              'required': ['asset'],
                              'properties': {
                                'asset': {
                                  'oneOf': [
                                    {...scalar, 'minLength': 4},
                                    {'type': 'array', 'items': scalar},
                                  ],
                                },
                              },
                            },
                            'encoding': {
                              if (format == 'json')
                                'asset': {
                                  'contentType': 'text/plain; charset=utf-8',
                                },
                            },
                          },
                        },
                      },
                      'responses': {
                        '204': {'description': 'No body'},
                      },
                    },
                  },
                },
              };
              original = format == 'json'
                  ? jsonEncode(document)
                  : '# Retain comment\r\n${document.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n';
              file.writeAsStringSync(original);
              File('${directory.path}/busyapi.yaml').writeAsStringSync(
                'version: 1\nroots: [{name: api, path: api.$format}]\nenvironments:\n  local: {baseUrl: "http://127.0.0.1:1"}\n',
              );
              await workspace.initialize();
              await workspace.open(file.path);
              await workspace.analyse();
              expect(workspace.projection, isNotNull, reason: workspace.error);
              await run.open(
                Map<String, dynamic>.from(
                  (workspace.projection!['operations'] as List).single as Map,
                ),
              );
              run.bodyFilePart = 'asset';
              run.addBodyFile(XFile(upload.path, name: 'upload.bin'));
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.light,
                  accentColor: const Color(0xffe95420),
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(body: RequestRunPanel(run: run)),
              ),
            );
            final disclosure = find.widgetWithText(
              BusyApiDisclosure,
              'Declared form parts',
            );
            final disclosureButton = find
                .descendant(of: disclosure, matching: find.byType(TextButton))
                .first;
            Future<void> choose(String label) async {
              await tester.pumpAndSettle();
              const channel = MethodChannel(nativeMenuChannelName);
              var presentations = 0;
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                channel,
                (call) async {
                  if (call.method != 'show') return null;
                  presentations++;
                  final entries = (call.arguments as Map)['entries'] as List;
                  expect(entries.map((entry) => (entry as Map)['label']), [
                    'Choose a value shape',
                    'Single value',
                    'Array of values',
                  ]);
                  return entries.indexWhere(
                    (entry) => (entry as Map)['label'] == label,
                  );
                },
              );
              final row = find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiComboRow &&
                    widget.title == 'asset · File values',
              );
              await tester.ensureVisible(disclosureButton);
              await tester.pumpAndSettle();
              if (row.evaluate().isEmpty) {
                await tester.tap(disclosureButton);
                await tester.pumpAndSettle();
              }
              final button = find.descendant(
                of: row,
                matching: find.byType(BusyApiMenuButton<int>),
              );
              await tester.ensureVisible(button);
              await tester.tap(button);
              await tester.pumpAndSettle();
              expect(presentations, 1);
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                channel,
                null,
              );
            }

            await choose('Array of values');
            expect(run.fileShapes, {'asset': MultipartFileShape.array});
            run.selectEnvironment('local');
            run.selectEnvironment(null);
            run.selectBodySerialization(true);
            run.selectBodySerialization(false);
            await tester.pumpAndSettle();
            expect(run.draft().body.fileShapes, {
              'asset': MultipartFileShape.array,
            });
            expect(run.bodyFiles.single.path, upload.path);
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp()),
            );
            expect(run.failure, isNull, reason: run.failureMessage);
            expect(run.result!.outgoing.complete, isTrue);
            expect(run.result!.outgoing.valid, isTrue);
            expect(seen, hasLength(1));
            final partType = format == 'json'
                ? 'text/plain; charset=utf-8'
                : version.startsWith('3.0.')
                ? 'application/octet-stream'
                : 'text/plain';
            final request = seen.single,
                boundary = ContentType.parse(seen.single.$3)
                    .parameters['boundary']!;
            expect(request.$1, 'POST');
            expect(request.$2, '/files');
            expect(
              request.$4,
              utf8.encode(
                '--$boundary\r\nContent-Disposition: form-data; name="asset"; filename="upload.bin"\r\nContent-Type: $partType\r\n\r\nabc\r\n--$boundary--\r\n',
              ),
            );
            await choose('Single value');
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp()),
            );
            expect(run.failure, isNull, reason: run.failureMessage);
            expect(run.result!.outgoing.complete, isTrue);
            expect(run.result!.outgoing.valid, isFalse);
            expect(seen, hasLength(2));
            final secondBoundary = ContentType.parse(seen.last.$3)
                .parameters['boundary']!;
            expect(
              utf8.decode(seen.last.$4).replaceAll(secondBoundary, boundary),
              utf8.decode(request.$4),
            );
            expect(run.fileShapes, {'asset': MultipartFileShape.single});
            expect(file.readAsStringSync(), original);
            expect(workspace.buffer!.text, original);
            expect(upload.readAsBytesSync(), [97, 98, 99]);
            await tester.runAsync(() async {
              workspace.sourceEdit(
                file.uri.toString(),
                original.replaceFirst(version, '3.2.1'),
              );
              await workspace.analyse();
              await run.reconcileDraft();
              await HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp());
            });
            expect(run.fileShapes, {'asset': MultipartFileShape.single});
            expect(run.failure, 'request.multipart.encoding.unsupported');
            expect(seen, hasLength(2));
            expect(file.readAsStringSync(), original);
            await tester.runAsync(() async {
              await workspace.undo();
              await run.reconcileDraft();
              run.selectFileShape('asset', MultipartFileShape.array);
              await HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp());
            });
            expect(workspace.buffer!.text, original);
            expect(run.failure, isNull, reason: run.failureMessage);
            expect(run.result!.outgoing.complete, isTrue);
            expect(run.result!.outgoing.valid, isTrue);
            expect(seen, hasLength(3));
            expect(file.readAsStringSync(), original);
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
