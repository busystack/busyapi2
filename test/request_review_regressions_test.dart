import 'dart:io';
import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'dart:convert';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_disclosure.dart';
import 'package:busyapi/src/designer/form_value_editor.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/reference/reference_object.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/test_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi/src/platform/secret_store.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _Fixture {
  _Fixture({EngineProcess? engine, this.secrets})
    : engine =
          engine ??
          EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  final EngineProcess engine;
  final EnvironmentSecretStore? secrets;
  final dir = Directory.systemTemp.createTempSync('busyapi-request-review-');
  late final file = File('${dir.path}/openapi.yaml');
  late final c = WorkspaceController(
    engine,
    StateLocations(
      config: '${dir.path}/config',
      state: '${dir.path}/state',
      cache: '${dir.path}/cache',
    ),
  );
  late final run = RequestRunController(c, secrets: secrets);
  late Map<String, dynamic> operation;
  Future<void> open(
    String source, {
    String extraConfiguration = '',
    String roots = '[{name: api, path: openapi.yaml}]',
  }) async {
    file.writeAsStringSync(source);
    File('${dir.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: $roots
environments:
  local: {baseUrl: 'http://127.0.0.1:1'}
$extraConfiguration
''');
    await c.initialize();
    await c.open(file.path);
    await c.analyse();
    expect(c.projection, isNotNull, reason: c.error);
    operation = Map<String, dynamic>.from(
      (c.projection!['operations'] as List).single as Map,
    );
    await run.open(operation);
  }

  Future<void> dispose() async {
    run.dispose();
    await c.shutdown();
    c.dispose();
    dir.deleteSync(recursive: true);
  }
}

class _NativeHttp extends HttpOverrides {}

class _InspectionEngine extends EngineProcess {
  _InspectionEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? inspection;

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    final gate = inspection;
    if (method == 'inspectExecutionJson' && gate != null && !gate.isCompleted) {
      gate.complete();
    }
    return result;
  }
}

class _RuntimeFindingEngine extends EngineProcess {
  _RuntimeFindingEngine(this.message, {this.context = const {}})
    : super(executable: runtimeNode, helper: runtimeHelper);
  final String message;
  final Map<String, Object?> context;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'evaluateSchemas' &&
        params['runtimeInstances'] is List &&
        (params['runtimeInstances'] as List).isNotEmpty) {
      return {
        ...result,
        'runtimeFindings': [
          ...(result['runtimeFindings'] as List),
          {
            'version': 1,
            'code': 'runtime.long-diagnostic',
            'severity': 'error',
            'message': message,
            ...context,
          },
        ],
      };
    }
    return result;
  }
}

String contract({
  String version = '3.1.2',
  bool empty = false,
  bool reduced = false,
  bool noAuthentication = false,
  bool parameter = false,
}) =>
    '''
openapi: $version
info: {title: Request review, version: '1'}
servers: ${empty ? '[]' : '[{url: "http://127.0.0.1:1"}${reduced ? '' : ', {url: "http://127.0.0.1:2"}'}]'}
security: ${empty || noAuthentication ? '[]' : '[{}${reduced ? '' : ', {access: []}'}]'}
paths:
  /pets:
    post:
${parameter ? '      parameters: [{name: name, in: query, schema: {type: string}}]\n' : ''}      requestBody:
        required: true
        content:
          text/plain: {schema: {type: string}, example: 'explicit example'}
      responses: {'200': {description: OK}}
components:
  securitySchemes:
    access: {type: http, scheme: bearer}
''';

Widget host(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => MaterialApp(
  theme: buildBusyApiTheme(brightness: brightness, accentColor: Colors.blue),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);

Future<void> expectCompleteCopy(
  WidgetTester tester,
  Finder content,
  String text,
) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    },
  );
  try {
    await tester.longPress(content);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, text);
  } finally {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  }
}

void main() {
  for (final version in ['3.0.0', '3.0.4', '3.1.2']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$version named generic multipart editor retains exact data through version switches in ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = _Fixture();
          final source = '''openapi: $version
info: {title: Generic multipart editor, version: api-version}
servers: [{url: 'http://127.0.0.1:1'}]
paths:
  /items:
    post:
      requestBody:
        required: true
        content:
          multipart/mixed:
            schema:
              type: object
              properties:
                flag: {type: boolean}
                metadata: {type: object, properties: {id: {type: integer}}}
            encoding:
              metadata: {contentType: application/json}
            examples:
              exact:
                value: {flag: false, metadata: {id: 9007199254740993.00}}
      responses: {'204': {description: Empty}}
''';
          try {
            await tester.runAsync(() => fixture.open(source));
            await tester.pumpWidget(
              host(RequestRunPanel(run: fixture.run), brightness: brightness),
            );
            await tester.pumpAndSettle();
            expect(fixture.run.bodyKind, RequestBodyKind.multipart);
            final example = find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiActionRow &&
                  widget.title == 'Examples · multipart/mixed · exact',
            );
            expect(example, findsOneWidget);
            await tester.ensureVisible(example);
            await tester.pumpAndSettle();
            await tester.tap(example);
            await tester.pumpAndSettle();
            expect(fixture.run.bodyStructured, isTrue);
            expect(fixture.run.bodyText, contains('9007199254740993.00'));
            expect(fixture.run.draft().body.kind, RequestBodyKind.multipart);
            expect(fixture.run.draft().body.mediaType, 'multipart/mixed');
            expect(
              tester
                  .widgetList<EditableText>(find.byType(EditableText))
                  .any(
                    (entry) => entry.controller.text == fixture.run.bodyText,
                  ),
              isTrue,
            );
            final retained = fixture.run.bodyText;
            await tester.runAsync(() async {
              fixture.c.store!.replace(
                fixture.c.root!,
                source.replaceFirst(version, '3.2.1'),
              );
              expect(fixture.run.outdated, isTrue);
              expect(fixture.run.canSend, isFalse);
              await fixture.run.reconcileDraft();
            });
            await tester.pumpAndSettle();
            expect(fixture.run.bodyText, retained);
            expect(
              fixture.run.plan!.formBindingForMedia('multipart/mixed'),
              isNull,
            );
            expect(fixture.run.outdated, isFalse);
            expect(fixture.run.hasUnavailableSelection, isTrue);
            expect(fixture.run.canSend, isFalse);
            await tester.runAsync(() async {
              fixture.c.store!.replace(fixture.c.root!, source);
              await fixture.run.reconcileDraft();
            });
            await tester.pumpAndSettle();
            expect(fixture.run.bodyText, retained);
            expect(
              fixture.run.plan!.formBindingForMedia('multipart/mixed'),
              RequestFormBinding.namedMultipart,
            );
            expect(fixture.run.hasUnavailableSelection, isFalse);
            expect(fixture.run.canSend, isTrue);
            expect(fixture.file.readAsStringSync(), source);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(fixture.dispose);
          }
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    testWidgets(
      'full request pane traversal reaches off-screen example in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = _Fixture();
        try {
          await tester.runAsync(
            () => fixture.open('''openapi: 3.2.1
info: {title: Native request traversal, version: '1'}
servers: [{url: 'http://127.0.0.1:1'}]
paths:
  /items:
    post:
      requestBody:
        content:
          text/plain:
            schema: {type: string}
            examples:
              exact: {serializedValue: 'retained serialized value'}
      responses: {'204': {description: Empty}}
'''),
          );
          await tester.pumpWidget(
            host(
              Row(
                children: [
                  SizedBox(
                    width: 300,
                    child: Column(
                      children: [
                        for (var i = 0; i < 12; i++)
                          BusyApiActionRow(
                            title: 'Navigation $i',
                            onTap: () {},
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: BusyApiEditorScrollBody(
                            child: Column(
                              children: [
                                for (var i = 0; i < 20; i++)
                                  BusyApiActionRow(
                                    title: 'Design $i',
                                    onTap: () {},
                                  ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 300,
                          child: SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 300),
                              child: RequestRunPanel(run: fixture.run),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          final send = find.descendant(
            of: find.byType(RequestRunPanel),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiCompactIconButton &&
                  widget.tooltip == 'Send',
            ),
          );
          Focus.of(
            tester.element(
              find.descendant(of: send, matching: find.byType(Icon)).first,
            ),
          ).requestFocus();
          await tester.pumpAndSettle();
          final trace = <String>[];
          var found = false;
          for (var step = 0; step < 64; step++) {
            final row = FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<BusyApiActionRow>();
            trace.add(
              row?.title ??
                  FocusManager.instance.primaryFocus?.debugLabel ??
                  'other',
            );
            if (row?.title == 'Examples · text/plain · exact') {
              found = true;
              break;
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
          }
          expect(found, isTrue, reason: trace.join(' → '));
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(fixture.run.bodyText, 'retained serialized value');
          expect(fixture.run.bodyEnabled, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.dispose);
        }
      },
    );
  }
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      '$version OpenID setup reviews a manual token and invalidates changed provider identity',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = _Fixture();
        final original = '''openapi: $version
info: {title: OpenID setup, version: "1"}
servers: [{url: 'http://127.0.0.1:1'}]
security: [{Provider: [read]}]
components:
  securitySchemes:
    Provider:
      type: openIdConnect
      openIdConnectUrl: https://identity.example.invalid/first/.well-known/openid-configuration
paths: {/items: {get: {responses: {'204': {description: Empty}}}}}
''';
        try {
          await tester.runAsync(() => fixture.open(original));
          final manifest = File('${fixture.dir.path}/busyapi.yaml');
          final configurationText = manifest.readAsStringSync();
          fixture.run.securityAlternative = 0;
          fixture.run.bodyText = 'retained draft';
          final panel = RequestRunPanel(run: fixture.run);
          await tester.pumpWidget(host(panel));
          final context = tester.element(find.byType(RequestRunPanel));
          final setup = panel.setup(context);
          await tester.pumpAndSettle();
          expect(find.text('OAuth access token'), findsOneWidget);
          expect(find.text('OAuth client ID'), findsNothing);
          await tester.tap(
            find.byWidgetPredicate(
              (w) =>
                  w is BusyApiDialogButton &&
                  w.label == 'Review configuration changes',
            ),
          );
          final apply = find.byWidgetPredicate(
            (w) => w is BusyApiDialogButton && w.label == 'Apply',
          );
          final watch = Stopwatch()..start();
          while (apply.evaluate().isEmpty &&
              watch.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          expect(apply, findsOneWidget);
          await tester.tap(apply);
          await runWidgetIo(
            tester,
            () => setup,
            timeout: const Duration(seconds: 10),
          );
          await tester.pump();
          String tokenReference() {
            final schemes =
                fixture
                        .run
                        .plan!
                        .configuration
                        .environments['local']!
                        .authentication['schemes']
                    as Map;
            return (schemes['Provider'] as Map)['accessTokenRef'] as String;
          }

          final reference = tokenReference();
          expect(
            reference,
            matches(
              RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              ),
            ),
          );
          expect(fixture.run.bodyText, 'retained draft');
          expect(manifest.readAsStringSync(), configurationText);
          expect(fixture.run.hasUnavailableSelection, isFalse);
          await tester.runAsync(() async {
            fixture.c.store!.replace(
              fixture.c.root!,
              original.replaceFirst('/first/', '/second/'),
            );
            await fixture.run.reconcileDraft();
          });
          expect(fixture.run.hasUnavailableSelection, isTrue);
          expect(fixture.run.canSend, isFalse);
          expect(fixture.run.bodyText, 'retained draft');
          expect(tokenReference(), reference);
          expect(
            fixture
                .run
                .plan!
                .result['security']['schemes']['Provider']['openIdConnectUrl'],
            contains('/second/'),
          );
          expect(fixture.file.readAsStringSync(), original);
          expect(manifest.readAsStringSync(), configurationText);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.dispose);
        }
      },
    );
  }
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      '$version TRACE panel retains refused drafts and permits a content-free retry',
      (tester) async {
        final fixture = _Fixture();
        HttpServer? endpoint;
        var received = 0;
        late final String original;
        try {
          await tester.runAsync(() async {
            endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            endpoint!.listen((request) async {
              received++;
              expect(request.method, 'TRACE');
              expect(await request.toList(), isEmpty);
              expect(request.headers.value('cookie'), isNull);
              request.response.statusCode = 204;
              await request.response.close();
            });
            original =
                '''openapi: $version
info: {title: TRACE request, version: "1"}
servers: [{url: 'http://127.0.0.1:${endpoint!.port}'}]
paths:
  /trace:
    trace:
      requestBody:
        content: {text/plain: {schema: {type: string}}}
      responses: {'204': {description: Empty}}
''';
            await fixture.open(original);
            fixture.run.bodyEnabled = version != '3.0.4';
            fixture.run.bodyText = 'retained 雪';
            fixture.run.refresh();
          });
          await tester.pumpWidget(
            host(
              SingleChildScrollView(child: RequestRunPanel(run: fixture.run)),
            ),
          );
          await tester.pump();
          final l = AppLocalizations.of(
            tester.element(find.byType(RequestRunPanel)),
          )!;
          Future<void> send() => tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              fixture.run.send,
              _NativeHttp(),
            ),
          );
          if (version == '3.0.4') {
            expect(fixture.run.plan!.ignoredRequestBody!.method, 'TRACE');
            expect(fixture.run.bodyMediaType, isNull);
            expect(find.text(l.requestBodyIgnored('TRACE')), findsOneWidget);
          } else {
            expect(fixture.run.canSend, isTrue);
            await send();
            await tester.pump();
            expect(received, 0);
            expect(fixture.run.failure, 'request.trace.content');
            expect(find.text(l.requestTraceContent), findsOneWidget);
            expect(fixture.run.bodyText, 'retained 雪');
            expect(fixture.run.result, isNull);
          }
          fixture.run.bodyEnabled = false;
          fixture.run.customHeaders.add(
            const RequestHeaderValue('Cookie', 'synthetic-secret'),
          );
          fixture.run.refresh();
          expect(fixture.run.canSend, isTrue);
          await send();
          await tester.pump();
          expect(received, 0);
          expect(fixture.run.failure, 'request.trace.credentials');
          expect(find.text(l.requestTraceCredentials), findsOneWidget);
          expect(
            fixture.run.failureMessage,
            isNot(contains('synthetic-secret')),
          );
          expect(fixture.run.customHeaders.single.value, 'synthetic-secret');
          expect(fixture.run.bodyText, 'retained 雪');
          fixture.run.customHeaders.clear();
          fixture.run.refresh();
          await send();
          await tester.pump();
          expect(received, 1);
          expect(
            fixture.run.failure,
            isNull,
            reason: fixture.run.failureMessage,
          );
          expect(fixture.run.result!.conforming, isTrue);
          expect(fixture.run.bodyText, 'retained 雪');
          expect(fixture.c.store!.get(fixture.c.root!).text, original);
          expect(fixture.file.readAsStringSync(), original);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await endpoint?.close(force: true);
            await fixture.dispose();
          });
        }
      },
    );
  }
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      '$version request panel reflects method-specific body applicability',
      (tester) async {
        final fixture = _Fixture();
        final original = '''openapi: $version
info: {title: Method body, version: "1"}
paths:
  /payload:
    get:
      requestBody:
        required: true
        content: {application/json: {schema: {type: string}, example: snow}}
      responses: {204: {description: Empty}}
''';
        try {
          await tester.runAsync(() => fixture.open(original));
          final ignored = version == '3.0.4';
          expect(fixture.run.plan!.ignoredRequestBody != null, ignored);
          expect(fixture.run.bodyEnabled, !ignored);
          await tester.pumpWidget(
            host(
              SingleChildScrollView(child: RequestRunPanel(run: fixture.run)),
            ),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(RequestRunPanel));
          expect(
            find.text(AppLocalizations.of(context)!.requestBodyIgnored('GET')),
            ignored ? findsOneWidget : findsNothing,
          );
          final message = AppLocalizations.of(context)!
              .requestBodyIgnored('GET');
          await tester.pumpWidget(
            host(
              ReferenceObjectView(
                controller: fixture.c,
                target: fixture.operation,
                reveal: (_) {},
                open: (_) {},
              ),
            ),
          );
          final watch = Stopwatch()..start();
          while (find
                  .text('Effective declarations and ownership')
                  .evaluate()
                  .isEmpty &&
              watch.elapsed < const Duration(seconds: 10)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          expect(
            find.text('Effective declarations and ownership'),
            findsOneWidget,
          );
          expect(find.text(message), ignored ? findsOneWidget : findsNothing);
          expect(fixture.c.store!.get(fixture.c.root!).text, original);
          expect(
            await tester.runAsync(() => fixture.file.readAsString()),
            original,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.dispose);
        }
      },
    );
  }
  for (final (location, long) in [
    ('header', false),
    ('query', false),
    ('header', true),
    ('query', true),
  ]) {
    testWidgets(
      '${long ? 'R14-E long' : 'R14-D'} mixed $location key reflection is redacted in the selectable redirect row',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = _Fixture();
        const shortSecret = 'BUSYAPI_TEST_ONLY/plus+equals=end';
        final secret = long
            ? '${'A' * (5000 - shortSecret.length)}$shortSecret'
            : shortSecret;
        HttpServer? origin, destination;
        var destinationRequests = 0;
        try {
          late String expected;
          await tester.runAsync(() async {
            destination = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            destination!.listen((request) async {
              destinationRequests++;
              request.response.statusCode = 204;
              await request.response.close();
            });
            origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            origin!.listen((request) async {
              expect(request.uri.query, startsWith('opaque=%E9&tag=one%2Ftwo'));
              request.response.statusCode = 302;
              request.response.headers.set(
                'location',
                'http://127.0.0.1:${destination!.port}/target?reflected=${secret.replaceAll('+', '%2B').replaceAll('=', '%3D')}&opaque=%E9',
              );
              await request.response.close();
            });
            await f.open(
              '''openapi: 3.2.1
info: {title: Redirect summary, version: "1"}
servers: [{url: 'http://127.0.0.1:${origin!.port}?opaque=%E9&tag=one%2Ftwo'}]
security: [{access: []}]
components: {securitySchemes: {access: {type: apiKey, in: $location, name: api_key}}}
paths: {/start: {get: {responses: {'302': {description: redirect}}}}}
''',
              extraConfiguration: '''  secured:
    authentication: {alternative: 0, schemes: {access: {secretRef: 123e4567-e89b-42d3-a456-426614174000}}}
''',
            );
            f.run.selectEnvironment('secured');
            await f.run.writeSecret(
              '123e4567-e89b-42d3-a456-426614174000',
              secret,
              SecretPersistence.sessionOnly,
            );
            expect(f.run.canSend, true);
            await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
            expect(f.run.result, isNotNull, reason: f.run.failureMessage);
            expect(
              f.run.result!.response.incompleteReason,
              'cross-origin-redirect-not-followed',
            );
            expected =
                'http://127.0.0.1:${destination!.port}/target?reflected=[REDACTED]&opaque=%E9';
            expect(f.run.result!.response.redirects.single, expected);
            expect(destinationRequests, 0);
          });
          await tester.pumpWidget(
            host(SingleChildScrollView(child: RequestRunPanel(run: f.run))),
          );
          final row = find.byWidgetPredicate(
            (w) => w is BusyApiActionRow && w.title == expected,
          );
          expect(row, findsOneWidget);
          expect(
            find.descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (w) => w is SelectableText && w.data == expected,
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is SelectableText &&
                  (w.data?.contains('BUSYAPI_TEST_ONLY') ?? false),
            ),
            findsNothing,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await origin?.close(force: true);
            await destination?.close(force: true);
            await f.dispose();
          });
        }
      },
    );
  }
  testWidgets(
    'F06 Cancel and owner replacement release authorization during a gated secret read',
    (tester) async {
      for (final replaceOwner in [false, true]) {
        for (final lateError in [false, true]) {
          late _GateSecretStore backing;
          late _ReadTrackingSecrets secrets;
          late _Fixture f;
          late Future<void> authorization;
          HttpServer? tokenServer;
          var tokenRequests = 0;
          addTearDown(() => tokenServer?.close(force: true));
          await tester.runAsync(() async {
            tokenServer = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            tokenServer!.listen((request) async {
              tokenRequests++;
              await request.drain<void>();
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                '{"access_token":"synthetic-token","token_type":"Bearer"}',
              );
              await request.response.close();
            });
            backing = _GateSecretStore();
            secrets = _ReadTrackingSecrets(backing);
            f = _Fixture(secrets: secrets);
            await f.open(
              '''openapi: 3.2.1
info: {title: Pending secret, version: '1'}
components: {securitySchemes: {oauth: {type: oauth2, flows: {clientCredentials: {tokenUrl: http://127.0.0.1:${tokenServer!.port}/token, scopes: {}}}}}}
paths: {/pets: {get: {security: [{oauth: []}], responses: {'200': {description: ok}}}}}
''',
              extraConfiguration: '''  secured:
    authentication:
      alternative: 0
      schemes:
        oauth: {clientId: desktop, clientAuthentication: basic, clientSecretRef: 123e4567-e89b-42d3-a456-426614174000, accessTokenRef: 123e4567-e89b-42d3-a456-426614174001}
''',
            );
            f.run.selectEnvironment('secured');
            authorization = HttpOverrides.runWithHttpOverrides(
              () => f.run.authorizeOAuth('oauth', browser: false),
              _NativeHttp(),
            );
            expect(
              f.run.busy,
              true,
              reason:
                  'Authorization did not start: phase=${f.run.phase}, unavailable=${f.run.hasUnavailableSelection}, outdated=${f.run.outdated}, failure=${f.run.failureMessage}',
            );
            final lookupStarted = await Future.any<bool>([
              backing.entered.future.then((_) => true),
              authorization.then((_) => false),
            ]);
            expect(
              lookupStarted,
              true,
              reason:
                  'OAuth stopped before lookup: ${f.run.phase} ${f.run.failure} ${f.run.failureMessage}',
            );
            expect(f.run.busy, true);
            if (replaceOwner) {
              f.run.clear();
            } else {
              f.run.cancel();
            }
            await authorization;
            expect(f.run.busy, false);
            expect(backing.release.isCompleted, false);
            final phase = f.run.phase, failure = f.run.failure;
            const reference = '123e4567-e89b-42d3-a456-426614174000';
            await secrets.checkAvailability(reference);
            expect(
              secrets.availability(reference),
              SecretAvailability.persistent,
            );
            final settled = expectLater(
              secrets.pendingRead!,
              throwsA(
                lateError
                    ? isA<SecretStoreFailure>().having(
                        (error) => error.code,
                        'code',
                        'secret.persistence.unavailable',
                      )
                    : isA<CoreFailure>().having(
                        (error) => error.code,
                        'code',
                        'cancelled',
                      ),
              ),
            );
            if (lateError) {
              backing.release.completeError(
                const SecretStoreFailure(
                  'secret.persistence.unavailable',
                  'Synthetic late secure backend failure',
                ),
              );
            } else {
              backing.release.complete('synthetic-secret');
            }
            await settled;
            expect(
              secrets.availability(reference),
              SecretAvailability.persistent,
            );
            expect(f.run.phase, phase);
            expect(f.run.failure, failure);
            expect(tokenRequests, 0);
            expect(backing.writes, 0);
            expect(
              secrets.metadata('123e4567-e89b-42d3-a456-426614174001'),
              null,
            );
            expect(
              await f.run.secrets.session.read(
                '123e4567-e89b-42d3-a456-426614174001',
              ),
              null,
            );
          });
          expect(tester.takeException(), null);
          await tester.runAsync(f.dispose);
        }
      }
    },
  );

  testWidgets('F03 nonempty 205 inspector offers only original export', (
    tester,
  ) async {
    final f = _Fixture();
    ServerSocket? server;
    final sockets = <Socket>{};
    try {
      await tester.runAsync(() async {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server!.listen((socket) async {
          sockets.add(socket);
          try {
            final input = <int>[];
            await for (final chunk in socket) {
              input.addAll(chunk);
              if (!ascii.decode(input).contains('\r\n\r\n')) continue;
              socket.write(
                'HTTP/1.1 205 Reset Content\r\n'
                'Content-Type: application/json\r\nContent-Length: 3\r\n'
                'Connection: close\r\n\r\nbad',
              );
              await socket.flush();
              await socket.close();
              break;
            }
          } finally {
            sockets.remove(socket);
            socket.destroy();
          }
        });
        await f.open('''openapi: 3.2.1
info: {title: Forbidden response content, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths: {/reset: {get: {responses: {'205': {description: Reset, content: {application/json: {}}}}}}}
''');
        await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
        expect(f.run.result!.response.receivedLength, 3);
        expect(f.run.result!.response.decodingComplete, false);
        expect(f.run.result!.received.complete, true);
        expect(f.run.result!.received.valid, false);
        expect(f.run.history.single.conforming, false);
      });
      await tester.pumpWidget(
        host(SingleChildScrollView(child: RequestRunPanel(run: f.run))),
      );
      final l = AppLocalizations.of(
        tester.element(find.byType(RequestRunPanel)),
      )!;
      expect(find.text(l.responseNonconforming), findsOneWidget);
      expect(find.text(l.responseCoverageIncomplete), findsNothing);
      expect(find.text(l.responseOriginalExport), findsWidgets);
      expect(find.text(l.responseDecodedExport), findsNothing);
      expect(find.text(l.responsePartialDecodedExport), findsNothing);
      expect(find.text(l.saveResponseExample), findsNothing);
      tester
          .widgetList<BusyApiComboRow<String>>(
            find.byType(BusyApiComboRow<String>),
          )
          .singleWhere((w) => w.values.contains('validation'))
          .onSelected('validation');
      await tester.pump();
      expect(
        find.textContaining('runtime.response.body.forbidden'),
        findsWidgets,
      );
      expect(
        find.textContaining('does not permit response content'),
        findsWidgets,
      );
      expect(tester.takeException(), null);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
        await server?.close();
        await f.dispose();
      });
    }
  });

  testWidgets('F03 residual no-body inspector keeps header syntax feedback', (
    tester,
  ) async {
    final f = _Fixture();
    HttpServer? server;
    var meta = '{"n":9007199254740993}', requests = 0;
    try {
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server!.listen((request) async {
          requests++;
          expect(request.method, 'HEAD');
          request.response.headers.set('X-Meta', meta);
          request.response.headers.set(
            'Content-Type',
            'application/jsonl; charset=utf-32',
          );
          request.response.headers.set('Content-Encoding', 'br');
          await request.response.close();
        });
        await f.open('''openapi: 3.2.1
info: {title: Metadata without content, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /pets:
    head:
      responses:
        '200':
          description: ok
          headers: {X-Meta: {content: {application/json: {}}}}
          content: {application/jsonl: {itemSchema: {type: object, required: [id]}}}
''');
        await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
        expect(f.run.result!.bodyPermitted, false);
        expect(f.run.result!.conforming, true);
        expect(f.run.history.single.conforming, true);
      });
      await tester.pumpWidget(
        host(SingleChildScrollView(child: RequestRunPanel(run: f.run))),
      );
      final l = AppLocalizations.of(
        tester.element(find.byType(RequestRunPanel)),
      )!;
      expect(find.text(l.responseConforming), findsOneWidget);
      expect(find.text(l.responseInvalidCharset), findsNothing);
      expect(find.text(l.responseBinary), findsNothing);
      expect(find.text(l.saveResponseExample), findsNothing);
      void select(String view) => tester
          .widgetList<BusyApiComboRow<String>>(
            find.byType(BusyApiComboRow<String>),
          )
          .singleWhere((w) => w.values.contains('validation'))
          .onSelected(view);
      select('headers');
      await tester.pump();
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == meta),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        meta = 'not json';
        await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
        expect(f.run.result!.received.complete, true);
        expect(f.run.result!.received.valid, false);
        expect(f.run.history.map((r) => r.conforming), [true, false]);
      });
      await tester.pump();
      expect(find.text(l.responseNonconforming), findsOneWidget);
      expect(find.text(l.responseCoverageIncomplete), findsNothing);
      select('validation');
      await tester.pump();
      expect(find.textContaining('runtime.body.syntax'), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SelectableText &&
              (w.data ?? '').contains('response-header') &&
              (w.data ?? '').contains('X-Meta'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('runtime.response.items.unchecked'),
        findsNothing,
      );
      expect(find.textContaining('runtime.response.decoding'), findsNothing);
      expect(requests, 2);
      expect(tester.takeException(), null);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await server?.close(force: true);
        await f.dispose();
      });
    }
  });

  testWidgets(
    'F08 old response cleanup cannot publish into a cleared or newer owner',
    (tester) async {
      final f = _Fixture();
      HttpServer? server;
      _GateResult? old;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            await request.drain<void>();
            request.response.statusCode = 204;
            await request.response.close();
          });
          await f.open('''openapi: 3.2.1
info: {title: Publication, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths: {/pets: {get: {responses: {'204': {description: ok}}}}}
''');
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          old = _GateResult(f.run.result!);
          f.run.result = old;
          final sending = HttpOverrides.runWithHttpOverrides(
            f.run.send,
            _NativeHttp(),
          );
          await old!.entered.future;
          // State and history publish before old disk deletion is allowed to finish.
          expect(f.run.phase, 'complete');
          expect(f.run.history, hasLength(2));
          await sending;
          f.run.clear();
          await f.run.open(f.operation);
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          final current = f.run.result;
          expect(f.run.history, hasLength(1));
          f.run.phase = 'failed';
          f.run.failure = 'new-owner.failure';
          f.run.failureMessage = 'Current feedback';
          var notifications = 0;
          void changed() {
            notifications++;
          }

          f.run.addListener(changed);
          old!.release.complete();
          await old!.closed.future;
          expect(f.run.result, same(current));
          expect(f.run.history, hasLength(1));
          expect(f.run.phase, 'failed');
          expect(f.run.failure, 'new-owner.failure');
          expect(f.run.failureMessage, 'Current feedback');
          expect(notifications, 0);
          expect(await File(old!.response.bodyFile).exists(), false);
          expect(old!.closes, 1);
          f.run.removeListener(changed);
        });
      } finally {
        if (old != null && !old!.release.isCompleted) old!.release.complete();
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  testWidgets(
    'F08 cleanup preserves the plan owned by a retained newer result during failed preparation',
    (tester) async {
      final f = _Fixture();
      HttpServer? server;
      _GateResult? old;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            await request.drain<void>();
            request.response.statusCode = 204;
            await request.response.close();
          });
          await f.open('''openapi: 3.2.1
info: {title: Retained plan ownership, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths: {/pets: {get: {responses: {'204': {description: ok}}}}}
''');
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          old = _GateResult(f.run.result!);
          f.run.result = old;
          final sending = HttpOverrides.runWithHttpOverrides(
            f.run.send,
            _NativeHttp(),
          );
          await old!.entered.future;
          await sending;
          final retained = f.run.result!;
          await f.run.open({...f.operation, 'pointer': '/paths/~1missing/get'});
          expect(f.run.plan, isNull);
          expect(f.run.result, same(retained));
          expect(f.run.failure, isNotNull);
          old!.release.complete();
          await old!.closed.future;
          await Future<void>.value();
          expect(retained.request.plan.closed, isFalse);
          expect(await File(old!.response.bodyFile).exists(), isFalse);
          expect(old!.closes, 1);
          // Inspection still uses the retained captured schema after cleanup.
          expect(
            (await retained.request.plan.inspectJson(
              '{"retained":true}',
            ))['entries'],
            isNotEmpty,
          );
        });
      } finally {
        if (old != null && !old!.release.isCompleted) old!.release.complete();
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  testWidgets(
    'F09 validation exposes distinct value paths constraints and captured schema navigation',
    (tester) async {
      final f = _Fixture();
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            await request.drain<void>();
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              '{"customer":{"id":"wrong"},"items":[{},{},{"quantity":"wrong"}]}',
            );
            await request.response.close();
          });
          await f.open('''openapi: 3.2.1
info: {title: Diagnostic locations, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /pets:
    post:
      parameters: [{name: count, in: query, schema: {type: integer}}]
      requestBody: {content: {application/json: {}}}
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  customer: {type: object, properties: {id: {type: integer}}}
                  items: {type: array, items: {type: object, properties: {quantity: {type: integer}}}}
''');
          f.run.values['query\u0000count'] = 'bad';
          f.run.structuredValues.add('query\u0000count');
          f.run.bodyEnabled = true;
          f.run.bodyText = 'not json';
          // A structured malformed parameter is a preparation failure. Use a
          // typed JSON string to exercise actual schema feedback instead.
          f.run.values['query\u0000count'] = '"bad"';
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          expect(f.run.result!.conforming, false);
          expect(f.run.result!.outgoing.valid, false);
        });
        await tester.pumpWidget(
          host(SingleChildScrollView(child: RequestRunPanel(run: f.run))),
        );
        final views = tester
            .widgetList<BusyApiComboRow<String>>(
              find.byType(BusyApiComboRow<String>),
            )
            .singleWhere((w) => w.values.contains('validation'));
        views.onSelected('validation');
        await tester.pump();
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SelectableText &&
                (w.data ?? '').contains('Value path: /customer/id') &&
                (w.data ?? '').contains('Constraint:'),
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SelectableText &&
                (w.data ?? '').contains('Value path: /items/2/quantity'),
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is SelectableText &&
                (w.data ?? '').contains('request-parameter') &&
                (w.data ?? '').contains('query:count'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('runtime.body.syntax'), findsWidgets);
        final row = tester
            .widgetList<BusyApiActionRow>(find.byType(BusyApiActionRow))
            .firstWhere(
              (w) => w.subtitle?.contains('Value path: /customer/id') == true,
            );
        expect(row.onTap, isNotNull);
        await tester.runAsync(() async {
          final navigated = Completer<void>();
          void changed() {
            if (f.c.selectedPointer.endsWith('/schema') == true &&
                f.c.buffer!.selection.base > 0 &&
                !navigated.isCompleted) {
              navigated.complete();
            }
          }

          f.c.addListener(changed);
          row.onTap!();
          await navigated.future;
          f.c.removeListener(changed);
        });
        expect(f.c.mode, 'Source');
        expect(f.c.selectedResource, f.file.uri.toString());
        expect(
          f.c.selectedPointer,
          endsWith('/responses/200/content/application~1json/schema'),
        );
        expect(f.c.buffer!.selection.base, greaterThan(0));
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  testWidgets(
    'F09 long diagnostic context stays bounded selectable and redacted',
    (tester) async {
      const secret = 'synthetic-context-credential';
      final contextPath = '/${'x' * 4094}😀/$secret/end';
      final f = _Fixture(
        engine: _RuntimeFindingEngine(
          'Diagnostic for $secret. ' * 300,
          context: {
            'subject': 'response-body',
            'location': 'application/json',
            'pointer': contextPath,
            'keyword': 'type',
            'schema': {
              'resource': 'file:///diagnostics/$secret.yaml',
              'pointer': contextPath,
              'range': [0, 1],
            },
          },
        ),
      );
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            expect(request.headers.value('authorization'), 'Bearer $secret');
            request.response.headers.contentType = ContentType.json;
            request.response.write('{}');
            await request.response.close();
          });
          await f.open(
            '''openapi: 3.2.1
info: {title: Diagnostic bounds, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
security: [{access: []}]
components: {securitySchemes: {access: {type: http, scheme: bearer}}}
paths: {/pets: {get: {responses: {'200': {description: ok, content: {application/json: {}}}}}}}
''',
            extraConfiguration: '''  secured:
    authentication: {alternative: 0, schemes: {access: {tokenRef: 123e4567-e89b-42d3-a456-426614174000}}}
''',
          );
          f.run.selectEnvironment('secured');
          await f.run.writeSecret(
            '123e4567-e89b-42d3-a456-426614174000',
            secret,
            SecretPersistence.sessionOnly,
          );
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
        });
        await tester.pumpWidget(
          host(SingleChildScrollView(child: RequestRunPanel(run: f.run))),
        );
        tester
            .widgetList<BusyApiComboRow<String>>(
              find.byType(BusyApiComboRow<String>),
            )
            .singleWhere((w) => w.values.contains('validation'))
            .onSelected('validation');
        await tester.pump();
        final row = tester
            .widgetList<BusyApiActionRow>(find.byType(BusyApiActionRow))
            .singleWhere((w) => w.title.contains('runtime.long-diagnostic'));
        expect(row.subtitleWidget, isA<SelectableText>());
        expect(row.subtitle, contains('[REDACTED]'));
        expect(row.subtitle, contains('…'));
        expect(row.subtitle!.length, lessThan(14000));
        expect(row.subtitle, isNot(contains(secret)));
        expect(
          row.subtitle!.runes.any((r) => r >= 0xd800 && r <= 0xdfff),
          false,
        );
        expect(
          row.onTap,
          null,
          reason: 'A derived or unavailable source cannot become a navigation capability.',
        );
        for (final text in tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        )) {
          expect(text.data ?? '', isNot(contains(secret)));
        }
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );
  testWidgets(
    'F10 response pages folds and search preserve Unicode and original bytes',
    (tester) async {
      final engine = _InspectionEngine();
      final f = _Fixture(engine: engine);
      HttpServer? server;
      try {
        const prefix = '{"message":"';
        var body = '$prefix${'a' * (16383 - prefix.length)}😀${'b' * 5000}"}';
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            request.response.headers.contentType = ContentType.json;
            request.response.write(body);
            await request.response.close();
          });
          await f.open('''openapi: 3.2.1
info: {title: Inspector, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths: {/pets: {get: {responses: {'200': {description: ok, content: {application/json: {}}}}}}}
''');
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
        });
        Future<void> inspectorReady() async {
          final inspected = engine.inspection = Completer<void>();
          await tester.pumpWidget(
            host(SingleChildScrollView(child: RequestRunPanel(run: f.run))),
          );
          // Observe the inspector's own RPC. A second, independent inspection
          // does not establish that this widget has received its result.
          await runWidgetIo(tester, () => inspected.future);
          await tester.pump();
        }

        void action(String label) {
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, label))
              .onPressed!();
        }

        String raw() => tester
            .widget<BusyApiRawSourceView>(find.byType(BusyApiRawSourceView))
            .source;
        await inspectorReady();
        final first = raw();
        expect(first.endsWith('a'), true);
        action('Next page');
        await tester.pump();
        final second = raw();
        expect(second.startsWith('😀'), true);
        expect(first + second, body);
        action('Fold top-level JSON values');
        await tester.pump();
        expect(find.text('message'), findsOneWidget);
        expect(find.text('1 / 1'), findsOneWidget);
        action('Show full formatted preview');
        await tester.pump();
        expect(raw(), first);
        await tester.runAsync(() async {
          final target = '${f.dir.path}/original.bin';
          await f.run.result!.response.export(target);
          expect(await File(target).readAsBytes(), utf8.encode(body));
        });
        body = jsonEncode({
          for (var i = 0; i < 60; i++)
            'entry$i': i == 59 ? 'needle at the end' : 'ordinary',
        });
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp()),
        );
        await inspectorReady();
        action('Fold top-level JSON values');
        await tester.pump();
        action('Next page');
        await tester.pump();
        final search = tester
            .widgetList<BusyApiGroupedTextEntry>(
              find.byType(BusyApiGroupedTextEntry),
            )
            .singleWhere((w) => w.label == 'Search retained preview')
            .controller!;
        search.text = 'needle';
        await tester.pump();
        expect(find.text('entry59'), findsOneWidget);
        expect(find.text('1 / 1'), findsOneWidget);
        search.text = 'absent needle';
        await tester.pump();
        expect(find.text('0 / 0'), findsOneWidget);
        expect(
          find.textContaining('No match in this inspection preview'),
          findsOneWidget,
        );
        action('Show full formatted preview');
        await tester.pump();
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  testWidgets(
    'F01 caret and composition preserve omission and serialized examples',
    (tester) async {
      final f = _Fixture();
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            expect(request.uri.query, 'tag=one&tag=two');
            request.response.statusCode = 204;
            await request.response.close();
          });
        });
        await tester.runAsync(
          () => f.open('''openapi: 3.2.1
info: {title: Caret, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /pets:
    get:
      parameters:
        - {in: query, name: tag, schema: {type: string}, examples: {pair: {serializedValue: 'tag=one&tag=two'}}}
      responses: {'204': {description: ok}}
'''),
        );
        await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
        final entry = find.byWidgetPredicate(
          (w) => w is RequestDraftEntry && w.label.startsWith('tag ·'),
        );
        final editable = find.descendant(
          of: entry,
          matching: find.byType(EditableText),
        );
        var controller = tester.widget<EditableText>(editable).controller;
        controller.selection = const TextSelection.collapsed(offset: 0);
        await tester.pump();
        const key = 'query\u0000tag';
        expect(f.run.values.containsKey(key), false);
        expect(f.run.draft().parameters.containsKey(key), false);
        final parameter =
            (f.run.plan!.result['parameters'] as List).single as Map;
        f.run.useExample(parameter);
        await tester.pump();
        Future<String> target() async =>
            (await const ContractRequestBuilder().build(
              f.run.plan!,
              f.run.draft(),
              resolveSecret: (_) async => null,
              previewOnly: true,
            )).uri.toString();
        final original = await tester.runAsync(target);
        expect(original, endsWith('?tag=one&tag=two'));
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp()),
        );
        await tester.pump();
        // A real IME composes in the currently focused field. Send can rebuild
        // the request controls; do not drive a controller from the old tree.
        await tester.showKeyboard(editable);
        controller = tester.widget<EditableText>(editable).controller;
        expect(f.run.resultDraftChanged, false);
        f.run.phase = 'failed';
        f.run.failure = 'retained.feedback';
        f.run.failureMessage = 'Retain this feedback';
        controller.selection = const TextSelection(
          baseOffset: 1,
          extentOffset: 5,
        );
        controller.value = controller.value.copyWith(
          composing: const TextRange(start: 0, end: 3),
        );
        await tester.pump();
        expect(f.run.hasComposingInput, true);
        expect(f.run.canSend, false);
        expect(f.run.phase, 'failed');
        expect(f.run.resultDraftChanged, false);
        expect(f.run.failureMessage, 'Retain this feedback');
        expect(
          f.run.exampleRepresentations[key],
          RequestValueRepresentation.serializedParameter,
        );
        expect(await tester.runAsync(target), original);
        controller.clearComposing();
        await tester.pump();
        expect(f.run.hasComposingInput, false);
        expect(f.run.phase, 'failed');
        expect(f.run.resultDraftChanged, false);
        controller.text = 'edited';
        await tester.pump();
        expect(f.run.values[key], 'edited');
        expect(f.run.exampleRepresentations.containsKey(key), false);
        expect(f.run.phase, 'ready');
        expect(await tester.runAsync(target), endsWith('?tag=edited'));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  testWidgets(
    'F02 authored dictionary names remain destination and security semantics',
    (tester) async {
      for (final name in [
        'source',
        'definition',
        'description',
        'range',
        'generation',
      ]) {
        final f = _Fixture();
        try {
          await tester.runAsync(() async {
            var source =
                '''openapi: 3.2.1
info: {title: Identity, version: '1'}
servers: [{url: 'https://{$name}.example.test', description: Original, variables: {$name: {default: development, description: Original}}}]
security: [{$name: [read]}, {}]
components:
  securitySchemes:
    $name: {type: oauth2, flows: {clientCredentials: {tokenUrl: https://auth.example.test/token, scopes: {read: Original, write: Write}}}}
paths: {/pets: {get: {responses: {'204': {description: ok}}}}}
''';
            await f.open(source);
            f.run.securityAlternative = 0;
            Future<Uri> destination() async =>
                (await const ContractRequestBuilder().build(
                  f.run.plan!,
                  OperationRequestDraft(
                    planIdentity: f.run.plan!.identity,
                    server: f.run.server,
                    securityAlternative: 1,
                  ),
                  resolveSecret: (_) async => null,
                  previewOnly: true,
                )).uri;
            expect((await destination()).host, 'development.example.test');
            source = source.replaceAll('Original', 'Updated documentation');
            f.c.store!.replace(f.c.root!, source);
            await f.run.reconcileDraft();
            expect(f.run.hasUnavailableSelection, false, reason: name);
            source = source.replaceFirst(
              'default: development',
              'default: production',
            );
            f.c.store!.replace(f.c.root!, source);
            await f.run.reconcileDraft();
            expect(f.run.server, -1, reason: name);
            f.run.server = 0;
            expect((await destination()).host, 'production.example.test');
            for (final change in [
              (': [read]', ': [write]'),
              (
                'https://auth.example.test/token',
                'https://auth.example.test/new-token',
              ),
              ('type: oauth2', 'type: http, scheme: bearer'),
              ('scheme: bearer', 'scheme: basic'),
            ]) {
              f.run.securityAlternative = 0;
              source = source.replaceFirst(change.$1, change.$2);
              f.c.store!.replace(f.c.root!, source);
              await f.run.reconcileDraft();
              expect(f.run.securityAlternative, -1, reason: '$name $change');
            }
            // Environment substitutions use the same unrestricted dictionary names.
            f.run.securityAlternative = 1;
            f.run.selectEnvironment('local');
            final manifest = Uri.file('${f.dir.path}/busyapi.yaml').toString();
            final buffer = await f.c.project!.buffer(manifest);
            final config = buffer.text.replaceFirst(
              "{baseUrl: 'http://127.0.0.1:1'}",
              "{baseUrl: 'https://\${$name}.example.test', variables: {$name: development}}",
            );
            f.c.store!.replace(manifest, config);
            await f.run.reconcileDraft();
            f.run.server = 0;
            f.c.store!.replace(
              manifest,
              config.replaceFirst('$name: development', '$name: production'),
            );
            await f.run.reconcileDraft();
            expect(f.run.server, -1, reason: 'environment $name');
            f.run.server = 0;
            final prepared = await const ContractRequestBuilder().build(
              f.run.plan!,
              f.run.draft(),
              resolveSecret: (_) async => null,
              previewOnly: true,
            );
            expect(prepared.uri.host, 'production.example.test');
          });
        } finally {
          await tester.runAsync(f.dispose);
        }
      }
    },
  );

  testWidgets(
    'H15 stale authorization never stores a token or leaves the client busy',
    (tester) async {
      final backing = SessionBusyApiSecretStore();
      final f = _Fixture(secrets: EnvironmentSecretStore(persistent: backing));
      HttpServer? server;
      late Completer<void> received, release;
      try {
        await tester.runAsync(() async {
          received = Completer<void>();
          release = Completer<void>();
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            await request.drain<void>();
            if (request.uri.path != '/token') {
              expect(
                request.headers.value('authorization'),
                'Bearer replacement-token',
              );
              request.response.statusCode = 204;
              await request.response.close();
              return;
            }
            received.complete();
            await release.future;
            try {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                '{"access_token":"synthetic-late-token","token_type":"Bearer","scope":"read"}',
              );
              await request.response.close();
            } on Object {
              /* A cancelled exchange closes its transport. */
            }
          });
          await f.open(
            '''openapi: 3.2.1
info: {title: Owned authorization, version: '1'}
security: [{oauth: [read]}, {}]
components: {securitySchemes: {oauth: {type: oauth2, flows: {clientCredentials: {tokenUrl: 'http://127.0.0.1:${server!.port}/token', scopes: {read: Read}}}}}}
paths: {/pets: {get: {responses: {'204': {description: ok}}}}}
''',
            extraConfiguration:
                '''  auth:
    baseUrl: http://127.0.0.1:${server!.port}
    authentication:
      alternative: 0
      schemes: {oauth: {clientId: synthetic, clientAuthentication: none, scopes: [read], accessTokenRef: 123e4567-e89b-42d3-a456-426614174000}}
''',
          );
          f.run.selectEnvironment('auth');
          final pending = HttpOverrides.runWithHttpOverrides(
            () => f.run.authorizeOAuth('oauth', browser: false),
            _NativeHttp(),
          );
          await received.future;
          f.run.securityAlternative =
              1; // A late selection callback must invalidate publication.
          release.complete();
          await pending;
          expect(
            await f.run.secrets.session.read(
              '123e4567-e89b-42d3-a456-426614174000',
            ),
            isNull,
          );
          expect(
            f.run.secrets.metadata('123e4567-e89b-42d3-a456-426614174000'),
            isNull,
          );
          expect(f.run.busy, false);
          expect(f.run.failure, 'oauth.stale');
          expect(f.run.history, isEmpty);
          const reference = '123e4567-e89b-42d3-a456-426614174000';
          await f.run.secrets.write(
            reference,
            'old-token',
            persistence: SecretPersistence.persistent,
          );
          f.run.secrets.rememberOAuth(reference, 'old-token', ['write'], null);
          await backing.write(reference, 'replacement-token');
          f.run.securityAlternative = 0;
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          expect(f.run.result!.response.status, 204);
          expect(f.run.failure, isNull);
          expect(
            f.run.secrets.metadata(reference),
            isNull,
            reason: 'A backend replacement must not inherit the previous token grant.',
          );
        });
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  testWidgets(
    'U3 stale setup preserves entered configuration and request input',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = _Fixture();
      try {
        await tester.runAsync(() => f.open(contract()));
        f.run.securityAlternative = 1;
        f.run.bodyText = 'retained request';
        final panel = RequestRunPanel(run: f.run);
        await tester.pumpWidget(host(panel));
        final context = tester.element(find.byType(RequestRunPanel));
        Finder field(String label) => find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is BusyApiGroupedTextEntry && w.label == label,
          ),
          matching: find.byType(TextField),
        );
        Object? failure;
        final setup = panel
            .setup(context)
            .then<void>(
              (_) {},
              onError: (Object error) {
                failure = error;
              },
            );
        await tester.pumpAndSettle();
        await tester.enterText(
          field('Base URL (optional override)'),
          'http://127.0.0.1:9999/kept',
        );
        await tester.enterText(
          field('Variables (literal name=value per line)'),
          'stage= retained ',
        );
        await tester.pump();
        await tester.runAsync(() async {
          final manifest = Uri.file('${f.dir.path}/busyapi.yaml').toString();
          final buffer = await f.c.project!.buffer(manifest);
          f.c.store!.replace(
            manifest,
            buffer.text.replaceFirst(':1\'', ':2\''),
          );
        });
        expect(f.run.outdated, true);
        await tester.tap(
          find.byWidgetPredicate(
            (w) =>
                w is BusyApiDialogButton &&
                w.label == 'Review configuration changes',
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() => setup);
        expect(
          failure,
          isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
        );
        await tester.runAsync(f.run.reconcileDraft);
        expect(f.run.bodyText, 'retained request');
        final retry = panel.setup(context);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(field('Base URL (optional override)'))
              .controller!
              .text,
          'http://127.0.0.1:9999/kept',
        );
        expect(
          tester
              .widget<TextField>(
                field('Variables (literal name=value per line)'),
              )
              .controller!
              .text,
          'stage= retained ',
        );
        expect(
          find.text(
            'Your setup input was retained. Review it against the current configuration before applying.',
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is BusyApiDialogButton && w.label == 'Cancel',
          ),
        );
        await tester.pumpAndSettle();
        await retry;
        expect(f.file.readAsStringSync(), contract());
        expect(
          File('${f.dir.path}/busyapi.yaml').readAsStringSync(),
          contains(':1\''),
        );
        expect(f.run.bodyText, 'retained request');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.dispose);
      }
    },
  );

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
  ButtonStyleButton send(WidgetTester tester) => tester
      .widget<ButtonStyleButton>(find.widgetWithText(ElevatedButton, 'Send'));
  BusyApiMenuButton<int> menu(WidgetTester tester, String title) =>
      tester.widget<BusyApiMenuButton<int>>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is BusyApiComboRow && w.title == title,
          ),
          matching: find.byType(BusyApiMenuButton<int>),
        ),
      );

  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'F16 inherited requirements cannot retain an unavailable no-auth choice $version',
      (tester) async {
        final f = _Fixture();
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        try {
          final initial = contract(
            version: version,
            noAuthentication: true,
            parameter: true,
          );
          await tester.runAsync(() => f.open(initial));
          f.run.bodyText = 'retained body';
          f.run.values[OperationRequestDraft.parameterKey('query', 'name')] =
              'retained parameter';
          expect(f.run.securityAlternative, isNull);
          final inherited = initial.replaceFirst(
            'security: []',
            'security: [{access: []}]',
          );
          await tester.runAsync(() async {
            f.c.sourceEdit(f.c.active!, inherited);
            await f.c.analyse();
            await f.run.reconcileDraft();
          });
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          await tester.pumpAndSettle();
          expect(f.run.plan!.result['security']['requirements'], hasLength(1));
          expect(f.run.securityAlternative, isNull);
          expect(f.run.hasUnavailableSelection, true);
          expect(send(tester).onPressed, isNull);
          final row = tester.widget<BusyApiComboRow<({int? value})>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow && widget.title == 'Authentication',
            ),
          );
          final requiredChoice = row.values.singleWhere(
            (choice) => row.enabledFor!(choice),
          );
          expect(requiredChoice.value, 0);
          row.onSelected(requiredChoice);
          await tester.pumpAndSettle();
          expect(f.run.hasUnavailableSelection, false);
          expect(send(tester).onPressed, isNotNull);
          // An explicit operation override can subsequently remove inherited auth.
          await tester.runAsync(() async {
            f.c.sourceEdit(
              f.c.active!,
              inherited.replaceFirst(
                '    post:',
                '    post:\n      security: []',
              ),
            );
            await f.c.analyse();
            await f.run.reconcileDraft();
          });
          await tester.pumpAndSettle();
          expect(f.run.plan!.result['security']['requirements'], isEmpty);
          expect(f.run.hasUnavailableSelection, true);
          final optionalRow = tester.widget<BusyApiComboRow<({int? value})>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is BusyApiComboRow && widget.title == 'Authentication',
            ),
          );
          optionalRow.onSelected(
            optionalRow.values.singleWhere(
              (choice) => optionalRow.enabledFor!(choice),
            ),
          );
          await tester.pumpAndSettle();
          expect(f.run.securityAlternative, isNull);
          expect(f.run.hasUnavailableSelection, false);
          expect(send(tester).onPressed, isNotNull);
          expect(f.run.bodyText, 'retained body');
          expect(
            f.run.values[OperationRequestDraft.parameterKey('query', 'name')],
            'retained parameter',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(f.dispose);
        }
      },
    );
    testWidgets(
      'F06 empty root servers retain the default and native Send $version',
      (tester) async {
        final f = _Fixture();
        try {
          await tester.runAsync(
            () => f.open(contract(version: version, empty: true)),
          );
          f.run.selectEnvironment('local');
          f.run.bodyEnabled = true;
          f.run.bodyMediaType = 'text/plain';
          f.run.bodyText = 'retained input';
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          expect((f.run.plan!.result['servers'] as List).single['url'], '/');
          expect(f.run.server, 0);
          expect(f.run.hasUnavailableSelection, false);
          expect(send(tester).onPressed, isNotNull);
          expect(find.text('No declared servers'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(f.dispose);
        }
      },
    );
    testWidgets(
      'explicit empty operation servers render safely and retain the request draft $version',
      (tester) async {
        final f = _Fixture();
        try {
          await tester.runAsync(
            () => f.open(
              contract(
                version: version,
                empty: true,
              ).replaceFirst('    post:', '    post:\n      servers: []'),
            ),
          );
          f.run.bodyText = 'owned draft';
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          expect(f.run.plan!.result['servers'], isEmpty);
          expect(find.text('No declared servers'), findsWidgets);
          expect(f.run.server, 0);
          expect(f.run.hasUnavailableSelection, true);
          expect(send(tester).onPressed, isNull);
          await tester.runAsync(f.run.send);
          expect(f.run.phase, 'ready');
          expect(f.run.bodyText, 'owned draft');
          expect(f.run.result, isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(f.dispose);
        }
      },
    );

    testWidgets(
      'removed server and authentication choices require explicit reconciliation $version',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = _Fixture();
        try {
          final original = contract(version: version);
          await tester.runAsync(() => f.open(original));
          f.run.server = 1;
          f.run.securityAlternative = 1;
          f.run.bodyText = 'retained exact draft 雪';
          f.c.store!.replace(
            f.c.root!,
            contract(version: version, reduced: true),
          );
          await tester.runAsync(() => f.run.open(f.operation));
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          expect(f.run.outdated, true);
          expect(f.run.server, 1);
          expect(f.run.securityAlternative, 1);
          expect(f.run.bodyText, 'retained exact draft 雪');
          expect(find.text('Unavailable selection (2)'), findsWidgets);
          for (final title in ['Server', 'Authentication']) {
            final native = menu(tester, title);
            if (title == 'Authentication') {
              expect(
                native.items.whereType<BusyApiPopupMenuItem<int>>().map(
                  (item) => item.label,
                ),
                isNot(contains('No authentication')),
              );
            }
            final missing = native.items
                .whereType<BusyApiPopupMenuItem<int>>()
                .singleWhere((i) => i.label == 'Unavailable selection (2)');
            expect(missing.enabled, false);
            native.onSelected(missing.menuValue);
          }
          expect(f.run.server, 1);
          expect(f.run.securityAlternative, 1);
          await tester.runAsync(f.run.reconcileDraft);
          await tester.pumpAndSettle();
          expect(f.run.outdated, false);
          expect(f.run.hasUnavailableSelection, true);
          expect(send(tester).onPressed, isNull);
          await tester.runAsync(f.run.send);
          expect(f.run.phase, 'ready');
          for (final title in ['Server', 'Authentication']) {
            final native = menu(tester, title);
            final available = native.items
                .whereType<BusyApiPopupMenuItem<int>>()
                .firstWhere((i) => i.enabled);
            native.onSelected(available.menuValue);
            await tester.pump();
          }
          expect(f.run.server, 0);
          expect(f.run.securityAlternative, 0);
          expect(send(tester).onPressed, isNotNull);
          expect(f.run.bodyText, 'retained exact draft 雪');

          f.c.store!.replace(
            f.c.root!,
            contract(
              version: version,
              empty: true,
            ).replaceFirst('    post:', '    post:\n      servers: []'),
          );
          await tester.runAsync(() => f.run.open(f.operation));
          await tester.pumpAndSettle();
          expect(f.run.server, 0);
          expect(f.run.securityAlternative, 0);
          expect(find.text('No declared servers'), findsWidgets);
          expect(find.text('Unavailable selection (1)'), findsWidgets);
          expect(send(tester).onPressed, isNull);
          expect(f.file.readAsStringSync(), original);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(f.dispose);
        }
      },
    );

    for (final configured in [false, true]) {
      testWidgets(
        'removed authentication permits explicit no-auth recovery without losing the draft $version environment=$configured',
        (tester) async {
          tester.view.physicalSize = const Size(1100, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final f = _Fixture();
          HttpServer? server;
          final received = <String>[];
          try {
            final observed = <(String?, String?, String?)>[];
            server = await tester.runAsync(() async {
              final bound = await HttpServer.bind(
                InternetAddress.loopbackIPv4,
                0,
              );
              bound.listen((request) async {
                observed.add((
                  request.headers.value('authorization'),
                  request.uri.queryParameters['name'],
                  request.headers.value('x-retained'),
                ));
                received.add(await utf8.decoder.bind(request).join());
                request.response.statusCode = 204;
                await request.response.close();
              });
              return bound;
            });
            final port = server!.port;
            final original = contract(
              version: version,
              parameter: true,
            ).replaceAll('http://127.0.0.1:2', 'http://127.0.0.1:$port');
            await tester.runAsync(
              () => f.open(
                original,
                extraConfiguration: configured
                    ? '''
  retained:
    baseUrl: http://127.0.0.1:$port
    authentication:
      alternative: 1
      schemes:
        access: {tokenRef: 123e4567-e89b-42d3-a456-426614174002}
'''
                    : '',
              ),
            );
            if (configured) f.run.selectEnvironment('retained');
            await f.run.writeSecret(
              '123e4567-e89b-42d3-a456-426614174002',
              'synthetic-retained-credential',
              SecretPersistence.sessionOnly,
            );
            f.run.bodyEnabled = true;
            f.run.bodyMediaType = 'text/plain';
            f.run.server = 1;
            f.run.securityAlternative = 1;
            f.run.bodyText = 'retained exact body 雪';
            f.run.values[OperationRequestDraft.parameterKey('query', 'name')] =
                'retained parameter 😀';
            f.run.headerName = 'X-Retained';
            f.run.headerValue = 'retained header';
            final values = Map<String, String>.of(f.run.values);
            final media = f.run.bodyMediaType;
            final bodyEnabled = f.run.bodyEnabled;
            final changed = contract(
              version: version,
              noAuthentication: true,
              parameter: true,
            ).replaceAll('http://127.0.0.1:2', 'http://127.0.0.1:$port');
            f.c.store!.replace(f.c.root!, changed);
            await tester.runAsync(() => f.run.open(f.operation));
            await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
            expect(f.run.outdated, true);
            expect(f.run.server, 1);
            expect(f.run.securityAlternative, 1);
            expect(send(tester).onPressed, isNull);
            await tester.runAsync(f.run.reconcileDraft);
            await tester.pumpAndSettle();
            expect(f.run.outdated, false);
            expect(f.run.plan!.result['servers'], hasLength(2));
            expect(f.run.plan!.result['security']['requirements'], isEmpty);
            expect(f.run.securityAlternative, 1);
            expect(send(tester).onPressed, isNull);
            final authentication = menu(tester, 'Authentication');
            final missing = authentication.items
                .whereType<BusyApiPopupMenuItem<int>>()
                .singleWhere(
                  (item) => item.label == 'Unavailable selection (2)',
                );
            expect(missing.enabled, false);
            final noAuthentication = authentication.items
                .whereType<BusyApiPopupMenuItem<int>>()
                .singleWhere((item) => item.label == 'No authentication');
            expect(noAuthentication.enabled, true);
            authentication.onSelected(noAuthentication.menuValue);
            await tester.pump();
            expect(f.run.securityAlternative, isNull);
            expect(f.run.hasUnavailableSelection, false);
            expect(send(tester).onPressed, isNotNull);
            expect(f.run.server, 1);
            expect(f.run.bodyText, 'retained exact body 雪');
            expect(f.run.values, values);
            expect(f.run.headerName, 'X-Retained');
            expect(f.run.headerValue, 'retained header');
            expect(f.run.bodyMediaType, media);
            expect(f.run.bodyEnabled, bodyEnabled);
            expect(f.run.phase, 'ready');
            expect(f.run.result, isNull);
            await tester.runAsync(
              () =>
                  HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp()),
            );
            expect(f.run.failure, isNull);
            expect(f.run.result?.response.status, 204);
            expect(received, ['retained exact body 雪']);
            expect(observed, [
              (null, 'retained parameter 😀', 'retained header'),
            ]);
            expect(
              await f.run.secrets.read('123e4567-e89b-42d3-a456-426614174002'),
              'synthetic-retained-credential',
            );
            expect(f.c.buffer!.text, changed);
            expect(f.file.readAsStringSync(), original);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              await server?.close(force: true);
              await f.dispose();
            });
          }
        },
      );
    }
  }

  for (final cancel in [false, true]) {
    testWidgets(
      'expanded request body guards actions through IME ${cancel ? 'cancellation' : 'commit'}',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = _Fixture();
        try {
          await tester.runAsync(() => f.open(contract()));
          f.run.bodyText = 'large value 雪😀\n' * 2000;
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          final body = find.byType(SourceEditor);
          expect(body, findsOneWidget);
          await tester.ensureVisible(body);
          final editable = find.descendant(
            of: body,
            matching: find.byType(EditableText),
          );
          await tester.tapAt(tester.getTopLeft(body) + const Offset(120, 50));
          await tester.showKeyboard(editable);
          final shown = tester.widget<EditableText>(editable).controller.value;
          final expanded = tester.widget<FormValueEditor>(
            find.byType(FormValueEditor),
          );
          final environmentBefore = menu(tester, 'Environment');
          final media =
              (f.run.plan!.result['requestBody']['content'] as List).single
                  as Map;
          tester.testTextInput.updateEditingValue(
            shown.copyWith(
              text: '漢${shown.text}',
              selection: const TextSelection.collapsed(offset: 1),
              composing: const TextRange(start: 0, end: 1),
            ),
          );
          await tester.pump();
          expect(f.run.hasComposingInput, true);
          expect(
            expanded.controller.value.composing.isValid,
            false,
            reason:
                'Expanded SourceEditor publishes its composition separately',
          );
          expect(send(tester).onPressed, isNull);
          expect(menu(tester, 'Environment').enabled, false);
          final draft = f.run.bodyText;
          await tester.runAsync(f.run.send);
          f.run.selectEnvironment('local');
          f.run.useBodyExample(media);
          environmentBefore.onSelected(
            environmentBefore.items
                .whereType<BusyApiPopupMenuItem<int>>()
                .last
                .menuValue,
          );
          expect(f.run.phase, 'ready');
          expect(f.run.environment, isNull);
          expect(f.run.bodyText, draft);
          final composing = tester
              .widget<EditableText>(editable)
              .controller
              .value;
          tester.testTextInput.updateEditingValue(
            cancel ? shown : composing.copyWith(composing: TextRange.empty),
          );
          await tester.pump();
          expect(f.run.hasComposingInput, false);
          expect(send(tester).onPressed, isNotNull);
          expect(menu(tester, 'Environment').enabled, true);
          f.run.useBodyExample(media);
          await tester.pump();
          // H07: a text/plain data example is literal text after IME completes.
          expect(f.run.bodyText, 'explicit example');
          f.run.selectEnvironment('local');
          expect(f.run.environment, 'local');
          expect(f.file.readAsStringSync(), contract());
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(f.dispose);
        }
      },
    );
  }

  testWidgets(
    'response URLs, headers and multiline findings remain selectable at narrow widths',
    (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = _Fixture();
      try {
        await tester.runAsync(() => f.open(contract()));
        final url = 'http://127.0.0.1:1/${'complete-path/' * 30}?exact=雪';
        final header = 'complete header value 雪 ' * 60;
        final diagnostic =
            '${'complete diagnostic line ' * 30}\nsecond line\nfinal diagnostic text';
        final plan = f.run.plan!;
        f.run.result = ContractRequestResult(
          request: PreparedContractRequest(
            runId: 'review',
            plan: plan,
            environment: null,
            method: 'POST',
            uri: Uri.parse(url),
            displayUri: url,
            headers: const [],
            body: null,
            sensitiveHeaders: const {},
            sensitiveQueryNames: const {},
            connectTimeout: const Duration(seconds: 1),
            overallTimeout: const Duration(seconds: 1),
            inactivityTimeout: const Duration(seconds: 1),
            securityAlternative: 0,
            tls: const RequestTlsConfiguration(),
          ),
          response: ContractHttpResponse(
            runId: 'review',
            status: 200,
            reason: 'OK',
            headers: [('x-complete-value', header)],
            bodyFile: '${f.dir.path}/response.bin',
            bodyLength: 0,
            bodyIdentity: '',
            receiptComplete: true,
            elapsed: Duration.zero,
            firstByte: Duration.zero,
            redirects: const [],
            displayBytes: Uint8List(0),
          ),
          outgoing: ContractConformance(
            complete: true,
            valid: false,
            findings: [
              {
                'severity': 'error',
                'code': 'review.multiline',
                'message': diagnostic,
              },
            ],
            producer: 'test',
            producerVersion: '1',
            coverage: const {},
          ),
          received: const ContractConformance(
            complete: true,
            valid: true,
            findings: [],
            producer: 'test',
            producerVersion: '1',
            coverage: {},
          ),
        );
        await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
        for (final text in [url, header, diagnostic]) {
          if (text != url) {
            tester
                .widget<BusyApiComboRow<String>>(
                  find.byWidgetPredicate(
                    (w) =>
                        w is BusyApiComboRow<String> && w.title == 'Responses',
                  ),
                )
                .onSelected(text == header ? 'headers' : 'validation');
            await tester.pump();
          }
          final content = find.byWidgetPredicate(
            (w) => w is SelectableText && w.data == text,
          );
          expect(content, findsOneWidget);
          await tester.ensureVisible(content);
          await tester.pump();
          final widget = tester.widget<SelectableText>(content);
          expect(widget.maxLines, isNull);
          expect(tester.getSize(content).width, lessThanOrEqualTo(500));
          await expectCompleteCopy(tester, content, text);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.dispose);
      }
    },
  );

  testWidgets(
    'completed contract-test findings retain complete selectable multiline diagnostics',
    (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final diagnostic =
          '${'captured contract diagnostic ' * 30}\nsecond line\nlast line remains copyable';
      final f = _Fixture(engine: _RuntimeFindingEngine(diagnostic));
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            request.response.headers.contentType = ContentType.json;
            request.response.write('1');
            await request.response.close();
          });
          await f.open(
            '''
openapi: 3.1.2
info: {title: Contract details, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /pets:
    get:
      responses:
        '200': {description: OK, content: {application/json: {schema: {type: integer}}}}
''',
            extraConfiguration: "tests: [{name: chosen, operation: {method: get, path: /pets}}]",
          );
        });
        final captured = (await tester.runAsync(
          () => f.c.project!.captureContractSnapshot(f.c.root!),
        ))!;
        await tester.pumpWidget(
          host(
            ContractTestsDialog(
              workspace: f.c,
              owner: f.c.project!,
              root: f.c.root!,
              captured: captured,
              configuration: ExecutionConfiguration.parse(
                captured.snapshot.configuration.singleOrNull,
                f.c.project!.access.boundary,
              ),
              secrets: EnvironmentSecretStore(),
            ),
          ),
        );
        await tester.tap(find.text('chosen'));
        await tester.pump();
        await tester.runAsync(() async {
          HttpOverrides.runWithHttpOverrides(() {
            tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(
                    BusyApiDialogButton,
                    'Test selected cases',
                  ),
                )
                .onPressed!
                .call();
          }, _NativeHttp());
        });
        final content = find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == diagnostic,
        );
        final clock = Stopwatch()..start();
        while (content.evaluate().isEmpty &&
            clock.elapsed < const Duration(seconds: 8)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(content, findsOneWidget);
        await tester.ensureVisible(content);
        await tester.pump();
        expect(tester.widget<SelectableText>(content).maxLines, isNull);
        expect(tester.getSize(content).width, lessThanOrEqualTo(500));
        await expectCompleteCopy(tester, content, diagnostic);
        expect(find.textContaining('failed'), findsWidgets);
        expect(find.textContaining('Request dispatched'), findsWidgets);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      'contract case preparation refusal is visibly unsent $version',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = _Fixture();
        HttpServer? endpoint;
        final seen = <String>[];
        late String original;
        try {
          await tester.runAsync(() async {
            endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            endpoint!.listen((request) async {
              seen.add(request.uri.path);
              request.response.statusCode = 204;
              await request.response.close();
            });
            original =
                '''${version == '2.0' ? "swagger: '2.0'" : 'openapi: $version'}
info: {title: Case dispatch, version: '1'}
${version == '2.0' ? "host: '127.0.0.1:${endpoint!.port}'\nschemes: [http]" : "servers: [{url: 'http://127.0.0.1:${endpoint!.port}'}]"}
paths:
  /pets/{id}:
    get:
      parameters:
        - {name: id, in: path, required: true, ${version == '2.0' ? 'type: string' : 'schema: {type: string}'}}
      responses: {'204': {description: ok}}
''';
            await f.open(
              original,
              extraConfiguration: "tests: [{name: missing, operation: {method: get, path: '/pets/{id}'}}]",
            );
          });
          final captured = (await tester.runAsync(
            () => f.c.project!.captureContractSnapshot(f.c.root!),
          ))!;
          await tester.pumpWidget(
            host(
              ContractTestsDialog(
                workspace: f.c,
                owner: f.c.project!,
                root: f.c.root!,
                captured: captured,
                configuration: ExecutionConfiguration.parse(
                  captured.snapshot.configuration.singleOrNull,
                  f.c.project!.access.boundary,
                ),
                secrets: EnvironmentSecretStore(),
              ),
            ),
          );
          await tester.tap(find.text('missing'));
          await tester.pump();
          await tester.runAsync(() async {
            HttpOverrides.runWithHttpOverrides(
              () => tester
                  .widget<BusyApiDialogButton>(
                    find.widgetWithText(
                      BusyApiDialogButton,
                      'Test selected cases',
                    ),
                  )
                  .onPressed!
                  .call(),
              _NativeHttp(),
            );
          });
          final unsent = find.textContaining('Request not sent');
          final clock = Stopwatch()..start();
          while (unsent.evaluate().isEmpty &&
              clock.elapsed < const Duration(seconds: 8)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          expect(unsent, findsOneWidget);
          expect(
            find.textContaining('0 dispatched operations; 1 untested.'),
            findsOneWidget,
          );
          expect(seen, isEmpty);
          expect(f.file.readAsStringSync(), original);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await endpoint?.close(force: true);
            await f.dispose();
          });
        }
      },
    );
  }

  testWidgets(
    'H02 H06 H07 H11 H21 real draft actions preserve literal requests and fresh defaults',
    (tester) async {
      final f = _Fixture();
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final received = <String>[];
          server!.listen((request) async {
            received.add(
              utf8.decode(
                await request.fold<List<int>>([], (a, b) => a..addAll(b)),
              ),
            );
            request.response.statusCode = 204;
            await request.response.close();
          });
          await f.open('''
openapi: 3.2.1
info: {title: Drafts, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /pets:
    post:
      parameters: [{name: tag, in: query, schema: {type: string}}]
      requestBody:
        required: true
        content:
          text/plain: {schema: {}, example: hello}
          application/x-www-form-urlencoded: {schema: {}}
          multipart/form-data: {schema: {}}
      responses: {'204': {description: ok}}
''');
          expect(f.run.bodyEnabled, isTrue);
          expect(f.run.bodyMediaType, 'text/plain');
          final file = File('${f.dir.path}/file.bin')
            ..writeAsStringSync('file-A');
          f.run.addBodyFile(XFile(file.path));
          expect(f.run.bodyKind, RequestBodyKind.binaryFile);
          final media = (f.run.plan!.result['requestBody']['content'] as List)
              .whereType<Map>()
              .first;
          f.run.useBodyExample(media);
          expect(f.run.bodyFiles, isEmpty);
          await HttpOverrides.runWithHttpOverrides(
            () => Future.wait([f.run.send(), f.run.send()]),
            _NativeHttp(),
          );
          expect(received, ['hello']);
          f.run.selectBodyMedia('application/x-www-form-urlencoded');
          f.run.bodyText = 'note=a&admin=true\nempty=\nnote= a=b%26雪 ';
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          expect(
            received.last,
            'note=a%26admin%3Dtrue&empty=&note=+a%3Db%2526%E9%9B%AA+',
          );
          final key = OperationRequestDraft.parameterKey('query', 'tag');
          f.run.values[key] = 'kept';
          f.run.omittedValues.add(key);
          expect(f.run.draft().parameters.containsKey(key), isFalse);
          f.run.omittedValues.remove(key);
          f.run.values[key] = '';
          expect(f.run.draft().parameters[key]!.present, isTrue);
          final previous = f.run.result;
          await f.run.open({
            ...f.operation,
            'pointer': '/paths/~1not-found/post',
          });
          expect(f.run.failureMessage, isNotEmpty);
          expect(identical(f.run.result, previous), isTrue);
          expect(previous!.request.plan.closed, isFalse);
          await f.run.open(f.operation);
          expect(identical(f.run.result, previous), isTrue);

          f.run.selectEnvironment('local');
          expect(f.run.bodyEnabled, isTrue);
          expect(f.run.bodyMediaType, 'text/plain');
          f.run.discardDraft();
          expect(f.run.bodyEnabled, isTrue);
          expect(f.run.bodyMediaType, 'text/plain');
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      'F08 native structured form controls retain drafts and send exact values $version',
      (tester) async {
        tester.view.physicalSize = const Size(1500, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = _Fixture();
        HttpServer? endpoint;
        final received = <(String, String, String)>[];
        late String original;
        try {
          await tester.runAsync(() async {
            endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            endpoint!.listen((request) async {
              received.add((
                request.method,
                request.uri.toString(),
                await utf8.decoder.bind(request).join(),
              ));
              request.response.statusCode = 204;
              await request.response.close();
            });
            original = version == '2.0'
                ? '''swagger: '2.0'
info: {title: Native form, version: '1'}
host: 127.0.0.1:${endpoint!.port}
schemes: [http]
consumes: [application/x-www-form-urlencoded]
paths:
  /form:
    post:
      parameters:
        - {in: formData, name: n, type: integer, required: true}
        - {in: formData, name: flag, type: boolean, required: true}
        - {in: formData, name: empty, type: string, required: true, allowEmptyValue: true}
      responses: {'204': {description: ok}}
'''
                : '''openapi: $version
info: {title: Native form, version: '1'}
servers: [{url: 'http://127.0.0.1:${endpoint!.port}'}]
paths:
  /form:
    post:
      requestBody:
        required: true
        content:
          application/x-www-form-urlencoded:
            schema: {type: object, required: [n, flag, empty], properties: {n: {type: integer}, flag: {type: boolean}, empty: {type: string}}}
      responses: {'204': {description: ok}}
''';
            await f.open(original);
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: RequestRunPanel(run: f.run)),
            ),
          );
          final toggle = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiSwitchRow &&
                widget.title == 'Use an exact JSON value',
          );
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(f.run.bodyStructured, isTrue);
          final entry = find.byWidgetPredicate(
            (widget) =>
                widget is RequestDraftEntry &&
                widget.label == 'Use an exact JSON value',
          );
          final input = find.descendant(
            of: entry,
            matching: find.byType(TextFormField),
          );
          await tester.ensureVisible(input);
          const data = '{"n":9007199254740993,"flag":false,"empty":""}';
          await tester.enterText(input, data);
          expect(f.run.bodyText, data);
          f.run.selectEnvironment('local');
          f.run.selectEnvironment(null);
          await tester.pumpAndSettle();
          expect(f.run.bodyStructured, isTrue);
          expect(f.run.bodyText, data);
          expect(f.run.draft().body.text, data);
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp()),
          );
          expect(f.run.failure, isNull, reason: f.run.failureMessage);
          expect(received, [
            ('POST', '/form', 'n=9007199254740993&flag=false&empty='),
          ]);
          expect(f.run.result!.outgoing.complete, isTrue);
          expect(
            f.run.result!.outgoing.valid,
            isTrue,
            reason: '${f.run.result!.outgoing.findings}',
          );
          expect(f.file.readAsStringSync(), original);
          expect(f.c.buffer!.text, original);
          if (version == '2.0') {
            await tester.runAsync(() async {
              f.c.sourceEdit(
                f.c.active!,
                original.replaceFirst(
                  'allowEmptyValue: true',
                  'allowEmptyValue: false',
                ),
              );
              await f.c.analyse();
              await f.run.reconcileDraft();
              await HttpOverrides.runWithHttpOverrides(
                f.run.send,
                _NativeHttp(),
              );
            });
            expect(f.run.failure, isNull, reason: f.run.failureMessage);
            expect(received, [
              ('POST', '/form', 'n=9007199254740993&flag=false&empty='),
              ('POST', '/form', 'n=9007199254740993&flag=false&empty='),
            ]);
            expect(f.run.bodyText, data);
            expect(f.run.result!.outgoing.complete, isTrue);
            expect(f.run.result!.outgoing.valid, isFalse);
            expect(
              f.run.result!.outgoing.findings.any(
                (finding) => finding['code'] == 'runtime.request.form.empty',
              ),
              isTrue,
            );
            expect(f.file.readAsStringSync(), original);
          }
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await endpoint?.close(force: true);
            await f.dispose();
          });
        }
      },
    );
  }

  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      'F10 native multipart controls encode captured files and preserve encoded JSON strings $version',
      (tester) async {
        tester.view.physicalSize = const Size(1500, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = _Fixture();
        HttpServer? server;
        final seen = <String>[];
        late String original;
        try {
          await tester.runAsync(() async {
            server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server!.listen((request) async {
              expect(request.method, 'POST');
              expect(request.uri.path, '/upload');
              seen.add(await utf8.decoder.bind(request).join());
              request.response.statusCode = 204;
              await request.response.close();
            });
            final encoded = version.startsWith('3.0.')
                ? '{type: string, format: byte}'
                : '{type: string, contentEncoding: base64}';
            original =
                '''# Native MIME data and raw file inputs
openapi: $version
info: {title: MIME, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths:
  /upload:
    post:
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema: {type: object, properties: {encoded: $encoded, file: $encoded, json: {type: object}}}
            encoding:
              json:
                contentType: application/json
                headers: {Content-Transfer-Encoding: {\$ref: '#/components/headers/Transfer'}}
      responses: {'204': {description: ok}}
components:
  headers:
    Transfer: {schema: {type: string, enum: [base64]}}
''';
            await f.open(original);
          });
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          final toggle = find.byWidgetPredicate(
            (widget) =>
                widget is BusyApiSwitchRow &&
                widget.title == 'Use an exact JSON value',
          );
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          final entry = find.byWidgetPredicate(
            (widget) =>
                widget is RequestDraftEntry &&
                widget.label == 'Use an exact JSON value',
          );
          final input = find.descendant(
            of: entry,
            matching: find.byType(TextFormField),
          );
          await tester.ensureVisible(input);
          await tester.enterText(
            input,
            '{"encoded":"Zg==","json":{"n":9007199254740993}}',
          );
          await tester.runAsync(() async {
            final upload = File('${f.dir.path}/file.bin');
            await upload.writeAsBytes([0, 255, 1]);
            f.run.bodyFilePart = 'file';
            f.run.addBodyFile(XFile(upload.path));
            await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          });
          expect(f.run.failure, isNull, reason: f.run.failureMessage);
          expect(
            seen.single,
            contains(
              'name="encoded"\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\nZg==\r\n',
            ),
          );
          expect(
            seen.single,
            contains(
              'Content-Type: application/json\r\nContent-Transfer-Encoding: base64\r\n\r\n${base64.encode(utf8.encode('{"n":9007199254740993}'))}\r\n',
            ),
          );
          expect(
            seen.single,
            contains(
              'filename="file.bin"\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\nAP8B\r\n',
            ),
          );
          expect(f.run.result!.outgoing.complete, isTrue);
          expect(f.run.result!.outgoing.valid, isTrue);
          expect(f.file.readAsStringSync(), original);
          expect(f.c.buffer!.text, original);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await server?.close(force: true);
            await f.dispose();
          });
        }
      },
    );
  }

  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      'F09 native part media controls retain explicit choices and reject changed declarations $version',
      (tester) async {
        tester.view.physicalSize = const Size(1500, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final f = _Fixture();
        HttpServer? endpoint;
        final received = <String>[];
        late String original;
        try {
          await tester.runAsync(() async {
            endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            endpoint!.listen((request) async {
              received.add(await utf8.decoder.bind(request).join());
              request.response.statusCode = 204;
              await request.response.close();
            });
            original =
                '''# Retain native form source
openapi: $version
info: {title: Part controls, version: '1'}
servers: [{url: 'http://127.0.0.1:${endpoint!.port}'}]
paths:
  /form:
    post:
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [value, other]
              properties:
                value: {type: string}
                other: {type: string}
                image: {type: array, items: ${version.startsWith('3.0.') ? '{type: string, format: binary}' : '{}'}}
            encoding:
              value: {contentType: 'application/json, text/plain'}
              other: {contentType: 'text/*'}
              image: {contentType: 'image/*'}
      responses: {'204': {description: ok}}
''';
            await f.open(original);
          });
          f.run.bodyText = 'value=雪+&\nother=hello';
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          final disclosure = find.widgetWithText(
            BusyApiDisclosure,
            'Declared form parts',
          );
          final disclosureButton = find
              .descendant(of: disclosure, matching: find.byType(TextButton))
              .first;
          await tester.ensureVisible(disclosureButton);
          await tester.tap(disclosureButton);
          await tester.pumpAndSettle();
          final choices = menu(tester, 'value · Content-Type');
          final plain = choices.items
              .whereType<BusyApiPopupMenuItem<int>>()
              .singleWhere((item) => item.label == 'text/plain');
          choices.onSelected(plain.menuValue);
          await tester.pumpAndSettle();
          final range = find.byWidgetPredicate(
            (widget) =>
                widget is RequestDraftEntry &&
                widget.label == 'other · Concrete Content-Type',
          );
          final rangeInput = find.descendant(
            of: range,
            matching: find.byType(TextFormField),
          );
          await tester.ensureVisible(rangeInput);
          await tester.enterText(rangeInput, 'text/plain; charset=utf-8');
          await tester.pumpAndSettle();
          f.run.selectEnvironment('local');
          f.run.selectEnvironment(null);
          await tester.pumpAndSettle();
          expect(f.run.partMediaTypes, {
            'value': 'text/plain',
            'other': 'text/plain; charset=utf-8',
          });
          expect(f.run.draft().body.partMediaTypes, f.run.partMediaTypes);
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp()),
          );
          expect(f.run.failure, isNull, reason: f.run.failureMessage);
          expect(
            received.single,
            contains('name="value"\r\nContent-Type: text/plain\r\n\r\n雪+&\r\n'),
          );
          expect(
            received.single,
            contains(
              'name="other"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n',
            ),
          );
          expect(f.run.result!.outgoing.complete, isTrue);
          expect(f.run.result!.outgoing.valid, isTrue);
          final binary = File('${f.dir.path}/upload.bin');
          await tester.runAsync(() => binary.writeAsBytes([0, 255, 128]));
          f.run.bodyFilePart = 'image';
          f.run.addBodyFile(XFile(binary.path, name: 'upload.bin'));
          await tester.pumpAndSettle();
          final fileChoice = find.byWidgetPredicate(
            (widget) =>
                widget is RequestDraftEntry &&
                widget.label == 'image · upload.bin · Concrete Content-Type',
          );
          final fileInput = find.descendant(
            of: fileChoice,
            matching: find.byType(TextFormField),
          );
          if (fileInput.evaluate().isEmpty) {
            await tester.ensureVisible(disclosureButton);
            await tester.tap(disclosureButton);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(fileInput);
          await tester.enterText(fileInput, 'image/png');
          await tester.pumpAndSettle();
          expect(
            f.run.draft().body.files.single.selectedMediaType,
            'image/png',
          );
          f.run.selectEnvironment('local');
          f.run.selectEnvironment(null);
          await tester.pumpAndSettle();
          expect(f.run.bodyFiles.single.selectedMediaType, 'image/png');
          await tester.runAsync(() async {
            f.c.sourceEdit(
              f.c.active!,
              original.replaceFirst(
                'application/json, text/plain',
                'application/json',
              ),
            );
            await f.c.analyse();
            await f.run.reconcileDraft();
            await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          });
          expect(f.run.partMediaTypes['value'], 'text/plain');
          expect(f.run.failure, 'request.form.content-type');
          expect(received, hasLength(1));
          expect(f.run.bodyText, 'value=雪+&\nother=hello');
          expect(f.file.readAsStringSync(), original);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await endpoint?.close(force: true);
            await f.dispose();
          });
        }
      },
    );
  }

  testWidgets(
    'H07 real example actions preserve data media and serialization layers on the wire',
    (tester) async {
      final f = _Fixture();
      HttpServer? endpoint;
      final observed = <(String, String, String)>[];
      try {
        await tester.runAsync(() async {
          endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          endpoint!.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            observed.add((
              request.uri.toString(),
              request.headers.contentType.toString(),
              utf8.decode(bytes),
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          await f.open('''openapi: 3.2.1
info: {title: Example layers, version: '1'}
x-colors: &colors [one, two]
x-fields: &fields {tag: *colors, n: 1.0000000000000000001}
servers: [{url: 'http://127.0.0.1:${endpoint!.port}'}]
paths:
  /items/{id}/details:
    post:
      parameters:
        - name: id
          in: path
          required: true
          schema: {type: string}
          examples: {encoded: {serializedValue: 'a%2Fb%23c'}}
        - name: tag
          in: query
          schema: {type: array, items: {type: string}}
          examples: {repeated: {serializedValue: 'tag=one&tag=two'}}
        - name: q
          in: query
          content:
            application/json: {schema: {}, examples: {media: {serializedValue: '"from media"'}}}
          examples: {parameter: {serializedValue: 'q=%22from%20parameter%22'}}
        - name: foreign
          in: query
          content: {application/xml: {schema: {}, examples: {unsupported: {dataValue: {id: 1}}}}}
      requestBody:
        content:
          application/json:
            schema: {}
            examples:
              object: {dataValue: {id: 9007199254740993, exact: 1.0000000000000000001, nested: {\$ref: literal}}}
              string: {dataValue: hello}
          text/plain: {schema: {}, examples: {literal: {dataValue: hello}, serialized: {serializedValue: 'one,two'}}}
          'Application/JSON; charset=utf-8': {schema: {}, examples: {upper: {dataValue: hello}}}
          application/x-www-form-urlencoded: {schema: {}, examples: {aliased: {dataValue: *fields}, fields: {dataValue: {note: 'fish&chips', empty: '', tag: [one, two]}}, nested: {dataValue: {note: {inner: value}}}}}
          multipart/form-data:
            schema: {}
            encoding: {metadata: {contentType: application/json}}
            examples: {aliasedParts: {dataValue: *fields}, parts: {dataValue: {metadata: hello, note: 'a&admin=true'}}}
      responses: {'204': {description: ok}}
''');
          for (final parameter
              in (f.run.plan!.result['parameters'] as List).cast<Map>()) {
            f.run.useExample(parameter);
          }
          expect(f.run.failure, 'request.example.conversion');
          expect(
            f.run.values.containsKey(
              OperationRequestDraft.parameterKey('query', 'foreign'),
            ),
            isFalse,
          );
          final media = (f.run.plan!.result['requestBody']['content'] as List)
              .cast<Map>();
          for (final declaration in media) {
            for (final example
                in (declaration['examples'] as List).cast<Map>()) {
              f.run.useBodyExample({...declaration, 'example': example});
              if (declaration['mediaType'] ==
                      'application/x-www-form-urlencoded' ||
                  declaration['mediaType'] == 'multipart/form-data') {
                expect(f.run.bodyStructured, isTrue);
                expect(f.run.bodyText, example['raw']);
              }
              await HttpOverrides.runWithHttpOverrides(
                f.run.send,
                _NativeHttp(),
              );
              expect(f.run.failure, isNull, reason: f.run.failureMessage);
              expect(
                observed.last.$1,
                '/items/a%2Fb%23c/details?tag=one&tag=two&q=%22from%20parameter%22',
              );
              switch (example['name']) {
                case 'object':
                  expect(observed.last.$3, contains('9007199254740993'));
                  expect(observed.last.$3, contains('1.0000000000000000001'));
                  expect(
                    observed.last.$3,
                    contains('"nested":{"\$ref":"literal"}'),
                  );
                case 'string':
                case 'upper':
                  expect(observed.last.$3, '"hello"');
                case 'literal':
                  expect(observed.last.$3, 'hello');
                case 'serialized':
                  expect(observed.last.$3, 'one,two');
                case 'aliased':
                  expect(
                    observed.last.$3,
                    'tag=one&tag=two&n=1.0000000000000000001',
                  );
                case 'aliasedParts':
                  expect(
                    RegExp('name="tag"').allMatches(observed.last.$3),
                    hasLength(2),
                  );
                  expect(observed.last.$3, contains('\r\n\r\none\r\n'));
                  expect(observed.last.$3, contains('\r\n\r\ntwo\r\n'));
                  expect(observed.last.$3, contains('1.0000000000000000001'));
                case 'fields':
                  expect(
                    observed.last.$3,
                    'note=fish%26chips&empty=&tag=one&tag=two',
                  );
                case 'nested':
                  expect(
                    observed.last.$3,
                    'note=%7B%22inner%22%3A%22value%22%7D',
                  );
                case 'parts':
                  expect(
                    observed.last.$3,
                    contains(
                      'Content-Type: application/json\r\n\r\n"hello"\r\n',
                    ),
                  );
                  expect(observed.last.$3, contains('a&admin=true'));
              }
            }
          }
          final q = (f.run.plan!.result['parameters'] as List)
              .cast<Map>()
              .singleWhere((p) => p['name'] == 'q');
          final mediaExample =
              ((q['content'] as List).single['examples'] as List).single as Map;
          for (final example in [
            mediaExample,
            (q['examples'] as List).single as Map,
          ]) {
            f.run.useExample({...q, 'example': example});
            await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
            expect(
              observed.last.$1,
              endsWith(
                example['level'] == 'media'
                    ? '&q=%22from%20media%22'
                    : '&q=%22from%20parameter%22',
              ),
            );
          }
        });
      } finally {
        await tester.runAsync(() async {
          await endpoint?.close(force: true);
          await f.dispose();
        });
      }
    },
  );

  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    testWidgets(
      '$version literal media Use example preserves actual request bytes',
      (tester) async {
        final f = _Fixture();
        HttpServer? endpoint;
        const wire = 'id=9007199254740993&flag=false&empty=&text=%E9%9B%AA';
        final observed = <(String, String, String?, List<int>)>[];
        try {
          await tester.runAsync(() async {
            endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            endpoint!.listen((request) async {
              observed.add((
                request.method,
                request.uri.toString(),
                request.headers.value('content-type'),
                await request.fold<List<int>>(
                  [],
                  (all, part) => all..addAll(part),
                ),
              ));
              request.response.statusCode = 204;
              await request.response.close();
            });
            await f.open('''openapi: $version
info: {title: Literal media, version: '1'}
servers: [{url: 'http://127.0.0.1:${endpoint!.port}'}]
paths:
  /items:
    post:
      requestBody:
        content:
          application/x-www-form-urlencoded:
            schema: {type: object}
            examples: {Literal: {value: '$wire'}}
      responses: {'204': {description: None}}
''');
          });
          final original = f.file.readAsStringSync();
          final media =
              (f.run.plan!.result['requestBody']['content'] as List).single
                  as Map;
          f.run.useBodyExample(media);
          expect(f.run.bodyText, wire);
          expect(f.run.bodyStructured, isFalse);
          await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
          await tester.pump();
          expect(
            find.byWidgetPredicate(
              (w) => w is RequestDraftEntry && w.value == wire,
            ),
            findsOneWidget,
          );
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp()),
          );
          expect(f.run.failure, isNull, reason: f.run.failureMessage);
          expect(observed, hasLength(1));
          expect(observed.single.$1, 'POST');
          expect(observed.single.$2, '/items');
          expect(observed.single.$3, 'application/x-www-form-urlencoded');
          expect(observed.single.$4, utf8.encode(wire));
          expect(f.file.readAsStringSync(), original);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await endpoint?.close(force: true);
            await f.dispose();
          });
        }
      },
    );
  }

  testWidgets(
    'U7 native tool components retain reachable controls at narrow widths and large text in both appearances',
    (tester) async {
      tester.view.physicalSize = const Size(620, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = _Fixture();
      try {
        await tester.runAsync(
          () => f.open(contract(noAuthentication: true, parameter: true)),
        );
        f.run.bodyText = 'long literal 雪 ' * 200;
        f.run.customHeaders.addAll([
          const RequestHeaderValue('Idempotency-Key', 'synthetic-id'),
          const RequestHeaderValue('X-Trace', 'synthetic-trace'),
        ]);
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            host(
              RequestRunPanel(run: f.run),
              brightness: brightness,
              textScale: 1.75,
            ),
          );
          await tester.pump();
          // Locate by the controlled draft value rather than a translated label.
          final editor = find.byWidgetPredicate(
            (w) => w is RequestDraftEntry && w.value == f.run.bodyText,
          );
          expect(editor, findsOneWidget);
          await tester.ensureVisible(editor);
          await tester.pump();
          expect(tester.getSize(editor).width, lessThanOrEqualTo(620));
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.dispose);
      }
    },
  );

  testWidgets(
    'H03 semantic reorder and replacement cannot silently change destinations',
    (tester) async {
      final f = _Fixture();
      try {
        await tester.runAsync(() async {
          final source = contract(noAuthentication: true);
          await f.open(source);
          f.run.server = 0;
          f.run.bodyText = 'retained';
          final reordered = source.replaceFirst(
            '[{url: "http://127.0.0.1:1"}, {url: "http://127.0.0.1:2"}]',
            '[{url: "http://127.0.0.1:2"}, {url: "http://127.0.0.1:1"}]',
          );
          f.c.store!.replace(f.c.root!, reordered);
          await f.run.reconcileDraft();
          expect(f.run.server, 1);
          expect(f.run.hasUnavailableSelection, isFalse);
          expect(f.run.bodyText, 'retained');
          final retained = await const ContractRequestBuilder().build(
            f.run.plan!,
            f.run.draft(),
            previewOnly: true,
            resolveSecret: (_) async =>
                throw StateError('Preview must not read secrets'),
          );
          expect(retained.uri.toString(), 'http://127.0.0.1:1/pets');
          f.c.store!.replace(
            f.c.root!,
            reordered.replaceAll('http://127.0.0.1:1', 'http://127.0.0.1:3'),
          );
          await f.run.reconcileDraft();
          expect(f.run.hasUnavailableSelection, isTrue);
          expect(f.run.canSend, isFalse);
          expect(f.run.bodyText, 'retained');
          f.run.server = 1; // Explicitly select the replacement declaration.
          var inserted = reordered
              .replaceAll('http://127.0.0.1:1', 'http://127.0.0.1:3')
              .replaceFirst('[{url:', '[{url: "http://127.0.0.1:4"}, {url:');
          f.c.store!.replace(f.c.root!, inserted);
          await f.run.reconcileDraft();
          expect(f.run.server, 2);
          final replacement = await const ContractRequestBuilder().build(
            f.run.plan!,
            f.run.draft(),
            previewOnly: true,
            resolveSecret: (_) async => null,
          );
          expect(replacement.uri.port, 3);
          inserted = inserted.replaceFirst(
            'http://127.0.0.1:4',
            'http://127.0.0.1:3',
          );
          f.c.store!.replace(f.c.root!, inserted);
          await f.run.reconcileDraft();
          expect(
            f.run.server,
            -1,
            reason: 'Duplicate semantic matches need an explicit choice.',
          );
        });
      } finally {
        await tester.runAsync(f.dispose);
      }
    },
  );

  testWidgets(
    'H03 relative retrieval and environment overrides retain destination authority',
    (tester) async {
      final f = _Fixture();
      try {
        await tester.runAsync(() async {
          await f.open(
            contract(noAuthentication: true).replaceFirst(
              '[{url: "http://127.0.0.1:1"}, {url: "http://127.0.0.1:2"}]',
              '[{url: "../api"}]',
            ),
            extraConfiguration: 'resourceMappings: {"http://127.0.0.1:8021/spec/openapi.yaml": openapi.yaml}',
          );
          f.run.bodyText = 'retained relative draft';
          Future<Uri> destination() async =>
              (await const ContractRequestBuilder().build(
                f.run.plan!,
                f.run.draft(),
                previewOnly: true,
                resolveSecret: (_) async => null,
              )).uri;
          expect(
            (await destination()).toString(),
            'http://127.0.0.1:8021/api/pets',
          );
          final manifest = Uri.file('${f.dir.path}/busyapi.yaml').toString();
          final buffer = await f.c.project!.buffer(manifest);
          f.c.store!.replace(
            manifest,
            buffer.text.replaceFirst(':8021/', ':8022/'),
          );
          await f.run.reconcileDraft();
          expect(f.run.server, -1);
          f.run.server = 0;
          expect(
            (await destination()).toString(),
            'http://127.0.0.1:8022/api/pets',
          );
          f.run.selectEnvironment('local');
          expect((await destination()).port, 1);
          f.run.bodyText = 'retained overridden draft';
          f.c.store!.replace(
            manifest,
            buffer.text.replaceFirst(':1\'', ':3\''),
          );
          await f.run.reconcileDraft();
          expect(f.run.server, -1);
          expect(f.run.canSend, false);
          f.run.server = 0;
          expect((await destination()).port, 3);
          expect(f.run.bodyText, 'retained overridden draft');
        });
      } finally {
        await tester.runAsync(f.dispose);
      }
    },
  );

  testWidgets(
    'H03 ambiguous alternatives changed scopes and server defaults require deliberate choices',
    (tester) async {
      final f = _Fixture();
      try {
        await tester.runAsync(() async {
          const source = '''openapi: 3.2.1
info: {title: Semantic selection, version: '1'}
servers: [{url: 'https://{region}.example.test', variables: {region: {default: dev}}}]
security: [{oauth: [read]}, {}]
components:
  securitySchemes:
    oauth: {type: oauth2, flows: {clientCredentials: {tokenUrl: https://auth.example.test/token, scopes: {read: Read, write: Write}}}}
paths: {/pets: {get: {responses: {'204': {description: ok}}}}}
''';
          await f.open(source);
          f.run.securityAlternative = 0;
          f.run.values['query\u0000kept'] = 'retained';
          var current = source.replaceFirst(
            'security: [{oauth: [read]}, {}]',
            'security: [{}, {oauth: [read]}]',
          );
          f.c.store!.replace(f.c.root!, current);
          await f.run.reconcileDraft();
          expect(f.run.securityAlternative, 1);
          expect(f.run.hasUnavailableSelection, isFalse);
          current = current.replaceFirst(
            'read: Read',
            'read: Updated description',
          );
          f.c.store!.replace(f.c.root!, current);
          await f.run.reconcileDraft();
          expect(f.run.securityAlternative, 1);
          expect(f.run.hasUnavailableSelection, isFalse);
          current = current.replaceFirst('oauth: [read]', 'oauth: [write]');
          f.c.store!.replace(f.c.root!, current);
          await f.run.reconcileDraft();
          expect(f.run.hasUnavailableSelection, isTrue);
          f.run.securityAlternative = 1; // Explicit current choice.
          current = current.replaceFirst(
            'security: [{}, {oauth: [write]}]',
            'security: [{oauth: [write]}, {oauth: [write]}]',
          );
          f.c.store!.replace(f.c.root!, current);
          await f.run.reconcileDraft();
          expect(f.run.hasUnavailableSelection, isTrue);
          f.run.securityAlternative = 0;
          current = current.replaceFirst('default: dev', 'default: production');
          f.c.store!.replace(f.c.root!, current);
          await f.run.reconcileDraft();
          expect(f.run.server, -1);
          expect(f.run.canSend, isFalse);
          expect(f.run.values['query\u0000kept'], 'retained');
        });
      } finally {
        await tester.runAsync(f.dispose);
      }
    },
  );

  testWidgets(
    'H12 changing roots retires the run owner and retains that roots draft',
    (tester) async {
      final f = _Fixture();
      try {
        await tester.runAsync(() async {
          final other = File('${f.dir.path}/other.yaml')
            ..writeAsStringSync(contract(noAuthentication: true));
          await f.open(
            contract(noAuthentication: true),
            roots: '[{name: api, path: openapi.yaml}, {name: other, path: other.yaml}]',
          );
          await f.c.open(f.dir.path);
          await f.c.selectRoot(f.file.uri.toString());
          await f.c.analyse();
          f.operation = Map<String, dynamic>.from(
            (f.c.projection!['operations'] as List).single as Map,
          );
          await f.run.open(f.operation);
          f.run.bodyText = 'owned by original root';
          final captured = f.run.plan!;
          expect(await f.c.selectRoot(other.uri.toString()), isTrue);
          expect(f.run.canSend, isFalse);
          expect(f.run.phase, 'idle');
          expect(captured.closed, isTrue);
          expect(await f.c.selectRoot(f.file.uri.toString()), isTrue);
          await f.run.open(f.operation);
          expect(f.run.bodyText, 'owned by original root');
          expect(f.run.canSend, isTrue);
        });
      } finally {
        await tester.runAsync(f.dispose);
      }
    },
  );

  testWidgets(
    'H12 cancellation after receipt discards a gated late evaluator result',
    (tester) async {
      final f = (await tester.runAsync(
        () async => _Fixture(engine: _GateResponseEngine()),
      ))!;
      // Use the single fixture-owned engine for all plan/evaluator work.
      final owned = f.engine as _GateResponseEngine;
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"id":1}');
            await request.response.close();
          });
          await f.open('''
openapi: 3.2.1
info: {title: Cancellation, version: '1'}
servers: [{url: 'http://127.0.0.1:${server!.port}'}]
paths: {/pets: {get: {responses: {'200': {description: ok, content: {application/json: {schema: {type: object}}}}}}}}
''');
          final sending = HttpOverrides.runWithHttpOverrides(
            f.run.send,
            _NativeHttp(),
          );
          expect(f.run.canSend || f.run.busy, isTrue);
          await Future.any([
            owned.received.future,
            sending.then(
              (_) => throw StateError(
                'Run ended before response evaluation: ${f.run.phase} ${f.run.failure}',
              ),
            ),
          ]).timeout(const Duration(seconds: 10));
          f.run.cancel();
          await sending;
          expect(f.run.phase, 'cancelled');
          expect(f.run.result!.response.receiptComplete, isTrue);
          expect(f.run.result!.conforming, isFalse);
          expect(f.run.history.single.conforming, isFalse);
          owned.release.complete();
          await owned.finished.future;
          expect(f.run.phase, 'cancelled');
          expect(f.run.history.single.conforming, isFalse);
        });
      } finally {
        if (!owned.release.isCompleted) owned.release.complete();
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );
  testWidgets(
    'H19 encrypted TLS key password is usable through session UI without HTTP authentication',
    (tester) async {
      final f = _Fixture();
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          await f.open('''
openapi: 3.2.1
info: {title: TLS UI, version: '1'}
security: []
paths: {/secure: {get: {responses: {'204': {description: ok}}}}}
''');
          final generated = await Process.run('openssl', [
            'req',
            '-x509',
            '-newkey',
            'rsa:2048',
            '-keyout',
            'key.pem',
            '-out',
            'cert.pem',
            '-days',
            '1',
            '-subj',
            '/CN=BusyAPI fixture',
            '-addext',
            'subjectAltName=IP:127.0.0.1',
            '-passout',
            'pass:synthetic-password',
          ], workingDirectory: f.dir.path);
          expect(generated.exitCode, 0);
          final context = SecurityContext(withTrustedRoots: false)
            ..useCertificateChain('${f.dir.path}/cert.pem')
            ..usePrivateKey(
              '${f.dir.path}/key.pem',
              password: 'synthetic-password',
            )
            ..setTrustedCertificates('${f.dir.path}/cert.pem');
          server = await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            context,
            requestClientCertificate: true,
          );
          server!.listen((request) async {
            expect(request.certificate, isNotNull);
            request.response.statusCode = 204;
            await request.response.close();
          });
          File('${f.dir.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  local:
    baseUrl: https://127.0.0.1:${server!.port}
    tls:
      caFile: cert.pem
      clientCertificateFile: cert.pem
      clientKeyFile: key.pem
      clientKeyPasswordRef: 123e4567-e89b-42d3-a456-426614174000
''');
          await f.run.reconcileDraft();
          f.run.selectEnvironment('local');
        });
        await tester.pumpWidget(host(RequestRunPanel(run: f.run)));
        expect(find.byType(RequestSecretInput), findsOneWidget);
        expect(find.text('TLS private-key password · local'), findsOneWidget);
        final entry = find.byWidgetPredicate(
          (w) => w is BusyApiGroupedTextEntry && w.label == 'Credential value',
        );
        await tester.ensureVisible(entry);
        await tester.enterText(
          find.descendant(of: entry, matching: find.byType(TextField)),
          'synthetic-password',
        );
        await tester
            .pump(); // Rebuild the explicit session action after editing.
        final session = find.byWidgetPredicate(
          (w) => w is BusyApiActionRow && w.title == 'Use for this session',
        );
        await tester.ensureVisible(session);
        late Completer<void> saved;
        void changed() {
          if (f.run.canSend && !saved.isCompleted) saved.complete();
        }

        await tester.runAsync(() async {
          saved = Completer<void>();
          f.run.addListener(changed);
        });
        try {
          await tester.tap(session);
          await tester.pump();
          await tester.runAsync(() async {
            await saved.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                fail(
                  'TLS credential not ready: phase=${f.run.phase}, pending=${f.run.hasPendingSecretInput}, selection=${f.run.hasUnavailableSelection}, required=${f.run.requiredInputMissing}, secret=${f.run.secrets.status('123e4567-e89b-42d3-a456-426614174000')}',
                );
              },
            );
            await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
          });
        } finally {
          f.run.removeListener(changed);
        }
        expect(
          f.run.result?.response.status,
          204,
          reason: f.run.failureMessage,
        );
        expect(f.run.result?.conforming, isTrue);
        final retained = f.run.result;
        await tester.runAsync(() async {
          await f.run.writeSecret(
            '123e4567-e89b-42d3-a456-426614174000',
            'wrong-password',
            SecretPersistence.sessionOnly,
          );
          await HttpOverrides.runWithHttpOverrides(f.run.send, _NativeHttp());
        });
        expect(f.run.failure, 'request.tls.material');
        expect(identical(f.run.result, retained), isTrue);
        expect(f.run.history.length, 1);
        await tester.runAsync(() async {
          f.run.tlsFiles.addAll({
            'clientCertificateFile': '',
            'clientKeyFile': '',
          });
          var reads = 0;
          final prepared = await const ContractRequestBuilder().build(
            f.run.plan!,
            f.run.draft(),
            resolveSecret: (_) async {
              reads++;
              return null;
            },
          );
          expect(reads, 0);
          expect(prepared.tls.privateKey, isNull);
          expect(prepared.tls.ca, isNotNull);
          await prepared.body?.close();
          f.run.refresh();
        });
        await tester.pump();
        expect(find.byType(RequestSecretInput), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await server?.close(force: true);
          await f.dispose();
        });
      }
    },
  );
}

class _GateResponseEngine extends EngineProcess {
  _GateResponseEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final received = Completer<void>(),
      release = Completer<void>(),
      finished = Completer<void>();
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'evaluateSchemas' &&
        (params['runtimeInstances'] as List? ?? []).whereType<Map>().any(
          (v) => v['subject'] == 'response-body',
        )) {
      if (!received.isCompleted) received.complete();
      await release.future;
      if (!finished.isCompleted) finished.complete();
    }
    return result;
  }
}

class _ReadTrackingSecrets extends EnvironmentSecretStore {
  _ReadTrackingSecrets(BusyApiSecretStore persistent)
    : super(persistent: persistent);
  Future<String?>? pendingRead;
  @override
  Future<String?> read(String reference, {RunCancellation? cancellation}) =>
      pendingRead = super.read(reference, cancellation: cancellation);
}

class _GateSecretStore extends SessionBusyApiSecretStore
    implements BusyApiSecretAvailability {
  final entered = Completer<void>(), release = Completer<String?>();
  int writes = 0;
  @override
  Future<SecretAvailability> availability(String reference) async =>
      SecretAvailability.persistent;
  @override
  Future<String?> read(String reference) {
    if (!entered.isCompleted) entered.complete();
    return release.future;
  }

  @override
  Future<void> write(
    String reference,
    String value, {
    bool allowEmpty = false,
  }) async {
    writes++;
    await super.write(reference, value, allowEmpty: allowEmpty);
  }
}

class _GateResult extends ContractRequestResult {
  _GateResult(ContractRequestResult source)
    : super(
        request: source.request,
        response: source.response,
        outgoing: source.outgoing,
        received: source.received,
      );
  final entered = Completer<void>(),
      release = Completer<void>(),
      closed = Completer<void>();
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
    entered.complete();
    await release.future;
    await super.close();
    closed.complete();
  }
}
