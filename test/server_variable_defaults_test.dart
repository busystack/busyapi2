import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/server_variable_defaults_support.dart';
import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _NativeHttp extends HttpOverrides {}

void main() {
  for (final format in ['yaml', 'json']) {
    for (final options in [
      <String>[],
      ['allowed'],
    ]) {
      testWidgets(
        '3.0 $format native Run sends the declared default with enum $options',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final channel in ['yaru_window', 'yaru_window/events']) {
            messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              (call) async => channel == 'yaru_window' && call.method == 'state'
                  ? {'active': true, 'visible': true, 'closable': true}
                  : null,
            );
            addTearDown(
              () => messenger.setMockMethodCallHandler(
                MethodChannel(channel),
                null,
              ),
            );
          }
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-native-server-default-',
          );
          final controller = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final run = RequestRunController(controller);
          HttpServer? endpoint;
          final received = <String>[];
          late List<int> bytes;
          late String source;
          late Map<String, dynamic> operation;
          final file = File('${temp.path}/api.$format');
          Future<void> ready(bool Function() condition) async {
            final clock = Stopwatch()..start();
            await tester.pump();
            while (!condition() &&
                clock.elapsed < const Duration(seconds: 12)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(
              condition(),
              true,
              reason:
                  '${run.failure} ${run.failureMessage} ${controller.error}',
            );
            await tester.pumpAndSettle();
          }

          try {
            await runWidgetIo(tester, () async {
              endpoint = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
              endpoint!.listen((request) async {
                expect(request.method, 'GET');
                expect(
                  request.headers.value(HttpHeaders.hostHeader),
                  '[::1]:${endpoint!.port}',
                );
                expect(
                  await request.fold<List<int>>([], (a, b) => a..addAll(b)),
                  isEmpty,
                );
                received.add(request.uri.toString());
                request.response.statusCode = 204;
                await request.response.close();
              });
              source = serverVariableDefaultsSource(
                '3.0.4',
                format,
                endpoint!.port,
                '雪',
                options,
              );
              bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
              file.writeAsBytesSync(bytes);
              await controller.initialize();
              await controller.open(file.path);
              await controller.analyse();
              expect(controller.analysis!['status'], 'complete');
              operation = Map<String, dynamic>.from(
                (controller.projection!['operations'] as List).single as Map,
              );
              await run.open(operation);
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
                  body: SingleChildScrollView(child: RequestRunPanel(run: run)),
                ),
              ),
            );
            await ready(() => run.canSend);
            final l = AppLocalizations.of(
              tester.element(find.byType(RequestRunPanel)),
            )!;
            final send = find.descendant(
              of: find.byType(RequestRunPanel),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiCompactIconButton &&
                    widget.tooltip == l.requestSend,
              ),
            );
            expect(send, findsOneWidget);
            await tester.ensureVisible(send);
            await tester.pumpAndSettle();
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(() async {
                await tester.tap(send);
              }, _NativeHttp()),
            );
            await ready(() => run.result != null || run.failure != null);
            expect(run.failure, isNull);
            expect(run.result!.conforming, true);
            expect(received, ['/v%E9%9B%AA/items']);
            for (final version in ['3.1.2', '3.2.1']) {
              await runWidgetIo(tester, () async {
                controller.sourceEdit(
                  controller.root!,
                  source.replaceFirst('3.0.4', version),
                );
                expect(run.outdated, true);
                expect(run.canSend, false);
                await run.reconcileDraft();
              });
              await ready(() => run.phase == 'failed');
              expect(
                run.failure,
                options.isEmpty
                    ? 'server.structure'
                    : 'server.variable.default-enum',
              );
              expect(run.canSend, false);
              expect(received, hasLength(1));
              expect(file.readAsBytesSync(), bytes);
              await runWidgetIo(tester, () async {
                controller.sourceEdit(controller.root!, source);
                await run.open(operation, reconcile: true);
              });
              await ready(() => run.canSend);
              expect(run.failure, isNull);
            }
            expect(file.readAsBytesSync(), bytes);
            await runWidgetIo(tester, controller.saveAll);
            expect(file.readAsBytesSync(), bytes);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            run.dispose();
            await runWidgetIo(tester, () async {
              await endpoint?.close(force: true);
              await controller.shutdown();
            });
            controller.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
