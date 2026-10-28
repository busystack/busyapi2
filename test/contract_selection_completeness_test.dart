import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/platform/secret_store.dart';
import 'package:busyapi/src/workspace/test_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/server_context_support.dart';
import '../packages/busyapi_core/test/test_support.dart';

class _NativeHttp extends HttpOverrides {}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format contract selection retains incomplete source and retires stale review',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
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
            'busyapi-selection-widget-',
          );
          final controller = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          HttpServer? server;
          final received = <String>[];
          Future<void> ready(bool Function() condition) async {
            for (var i = 0; i < 400 && !condition(); i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump();
            }
            expect(tester.takeException(), isNull);
            expect(condition(), true);
          }

          try {
            late File file;
            late String valid, missing;
            late List<int> original;
            await tester.runAsync(() async {
              server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
              server!.listen((request) async {
                expect(request.method, 'GET');
                expect(request.uri.toString(), '/v1/items');
                expect(
                  request.headers.value('host'),
                  '127.0.0.1:${server!.port}',
                );
                expect(
                  await request.fold<List<int>>([], (a, b) => a..addAll(b)),
                  isEmpty,
                );
                received.add(request.uri.toString());
                request.response.headers.contentType = ContentType.text;
                request.response.write(serverContextBody);
                await request.response.close();
              });
              final url = version == '2.0'
                  ? '127.0.0.1:${server!.port}'
                  : 'http://127.0.0.1:${server!.port}/v1';
              valid = serverContextSource(version, format, url);
              final declaration = version == '2.0' ? 'swagger' : 'openapi';
              missing = valid.replaceFirst(
                format == 'yaml'
                    ? '$declaration: "$version"\r\n'
                    : '  "$declaration": "$version",\n',
                '',
              );
              expect(missing, isNot(valid));
              file = File('${temp.path}/api.$format')
                ..writeAsStringSync('\ufeff$valid');
              original = file.readAsBytesSync();
              File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: api.$format}]
tests:
  - {name: held, operation: {method: get, path: /items}, expect: {status: 200}}
  - {name: untouched, operation: {method: post, path: /unselected}}
''');
              await controller.initialize();
              await controller.open(file.path);
              controller.sourceEdit(controller.root!, missing);
              await controller.analyse();
            });
            final project = controller.project!, root = controller.root!;
            late AppLocalizations l;
            Future<void> showSelection() async {
              final captured = (await tester.runAsync(
                () => project.captureContractSnapshot(root),
              ))!;
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpWidget(
                MaterialApp(
                  theme: buildBusyApiTheme(
                    brightness: Brightness.light,
                    accentColor: Colors.blue,
                  ),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Scaffold(
                    body: ContractTestsDialog(
                      workspace: controller,
                      owner: project,
                      root: root,
                      captured: captured,
                      configuration: ExecutionConfiguration.parse(
                        captured.snapshot.configuration.singleOrNull,
                        project.access.boundary,
                      ),
                      secrets: EnvironmentSecretStore(),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              l = AppLocalizations.of(
                tester.element(find.byType(ContractTestsDialog)),
              )!;
              await tester.tap(find.text('held'));
              await tester.pump();
              final untouched = tester.widget<BusyApiCheckbox>(
                find.descendant(
                  of: find.widgetWithText(BusyApiActionRow, 'untouched'),
                  matching: find.byType(BusyApiCheckbox),
                ),
              );
              expect(untouched.value, false);
            }

            Finder action() => find.widgetWithText(
              BusyApiDialogButton,
              l.contractTestSelected,
            );
            await showSelection();
            await tester.tap(action());
            await ready(
              () => find.text(l.contractTestIncomplete).evaluate().isNotEmpty,
            );
            expect(find.text('version.missing'), findsOneWidget);
            expect(find.text('test.operation'), findsNothing);
            expect(find.textContaining(l.contractTestNotSent), findsOneWidget);
            expect(received, isEmpty);
            expect(project.store.get(root).text, missing);
            expect(await tester.runAsync(file.readAsBytes), original);
            await tester.runAsync(() async {
              controller.sourceEdit(root, valid);
              await controller.flush();
            });
            controller.notifyListeners();
            await tester.pump();
            expect(
              tester.widget<BusyApiDialogButton>(action()).onPressed,
              isNull,
            );
            expect(find.textContaining(l.contractTestOutdated), findsOneWidget);
            await showSelection();
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(() async {
                await tester.tap(action());
              }, _NativeHttp()),
            );
            await ready(
              () =>
                  received.isNotEmpty &&
                  find.text(l.contractTestPassed).evaluate().isNotEmpty,
            );
            expect(received, ['/v1/items']);
            expect(project.store.get(root).text, valid);
            expect(await tester.runAsync(file.readAsBytes), original);
            await tester.runAsync(() => project.save(project.store.get(root)));
            expect(await tester.runAsync(file.readAsBytes), original);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              await controller.shutdown();
              await controller.engine.close();
              await server?.close(force: true);
            });
            controller.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
