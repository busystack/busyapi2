import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/workspace/search_session.dart';
import 'package:busyapi/src/workspace/search_sidebar.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'support/search_test_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      (call) async => call.method == 'state'
          ? {'active': true, 'visible': true, 'closable': true}
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      (_) async => null,
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      null,
    );
  });
  testWidgets(
    'integrated search retains regex, case, document scope, semantic occurrences and stale captures',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-search-session-',
      );
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      BusyApiSearchSession? session, enteredSession;
      try {
        const composingQuery = TextEditingValue(
          text: 'Draft中',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 5, end: 6),
        );
        final s = session = BusyApiSearchSession(c);
        final entered = enteredSession = BusyApiSearchSession(c);
        entered.query.value = composingQuery;
        await tester.runAsync(() async {
          await c.initialize();
          await Initializer.create(
            destination: '${temp.path}/api',
            title: 'MatchingAlpha',
            apiVersion: '1',
          );
          final file = File('${temp.path}/api/openapi.yaml');
          await file.writeAsString(
            file.readAsStringSync().replaceFirst(
              'paths: {}',
              'paths: {"/items": {get: {summary: "Semantic Needle", responses: {"200": {description: OK}}}}}',
            ),
          );
          await File('${temp.path}/api/part.yaml')
              .writeAsString('value: MatchingAlpha\n');
          await c.open('${temp.path}/api');
          await c.analyse();
        });
        // Startup restores the project view after the shell's session exists.
        c.layoutState = {
          ...c.layoutState,
          'projectSearch': {
            'query': 'Saved query',
            'replacement': 'Saved replacement',
            'regex': true,
            'sensitive': true,
            'mode': 'semantic',
            'category': 'operations',
          },
        };
        s.open();
        expect(s.query.text, 'Saved query');
        expect(s.replacement.text, 'Saved replacement');
        expect(s.regex, true);
        expect(s.sensitive, true);
        expect(s.category, BusyApiSearchCategory.semantic);
        expect(s.semanticCategory, 'operations');
        entered.open();
        expect(entered.query.value, composingQuery);
        expect(entered.replacement.text, isEmpty);
        entered.dispose();
        enteredSession = null;
        s.query.value = composingQuery;
        s.close();
        s.open();
        expect(s.query.value, composingQuery);
        expect(s.replacement.text, 'Saved replacement');
        s.replacement.clear();
        s.open(BusyApiSearchCategory.project);
        s.regex = true;
        s.sensitive = true;
        s.query.text = r'Matching[A-Z]\w+';
        await tester.runAsync(s.search);
        expect(s.error, isNull);
        expect(s.result!.matches, hasLength(2));
        expect(s.result!.resources, hasLength(2));

        s.regex = false;
        s.query.text = 'matchingalpha';
        await tester.runAsync(s.search);
        expect(s.result!.matches, isEmpty);
        s.sensitive = false;
        await tester.runAsync(s.search);
        expect(s.result!.matches, hasLength(2));

        s.open(BusyApiSearchCategory.document);
        await tester.runAsync(s.search);
        expect(s.result!.matches.single.resource, c.active);
        expect(s.result!.resources.single['id'], c.active);
        final captured = s.result!;
        final revealed = <Map<String, dynamic>>[];
        await tester.pumpWidget(
          searchTestHost(s, onReveal: (value) async => revealed.add(value)),
        );
        await tester.pumpAndSettle();
        final sidebar = tester.state<BusyApiSearchSidebarState>(
          find.byType(BusyApiSearchSidebar),
        );
        final heldText = sidebar.results.single.activate;
        await tester.runAsync(() async {
          c.sourceEdit(c.active!, '${c.buffer!.text}\n# newer input\n');
        });
        expect(captured.current(c.store!), false);
        expect(s.result, same(captured));

        s.semanticCategory = 'operations';
        s.query.text = 'Needle';
        s.open(BusyApiSearchCategory.semantic);
        await tester.runAsync(s.search);
        expect(s.error, isNull);
        final occurrence = s.semanticResult!.matches.single;
        expect(occurrence['root'], c.root);
        expect(occurrence['resource'], c.active);
        expect(occurrence['pointer'], '/paths/~1items/get');
        expect(occurrence['occurrence'], isNotEmpty);
        expect(s.semanticResult!.current, true);
        expect(
          File('${temp.path}/api/openapi.yaml').readAsStringSync(),
          isNot(contains('# newer input')),
        );
        await tester.pumpAndSettle();
        final heldSemantic = sidebar.results.single.activate;
        await tester.runAsync(() async {
          await Initializer.create(
            destination: '${temp.path}/other-api',
            title: 'Other owner',
            apiVersion: '1',
          );
          await c.open('${temp.path}/other-api');
          await c.analyse();
        });
        final active = c.active, root = c.root;
        await tester.runAsync(() async {
          await heldText();
          await heldSemantic();
        });
        expect(revealed, isEmpty);
        expect(c.active, active);
        expect(c.root, root);
        expect(s.error, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        enteredSession?.dispose();
        session?.dispose();
        await tester.runAsync(c.shutdown);
        c.dispose();
        await tester.runAsync(c.engine.close);
        temp.deleteSync(recursive: true);
      }
    },
  );
  for (final matches in [1, 2, 261]) {
    testWidgets(
      'project search reviews $matches overlay matches and applies one undoable transaction',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-search-widget-',
        );
        final c = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        BusyApiSearchSession? session;
        final partSource = matches == 1
            ? 'value: Other\n'
            : matches == 2
            ? 'value: Old\n'
            : List.generate(
                260,
                (i) => 'value$i: "Old 😀 $i" # context',
              ).join('\r\n');
        try {
          await tester.runAsync(() async {
            await c.initialize();
            await Initializer.create(
              destination: '${temp.path}/api',
              title: 'Old title',
              apiVersion: '1',
            );
            await File('${temp.path}/api/part.yaml').writeAsString(partSource);
            await c.open('${temp.path}/api');
            await c.analyse();
          });
          final before = c.buffer!.text;
          await tester.runAsync(() async {
            c.sourceEdit(
              c.buffer!.id,
              before.replaceFirst('Old title', 'Old unsaved'),
            );
            await c.persist();
            await c.analyse();
          });
          final search = session = BusyApiSearchSession(c);
          search.open(BusyApiSearchCategory.project);
          await tester.pumpWidget(searchTestHost(search, textScale: 1.3));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byType(BusyApiSearchField),
              matching: find.byType(TextField),
            ),
            'Old',
          );
          await tester.enterText(
            find.descendant(
              of: find.widgetWithText(BusyApiGroupedTextEntry, 'Replacement'),
              matching: find.byType(TextField),
            ),
            'New',
          );
          await tester.runAsync(search.search);
          final result = find.text(
            matches == 1 ? '1 match in 1 file' : '$matches matches in 2 files',
          );
          // Collection and result handling are asynchronous too; the core's
          // regex execution timeout is not a 300-ms end-to-end search SLA.
          // Wait for the exact complete result, retaining every later review,
          // source-preservation and one-transaction assertion below.
          final collecting = Stopwatch()..start();
          while (result.evaluate().isEmpty &&
              collecting.elapsed < const Duration(seconds: 8)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(result, findsOneWidget);
          await tester.pumpAndSettle();
          if (matches == 1) {
            final captured = search.result;
            final reviewRow = find.widgetWithText(
              BusyApiActionRow,
              'Review replacement',
            );
            for (final input in [search.query, search.replacement]) {
              final value = input.value;
              final retainedActivation = tester
                  .widget<BusyApiActionRow>(reviewRow)
                  .onTap!;
              input.value = value.copyWith(
                composing: TextRange(start: 0, end: value.text.length),
              );
              await tester.pump();
              expect(tester.widget<BusyApiActionRow>(reviewRow).enabled, false);
              retainedActivation();
              await tester.pumpAndSettle();
              expect(find.byType(BusyApiDialogShell), findsNothing);
              expect(search.result, same(captured));
              expect(input.value.composing.isValid, true);
              input.value = value;
              await tester.pump();
            }
          }
          await tester.tap(find.text('Review replacement'));
          await tester.pumpAndSettle();
          expect(c.buffer!.text, contains('Old unsaved'));
          if (matches <= 2) {
            expect(find.text('− Old'), findsNWidgets(matches));
            expect(find.text('+ New'), findsNWidgets(matches));
            expect(
              tester.getRect(find.text('+ New').first).bottom,
              lessThanOrEqualTo(
                tester
                    .getRect(
                      find.descendant(
                        of: find.byType(BusyApiDialogShell),
                        matching: find.byType(ListView),
                      ),
                    )
                    .bottom,
              ),
            );
          } else {
            expect(find.text('Page 1 of 6'), findsOneWidget);
            await tester.tap(find.text('Last'));
            await tester.pumpAndSettle();
            expect(find.text('Page 6 of 6'), findsOneWidget);
            final last = find.byKey(const ValueKey('search-match-260'));
            await tester.scrollUntilVisible(
              last,
              180,
              scrollable: find
                  .descendant(
                    of: find.descendant(
                      of: find.byType(BusyApiDialogShell),
                      matching: find.byType(ListView),
                    ),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            expect(find.text('part.yaml:260'), findsOneWidget);
            final contextRow = find.text('Inspect surrounding source').last;
            await tester.ensureVisible(contextRow);
            await tester.tap(contextRow);
            await tester.pumpAndSettle();
            expect(
              find.textContaining('value259: "Old 😀 259" # context'),
              findsOneWidget,
            );
            expect(
              find.textContaining('value259: "New 😀 259" # context'),
              findsOneWidget,
            );
            final staleApply = tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(
                    BusyApiDialogButton,
                    'Replace 261 matches',
                  ),
                )
                .onPressed!;
            final part = c.store!.buffers.values.singleWhere(
              (b) => b.path.endsWith('part.yaml'),
            );
            await tester.runAsync(() async {
              c.sourceEdit(part.id, '${part.text}\r\n# changed after review');
              await c.persist();
            });
            final before = {
              for (final b in c.store!.buffers.values) b.id: b.text,
            };
            await tester.runAsync(() async => staleApply());
            final rejecting = Stopwatch()..start();
            bool rejected() => tester
                .widgetList<BusyApiStatusBox>(find.byType(BusyApiStatusBox))
                .any((box) => box.kind == BusyApiStatusKind.error);
            while (!rejected() &&
                rejecting.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(rejected(), true);
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(BusyApiDialogShell),
                matching: find.text(
                  'Source changed after this search. Search again before applying or navigating.',
                ),
              ),
              findsOneWidget,
            );
            expect({
              for (final b in c.store!.buffers.values) b.id: b.text,
            }, before);
            await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Close'));
            await tester.pumpAndSettle();
            await tester.runAsync(search.search);
            await tester.pumpAndSettle();
            await tester.tap(find.text('Review replacement'));
            await tester.pumpAndSettle();
          }
          await tester.runAsync(
            () => tester.tap(
              find.text(
                matches == 1 ? 'Replace 1 match' : 'Replace $matches matches',
              ),
            ),
          );
          final applying = Stopwatch()..start();
          while (find.byType(BusyApiDialogShell).evaluate().isNotEmpty &&
              applying.elapsed < const Duration(seconds: 8)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          await tester.pumpAndSettle();
          expect(find.byType(BusyApiDialogShell), findsNothing);
          expect(c.buffer!.text, contains('New unsaved'));
          expect(
            File('${temp.path}/api/openapi.yaml').readAsStringSync(),
            before,
          );
          c.store!.undo();
          expect(c.buffer!.text, contains('Old unsaved'));
          expect(
            c.store!.buffers.values
                .where((b) => b.path.endsWith('part.yaml'))
                .single
                .text,
            matches > 200
                ? '$partSource\r\n# changed after review'
                : partSource,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          session?.dispose();
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
  testWidgets(
    'search collection refreshes mounted Source and ignores a previous project or disposed owner',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-search-owner-');
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      try {
        await tester.runAsync(() async {
          await c.initialize();
          await Initializer.create(
            destination: '${temp.path}/one',
            title: 'Original',
            apiVersion: '1',
          );
          await Initializer.create(
            destination: '${temp.path}/two',
            title: 'Second',
            apiVersion: '1',
          );
          await c.open('${temp.path}/one');
        });
        final owner = c.project!, buffer = c.buffer!;
        final oldSearch = c.projectSearch(owner);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SourceEditor(
                buffer: buffer,
                owner: owner,
                changes: c,
                isCurrent: () => !c.disposed && identical(c.project, owner),
                onChanged: (_) {},
                undo: () {},
                redo: () {},
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await File(buffer.path)
              .writeAsString(buffer.text.replaceFirst('Original', 'Reloaded'));
          expect(
            (await oldSearch.run(const SearchOptions('Reloaded'))).matches,
            hasLength(1),
          );
        });
        await tester.pump();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          contains('Reloaded'),
        );
        // A retained search object must not notify a new owner, including after
        // the original Source control has been unmounted.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => c.open('${temp.path}/two'));
        var notifications = 0;
        c.addListener(() => notifications++);
        await tester.runAsync(() async {
          await File(buffer.path)
              .writeAsString(buffer.text.replaceFirst('Reloaded', 'Later'));
          await oldSearch.run(const SearchOptions('Later'));
        });
        // Ignore ordinary analysis of the new project; the resource refresh
        // callback itself is synchronous and must not touch its selection.
        expect(c.buffer!.text, contains('Second'));
        final second = c.buffer!.text;
        await tester.runAsync(c.shutdown);
        c.dispose();
        final count = notifications;
        await tester.runAsync(() async {
          await File(buffer.path)
              .writeAsString(buffer.text.replaceFirst('Later', 'Final'));
          await oldSearch.run(const SearchOptions('Final'));
        });
        expect(notifications, count);
        expect(c.buffer?.text, second);
        oldSearch.cancel();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!c.disposed) {
          await tester.runAsync(c.shutdown);
          c.dispose();
        }
        temp.deleteSync(recursive: true);
      }
    },
  );
}
