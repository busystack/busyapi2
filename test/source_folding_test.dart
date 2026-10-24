import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'automatic folds await structural readiness without losing source or pending ownership',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('busyapi-fold-ready-');
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      final changes = ValueNotifier(0);
      BusyProject? project;
      var ready = false, captures = 0;
      const original =
          'openapi: 3.2.1\ninfo: {title: Deferred, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Value:\n      type: object\n      properties:\n        name: {type: string}\nx-tail: true\n';
      try {
        late DocumentBuffer buffer;
        await tester.runAsync(() async {
          final file = File('${temp.path}/root.yaml');
          await file.writeAsString(original);
          project = await BusyProject.open(file.path, engine);
          buffer = await project!.buffer(project!.roots.single.id);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.dark,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SourceEditor(
                buffer: buffer,
                owner: project,
                changes: changes,
                foldedPointers: const ['/components'],
                backgroundAssistanceReady: () => ready,
                assistance: (selection) {
                  captures++;
                  return project!.sourceAssistance(
                    project!.roots.single.id,
                    buffer.id,
                    selection,
                  );
                },
                onChanged: (_) => fail('Folding cannot serialize source'),
                onEdit: (edit) => project!.store.apply([edit]),
                undo: () {},
                redo: () {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          captures,
          0,
          reason: 'A checking workspace already owns snapshot collection',
        );
        expect(buffer.text, original);
        ready = true;
        changes.value++;
        await tester.pump(const Duration(milliseconds: 450));
        final clock = Stopwatch()..start();
        TextEditingController field() =>
            tester.widget<TextField>(find.byType(TextField)).controller!;
        while (field().text.contains('properties:') &&
            clock.elapsed < const Duration(seconds: 10)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(captures, 1);
        expect(field().text, isNot(contains('properties:')));
        expect(field().text, contains('x-tail: true'));
        expect(buffer.text, original);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        changes.dispose();
        project?.close();
        await tester.runAsync(engine.close);
        await tester.runAsync(() => temp.delete(recursive: true));
      }
    },
  );
  for (final json in [false, true]) {
    testWidgets(
      'restored megabyte fold remains a bounded projection through clean reload ${json ? 'JSON' : 'YAML'}',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync('busyapi-fold-large-');
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        BusyProject? project;
        late DocumentBuffer buffer;
        final changes = ValueNotifier(0), key = GlobalKey<SourceEditorState>();
        final payload = List.filled(10000, 'preserved data ${'a' * 90}');
        final original = json
            ? '${const JsonEncoder.withIndent('  ').convert({
                'openapi': '3.2.1',
                'info': {'title': 'Large', 'version': '1'},
                'x-data': payload,
                'paths': <String, Object?>{},
                'x-tail': 'tail 雪😀',
              })}\n'
            : 'openapi: 3.2.1\ninfo: {title: Large, version: "1"}\nx-data:\n${payload.map((s) => '  - $s\n').join()}paths: {}\nx-tail: tail 雪😀\n';
        Future<void> ready(bool Function() predicate) async {
          final clock = Stopwatch()..start();
          while (!predicate() && clock.elapsed < const Duration(seconds: 25)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 40)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(predicate(), true);
        }

        TextEditingController controller() =>
            tester.widget<TextField>(find.byType(TextField)).controller!;
        try {
          await tester.runAsync(() async {
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            await file.writeAsString(original);
            project = await BusyProject.open(file.path, engine);
            buffer = await project!.buffer(project!.roots.single.id);
          });
          expect(buffer.text.length, greaterThan(1024 * 1024));
          final watch = Stopwatch()..start();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.dark,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SourceEditor(
                  key: key,
                  buffer: buffer,
                  owner: project,
                  changes: changes,
                  foldedPointers: const ['/x-data'],
                  assistance: (s) => project!.sourceAssistance(
                    project!.roots.single.id,
                    buffer.id,
                    s,
                  ),
                  onChanged: (_) => fail('Folding cannot serialize source'),
                  onEdit: (edit) {
                    project!.store.apply([edit]);
                    changes.value++;
                  },
                  undo: () {},
                  redo: () {},
                ),
              ),
            ),
          );
          await ready(() => controller().text.contains('tail 雪😀'));
          expect(controller().text.length, lessThan(1024));
          expect(buffer.text, original);
          // Measure total collection/IPC/result handling, not only regex/parser
          // time. This is a widget usability observation, not native p95 evidence.
          // ignore: avoid_print
          print(
            'FOLD_LARGE ${json ? 'JSON' : 'YAML'} units=${original.length} readyMs=${watch.elapsedMilliseconds} visibleUnits=${controller().text.length}',
          );
          await tester.runAsync(() async {
            await File(
              buffer.path,
            ).writeAsString(original.replaceFirst('tail 雪😀', 'reloaded 雪😀'));
            final result = await project!.refreshResources();
            expect(result.resources, contains(buffer.id));
          });
          changes.value++;
          await tester.pump();
          expect(controller().text, contains('reloaded 雪😀'));
          expect(controller().text.length, lessThan(1024));
          expect(buffer.dirty, false);
          key.currentState!.reveal(buffer.text.indexOf('preserved data'));
          await tester.pump();
          expect(controller().text, contains('preserved data'));
          expect(controller().text.length, lessThanOrEqualTo(16384));
          expect(
            buffer.text,
            original.replaceFirst('tail 雪😀', 'reloaded 雪😀'),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          changes.dispose();
          project?.close();
          await tester.runAsync(engine.close);
          await tester.runAsync(() => temp.delete(recursive: true));
        }
      },
    );
  }
  for (final json in [false, true]) {
    for (final version in ['3.1.2', '3.2.1']) {
      testWidgets(
        'Source folds retain full source, editing, selection and history $version ${json ? 'JSON' : 'YAML'}',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-source-fold-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          String? clipboard;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.getData') {
                return {'text': clipboard};
              }
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          BusyProject? project;
          final changes = ValueNotifier(0);
          final key = GlobalKey<SourceEditorState>();
          var remembered = <String>[];
          final values = {
            'openapi': version,
            'info': {'title': 'Fold 雪😀', 'version': '1'},
            'components': {
              'schemas': {
                'Model': {
                  'type': 'object',
                  'properties': {
                    for (var i = 0; i < 300; i++)
                      'field$i': {
                        'type': 'string',
                        'description': 'Preserved $i 雪😀',
                      },
                  },
                },
              },
            },
            'paths': <String, Object?>{},
            'x-tail': 'after-fold',
          };
          final original = json
              ? '${const JsonEncoder.withIndent('  ').convert(values)}\r\n'
              : '# retained\r\nopenapi: $version\r\ninfo:\r\n  title: "Fold 雪😀"\r\n  version: \'1\'\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      type: object\r\n      properties:\r\n${List.generate(300, (i) => '        field$i:\r\n          type: string\r\n          description: "Preserved $i 雪😀"\r\n').join()}paths: {}\r\nx-tail: after-fold\r\n';
          late DocumentBuffer buffer;
          Future<void> waitFor(bool Function() ready) async {
            final watch = Stopwatch()..start();
            while (!ready() && watch.elapsed < const Duration(seconds: 15)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 25)),
              );
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(ready(), true);
            await tester.pump();
          }

          Finder fold(String pointer) =>
              find.byKey(ValueKey(('source-fold', pointer)));
          TextEditingController controller() =>
              tester.widget<TextField>(find.byType(TextField)).controller!;
          Future<void> shortcut(LogicalKeyboardKey key) async {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(key);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
          }

          Widget app() => MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SourceEditor(
                key: key,
                buffer: buffer,
                owner: project,
                changes: changes,
                foldedPointers: remembered,
                onFoldStateChanged: (p) => remembered = p,
                assistance: (s) => project!.sourceAssistance(
                  project!.roots.single.id,
                  buffer.id,
                  s,
                ),
                onChanged: (_) =>
                    fail('Folding must use the existing core transaction'),
                onEdit: (edit) {
                  project!.store.apply([edit], label: 'Source');
                  changes.value++;
                },
                undo: () {
                  project!.store.undo();
                  changes.value++;
                },
                redo: () {
                  project!.store.redo();
                  changes.value++;
                },
              ),
            ),
          );
          try {
            await tester.runAsync(() async {
              final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
              await file.writeAsBytes([
                239,
                187,
                191,
                ...utf8.encode(original),
              ]);
              project = await BusyProject.open(file.path, engine);
              buffer = await project!.buffer(project!.roots.single.id);
            });
            await tester.pumpWidget(app());
            await waitFor(
              () => fold('/components/schemas/Model').evaluate().isNotEmpty,
            );
            final before = buffer.bytes();
            await tester.tap(fold('/components/schemas/Model'));
            await tester.pump();
            expect(remembered, contains('/components/schemas/Model'));
            expect(controller().text, isNot(contains('Preserved 299')));
            expect(controller().text, contains('after-fold'));
            expect(buffer.bytes(), before);
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            await tester.pumpWidget(app());
            await waitFor(
              () =>
                  controller().text.contains('after-fold') &&
                  !controller().text.contains('Preserved 299'),
            );
            expect(buffer.bytes(), before);

            // Clipboard and projected whole-document selection include all hidden
            // source, not the shorter string painted by EditableText.
            await tester.tap(find.byType(TextField));
            await shortcut(LogicalKeyboardKey.keyA);
            await shortcut(LogicalKeyboardKey.keyC);
            final copied = await tester.runAsync(
              () => Clipboard.getData(Clipboard.kTextPlain),
            );
            expect(copied!.text, original);
            expect(buffer.selection.base, 0);
            expect(buffer.selection.extent, original.length);

            // Equal prefix characters in replacement are newly typed, not source
            // to retain from a hidden or out-of-window selection.
            tester.testTextInput.updateEditingValue(
              TextEditingValue(
                text: 'openapi: replacement 雪😀',
                selection: TextSelection.collapsed(
                  offset: 'openapi: replacement 雪😀'.length,
                ),
              ),
            );
            await tester.pump();
            expect(buffer.text, 'openapi: replacement 雪😀');
            await shortcut(LogicalKeyboardKey.keyZ);
            expect(buffer.bytes(), before);
            await waitFor(
              () => fold('/components/schemas/Model').evaluate().isNotEmpty,
            );
            // Undo restores source, not an obsolete hidden byte range. Collapse
            // the current owner again through its current native control.
            if (!remembered.contains('/components/schemas/Model')) {
              await tester.tap(fold('/components/schemas/Model'));
              await tester.pump();
            }
            final tail = buffer.text.indexOf('after-fold');
            key.currentState!.select(
              SourceSelection(tail, tail),
              reveal: false,
            );
            await tester.pump();
            final old = controller().value;
            final at = old.selection.extentOffset;
            final edited = old.text.replaceRange(at, at, '拼音');
            tester.testTextInput.updateEditingValue(
              TextEditingValue(
                text: edited,
                selection: TextSelection.collapsed(offset: at + 2),
                composing: TextRange(start: at, end: at + 2),
              ),
            );
            await tester.pump();
            expect(
              buffer.text,
              original.replaceFirst('after-fold', '拼音after-fold'),
            );
            expect(
              controller().value.composing,
              TextRange(start: at, end: at + 2),
            );
            await tester.pump(const Duration(milliseconds: 600));
            expect(
              controller().value.composing,
              TextRange(start: at, end: at + 2),
            );
            tester.testTextInput.updateEditingValue(
              controller().value.copyWith(composing: TextRange.empty),
            );
            await tester.pump();
            await shortcut(LogicalKeyboardKey.keyZ);
            expect(buffer.bytes(), before);

            // A Design edit inside a fold keeps the view collapsed but changes
            // the canonical hidden source. Revealing a diagnostic expands it.
            final where = buffer.text.indexOf('Preserved 299');
            project!.store.apply([
              TextEdit(
                buffer: buffer.id,
                generation: buffer.generation,
                start: where,
                end: where + 'Preserved 299'.length,
                expected: 'Preserved 299',
                replacement: 'Changed 299',
              ),
            ], label: 'Design');
            changes.value++;
            await tester.pump();
            expect(controller().text, isNot(contains('Changed 299')));
            key.currentState!.reveal(where);
            await tester.pump();
            expect(controller().text, contains('Changed 299'));
            expect(remembered, isNot(contains('/components/schemas/Model')));
            await tester.runAsync(() => project!.save(buffer));
            expect(
              await tester.runAsync(() => File(buffer.path).readAsBytes()),
              buffer.bytes(),
            );
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            project!.close();
            await tester.runAsync(() async {
              project = await BusyProject.open(buffer.path, engine);
              buffer = await project!.buffer(project!.roots.single.id);
            });
            expect(
              buffer.text,
              original.replaceFirst('Preserved 299', 'Changed 299'),
            );
            expect(buffer.hasBom, true);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            changes.dispose();
            project?.close();
            await tester.runAsync(engine.close);
            await tester.runAsync(() => temp.delete(recursive: true));
          }
        },
      );
    }
  }
}
