import 'dart:async';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_settings.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_dialogs.dart';
import 'package:busyapi/src/app/busyapi_glyphs.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/app/command_registry.dart';
import 'package:busyapi/src/app/command_shortcuts.dart';
import 'package:busyapi/src/app/shortcut_binding.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/workspace/settings_screen.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi/src/workspace/search_session.dart';
import 'package:busyapi/src/workspace/search_sidebar.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/tool_surface.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

import '../packages/busyapi_core/test/test_support.dart';

Widget host(Widget child) => MaterialApp(
  theme: buildBusyApiTheme(
    brightness: Brightness.light,
    accentColor: const Color(0xff3584e4),
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

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
  testWidgets(
    'retained tools use remaining editor space and scroll with small windows and notices',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('busyapi-tool-layout-');
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${dir.path}/config',
          state: '${dir.path}/state',
          cache: '${dir.path}/cache',
        ),
      );
      try {
        await tester.runAsync(() async {
          await c.initialize();
          final api = Directory('${dir.path}/api')..createSync();
          final file = File('${api.path}/openapi.yaml')
            ..writeAsStringSync(
              'openapi: 3.1.2\ninfo: {title: Layout, version: "1"}\npaths: {}\n',
            );
          await c.open(file.path);
          await c.analyse();
          c.mode = 'Source';
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(
              controller: c,
              initialAppearance: BusyApiAppearance(failure: StateError('load')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final area = find.byKey(const ValueKey('workspace-working-area'));
        final editor = find.byType(SourceEditor);
        final state = tester.state(editor);
        expect(tester.getSize(editor).height, tester.getSize(area).height);
        c.storageError = 'Simulated recovery failure';
        c.notifyListeners();
        final workspace = tester.state<WorkspaceScreenState>(
          find.byType(WorkspaceScreen),
        );
        workspace.requestRun.phase = 'failed';
        workspace.requestRun.refresh();
        workspace.mockRun.phase = 'ready';
        workspace.mockRun.notifyListeners();
        workspace.bundleRun.phase = 'failed';
        workspace.bundleRun.notifyListeners();
        tester.view.physicalSize = const Size(560, 480);
        await tester.pumpAndSettle();
        expect(find.byType(BusyApiToolSurface), findsNWidgets(3));
        expect(tester.state(editor), same(state));
        expect(
          tester.getSize(editor).height,
          greaterThanOrEqualTo(tester.getSize(area).height / 2),
        );
        final tools = find.byKey(const ValueKey('workspace-tools'));
        expect(
          tester.getSize(tools).height,
          lessThanOrEqualTo(tester.getSize(area).height / 2),
        );
        for (final surface in find.byType(BusyApiToolSurface).evaluate()) {
          final owner = find.byWidget(surface.widget);
          final viewport = tester.getRect(
            find
                .descendant(
                  of: owner,
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          );
          final status = tester.getRect(
            find
                .descendant(of: owner, matching: find.byType(BusyApiStatusBox))
                .first,
          );
          expect(status.top, greaterThanOrEqualTo(viewport.top));
          expect(
            status.bottom,
            lessThanOrEqualTo(viewport.bottom),
            reason: 'Each retained status fits its own scroll viewport.',
          );
        }
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: tools, matching: find.byType(Scrollable)).first,
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        expect(find.byType(BusyApiToolSurface), findsNWidgets(3));
        tester.view.physicalSize = const Size(1100, 800);
        await tester.pumpAndSettle();
        expect(tester.state(editor), same(state));
        expect(workspace.requestRun.phase, 'failed');
        expect(workspace.mockRun.phase, 'ready');
        expect(workspace.bundleRun.phase, 'failed');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        await tester.runAsync(c.engine.close);
        dir.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'only the focused composing input suppresses application commands',
    (tester) async {
      final text = TextEditingController(text: 'draft'),
          inputFocus = FocusNode(),
          buttonFocus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(inputFocus.dispose);
      addTearDown(buttonFocus.dispose);
      var dispatched = 0;
      await tester.pumpWidget(
        host(
          BusyApiCommandShortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.keyS, control: true):
                  BusyApiCommandIntent('save'),
            },
            isComposing: busyApiFocusedInputIsComposing,
            child: Actions(
              actions: {
                BusyApiCommandIntent: CallbackAction<BusyApiCommandIntent>(
                  onInvoke: (_) {
                    dispatched++;
                    return null;
                  },
                ),
              },
              child: Column(
                children: [
                  TextField(controller: text, focusNode: inputFocus),
                  TextButton(
                    focusNode: buttonFocus,
                    onPressed: () {},
                    child: const Text('Action'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      inputFocus.requestFocus();
      await tester.pump();
      text.value = const TextEditingValue(
        text: 'draft中',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 5, end: 6),
      );
      expect(busyApiFocusedInputIsComposing(), true);
      Future<void> save() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }

      await save();
      expect(dispatched, 0);
      buttonFocus.requestFocus();
      await tester.pump();
      text.value = text.value.copyWith(
        composing: const TextRange(start: 5, end: 6),
      );
      expect(busyApiFocusedInputIsComposing(), false);
      await save();
      expect(dispatched, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'search categories restore their measured list scroll positions',
    (tester) async {
      final first = ScrollController(), second = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      late StateSetter rebuild;
      var alternate = false;
      final results = List.generate(
        100,
        (index) => BusyApiSearchResult(
          identity: '$index',
          title: 'Result $index',
          subtitle: 'Location $index',
          activate: () async {},
        ),
      );
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return BusyApiSearchResultList(
                key: ValueKey(alternate),
                results: results,
                selected: 0,
                scroll: alternate ? second : first,
                onSelected: (_) {},
                onActivate: (_) {},
              );
            },
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      final initial = first.offset;
      expect(initial, greaterThan(0));
      rebuild(() => alternate = true);
      await tester.pumpAndSettle();
      expect(second.offset, 0);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      final other = second.offset;
      rebuild(() => alternate = false);
      await tester.pumpAndSettle();
      expect(first.offset, initial);
      rebuild(() => alternate = true);
      await tester.pumpAndSettle();
      expect(second.offset, other);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'native combo mouse and keyboard activation retain unavailable choices',
    (tester) async {
      const channel = MethodChannel(nativeMenuChannelName);
      final calls = <MethodCall>[];
      var selectionIndex = 1;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'show' ? selectionIndex : true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      var selected = 'old';
      await tester.pumpWidget(
        host(
          BusyApiComboRow<String>(
            title: 'Media',
            values: const ['old', 'new'],
            selected: 'old',
            labelFor: (v) => v,
            enabledFor: (v) => v != 'old',
            onSelected: (v) => selected = v,
          ),
        ),
      );
      await tester.tap(find.byType(YaruListTile));
      await tester.pumpAndSettle();
      expect(selected, 'new');
      final entries = (calls.single.arguments as Map)['entries'] as List;
      expect((entries.first as Map)['enabled'], false);
      expect((entries.last as Map)['enabled'], true);
      calls.clear();
      final tile = tester.widget<YaruListTile>(find.byType(YaruListTile));
      tile.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'show'), hasLength(1));
      selectionIndex = 0;
      String? environment = 'sandbox';
      await tester.pumpWidget(
        host(
          BusyApiComboRow<({String? value})>(
            title: 'Environment',
            values: const [(value: null), (value: 'sandbox')],
            selected: (value: environment),
            labelFor: (option) => option.value ?? 'Project defaults',
            onSelected: (option) => environment = option.value,
          ),
        ),
      );
      await tester.tap(find.byType(YaruListTile));
      await tester.pumpAndSettle();
      expect(
        environment,
        isNull,
        reason: 'Choosing project defaults is distinct from dismissing the native menu.',
      );
    },
  );
  testWidgets(
    'search layout changes retain the live header input and guard composing keys',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('busyapi-search-layout-');
      final c = WorkspaceController(
        EngineProcess(executable: '/unused', helper: '/unused'),
        StateLocations(
          config: '${dir.path}/config',
          state: '${dir.path}/state',
          cache: '${dir.path}/cache',
        ),
      );
      await tester.runAsync(c.initialize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
          child: BusyApiApp(controller: c),
        ),
      );
      final workspace = tester.state<WorkspaceScreenState>(
        find.byType(WorkspaceScreen),
      );
      await workspace.palette();
      await tester.pumpAndSettle();
      final inputState = tester.state(
        find.byKey(const ValueKey('shared-search-query')),
      );
      final query = workspace.search.query;
      query.value = const TextEditingValue(
        text: 'part中',
        selection: TextSelection.collapsed(offset: 5),
      );
      final queryFocus = FocusManager.instance.primaryFocus;
      await workspace.settings();
      await tester.pumpAndSettle();
      expect(queryFocus?.hasFocus, false);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byKey(const ValueKey('shared-search-query'))),
        same(inputState),
      );
      expect(queryFocus?.hasFocus, true);
      expect(query.text, 'part中');
      expect(query.selection.extentOffset, 5);
      query.value = query.value.copyWith(
        composing: const TextRange(start: 4, end: 5),
      );
      tester.view.physicalSize = const Size(560, 800);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byKey(const ValueKey('shared-search-query'))),
        same(inputState),
      );
      expect(query.value.composing, const TextRange(start: 4, end: 5));
      expect(query.selection.extentOffset, 5);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(workspace.search.active, true);
      query.value = query.value.copyWith(composing: TextRange.empty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(workspace.search.active, false);
      expect(query.text, 'part中');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(c.shutdown);
      c.dispose();
      await tester.runAsync(c.engine.close);
      dir.deleteSync(recursive: true);
    },
  );

  testWidgets('search result keyboard navigation is local and composing-safe', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'query');
    addTearDown(controller.dispose);
    var moved = 0, submitted = 0;
    await tester.pumpWidget(
      host(
        BusyApiSearchField(
          controller: controller,
          autofocus: true,
          onMoveSelection: (delta) => moved += delta,
          onSubmitted: (_) => submitted++,
        ),
      ),
    );
    await tester.pump();
    controller.value = const TextEditingValue(
      text: 'query中',
      selection: TextSelection.collapsed(offset: 6),
      composing: TextRange(start: 5, end: 6),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(controller.value.composing, const TextRange(start: 5, end: 6));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(moved, 0);
    expect(submitted, 0);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(submitted, 0);
    expect(controller.value.composing, const TextRange(start: 5, end: 6));
    controller.value = controller.value.copyWith(composing: TextRange.empty);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(moved, 1);
    expect(submitted, 1);
  });
  testWidgets(
    'selector uses neutral borderless geometry and multiline labels',
    (tester) async {
      await tester.pumpWidget(
        host(
          BusyApiPopupSelector<int>(
            value: 1,
            label: 'Selected view\nSecond line',
            tooltip: 'View',
            maxLabelLines: 2,
            fullWidth: true,
            options: const [
              BusyApiPopupSelectorOption(value: 1, label: 'Selected view'),
            ],
            onSelected: (_) {},
          ),
        ),
      );
      final button = tester.widget<TextButton>(find.byType(TextButton));
      final text = tester.widget<Text>(find.text('Selected view\nSecond line'));
      expect(text.maxLines, 2);
      expect(text.softWrap, true);
      final theme = Theme.of(tester.element(find.byType(TextButton)));
      expect(
        button.style!.foregroundColor!.resolve({}),
        theme.outlinedButtonTheme.style!.foregroundColor!.resolve({}),
      );
      expect(find.byType(ElevatedButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'standard sidebar identities use Yaru geometry and explicit focus',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final anchor = GlobalKey();
      await tester.pumpWidget(
        host(
          BusyApiSidebarRecordRow<void>(
            icon: BusyApiGlyphs.document,
            title: 'Contract',
            subtitle: '/demo/contracts/openapi.yaml',
            pathSubtitle: true,
            geometryKey: anchor,
            focusNode: focus,
            trailing: const Text('GET'),
            selected: true,
            onTap: () {},
          ),
        ),
      );
      expect(find.byType(YaruListTile), findsOneWidget);
      expect(anchor.currentContext, isNotNull);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, true);
      expect(find.text('GET'), findsOneWidget);
    },
  );

  testWidgets(
    'effective command bindings are isolated while modal text editing stays local',
    (tester) async {
      var dispatched = 0;
      late BuildContext owner;
      final text = TextEditingController(text: 'retained draft');
      addTearDown(text.dispose);
      final registry = BusyApiCommandRegistry([
        BusyApiCommand(
          id: 'custom',
          label: (_) => 'Custom',
          category: (_) => 'App',
          shortcut: const BusyApiKeyBinding(
            LogicalKeyboardKey.keyL,
            control: true,
          ),
          execute: () {
            dispatched++;
          },
        ),
      ]);
      await tester.pumpWidget(
        host(
          BusyApiCommandRegistryScope(
            registry: registry,
            child: Shortcuts(
              shortcuts: registry.shortcutIntents(),
              child: Actions(
                actions: {
                  BusyApiCommandIntent: CallbackAction<BusyApiCommandIntent>(
                    onInvoke: (intent) {
                      unawaited(registry.execute(intent.commandId));
                      return null;
                    },
                  ),
                },
                child: Builder(
                  builder: (context) {
                    owner = context;
                    return const Text('Workspace');
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final done = showBusyApiModalDialog<void>(
        context: owner,
        builder: (_) => BusyApiDialogShell(
          title: 'Draft',
          children: [
            BusyApiGroupedTextEntry(
              label: 'Value',
              controller: text,
              autofocus: true,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(dispatched, 0);
      expect(
        text.selection,
        TextSelection(baseOffset: 0, extentOffset: text.text.length),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await done;
      expect(text.text, 'retained draft');
    },
  );

  testWidgets(
    'Settings keeps the page and project field through theme and width changes',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var mode = ThemeMode.system, back = 0;
      late StateSetter update;
      final project = TextEditingController(text: 'mapping draft');
      addTearDown(project.dispose);
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return BusyApiSettingsScreen(
                mode: mode,
                onThemeChanged: (v) => setState(() => mode = v),
                onBack: () => back++,
                projectSettings: BusyApiGroupedTextEntry(
                  label: 'Resource',
                  controller: project,
                ),
              );
            },
          ),
        ),
      );
      final state = tester.state(find.byType(BusyApiSettingsScreen));
      tester
          .widget<BusyApiPopupSelector<ThemeMode>>(
            find.byType(BusyApiPopupSelector<ThemeMode>),
          )
          .onSelected(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(mode, ThemeMode.dark);
      expect(tester.state(find.byType(BusyApiSettingsScreen)), same(state));
      await tester.tap(find.byKey(const ValueKey('settings-navigation-1')));
      await tester.pumpAndSettle();
      project.selection = const TextSelection.collapsed(offset: 3);
      tester.view.physicalSize = const Size(560, 900);
      update(() {});
      await tester.pumpAndSettle();
      expect(find.byType(BusyApiPopupSelector<int>), findsOneWidget);
      expect(project.selection.extentOffset, 3);
      expect(project.text, 'mapping draft');
      expect(back, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved dark appearance is used on the first application frame', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('busyapi-appearance-');
    final locations = StateLocations(
      config: '${dir.path}/config',
      state: '${dir.path}/state',
      cache: '${dir.path}/cache',
    );
    final c = WorkspaceController(
      EngineProcess(executable: '/unused', helper: '/unused'),
      locations,
    );
    late BusyApiAppearance appearance;
    await tester.runAsync(() async {
      await c.initialize();
      await BusyApiAppearance.save(locations, ThemeMode.dark);
      appearance = await BusyApiAppearance.load(locations);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
        child: BusyApiApp(controller: c, initialAppearance: appearance),
      ),
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(
      Theme.of(tester.element(find.byType(WorkspaceScreen))).brightness,
      Brightness.dark,
    );
    final setTheme = tester
        .widget<WorkspaceScreen>(find.byType(WorkspaceScreen))
        .setTheme;
    await tester.runAsync(() async {
      await Future.wait([
        setTheme(ThemeMode.light),
        setTheme(ThemeMode.dark),
        setTheme(ThemeMode.light),
      ]);
      expect((await BusyApiAppearance.load(locations)).mode, ThemeMode.light);
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    final blocked = Directory('${locations.config}/appearance.json');
    await tester.runAsync(() async {
      await File(blocked.path).delete();
      await blocked.create();
      await setTheme(ThemeMode.dark);
    });
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Appearance could not be loaded or saved. Select a theme to try saving again.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tester.runAsync(() async {
      await blocked.delete();
      await setTheme(ThemeMode.dark);
      expect((await BusyApiAppearance.load(locations)).mode, ThemeMode.dark);
    });
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Appearance could not be loaded or saved. Select a theme to try saving again.',
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(c.shutdown);
    c.dispose();
    await tester.runAsync(c.engine.close);
    dir.deleteSync(recursive: true);
  });

  testWidgets(
    'request draft entry retains composing text and caret through rebuilds',
    (tester) async {
      final c = WorkspaceController(
        EngineProcess(executable: '/unused', helper: '/unused'),
        StateLocations(
          config: '/tmp/unused-config',
          state: '/tmp/unused-state',
          cache: '/tmp/unused-cache',
        ),
      );
      final run = RequestRunController(c);
      var value = 'draft';
      late StateSetter rebuild;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return RequestDraftEntry(
                run: run,
                label: 'Value',
                value: value,
                onChanged: (v) => value = v,
              );
            },
          ),
        ),
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      field.controller!.value = const TextEditingValue(
        text: 'draft中',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 5, end: 6),
      );
      rebuild(() {});
      await tester.pump();
      expect(run.hasComposingInput, true);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(field.controller),
      );
      expect(
        field.controller!.value.composing,
        const TextRange(start: 5, end: 6),
      );
      expect(field.controller!.selection.extentOffset, 6);
      field.controller!.value = field.controller!.value.copyWith(
        composing: TextRange.empty,
      );
      expect(run.hasComposingInput, false);
      rebuild(() => value = 'explicit example');
      await tester.pump();
      expect(field.controller!.text, 'explicit example');
      await tester.pumpWidget(const SizedBox.shrink());
      run.dispose();
      c.dispose();
    },
  );

  test(
    'search category activation retains query, selection and composing input',
    () async {
      final c = WorkspaceController(
        EngineProcess(executable: '/unused', helper: '/unused'),
        StateLocations(
          config: '/tmp/unused-config',
          state: '/tmp/unused-state',
          cache: '/tmp/unused-cache',
        ),
      );
      final s = BusyApiSearchSession(c);
      s.query.value = const TextEditingValue(
        text: 'partial中',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 7, end: 8),
      );
      s.open(BusyApiSearchCategory.actions);
      s.select(3);
      s.open(BusyApiSearchCategory.navigation);
      s.open(BusyApiSearchCategory.actions);
      expect(s.selected, 3);
      expect(s.query.value.composing, const TextRange(start: 7, end: 8));
      expect(s.query.selection.extentOffset, 8);
      s.dispose();
      c.dispose();
    },
  );
}
