import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/designer/form_value_editor.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_io.dart';

Widget host(Widget child) => MaterialApp(
  theme: buildBusyApiTheme(
    brightness: Brightness.light,
    accentColor: const Color(0xffe95420),
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'a full data draft is windowed, exact, undoable and composition-aware without publication',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final original =
          '[\n${List.filled(18000, r'{"number":9007199254740993.00,"$ref":"literal payload 雪😀"}').join(',\n')}\n]';
      expect(original.length, greaterThan(1000000));
      final controller = TextEditingController(text: original),
          compositions = <bool>[];
      await tester.pumpWidget(
        host(
          FormValueEditor(
            label: 'Data',
            controller: controller,
            enabled: true,
            multiline: true,
            json: true,
            onCompositionChanged: compositions.add,
          ),
        ),
      );
      final source = find.byType(SourceEditor),
          key =
              tester.widget<SourceEditor>(source).key!
                  as GlobalKey<SourceEditorState>;
      final editable = find.descendant(
        of: source,
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(editable).controller.text.length,
        lessThanOrEqualTo(16384),
      );
      await tester.tapAt(tester.getTopLeft(source) + const Offset(120, 50));
      await tester.showKeyboard(editable);
      final shown = tester.widget<EditableText>(editable).controller.value;
      final at = shown.text.indexOf('literal');
      tester.testTextInput.updateEditingValue(
        shown.copyWith(
          text: shown.text.replaceRange(at, at, '漢'),
          selection: TextSelection.collapsed(offset: at + 1),
          composing: TextRange(start: at, end: at + 1),
        ),
      );
      await tester.pump();
      final changed = original.replaceFirst('literal', '漢literal');
      expect(controller.text, changed);
      expect(compositions, [true]);
      final preedit = tester.widget<EditableText>(editable).controller.value;
      tester.testTextInput.updateEditingValue(
        preedit.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      expect(controller.text, changed);
      expect(compositions, [true, false]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, original);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, changed);
      key.currentState!.select(
        SourceSelection(0, changed.length),
        reveal: false,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        (await runWidgetIo(
          tester,
          () => Clipboard.getData('text/plain'),
        ))?.text,
        changed,
      );
      key.currentState!.reveal(changed.length - 2);
      await tester.pump();
      expect(
        tester.widget<EditableText>(editable).controller.text.length,
        lessThanOrEqualTo(16384),
      );
      expect(controller.text, changed);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.text = 'retained after presentation disposal';
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pasting a large value promotes its existing field without losing text, selection or focus',
    (tester) async {
      final controller = TextEditingController(text: 'small');
      await tester.pumpWidget(
        host(
          FormValueEditor(
            label: 'Text',
            controller: controller,
            enabled: true,
            multiline: true,
            json: false,
            onCompositionChanged: (_) {},
          ),
        ),
      );
      final field = find.byType(EditableText);
      await tester.tapAt(
        tester.getTopLeft(find.byType(FormValueEditor)) + const Offset(120, 50),
      );
      await tester.showKeyboard(field);
      final large = '😀 雪\n' * 10000;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: large,
          selection: TextSelection(
            baseOffset: 3,
            extentOffset: large.length - 3,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.text, large);
      final source = tester.widget<SourceEditor>(find.byType(SourceEditor));
      expect(source.buffer.selection.base, 3);
      expect(source.buffer.selection.extent, large.length - 3);
      final shown = tester.widget<EditableText>(find.byType(EditableText));
      expect(shown.focusNode.hasFocus, true);
      expect(shown.controller.text.length, lessThanOrEqualTo(16384));
      expect(source.syntaxHighlight, false);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'captured data Apply rejects composition and accepts the exact committed value once',
    (tester) async {
      final original =
          '{"text":"${'雪😀 ' * 6000}","number":9007199254740993.00}';
      String? accepted;
      var calls = 0;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => editForm(
                context,
                'Data',
                [
                  const FormFieldSpec(
                    'value',
                    'Data value',
                    json: true,
                    multiline: true,
                  ),
                ],
                {'value': original},
                onApply: (result) async {
                  accepted = result['value'];
                  calls++;
                },
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(SourceEditor),
        matching: find.byType(EditableText),
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(SourceEditor)) + const Offset(120, 50),
      );
      await tester.showKeyboard(field);
      final shown = tester.widget<EditableText>(field).controller.value,
          at = shownOffset(original);
      tester.testTextInput.updateEditingValue(
        shown.copyWith(
          text: shown.text.replaceRange(at, at, '漢'),
          selection: TextSelection.collapsed(offset: at + 1),
          composing: TextRange(start: at, end: at + 1),
        ),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.textContaining('Finish composing'), findsOneWidget);
      await tester.tapAt(
        tester.getTopLeft(find.byType(SourceEditor)) + const Offset(120, 50),
      );
      await tester.showKeyboard(field);
      final value = tester.widget<EditableText>(field).controller.value;
      tester.testTextInput.updateEditingValue(
        value.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(accepted, original.replaceRange(at, at, '漢'));
      expect(find.byType(SourceEditor), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

int shownOffset(String text) => text.indexOf('雪');
