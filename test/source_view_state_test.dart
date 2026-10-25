import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  testWidgets(
    'a retired Source owner paints one coherent retained line window',
    (tester) async {
      const original = 'one\ntwo\nthree\nfour\nfive',
          replacement = 'one\ntwo\nthree\nfour';
      final buffer = DocumentBuffer(
        id: 'form-value:retired',
        path: 'value.yaml',
        text: original,
        baseline: original,
        diskIdentity: '',
        hasBom: false,
      );
      final store = BufferStore()..buffers[buffer.id] = buffer;
      buffer.selection = SourceSelection(original.length, original.length);
      final changes = ValueNotifier(0);
      var current = true;
      final editor = SourceEditor(
        buffer: buffer,
        owner: buffer,
        isCurrent: () => current,
        changes: changes,
        onChanged: (text) => store.replace(buffer.id, text),
        onEdit: (edit) => store.apply([edit]),
        undo: store.undo,
        redo: store.redo,
      );
      addTearDown(tester.view.resetPhysicalSize);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: const Color(0xffe95420),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: editor),
          ),
        );
        await tester.pump();
        final field = find.descendant(
          of: find.byType(SourceEditor),
          matching: find.byType(EditableText),
        );
        expect(tester.widget<EditableText>(field).controller.text, original);
        expect(find.text('5'), findsOneWidget);
        current = false;
        store.replace(buffer.id, replacement);
        changes.value++;
        final size = tester.view.physicalSize;
        tester.view.physicalSize = Size(size.width + 20, size.height + 20);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.widget<EditableText>(field).controller.text, original);
        expect(find.text('5'), findsOneWidget);
        expect(buffer.text, replacement);
        current = true;
        changes.value++;
        await tester.pump();
        await tester.pump();
        expect(tester.widget<EditableText>(field).controller.text, replacement);
        expect(find.text('5'), findsNothing);
        expect(find.text('4'), findsOneWidget);
        store.undo();
        changes.value++;
        await tester.pump();
        expect(tester.widget<EditableText>(field).controller.text, original);
        expect(find.text('5'), findsOneWidget);
        expect(buffer.text, original);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        changes.dispose();
      }
    },
  );
  test('fold pointers persist independently per root/resource without authoring project settings', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-fold-preferences-',
    );
    final file = File('${temp.path}/root.json');
    const source =
        '{"openapi":"3.2.1","info":{"title":"Views","version":"1"},"paths":{}}';
    await file.writeAsString(source);
    WorkspaceController workspace() => WorkspaceController(
      EngineProcess(executable: runtimeNode, helper: runtimeHelper),
      StateLocations(
        config: '${temp.path}/config',
        state: '${temp.path}/state',
        cache: '${temp.path}/cache',
      ),
    );
    var c = workspace();
    try {
      await c.initialize();
      await c.open(file.path);
      final owner = c.project!, root = c.root!;
      c.rememberSourceFolds(owner, root, root, const ['/info']);
      c.rememberSourceFolds(owner, 'another-root-context', root, const [
        '/paths',
      ]);
      await c.persistView();
      await c.shutdown();
      c.dispose();
      c = workspace();
      await c.initialize();
      await c.open(file.path);
      expect(c.sourceFolds(root, root), ['/info']);
      expect(c.sourceFolds('another-root-context', root), ['/paths']);
      expect(c.sourceFolds(root, 'another-resource'), isEmpty);
      expect(await file.readAsString(), source);
      expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
      c.rememberSourceFolds(owner, root, root, const []);
      expect(c.sourceFolds(root, root), [
        '/info',
      ], reason: 'A retired project cannot write the new owner’s fold state');
    } finally {
      await c.shutdown();
      c.dispose();
      await temp.delete(recursive: true);
    }
  });
  testWidgets(
    'restored reading window follows viewport independently of a full-document selection',
    (tester) async {
      final text = List.generate(
        6000,
        (i) => 'line${i.toString().padLeft(5, '0')}: "雪😀 value"',
      ).join('\r\n');
      final buffer =
          DocumentBuffer(
              id: 'form-value:view',
              path: 'value.yaml',
              text: text,
              baseline: text,
              diskIdentity: '',
              hasBom: false,
            )
            ..selection = SourceSelection(0, text.length)
            ..scroll = 1200;
      final store = BufferStore()..buffers[buffer.id] = buffer;
      final changes = ValueNotifier(0);
      final key = GlobalKey<SourceEditorState>();
      Widget host() => MaterialApp(
        theme: buildBusyApiTheme(
          brightness: Brightness.light,
          accentColor: const Color(0xffe95420),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SourceEditor(
            key: key,
            buffer: buffer,
            owner: buffer,
            changes: changes,
            onChanged: (text) => store.replace(buffer.id, text),
            onEdit: (edit) => store.apply([edit]),
            undo: store.undo,
            redo: store.redo,
          ),
        ),
      );
      try {
        await tester.pumpWidget(host());
        await tester.pump();
        final editor = find.byType(SourceEditor),
            field = find.descendant(
              of: editor,
              matching: find.byType(EditableText),
            );
        expect(
          tester.getRect(field).overlaps(tester.getRect(editor)),
          true,
          reason: 'The current text window must intersect its restored viewport, not sit at the distant selection extent',
        );
        final shown = tester.widget<EditableText>(field).controller.text;
        expect(shown, contains('line00060'));
        expect(shown.length, lessThanOrEqualTo(16384));
        expect(buffer.selection.base, 0);
        expect(buffer.selection.extent, text.length);
        expect(buffer.scroll, closeTo(1200, .1));
        expect(buffer.text, text);
        // A Design/external model edit may update an unrelated scope without
        // moving the full selection's reading viewport to its extent either.
        store.apply([
          TextEdit(
            buffer: buffer.id,
            generation: buffer.generation,
            start: 0,
            end: 0,
            expected: '',
            replacement: '# appended model update\r\n',
          ),
        ]);
        changes.value++;
        await tester.pump();
        await tester.pump();
        expect(tester.getRect(field).overlaps(tester.getRect(editor)), true);
        expect(
          tester.widget<EditableText>(field).controller.text,
          contains('line00060'),
        );
        expect(buffer.scroll, closeTo(1200, .1));
        store.apply([
          TextEdit(
            buffer: buffer.id,
            generation: buffer.generation,
            start: 0,
            end: 0,
            expected: '',
            replacement: '# next model update\r\n',
          ),
        ]);
        changes.value++;
        key.currentState!.reveal(buffer.text.length);
        await tester.pump();
        await tester.pump();
        expect(buffer.selection.base, buffer.text.length);
        expect(buffer.selection.extent, buffer.text.length);
        expect(
          buffer.scroll,
          greaterThan(100000),
          reason:
              'An explicit reveal wins over queued reading-window restoration',
        );
        expect(tester.getRect(field).overlaps(tester.getRect(editor)), true);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        changes.dispose();
      }
    },
  );
}
