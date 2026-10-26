import 'dart:io';
import 'dart:convert';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _NativeHttp extends HttpOverrides {}

const _wire =
    '--Fixture\r\nContent-Disposition: form-data; name="flag"\r\nContent-Type: text/plain\r\n\r\nfalse\r\n--Fixture--\r\n';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      '$version native entity input retains drafts and sends exact text/files',
      (tester) async {
        tester.view.physicalSize = const Size(1500, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync(
          'busyapi-entity-controls-',
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
        final part = File('${directory.path}/part.txt')
          ..writeAsStringSync('retained part');
        final entity = File('${directory.path}/entity.bin')
          ..writeAsBytesSync(utf8.encode(_wire));
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
            source = version == '2.0'
                ? '''swagger: '2.0'
info: {title: Keep source, version: unchanged}
host: 127.0.0.1:${server!.port}
schemes: [http]
consumes: [multipart/form-data; boundary=Fixture]
paths:
  /parts:
    post:
      parameters: [{name: flag, in: formData, required: true, type: boolean, enum: [false]}]
      responses: {'204': {description: Empty}}
'''
                : '''openapi: $version
info: {title: Keep source, version: unchanged}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /parts:
    post:
      requestBody:
        required: true
        content:
          multipart/form-data; boundary=Fixture:
            schema: {type: object, required: [flag], properties: {flag: {type: boolean, enum: [false]}}}
            encoding: {flag: {contentType: text/plain}}
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
            run.bodyText = '{"flag":false}';
            run.bodyFiles.add(
              MultipartFileValue(
                name: 'retained',
                path: part.path,
                mediaType: 'text/plain',
              ),
            );
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
          final mode = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiSwitchRow &&
                widget.title == 'Use a serialized entity',
          );
          await tester.ensureVisible(mode);
          await tester.tap(mode);
          await tester.pumpAndSettle();
          expect(run.bodyKind, RequestBodyKind.raw);
          expect(run.bodyStructured, isTrue);
          expect(run.bodyText, '{"flag":false}');
          expect(run.bodyFiles.single.path, part.path);
          expect(find.text('Validate and format exact JSON'), findsNothing);
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
          await tester.enterText(input, _wire);
          run.selectEnvironment('local');
          run.selectEnvironment(null);
          await tester.pumpAndSettle();
          expect(run.bodyKind, RequestBodyKind.raw);
          expect(run.bodyText, _wire);
          expect(run.bodyFiles.single.path, part.path);
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
            run.result!.outgoing.valid,
            isTrue,
            reason: '${run.result!.outgoing.findings}',
          );
          expect(seen.single.$1, 'POST');
          expect(seen.single.$2, '/parts');
          expect(seen.single.$3, 'multipart/form-data; boundary=Fixture');
          expect(seen.single.$4, utf8.encode(_wire));
          run.selectBodySerialization(false);
          expect(run.bodyKind, RequestBodyKind.multipart);
          expect(run.bodyFiles.single.path, part.path);
          run.selectBodySerialization(true);
          run.addBodyFile(XFile(entity.path));
          await tester.pumpAndSettle();
          expect(run.bodyKind, RequestBodyKind.binaryFile);
          expect(run.bodyFiles.single.path, entity.path);
          expect(run.draft().body.kind, RequestBodyKind.binaryFile);
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
            run.result!.outgoing.valid,
            isTrue,
            reason: '${run.result!.outgoing.findings}',
          );
          expect(seen, hasLength(2));
          expect(seen.last.$4, utf8.encode(_wire));
          await tester.runAsync(() async {
            workspace.sourceEdit(
              workspace.active!,
              source.replaceFirst('enum: [false]', 'enum: [true]'),
            );
            await workspace.analyse();
            await run.reconcileDraft();
            await HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp());
          });
          expect(run.failure, isNull, reason: run.failureMessage);
          expect(run.result!.outgoing.complete, isTrue);
          expect(run.result!.outgoing.valid, isFalse);
          expect(run.bodyKind, RequestBodyKind.binaryFile);
          expect(run.bodyFiles.single.path, entity.path);
          expect(seen, hasLength(3));
          expect(seen.last.$4, utf8.encode(_wire));
          run.clearBodyFiles();
          expect(run.bodyKind, RequestBodyKind.raw);
          expect(run.bodyText, _wire);
          expect(file.readAsStringSync(), source);
          expect(part.readAsStringSync(), 'retained part');
          expect(entity.readAsBytesSync(), utf8.encode(_wire));
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
