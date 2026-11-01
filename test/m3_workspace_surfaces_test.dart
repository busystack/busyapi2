import 'dart:async';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/git_workspace.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
import 'package:busyapi/src/workspace/test_run.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/platform/secret_store.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

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
  test('native form draft preserves repeated and empty literal values', () {
    expect(
      RequestRunController.formFields('tag=one\ntag=\nfalse=false\nzero=0'),
      {
        'tag': ['one', ''],
        'false': ['false'],
        'zero': ['0'],
      },
    );
    expect(
      () => RequestRunController.formFields('missing-separator'),
      throwsA(isA<CoreFailure>()),
    );
  });

  testWidgets(
    'Git surface opens an unborn repository and commits its reviewed index',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-native-unborn-',
      );
      Future<void> git(List<String> args) async {
        final result = await Process.run(
          '/usr/bin/git',
          args,
          workingDirectory: temp.path,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      final contract = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync(
          'openapi: 3.1.2\ninfo: {title: First, version: "1"}\npaths: {}\n',
        );
      final workspace = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      final errors = <Object>[];
      Future<void> waitFor(bool Function() condition) async {
        for (
          var i = 0;
          i < 200 &&
              (!condition() ||
                  find.byType(LinearProgressIndicator).evaluate().isNotEmpty);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(errors, isEmpty);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          condition(),
          true,
          reason:
              'status=${tester.widgetList<BusyApiStatusBox>(find.byType(BusyApiStatusBox)).map((w) => w.message).toList()}; '
              'busy=${find.byType(LinearProgressIndicator).evaluate().length}; '
              'fields=${tester.widgetList<TextField>(find.byWidgetPredicate((w) => w is TextField)).map((w) => w.controller?.text).toList()}',
        );
      }

      try {
        await tester.runAsync(() async {
          await git(['init', '-b', 'new-api']);
          await git(['config', 'user.name', 'BusyAPI Native Test']);
          await git(['config', 'user.email', 'native@example.invalid']);
          await workspace.initialize();
          await workspace.open(contract.path);
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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    unawaited(
                      showGitWorkspace(
                        context,
                        workspace,
                      ).catchError(errors.add),
                    );
                  },
                  child: const Text('Open Git'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Git'));
        await waitFor(
          () => find
              .byTooltip('Stage reviewed disk content')
              .evaluate()
              .isNotEmpty,
        );
        expect(find.textContaining('new-api'), findsWidgets);
        await tester.tap(find.byTooltip('Stage reviewed disk content').first);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply'));
        await waitFor(
          () =>
              find.byType(BusyApiRawSourceView).evaluate().isNotEmpty &&
              find
                  .byWidgetPredicate(
                    (w) =>
                        w is BusyApiCompactIconButton &&
                        w.tooltip == 'Stage reviewed disk content' &&
                        w.onPressed != null,
                  )
                  .evaluate()
                  .isNotEmpty,
        );
        await tester.tap(find.byTooltip('Stage reviewed disk content').first);
        await waitFor(() => find.byTooltip('Unstage').evaluate().isNotEmpty);
        await waitFor(
          () =>
              tester
                  .widget<TextField>(
                    find.widgetWithText(TextField, 'Commit message'),
                  )
                  .enabled !=
              false,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Commit message'),
          'First native reviewed commit',
        );
        await tester.pump();
        await waitFor(
          () =>
              tester
                  .widget<ElevatedButton>(
                    find.widgetWithText(
                      ElevatedButton,
                      'Commit reviewed index',
                    ),
                  )
                  .onPressed !=
              null,
        );
        await tester.tap(find.text('Commit reviewed index'));
        await waitFor(() => find.byTooltip('Unstage').evaluate().isEmpty);
        tester
            .widget<BusyApiPopupSelector<int>>(
              find.byType(BusyApiPopupSelector<int>),
            )
            .onSelected(1);
        await tester.pumpAndSettle();
        await waitFor(
          () => find.text('First native reviewed commit').evaluate().isNotEmpty,
        );
        expect(contract.readAsStringSync(), contains('title: First'));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(workspace.shutdown);
        workspace.dispose();
        await tester.runAsync(workspace.engine.close);
        temp.deleteSync(recursive: true);
      }
    },
  );

  test('native history export publishes only captured sanitized metadata without clobber', () async {
    final temp = Directory.systemTemp.createTempSync('busyapi-history-export-');
    final workspace = WorkspaceController(
      EngineProcess(executable: runtimeNode, helper: runtimeHelper),
      StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      ),
    );
    final run = RequestRunController(workspace);
    final target = File('${temp.path}/history.json');
    try {
      Object? collision;
      try {
        await run.exportHistory(
          target.path,
          beforePublish: () async {
            target.writeAsBytesSync([0, 255, 17]);
          },
        );
      } on Object catch (error) {
        collision = error;
      }
      expect(target.readAsBytesSync(), [0, 255, 17]);
      expect(collision, isA<AtomicFileAlreadyExistsException>());
      target.deleteSync();
      await run.exportHistory(target.path);
      expect(target.readAsStringSync(), contains('"records": []'));
      expect(temp.listSync().length, 1);
    } finally {
      run.dispose();
      workspace.dispose();
      await workspace.engine.close();
      temp.deleteSync(recursive: true);
    }
  });

  for (final change in [
    'remove',
    'replace',
    'environment',
    'project',
    'newer input',
  ]) {
    testWidgets('pending secret completion cannot retarget $change', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const reference = '123e4567-e89b-42d3-a456-426614174000';
      final store = _DelayedSecretStore();
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-secret-lifetime-',
      );
      final workspace = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      final run = RequestRunController(
        workspace,
        secrets: EnvironmentSecretStore(persistent: store),
      );
      Widget screen({bool visible = true, String key = 'original'}) =>
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: visible
                  ? RequestSecretInput(
                      key: ValueKey(key),
                      run: run,
                      reference: reference,
                    )
                  : const SizedBox.shrink(),
            ),
          );
      try {
        await tester.pumpWidget(screen());
        await tester.enterText(find.byType(TextField), 'synthetic-submission');
        await tester
            .pump(); // Apply the credential validation state before activation.
        await tester.tap(find.text('Store in Secret Service'));
        await tester.tap(find.text('Store in Secret Service'));
        await tester.pump();
        expect(store.writes, 1);
        switch (change) {
          case 'remove':
            await tester.pumpWidget(screen(visible: false));
          case 'replace':
            await tester.pumpWidget(screen(key: 'replacement'));
          case 'environment':
            run.selectEnvironment('different');
          case 'project':
            run.clear();
          case 'newer input':
            break;
        }
        if (change != 'remove') {
          await tester.enterText(find.byType(TextField), 'newer-private-input');
        }
        store.completed.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (change != 'remove') {
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'newer-private-input',
          );
        }
        expect(store.writes, 1);
        expect(find.textContaining('synthetic-submission'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        run.dispose();
        workspace.dispose();
        await tester.runAsync(workspace.engine.close);
        temp.deleteSync(recursive: true);
      }
    });
  }

  testWidgets(
    'native test selection authorizes only checked cases and refuses changed inputs',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-m3-native-tests-',
      );
      final contract = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync(
          'openapi: 3.1.2\ninfo: {title: Native tests, version: "1"}\npaths: {}\n',
        );
      File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
