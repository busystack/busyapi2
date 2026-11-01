import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _AssistanceEngine extends EngineProcess {
  _AssistanceEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  int calls = 0;
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'assistSource') {
      calls++;
      final gate = release;
      if (gate != null) {
        entered!.complete();
        await gate.future;
      }
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final behavior in [
    'accept',
    'incomplete',
    'composition',
    'stale',
    'dispose',
    'help',
    'hover',
    'definition',
    'usages',
  ]) {
    testWidgets(
      'Source assistance $behavior uses the existing full-source input owner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-source-intelligence-',
        );
        final engine = _AssistanceEngine(), changes = ValueNotifier(0);
        final key = GlobalKey<SourceEditorState>();
        final reveals = <Map<String, dynamic>>[];
        BusyProject? project;
        late DocumentBuffer buffer;
        final marker = behavior == 'incomplete'
            ? r'{"openapi":"3.2.1","info":{"title":"Source", "version":"1", "summ§},"paths":{}}'
            : r'{"openapi":"3.2.1","info":{"title":"Source", § "version":"1"},"paths":{},"components":{"schemas":{"Model":{"$ref":"part.json#/Thing"}}}}';
        final original = marker.replaceFirst('§', '');
        final caret = ['definition', 'usages'].contains(behavior)
            ? original.indexOf('part.json') + 3
            : behavior == 'help'
            ? original.indexOf('"title"') + 3
            : marker.indexOf('§');
        Future<void> waitFor(bool Function() predicate) async {
          final timer = Stopwatch()..start();
          while (!predicate() && timer.elapsed < const Duration(seconds: 8)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(predicate(), true);
          await tester.pumpAndSettle();
        }

        Future<void> complete() async {
          await tester.runAsync(
            () => tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft),
          );
          await tester.runAsync(
            () => tester.sendKeyEvent(LogicalKeyboardKey.space),
          );
          await tester.runAsync(
            () => tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft),
          );
          await tester.pump();
        }

        try {
          await tester.runAsync(() async {
            final file = File('${temp.path}/root.json');
            await file.writeAsString(
              behavior == 'incomplete'
                  ? original.replaceFirst('"summ}', '"summary":""}')
                  : original,
            );
            await File('${temp.path}/part.json').writeAsString(
              '{"Thing":{"type":"string","description":"Located definition"}}',
            );
            project = await BusyProject.open(file.path, engine);
            buffer = await project!.buffer(project!.roots.single.id);
            if (behavior == 'incomplete') {
              project!.store.replace(buffer.id, original);
            }
            buffer.selection = SourceSelection(caret, caret);
            await project!.check(project!.roots.single.id);
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
                body: SourceEditor(
                  key: key,
                  buffer: buffer,
                  owner: project,
                  changes: changes,
                  // Explicit completion remains usable while automatic
                  // outlines defer to the workspace's structural collection.
                  backgroundAssistanceReady: behavior == 'accept'
                      ? () => false
                      : null,
                  onReveal: reveals.add,
                  assistance: (selection) => project!.sourceAssistance(
                    project!.roots.single.id,
                    buffer.id,
                    selection,
                  ),
                  onEdit: (edit) {
                    project!.store.apply([edit], label: 'Source');
                    changes.value++;
                  },
                  onChanged: (_) =>
                      fail('Assistance replaced the source input transaction'),
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
            ),
          );
          await tester.tap(find.byType(TextField));
          key.currentState!.select(
            SourceSelection(caret, caret),
            reveal: false,
          );
          await tester.pump();
          if (behavior == 'dispose') {
            engine.entered = Completer();
            engine.release = Completer();
          }
          if (behavior == 'help') {
            await tester.runAsync(
              () => tester.sendKeyEvent(LogicalKeyboardKey.f1),
            );
          } else if (behavior == 'definition') {
            await tester.runAsync(
              () => tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft),
            );
            await tester.runAsync(
              () => tester.sendKeyEvent(LogicalKeyboardKey.keyB),
            );
            await tester.runAsync(
              () => tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft),
            );
          } else if (behavior == 'usages') {
            await tester.runAsync(
              () => tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft),
            );
            await tester.runAsync(
              () => tester.sendKeyEvent(LogicalKeyboardKey.f7),
            );
            await tester.runAsync(
              () => tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft),
            );
          } else if (behavior == 'hover') {
            final editable = tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable;
            final rect = editable.getLocalRectForCaret(
              TextPosition(offset: original.indexOf('"title"') + 3),
            );
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await tester.runAsync(
              () => mouse.addPointer(location: const Offset(0, 0)),
            );
            await tester.runAsync(
              () => mouse.moveTo(editable.localToGlobal(rect.center)),
            );
            addTearDown(mouse.removePointer);
          } else {
            await complete();
          }
          if (behavior == 'definition') {
            await waitFor(() => reveals.isNotEmpty);
            expect(reveals.single['resource'], endsWith('/part.json'));
            expect(reveals.single['pointer'], '/Thing');
            final target = await tester.runAsync(
              () => project!.buffer(reveals.single['resource'] as String),
            );
            expect(reveals.single['identity'], target!.sourceIdentity);
            expect(buffer.text, original);
            return;
          }
          if (behavior == 'help' || behavior == 'hover') {
            await waitFor(
              () => find.textContaining('Authored title').evaluate().isNotEmpty,
            );
            expect(
              find.textContaining(
                'https://spec.openapis.org/oas/v3.2.1.html#info-object',
              ),
              findsOneWidget,
            );
            expect(buffer.selection.extent, caret);
            expect(buffer.text, original);
            return;
          }
          if (behavior == 'usages') {
            final usage = find.text(r'/components/schemas/Model/$ref');
            await waitFor(() => usage.evaluate().isNotEmpty);
            await tester.runAsync(() => tester.tap(usage));
            expect(reveals.single['resource'], buffer.id);
            expect(
              reveals.single['pointer'],
              r'/components/schemas/Model/$ref',
            );
            expect(buffer.text, original);
            return;
          }
          if (behavior == 'dispose') {
            await waitFor(() => engine.entered!.isCompleted);
            await tester.pumpWidget(const SizedBox.shrink());
            engine.release!.complete();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump();
            expect(buffer.text, original);
            expect(tester.takeException(), isNull);
            return;
          }
          await waitFor(() => find.text('summary').evaluate().isNotEmpty);
          expect(
            find.byKey(const ValueKey('source-assistance-popup')),
            findsOneWidget,
          );
          expect(engine.calls, 1);
          if (behavior == 'accept' || behavior == 'incomplete') {
            await tester.runAsync(() => tester.tap(find.text('summary')));
            await tester.pumpAndSettle();
            expect(jsonDecode(buffer.text)['info']['summary'], '');
            expect(
              find.byKey(const ValueKey('source-assistance-popup')),
              findsNothing,
            );
            project!.store.undo();
            expect(buffer.text, original);
            project!.store.redo();
            expect(jsonDecode(buffer.text)['info']['summary'], '');
            await tester.runAsync(() => project!.save(buffer));
            expect(File(buffer.path).readAsStringSync(), buffer.text);
          } else if (behavior == 'stale') {
            final row = find
                .ancestor(
                  of: find.text('summary'),
                  matching: find.byType(InkWell),
                )
                .first;
            final staleClick = tester.widget<InkWell>(row).onTap!;
            key.currentState!.select(
              SourceSelection(caret + 1, caret + 1),
              reveal: false,
            );
            await tester.pump();
            staleClick();
            await tester.pumpAndSettle();
            expect(buffer.text, original);
            expect(
              find.byKey(const ValueKey('source-assistance-popup')),
              findsNothing,
            );
          } else {
            final preedit =
                '${original.substring(0, caret)}中${original.substring(caret)}';
            tester.testTextInput.updateEditingValue(
              TextEditingValue(
                text: preedit,
                selection: TextSelection.collapsed(offset: caret + 1),
                composing: TextRange(start: caret, end: caret + 1),
              ),
            );
            await tester.pump();
            expect(buffer.text, preedit);
            expect(
              find.byKey(const ValueKey('source-assistance-popup')),
              findsNothing,
            );
            await complete();
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pump();
            expect(engine.calls, 1);
            expect(buffer.text, preedit);
            tester.testTextInput.updateEditingValue(
              TextEditingValue(
                text: preedit,
                selection: TextSelection.collapsed(offset: caret + 1),
              ),
            );
            await tester.pump();
            expect(buffer.text, preedit);
          }
          expect(tester.takeException(), isNull);
        } finally {
          if (engine.release != null && !engine.release!.isCompleted) {
            engine.release!.complete();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            project?.close();
            await engine.close();
          });
          changes.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
