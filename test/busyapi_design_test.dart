// Ported BusyMark control assertions, Copyright 2026 BusyStack, Apache-2.0.
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

void main() {
  testWidgets('compact icon actions expose their localized accessible name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final brightness in Brightness.values) {
        for (final enabled in [true, false]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: brightness,
                accentColor: const Color(0xFF3584E4),
              ),
              home: Scaffold(
                body: BusyApiCompactIconButton(
                  tooltip: 'Arrêter 雪',
                  icon: Icons.stop,
                  onPressed: enabled ? () {} : null,
                ),
              ),
            ),
          );
          expect(
            tester
                .getSemantics(find.byType(IconButton))
                .getSemanticsData()
                .label,
            'Arrêter 雪',
          );
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('dialog title and body share a clipped surface in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildBusyApiTheme(
            brightness: brightness,
            accentColor: const Color(0xFFE95420),
          ),
          home: const Scaffold(
            body: BusyApiDialogShell(title: 'Dialog', children: [Text('Body')]),
          ),
        ),
      );
      final shell = find.byType(BusyApiDialogShell);
      final dialog = tester.widget<Dialog>(
        find.descendant(of: shell, matching: find.byType(Dialog)),
      );
      final titleBar = tester.widget<YaruDialogTitleBar>(
        find.descendant(of: shell, matching: find.byType(YaruDialogTitleBar)),
      );
      expect(
        dialog.backgroundColor,
        busyApiDialogSurfaceColor(tester.element(shell)),
      );
      expect(titleBar.backgroundColor, dialog.backgroundColor);
      expect(dialog.surfaceTintColor, dialog.backgroundColor);
      expect(dialog.clipBehavior, Clip.antiAlias);
    }
  });

  testWidgets('dialog actions wrap at narrow localized text widths', (
    tester,
  ) async {
    final theme = buildBusyApiTheme(
      brightness: Brightness.light,
      accentColor: const Color(0xFFE95420),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: SizedBox(
                width: 320,
                height: 520,
                child: BusyApiDialogShell(
                  title: 'Unsaved changes',
                  actions: [
                    BusyApiDialogButton(
                      label: 'Keep editing',
                      onPressed: () {},
                    ),
                    BusyApiDialogButton(
                      label: 'Discard changes',
                      destructive: true,
                      onPressed: () {},
                    ),
                    BusyApiDialogButton(
                      label: 'Save changes',
                      suggested: true,
                      onPressed: () {},
                    ),
                  ],
                  children: const [Text('Choose how to continue.')],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(OverflowBar), findsOneWidget);
    final actionRows = {
      for (final label in ['Keep editing', 'Discard changes', 'Save changes'])
        tester.getCenter(find.text(label)).dy,
    };
    expect(actionRows.length, greaterThan(1));
  });

  testWidgets('grouped text entry uses the native row-owned form surface', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildBusyApiTheme(
          brightness: Brightness.light,
          accentColor: const Color(0xFF3584E4),
        ),
        home: Scaffold(
          body: BusyApiGroupedList(
            filled: true,
            children: [
              BusyApiGroupedTextEntry(
                label: 'Language',
                controller: controller,
                hintText: 'dart',
                errorText: 'Required',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(YaruListTile), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    expect(
      tester
          .widget<BusyApiGroupedTextEntry>(find.byType(BusyApiGroupedTextEntry))
          .readOnly,
      isFalse,
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isFalse);
    final decoration = field.decoration!;
    expect(decoration.filled, isFalse);
    expect(decoration.fillColor, Colors.transparent);
    expect(decoration.hoverColor, Colors.transparent);
    expect(decoration.border, InputBorder.none);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
    expect(decoration.contentPadding, EdgeInsets.zero);
    expect(decoration.labelText, 'Language');
    expect(decoration.hintText, 'dart');
    expect(find.text('Required'), findsOneWidget);
  });
}
