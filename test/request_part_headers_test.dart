import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_disclosure.dart';
import 'package:busyapi/src/workspace/request_part_headers.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _NativeHttp extends HttpOverrides {}

const _meta = '{"id":9007199254740993.00}';

void main() {
  for (final version in ['3.0.4', '3.1.2']) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        '$version $brightness native MIME header drafts reach actual HTTP',
        (tester) async {
          tester.view.physicalSize = const Size(1500, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-part-headers-',
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
          final file = File('${directory.path}/api.yaml');
          late String source;
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
                    (all, chunk) => all..addAll(chunk),
                  ),
                ));
                request.response.statusCode = 204;
                await request.response.close();
              });
              source =
                  '''openapi: $version
info: {title: Keep source, version: unchanged}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /parts:
    post:
      requestBody:
        required: true
        content:
          multipart/mixed:
            schema: {type: object, required: [value], properties: {value: {type: boolean, enum: [false]}}}
            encoding:
              value:
                contentType: text/plain
                headers:
                  X-Meta:
                    required: true
                    content:
                      application/json:
                        schema: {type: object, required: [id], properties: {id: {type: integer, enum: [9007199254740993.00]}}}
      responses: {'204': {description: Empty}}
''';
              file.writeAsStringSync(source);
              File('${directory.path}/busyapi.yaml').writeAsStringSync(
                'version: 1\nroots: [{name: api, path: api.yaml}]\nenvironments: {local: {baseUrl: "http://127.0.0.1:1"}}\n',
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
              run.bodyEnabled = true;
              run.bodyStructured = true;
              run.bodyText = '{"value":false}';
              run.refresh();
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: brightness,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(body: RequestRunPanel(run: run)),
              ),
            );
            final l = AppLocalizations.of(
              tester.element(find.byType(RequestRunPanel)),
            )!;
            final encoding = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiDisclosure &&
                  widget.title is Text &&
                  (widget.title as Text).data == l.requestPartEncoding,
            );
            final encodingTitle = find
                .descendant(
                  of: encoding,
                  matching: find.text(l.requestPartEncoding),
                )
                .first;
            await tester.ensureVisible(encodingTitle);
            await tester.tap(encodingTitle);
            await tester.pumpAndSettle();
            final editor = find.byType(RequestPartHeadersEditor);
            final title = find.descendant(
              of: editor,
              matching: find.text(l.requestPartHeaders),
            );
            await tester.ensureVisible(title);
            await tester.tap(title);
            await tester.pumpAndSettle();
            Future<void> enter(String label, String value) async {
              final row = find.descendant(
                of: editor,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is RequestDraftEntry && widget.label == label,
                ),
              );
              final input = find.descendant(
                of: row,
                matching: find.byType(TextFormField),
              );
              await tester.ensureVisible(input);
              await tester.enterText(input, value);
              await tester.pump();
            }

            await enter(l.requestMultipartName, 'value');
            await enter(l.requestHeaderName, 'X-Meta');
            await enter(l.requestHeaderValue, _meta);
            final add = find.descendant(
              of: editor,
              matching: find.text(l.requestAddHeader),
            );
            await tester.ensureVisible(add);
            await tester.tap(add);
            await tester.pumpAndSettle();
            expect(run.partHeaders.single.toJson(), {
              'part': 'value',
              'name': 'X-Meta',
              'value': _meta,
            });
            run.partHeaderName = 'X-Pending';
            run.partHeaderValue = 'retained';
            run.selectEnvironment('local');
            run.selectEnvironment(null);
            await tester.pumpAndSettle();
            expect(run.partHeaders.single.value, _meta);
            expect(run.partHeaderName, 'X-Pending');
            expect(run.partHeaderValue, 'retained');
            run.selectBodySerialization(true);
            run.selectBodySerialization(false);
            expect(run.partHeaders.single.value, _meta);
            expect(run.partHeaderValue, 'retained');
            run.partHeaderName = run.partHeaderValue = '';
            run.refresh();
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp()),
            );
            expect(run.failure, isNull, reason: run.failureMessage);
            expect(
              run.result!.outgoing.complete,
              isTrue,
              reason: '${run.result!.outgoing.findings}',
            );
            expect(
              run.result!.conforming,
              isTrue,
              reason: '${run.result!.outgoing.findings}',
            );
            expect(seen.single.$1, 'POST');
            expect(seen.single.$2, '/parts');
            final type = ContentType.parse(seen.single.$3),
                boundary = type.parameters['boundary']!;
            expect(type.mimeType, 'multipart/mixed');
            String wire(String boundary) =>
                '--$boundary\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\nX-Meta: $_meta\r\n\r\nfalse\r\n--$boundary--\r\n';
            expect(seen.single.$4, utf8.encode(wire(boundary)));
            await tester.runAsync(() async {
              workspace.sourceEdit(
                workspace.active!,
                source.replaceFirst(
                  'enum: [9007199254740993.00]',
                  'enum: [9007199254740994]',
                ),
              );
              await workspace.analyse();
              await run.reconcileDraft();
              await HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp());
            });
            expect(run.failure, isNull, reason: run.failureMessage);
            expect(run.result!.outgoing.complete, isTrue);
            expect(run.result!.outgoing.valid, isFalse);
            expect(run.partHeaders.single.value, _meta);
            expect(seen.length, 2);
            final secondBoundary = ContentType.parse(seen.last.$3)
                .parameters['boundary']!;
            expect(seen.last.$4, utf8.encode(wire(secondBoundary)));
            expect(file.readAsStringSync(), source);
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
