import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/platform/secret_store.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _NativeHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => <String, Object?>{},
          );
    }
  });
  tearDown(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  for (final version in ['3.0.4', '2.0', '3.1.2', '3.2.1']) {
    for (final kind in ['basic', 'key', 'token']) {
      testWidgets(
        '$version native $kind credential editor uses captured consumer rules',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 1050);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final directory = Directory.systemTemp.createTempSync(
            'busyapi-native-credential-',
          );
          final reference = '123e4567-e89b-42d3-a456-426614174000';
          final store = EnvironmentSecretStore(
            persistent: SessionBusyApiSecretStore(),
          );
          final workspace = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${directory.path}/config',
              state: '${directory.path}/state',
              cache: '${directory.path}/cache',
            ),
          );
          final run = RequestRunController(workspace, secrets: store);
          HttpServer? server;
          final received = <String?>[];
          try {
            late File file, manifest;
            late String original, configuration;
            await runWidgetIo(tester, () async {
              server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
              server!.listen((request) async {
                expect(request.method, 'GET');
                expect(request.uri.toString(), '/data');
                expect(
                  await request.fold<List<int>>(
                    [],
                    (all, part) => all..addAll(part),
                  ),
                  isEmpty,
                );
                received.add(
                  request.headers.value(
                    kind == 'key' ? 'x-key' : 'authorization',
                  ),
                );
                request.response.statusCode = 204;
                await request.response.close();
              });
              final swagger = version == '2.0';
              final declaration = kind == 'key'
                  ? {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'}
                  : kind == 'basic'
                  ? swagger
                        ? {'type': 'basic'}
                        : {'type': 'http', 'scheme': 'basic'}
                  : swagger
                  ? {
                      'type': 'oauth2',
                      'flow': 'application',
                      'tokenUrl': 'http://127.0.0.1:${server!.port}/token',
                      'scopes': <String, String>{},
                    }
                  : {'type': 'http', 'scheme': 'bearer'};
              final field = kind == 'key'
                  ? 'secretRef'
                  : kind == 'basic'
                  ? 'passwordRef'
                  : swagger
                  ? 'accessTokenRef'
                  : 'tokenRef';
              original = const JsonEncoder.withIndent('  ').convert({
                if (swagger) 'swagger': version else 'openapi': version,
                'info': {
                  'title': 'Native credentials 雪',
                  'version': 'api-version',
                },
                if (swagger) ...{
                  'host': '127.0.0.1:${server!.port}',
                  'schemes': ['http'],
                  'securityDefinitions': {'access': declaration},
                } else ...{
                  'servers': [
                    {'url': 'http://127.0.0.1:${server!.port}'},
                  ],
                  'components': {
                    'securitySchemes': {'access': declaration},
                  },
                },
                'security': [
                  {'access': <String>[]},
                ],
                'paths': {
                  '/data': {
                    'get': {
                      'responses': {
                        '204': {'description': 'Empty'},
                      },
                    },
                  },
                },
              });
              configuration =
                  'version: 1\nroots: [{name: api, path: api.json}]\nenvironments:\n  local:\n    authentication:\n      alternative: 0\n      schemes:\n        access: {${kind == 'basic' ? 'username: user, ' : ''}$field: $reference}\n';
              file = File('${directory.path}/api.json')
                ..writeAsStringSync(original);
              manifest = File('${directory.path}/busyapi.yaml')
                ..writeAsStringSync(configuration);
              await workspace.initialize();
              await workspace.open(file.path);
              await workspace.analyse();
              expect(workspace.projection, isNotNull, reason: workspace.error);
              final operation = (workspace.projection!['operations'] as List)
                  .cast<Map>()
                  .single;
              await run.open(Map<String, dynamic>.from(operation));
              run.selectEnvironment('local');
              expect(run.securityAlternative, 0);
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
            await tester.pumpAndSettle();
            final input = find.byType(RequestSecretInput);
            expect(input, findsOneWidget);
            expect(tester.widget<RequestSecretInput>(input).valuePolicies, [
              switch (kind) {
                'basic' => CredentialValuePolicy.basicPassword,
                'key' => CredentialValuePolicy.apiKey,
                _ => CredentialValuePolicy.bearerToken,
              },
            ]);
            final field = find.descendant(
              of: input,
              matching: find.byType(TextField),
            );
            expect(field, findsOneWidget);
            final action = find.descendant(
              of: input,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiActionRow &&
                    widget.title == 'Use for this session',
              ),
            );
            expect(action, findsOneWidget);
            expect(
              tester.widget<BusyApiActionRow>(action).enabled,
              kind != 'token',
            );
            expect(await tester.runAsync(() => store.read(reference)), null);
            if (kind == 'basic' || kind == 'token') {
              await tester.ensureVisible(field);
              await tester.enterText(
                field,
                kind == 'basic' ? 'private\ttail' : 'two words',
              );
              await tester.pump();
              expect(tester.widget<BusyApiActionRow>(action).enabled, false);
              expect(received, isEmpty);
              await tester.enterText(
                field,
                kind == 'basic' ? '' : 'wire-token',
              );
              await tester.pump();
            }
            expect(tester.widget<BusyApiActionRow>(action).enabled, true);
            await tester.ensureVisible(action);
            await tester.tap(action);
            await tester.pumpAndSettle();
            expect(
              await tester.runAsync(() => store.read(reference)),
              kind == 'token' ? 'wire-token' : '',
            );
            expect(store.status(reference), SecretPersistence.sessionOnly);
            await runWidgetIo(
              tester,
              () => HttpOverrides.runWithHttpOverrides(
                () => run.send(),
                _NativeHttp(),
              ),
            );
            expect(run.failure, null, reason: run.failureMessage);
            expect(run.result?.conforming, true);
            expect(received, [
              kind == 'key'
                  ? ''
                  : kind == 'basic'
                  ? 'Basic dXNlcjo='
                  : 'Bearer wire-token',
            ]);
            expect(await tester.runAsync(file.readAsString), original);
            expect(await tester.runAsync(manifest.readAsString), configuration);
            expect(tester.takeException(), null);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            run.dispose();
            await tester.runAsync(() async {
              await server?.close(force: true);
              await workspace.shutdown();
              workspace.dispose();
              await directory.delete(recursive: true);
            });
          }
        },
      );
    }
  }
}