tests:
  - {name: chosen, operation: {method: get, path: /chosen}}
  - {name: unselected, operation: {method: post, path: /unselected}}
''');
      final workspace = WorkspaceController(
        EngineProcess(
          executable: runtimeNode,
          helper: '$repositoryRoot/tools/contract_engine/dist/engine.cjs',
        ),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      try {
        await tester.runAsync(() async {
          await workspace.initialize();
          await workspace.open(contract.path);
          await workspace.analyse();
        });
        final project = workspace.project!, root = workspace.root!;
        final captured = (await tester.runAsync(
          () => project.captureContractSnapshot(root),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.dark,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ContractTestsDialog(
                workspace: workspace,
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
        BusyApiDialogButton action() => tester.widget<BusyApiDialogButton>(
          find.widgetWithText(BusyApiDialogButton, 'Test selected cases'),
        );
        expect(action().onPressed, isNull);
        expect(
          tester
              .widget<BusyApiCheckbox>(
                find.descendant(
                  of: find.widgetWithText(BusyApiActionRow, 'unselected'),
                  matching: find.byType(BusyApiCheckbox),
                ),
              )
              .value,
          false,
        );
        await tester.tap(find.text('chosen'));
        await tester.pump();
        expect(action().onPressed, isNotNull);
        expect(
          tester
              .widget<BusyApiCheckbox>(
                find.descendant(
                  of: find.widgetWithText(BusyApiActionRow, 'unselected'),
                  matching: find.byType(BusyApiCheckbox),
                ),
              )
              .value,
          false,
        );
        project.store.replace(
          root,
          '${contract.readAsStringSync()}\n# changed after selection\n',
          label: 'Changed test declaration',
        );
        workspace.notifyListeners();
        await tester.pump();
        expect(action().onPressed, isNull);
        expect(
          find.textContaining('Captured inputs are outdated'),
          findsOneWidget,
        );
        expect(
          contract.readAsStringSync(),
          isNot(contains('changed after selection')),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(workspace.shutdown);
        workspace.dispose();
        await tester.runAsync(workspace.engine.close);
        temp.deleteSync(recursive: true);
      }
    },
  );

  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets('restored body draft survives removed media type $version', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync('busyapi-draft-media-');
      String source(String? media) =>
          '''
