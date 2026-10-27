import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _NativeHttp extends HttpOverrides {}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format native access editing updates actual request conformance and undo',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-access-widget-',
          );
          final seen = <String>[];
          final server = await tester.runAsync(
            () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
          );
          server!.listen((request) async {
            seen.add(await utf8.decoder.bind(request).join());
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"token":""}');
            await request.response.close();
          });
          final source = File('${temp.path}/api.$format'),
              part = File('${temp.path}/part.$format');
          final defs = version == '2.0'
              ? '/definitions'
              : '/components/schemas';
          final schema = {r'$ref': '#$defs/Model'};
          final model = {
            'type': 'object',
            'required': ['token'],
            'properties': {
              'token': {r'$ref': 'part.$format#/Read'},
            },
          };
          final value = <String, Object?>{
            version == '2.0' ? 'swagger' : 'openapi': version,
            'info': {'title': 'Native access', 'version': '1'},
            if (version == '2.0') ...{
              'host': '127.0.0.1:${server.port}',
              'schemes': ['http'],
              'consumes': ['application/json'],
              'produces': ['application/json'],
            } else
              'servers': [
                {'url': 'http://127.0.0.1:${server.port}'},
              ],
            'paths': {
              '/items': {
                'post': {
                  if (version == '2.0')
                    'parameters': [
                      {'name': 'body', 'in': 'body', 'schema': schema},
                    ]
                  else
                    'requestBody': {
                      'content': {
                        'application/json': {'schema': schema},
                      },
                    },
                  'responses': {
                    '200': {
                      'description': 'Read',
                      if (version == '2.0')
                        'schema': schema
                      else
                        'content': {
                          'application/json': {'schema': schema},
                        },
                    },
                  },
                },
              },
            },
            if (format == 'json')
              (version == '2.0'
                  ? 'definitions'
                  : 'components'): version == '2.0'
                  ? {'Model': model}
                  : {
                      'schemas': {'Model': model},
                    },
          };
          final original = format == 'json'
              ? jsonEncode(value)
              : '# Keep aliased owner 雪\r\n${value.entries.map((e) => '${jsonEncode(e.key)}: ${jsonEncode(e.value)}').join('\r\n')}\r\nx-model: &model ${jsonEncode(model)}\r\n${version == '2.0' ? 'definitions: {Model: *model}' : 'components: {schemas: {Model: *model}}'}\r\n';
          final originalPart =
              '${format == 'yaml' ? '# Keep property target 雪\r\n' : ''}{"Read":{"type":"string","readOnly":true},"x-kept":9007199254740993.000}\r\n';
          source.writeAsStringSync(original);
          part.writeAsStringSync(originalPart);
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final run = RequestRunController(c);
          Future<void>? pending;
          final failures = <Object>[];
          final body = version.startsWith('3.0') ? '{}' : '{"token":""}';
          Future<void> send(Map<String, dynamic> operation) async {
            await run.open(operation, reconcile: true);
            run.bodyEnabled = true;
            run.bodyStructured = false;
            run.bodyMediaType = 'application/json';
            run.bodyText = body;
            run.refresh();
            expect(run.canSend, true, reason: '${run.failure} ${run.phase}');
            await HttpOverrides.runWithHttpOverrides(run.send, _NativeHttp());
            expect(run.failure, null);
            expect(run.result, isNotNull);
            expect(run.result!.outgoing.complete, true);
            expect(
              run.result!.received.complete && run.result!.received.valid,
              true,
            );
          }

          try {
            late Map<String, dynamic> operation;
            await runWidgetIo(tester, () async {
              await c.initialize();
              await c.open(source.path);
              await c.analyse();
              operation = Map<String, dynamic>.from(
                (c.projection!['operations'] as List).single,
              );
              await send(operation);
              expect(run.result!.outgoing.valid, version != '2.0');
              await c.selectObject({
                'root': c.root,
                'resource': part.uri.toString(),
                'pointer': '/Read',
              });
            });
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
            final field = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow<String> &&
                  widget.title.contains('readOnly'),
            );
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (field.evaluate().isEmpty &&
                DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 20));
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
            }
            expect(field, findsOneWidget);
            final control = tester.widget<BusyApiComboRow<String>>(field);
            expect(control.enabled, true);
            await runWidgetIo(tester, () async {
              control.onSelected('false');
              await pending;
            });
            expect(failures, isEmpty);
            expect(
              c.buffer!.text,
              originalPart.replaceFirst('"readOnly":true', '"readOnly":false'),
            );
            final changed = c.buffer!.text;
            await runWidgetIo(tester, () => send(operation));
            expect(run.result!.outgoing.valid, !version.startsWith('3.0'));
            c.store!.undo();
            expect(c.buffer!.text, originalPart);
            await runWidgetIo(tester, () => send(operation));
            expect(run.result!.outgoing.valid, version != '2.0');
            c.store!.redo();
            expect(c.buffer!.text, changed);
            expect(source.readAsStringSync(), original);
            expect(part.readAsStringSync(), originalPart);
            expect(seen, [body, body, body]);
            expect(tester.takeException(), null);
          } finally {
            await tester.pumpWidget(const SizedBox());
            run.dispose();
            await tester.runAsync(() async {
              await c.shutdown();
              c.dispose();
              await server.close(force: true);
              await temp.delete(recursive: true);
            });
          }
        },
      );
    }
  }
}
