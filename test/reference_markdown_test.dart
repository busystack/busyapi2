import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/reference/reference_markdown.dart';
import 'package:busyapi/src/reference/owned_reference_markdown.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

Future<void> ready(WidgetTester tester, bool Function() done) async {
  final limit = DateTime.now().add(const Duration(seconds: 8));
  while (!done() && DateTime.now().isBefore(limit)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), true);
}

Widget screen(String text, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: buildBusyApiTheme(
        brightness: brightness,
        accentColor: Colors.blue,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReferenceMarkdownText(
            key: const ValueKey('owned-description'),
            text: text,
            base: Uri.parse('https://docs.example/source/api.yaml'),
          ),
        ),
      ),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'native CommonMark ${brightness.name} keeps safe text and explicitly copies only inspected links',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          screen(
            '# Heading 雪\n\n**Bold** and *emphasis*.\n\n![Alt text](https://must-not-load.invalid/image)\n\n[Guide](../guide) [unsafe](javascript:bad)',
            brightness: brightness,
          ),
        );
        await ready(tester, () => find.text('Heading 雪').evaluate().isNotEmpty);
        expect(find.byType(Image), findsNothing);
        expect(copied, isEmpty);
        expect(find.text('Alt text'), findsOneWidget);
        final inspect = find.widgetWithText(
          BusyApiActionRow,
          'Inspect documentation links (1)',
        );
        await tester.ensureVisible(inspect);
        await tester.tap(inspect);
        await tester.pump();
        final copy = find.widgetWithText(BusyApiActionRow, 'Copy link: Guide');
        await tester.ensureVisible(copy);
        await tester.tap(copy);
        await tester.pump();
        expect(copied, ['https://docs.example/guide']);
        expect(
          find.text('Link copied. No resource was opened or requested.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'native Markdown lists and link inspections expose their last page with bounded rows',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        screen(
          [for (var index = 0; index < 261; index++) '- entry$index']
              .join('\n'),
        ),
      );
      await ready(tester, () => find.text('entry0').evaluate().isNotEmpty);
      expect(find.text('entry260'), findsNothing);
      for (var page = 0; page < 5; page++) {
        final next = find.widgetWithText(FilledButton, 'Next');
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pump();
      }
      expect(find.text('entry260'), findsOneWidget);
      expect(find.byType(Text).evaluate().length, lessThan(100));
      await tester.pumpWidget(
        screen(
          [
            for (var index = 0; index < 61; index++)
              '[L$index](https://docs.example/$index)',
          ].join(' '),
        ),
      );
      await ready(
        tester,
        () =>
            find.text('Inspect documentation links (61)').evaluate().isNotEmpty,
      );
      final inspect = find.widgetWithText(
        BusyApiActionRow,
        'Inspect documentation links (61)',
      );
      await tester.ensureVisible(inspect);
      await tester.tap(inspect);
      await tester.pump();
      final next = find.widgetWithText(FilledButton, 'Next');
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pump();
      expect(
        find.widgetWithText(BusyApiActionRow, 'Copy link: L60'),
        findsOneWidget,
      );
      expect(find.byType(BusyApiActionRow).evaluate().length, lessThan(20));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native description replacement/disposal rejects late parsing and long text preserves the final Unicode page',
    (tester) async {
      await tester.pumpWidget(screen('[unfinished](' * 1000));
      await tester.pumpWidget(screen('**Current**'));
      await ready(tester, () => find.text('Current').evaluate().isNotEmpty);
      expect(find.textContaining('unfinished'), findsNothing);
      final long = '${'x' * 32767}😀last 雪';
      await tester.pumpWidget(screen(long));
      expect(
        find.text(
          'Long descriptions use paged plain text. No content is omitted.',
        ),
        findsOneWidget,
      );
      for (var page = 0; page < 2; page++) {
        final next = find.widgetWithText(FilledButton, 'Next');
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pump();
      }
      expect(find.text('😀last 雪'), findsOneWidget);
      await tester.pumpWidget(screen('[unfinished](' * 1000));
      await tester.pumpWidget(const SizedBox());
      await ready(tester, () => ReferenceMarkdownJob.admission == (0, 0));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'owned Markdown last-page state survives reparse, semantic rename, undo/redo and restart without stale-owner writes',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-markdown-state-',
      );
      final source = File('${temp.path}/root.json');
      final text = [for (var index = 0; index < 261; index++) '- entry$index 雪']
          .join('\n');
      final original = jsonEncode({
        'openapi': '3.2.1',
        'info': {'title': 'Reading', 'version': '1'},
        'paths': {},
        'components': {
          'schemas': {
            'Model': {'description': text},
          },
        },
      });
      source.writeAsStringSync(original);
      final locations = StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      );
      WorkspaceController create() => WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        locations,
      );
      var c = create();
      String pointer = '/components/schemas/Model/description';
      Widget owned({String? value}) => MaterialApp(
        theme: buildBusyApiTheme(
          brightness: Brightness.light,
          accentColor: Colors.blue,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: OwnedReferenceMarkdownText(
              controller: c,
              root: c.root!,
              resource: source.uri.toString(),
              pointer: pointer,
              text: value ?? text,
            ),
          ),
        ),
      );
      try {
        await tester.runAsync(() async {
          await c.initialize();
          await c.open(source.path);
          await c.analyse();
        });
        await tester.pumpWidget(owned());
        await ready(tester, () => find.text('entry0 雪').evaluate().isNotEmpty);
        for (var page = 0; page < 5; page++) {
          final next = find.widgetWithText(FilledButton, 'Next');
          await tester.ensureVisible(next);
          await tester.tap(next);
          await tester.pump();
        }
        expect(find.text('entry260 雪'), findsOneWidget);
        await tester.pumpWidget(
          owned(value: '$text\n- added after the current page'),
        );
        await ready(
          tester,
          () => find.text('entry260 雪').evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(owned());
        await ready(
          tester,
          () => find.text('entry260 雪').evaluate().isNotEmpty,
        );
        await tester.runAsync(() async {
          final owner = c.project!,
              buffer = await owner.buffer(source.uri.toString());
          final plan = await owner.planComponentRename({
            'root': c.root,
            'resource': buffer.id,
            'pointer': '/components/schemas/Model',
            'generation': buffer.generation,
          }, 'Renamed');
          await c.applyRefactoring(owner, plan);
        });
        final states = c.layoutState['referenceText'] as Map;
        expect(
          states.keys.whereType<String>().any(
            (key) => key.contains('/Model/description'),
          ),
          false,
        );
        expect(
          states.keys.whereType<String>().any(
            (key) => key.contains('/Renamed/description'),
          ),
          true,
        );
        // The still-mounted old route captured its earlier semantic revision.
        final previous = find.widgetWithText(FilledButton, 'Previous');
        await tester.ensureVisible(previous);
        await tester.tap(previous);
        await tester.pump();
        expect(
          (c.layoutState['referenceText'] as Map).keys.whereType<String>().any(
            (key) => key.contains('/Model/description'),
          ),
          false,
        );
        pointer = '/components/schemas/Renamed/description';
        await tester.pumpWidget(owned());
        await ready(
          tester,
          () => find.text('entry260 雪').evaluate().isNotEmpty,
        );
        await tester.runAsync(c.undo);
        pointer = '/components/schemas/Model/description';
        await tester.pumpWidget(owned());
        await ready(
          tester,
          () => find.text('entry260 雪').evaluate().isNotEmpty,
        );
        await tester.runAsync(c.redo);
        pointer = '/components/schemas/Renamed/description';
        await tester.pumpWidget(owned());
        await ready(
          tester,
          () => find.text('entry260 雪').evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await c.saveAll();
          await c.persistView();
          c.dispose();
          await c.engine.close();
        });
        c = create();
        await tester.runAsync(() async {
          await c.initialize();
          await c.open(source.path);
          await c.analyse();
        });
        await tester.pumpWidget(owned());
        await ready(
          tester,
          () => find.text('entry260 雪').evaluate().isNotEmpty,
        );
        expect(
          source.readAsStringSync(),
          original.replaceFirst('"Model"', '"Renamed"'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.runAsync(() async {
          await c.engine.close();
          await temp.delete(recursive: true);
        });
      }
    },
  );
}