openapi: $version
info: {title: Body draft, version: "1"}
paths:
  /items:
    post:
${media == null ? '' : '      requestBody: {required: true, content: {$media: {schema: {type: string}}}}\n'}      responses: {"200": {description: ok}}
''';
      final original = source('application/json');
      final contract = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync(original);
      final workspace = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      final request = RequestRunController(workspace);
      final mediaField = find.byWidgetPredicate(
        (widget) =>
            widget is BusyApiComboRow<String?> &&
            widget.title == 'Body media type',
      );
      ButtonStyleButton sendButton() => tester.widget<ButtonStyleButton>(
        find.widgetWithText(ElevatedButton, 'Send'),
      );
      const text = '{\n  "note": "keep this draft exactly"\n}';
      try {
        late Map<String, dynamic> operation;
        await tester.runAsync(() async {
          await workspace.initialize();
          await workspace.open(contract.path);
          await workspace.analyse();
          operation = Map<String, dynamic>.from(
            (workspace.projection!['operations'] as List).single as Map,
          );
          await request.open(operation);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: RequestRunPanel(run: request)),
          ),
        );
        final bodyField = find.widgetWithText(
          TextFormField,
          'Authored text or exact JSON bytes',
        );
        await tester.ensureVisible(bodyField);
        await tester.enterText(bodyField, text);
        expect(request.bodyMediaType, 'application/json');
        expect(workspace.buffer!.text, original);

        final replaced = source('text/plain');
        workspace.project!.store.replace(workspace.root!, replaced);
        await tester.runAsync(() => request.open(operation));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(request.outdated, true);
        expect(request.bodyText, text);
        expect(request.bodyMediaType, 'application/json');
        expect(find.textContaining('application/json'), findsWidgets);

        await tester.runAsync(request.reconcileDraft);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(request.outdated, false);
        expect(sendButton().onPressed, isNull);
        await tester.runAsync(request.send);
        expect(request.phase, 'ready');
        expect(request.result, isNull);
        expect(request.history, isEmpty);

        await tester.ensureVisible(mediaField);
        final nativeMedia = tester.widget<BusyApiMenuButton<int>>(
          find.descendant(
            of: mediaField,
            matching: find.byType(BusyApiMenuButton<int>),
          ),
        );
        final oldChoice = nativeMedia.items
            .whereType<BusyApiPopupMenuItem<int>>()
            .where((item) => item.label.contains('application/json'));
        expect(oldChoice, isNotEmpty);
        expect(oldChoice.every((item) => !item.enabled), true);
        final unavailableIndex = nativeMedia.items.indexOf(oldChoice.single);
        nativeMedia.onSelected(unavailableIndex);
        expect(request.bodyMediaType, 'application/json');
        final plain = nativeMedia.items
            .whereType<BusyApiPopupMenuItem<int>>()
            .singleWhere((item) => item.label == 'text/plain');
        nativeMedia.onSelected(plain.menuValue);
        await tester.pumpAndSettle();
        expect(request.bodyMediaType, 'text/plain');
        expect(request.bodyText, text);
        expect(sendButton().onPressed, isNotNull);
        expect(workspace.buffer!.text, replaced);

        // Removing requestBody entirely must keep the same owned text usable
        // until the user explicitly omits/discards it, not hide a blocked Send.
        final removed = source(null);
        workspace.project!.store.replace(workspace.root!, removed);
        await tester.runAsync(() => request.open(operation));
        await tester.runAsync(request.reconcileDraft);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(request.bodyText, text);
        expect(mediaField, findsOneWidget);
        expect(sendButton().onPressed, isNull);
        final includeBody = find.byWidgetPredicate(
          (widget) =>
              widget is BusyApiSwitchRow &&
              widget.title == 'Include request body',
        );
        await tester.ensureVisible(includeBody);
        await tester.pump();
        await tester.tap(includeBody);
        await tester.pumpAndSettle();
        expect(request.bodyEnabled, false);
        expect(request.bodyText, text);
        expect(sendButton().onPressed, isNotNull);
        expect(workspace.buffer!.text, removed);
        expect(contract.readAsStringSync(), original);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        request.dispose();
        await tester.runAsync(workspace.shutdown);
        workspace.dispose();
        await tester.runAsync(workspace.engine.close);
        temp.deleteSync(recursive: true);
      }
    });
  }

  testWidgets(
    'Design and Reference Try share one compact native draft without editing source',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync('busyapi-m3-surface-');
      final contract = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync('''
