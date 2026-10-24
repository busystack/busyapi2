import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'diagnostic ranges retain exact text and never replace composing underlines',
    (tester) async {
      const text = 'description: "雪😀"\r\nrequired: false';
      final buffer = DocumentBuffer(
        id: 'view',
        path: 'value.yaml',
        text: text,
        baseline: text,
        diskIdentity: '',
        hasBom: false,
      );
      final start = text.indexOf('false');
      final controller = SyntaxController()
        ..diagnosticsBuffer = buffer
        ..diagnostics = [
          SourceDiagnostic(
            resource: buffer.id,
            generation: 1,
            start: start,
            end: text.length,
            code: 'parameter.path.required',
            severity: 'error',
            message: 'Localized, masked explanation',
          ),
        ]
        ..value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: start + 3),
          composing: TextRange(start: start + 1, end: start + 3),
        );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      List<(int, int, TextStyle?)> runs(TextSpan span) {
        final output = <(int, int, TextStyle?)>[];
        var offset = 0;
        void visit(TextSpan item) {
          if (item.text != null) {
            output.add((offset, offset + item.text!.length, item.style));
            offset += item.text!.length;
          }
          for (final child in item.children ?? const <InlineSpan>[]) {
            if (child is TextSpan) visit(child);
          }
        }

        visit(span);
        return output;
      }

      final span = controller.buildTextSpan(
        context: context,
        withComposing: true,
      );
      expect(span.toPlainText(), text);
      final marked = runs(span);
      expect(
        marked.any(
          (r) =>
              r.$1 == start &&
              r.$3?.decorationStyle == TextDecorationStyle.wavy,
        ),
        true,
      );
      final preedit = marked.singleWhere(
        (r) => r.$1 == start + 1 && r.$2 == start + 3,
      );
      expect(preedit.$3?.decoration, TextDecoration.underline);
      expect(preedit.$3?.decorationStyle, isNot(TextDecorationStyle.wavy));
      expect(
        marked.any(
          (r) =>
              r.$1 == start + 3 &&
              r.$3?.decorationStyle == TextDecorationStyle.wavy,
        ),
        true,
      );
      buffer.generation++;
      final stale = controller.buildTextSpan(
        context: context,
        withComposing: true,
      );
      expect(stale.toPlainText(), text);
      expect(
        runs(stale)
            .any((r) => r.$3?.decorationStyle == TextDecorationStyle.wavy),
        false,
      );
      expect(
        runs(stale).any((r) => r.$3?.decoration == TextDecoration.underline),
        true,
      );
      final emoji = text.indexOf('😀');
      controller.diagnostics = [
        SourceDiagnostic(
          resource: buffer.id,
          generation: buffer.generation,
          start: emoji + 1,
          end: emoji + 2,
          code: 'syntax',
          severity: 'error',
          message: 'A located syntax finding',
        ),
      ];
      controller.value = controller.value.copyWith(composing: TextRange.empty);
      final unicode = controller.buildTextSpan(
        context: context,
        withComposing: true,
      );
      expect(unicode.toPlainText(), text);
      expect(
        runs(unicode).any(
          (r) =>
              r.$1 == emoji &&
              r.$2 == emoji + 2 &&
              r.$3?.decorationStyle == TextDecorationStyle.wavy,
        ),
        true,
        reason: 'Decoration cannot split a non-BMP character into separately shaped surrogate spans',
      );
      controller.dispose();
    },
  );
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'later diagnostic markers $brightness remain lazy, current and bounded after full-source reveal',
      (tester) async {
        final text = List.generate(900, (i) => 'field$i: "雪😀"').join('\r\n');
        final buffer = DocumentBuffer(
          id: 'view',
          path: 'value.yaml',
          text: text,
          baseline: text,
          diskIdentity: '',
          hasBom: false,
        );
        final store = BufferStore()..buffers[buffer.id] = buffer;
        final diagnostics = [
          for (var line = 1; line <= 900; line++)
            SourceDiagnostic(
              resource: buffer.id,
              generation: 1,
              start: buffer.lines.lineAt(line).startOffset,
              end: buffer.lines.lineAt(line).endOffset,
              code: 'finding-$line',
              severity: 'error',
              message: 'Localized finding on line $line',
            ),
        ];
        final key = GlobalKey<SourceEditorState>();
        Widget host() => MaterialApp(
          theme: buildBusyApiTheme(
            brightness: brightness,
            accentColor: const Color(0xffe95420),
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SourceEditor(
              key: key,
              buffer: buffer,
              diagnostics: diagnostics,
              onChanged: (value) => store.replace(buffer.id, value),
              onEdit: (edit) => store.apply([edit]),
              undo: store.undo,
              redo: store.redo,
            ),
          ),
        );
        await tester.pumpWidget(host());
        await tester.pump();
        key.currentState!.reveal(buffer.lines.lineAt(800).startOffset);
        await tester.pump();
        await tester.pump();
        final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
        expect(
          tooltips.any(
            (tooltip) => tooltip.message?.startsWith('finding-800:') ?? false,
          ),
          true,
        );
        expect(
          tooltips.length,
          lessThan(120),
          reason: 'Only the source window, not 900 gutter rows, is mounted',
        );
        final field = tester.widget<EditableText>(find.byType(EditableText));
        expect(field.controller.text.length, lessThanOrEqualTo(16384));
        final marked = (field.controller as SyntaxController).buildTextSpan(
          context: tester.element(find.byType(EditableText)),
          withComposing: false,
        );
        expect(marked.toPlainText(), field.controller.text);
        key.currentState!.select(
          SourceSelection(0, text.length),
          reveal: false,
        );
        await tester.pump();
        expect(buffer.selection.base, 0);
        expect(buffer.selection.extent, text.length);
        expect(buffer.text, text);
        buffer.generation++;
        await tester.pumpWidget(host());
        await tester.pump();
        expect(
          tester
              .widgetList<Tooltip>(find.byType(Tooltip))
              .any((t) => t.message?.startsWith('finding-') ?? false),
          false,
        );
        expect(buffer.text, text);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