openapi: 3.2.1
info: {title: Try, version: "1"}
components:
  securitySchemes:
    access: {type: http, scheme: bearer}
security: [{access: []}, {}]
paths:
  /other:
    get:
      responses: {"200": {description: ok}}
  /things/{id}:
    get:
      summary: Get a thing
      parameters:
        - {name: id, in: path, required: true, schema: {type: string}}
      responses: {"200": {description: ok}}
''');
      File('${temp.path}/busyapi.yaml').writeAsStringSync('''
version: 1
roots: [{name: api, path: openapi.yaml}]
environments:
  local:
    baseUrl: http://127.0.0.1:1
    authentication:
      alternative: 0
      schemes: {access: {tokenRef: 123e4567-e89b-42d3-a456-426614174000}}
''');
      final workspace = WorkspaceController(
        EngineProcess(
          executable: runtimeNode,
          helper: '$repositoryRoot/tools/contract_engine/dist/engine.cjs',
        ),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      final failures = <Object>[];
      void run(Future<void> Function() action) =>
          unawaited(action().catchError(failures.add));
      final request = RequestRunController(workspace);
      var dark = false, reference = false;
      late StateSetter rebuild;
      Widget screen() => StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return MaterialApp(
            theme: buildBusyApiTheme(
              brightness: dark ? Brightness.dark : Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: ListenableBuilder(
                      listenable: workspace,
                      builder: (_, _) => reference
                          ? ReferenceView(
                              controller: workspace,
                              reveal: (_) {},
                              tryOperation: (operation) =>
                                  run(() => request.open(operation)),
                            )
                          : Designer(
                              controller: workspace,
                              run: run,
                              reveal: (_) {},
                              tryOperation: (operation) =>
                                  run(() => request.open(operation)),
                            ),
                    ),
                  ),
                  RequestRunPanel(run: request),
                ],
              ),
            ),
          );
        },
      );

      Future<void> waitFor(bool Function() condition) async {
        final watch = Stopwatch()..start();
        while (!condition() && watch.elapsed < const Duration(seconds: 10)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(failures, isEmpty);
        expect(
          condition(),
          true,
          reason:
              'request=${request.phase}/${request.failure} workspace=${workspace.error} checking=${workspace.checking}',
        );
      }

      try {
        await tester.runAsync(() async {
          await workspace.initialize();
          await workspace.open(contract.path);
          await workspace.analyse();
          final operation = (workspace.projection!['operations'] as List)
              .whereType<Map>()
              .singleWhere((value) => value['path'] == '/things/{id}');
          await workspace.selectObject(Map<String, dynamic>.from(operation));
          await workspace.analyse();
        });
        final original = contract.readAsStringSync();
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(find.text('Try'), findsOneWidget);
        await tester.tap(find.text('Try'));
        await waitFor(() => request.phase == 'ready');
        expect(find.textContaining('GET /things/{id}'), findsWidgets);
        final input = find.widgetWithText(
          TextFormField,
          'id · path · Required',
        );
        expect(input, findsOneWidget);
        await tester.enterText(input, 'draft-only');
        expect(request.values.values, contains('draft-only'));
        expect(workspace.buffer!.text, original);
        expect(contract.readAsStringSync(), original);
        request.selectEnvironment('local');
        await tester.pump();
        expect(find.text('local'), findsOneWidget);
        expect(
          request.securityAlternative,
          0,
          reason:
              'Show the same configured authentication that Send would execute',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'id · path · Required'),
          'draft-only',
        );
        final selectedOperation = Map<String, dynamic>.from(
          (workspace.projection!['operations'] as List)
              .whereType<Map>()
              .singleWhere((value) => value['path'] == '/things/{id}'),
        );
        await tester.runAsync(() => request.open(selectedOperation));
        await tester.pumpAndSettle();
        expect(request.values.values, contains('draft-only'));
        expect(request.environment, 'local');
        request.securityAlternative =
            1; // Explicit anonymous requirement, not environment fallback.
        await tester.runAsync(() => request.open(selectedOperation));
        expect(request.securityAlternative, 1);
        final other = Map<String, dynamic>.from(
          (workspace.projection!['operations'] as List)
              .whereType<Map>()
              .singleWhere((value) => value['path'] == '/other'),
        );
        await tester.runAsync(() => request.open(other));
        expect(request.values, isEmpty);
        request.values['other-input'] = 'other-owned';
        await tester.runAsync(() => request.open(selectedOperation));
        expect(request.values.values, contains('draft-only'));
        expect(request.values.values, isNot(contains('other-owned')));
        request.headerName = 'X-Local';
        request.headerValue = 'local-only';
        request.selectEnvironment(null);
        expect(request.headerValue, isEmpty);
        expect(request.values.values, contains('draft-only'));
        request.selectEnvironment('local');
        expect(request.headerValue, 'local-only');
        workspace.project!.store.replace(
          workspace.root!,
          '$original\n# changed declaration snapshot\n',
        );
        await tester.runAsync(() => request.open(selectedOperation));
        expect(request.outdated, true);
        expect(request.values.values, contains('draft-only'));
        await tester.runAsync(request.reconcileDraft);
        expect(request.outdated, false);
        expect(request.values.values, contains('draft-only'));
        request.discardDraft();
        expect(request.values, isEmpty);
        expect(request.headerValue, isEmpty);
        workspace.project!.store.undo();

        dark = true;
        rebuild(() {});
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(RequestRunPanel))).brightness,
          Brightness.dark,
        );
        expect(tester.takeException(), isNull);

        reference = true;
        workspace.mode = 'Reference';
        rebuild(() {});
        workspace.notifyListeners();
        await tester.pump();
        await waitFor(
          () => find.text('GET /things/{id}').evaluate().isNotEmpty,
        );
        await tester.ensureVisible(find.text('GET /things/{id}').last);
        await tester.pump();
        await tester.tap(find.text('GET /things/{id}').last);
        await tester.pump();
        await waitFor(() => find.text('Try').evaluate().isNotEmpty);
        expect(find.text('Try'), findsWidgets);
        expect(contract.readAsStringSync(), original);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        request.dispose();
        await tester.runAsync(workspace.shutdown);
        workspace.dispose();
        await tester.runAsync(workspace.engine.close);
        temp.deleteSync(recursive: true);
      }
    },
  );
}

class _DelayedSecretStore implements BusyApiSecretStore {
  final completed = Completer<void>();
  int writes = 0;
  @override
  Future<void> write(
    String reference,
    String value, {
    bool allowEmpty = false,
  }) {
    writes++;
    return completed.future;
  }

  @override
  Future<String?> read(String reference) async => null;
  @override
  Future<void> delete(String reference) async {}
}
