// Ported BusyMark control assertions, Copyright 2026 BusyStack, Apache-2.0.
import 'dart:ui' as ui;

import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final enabled in [true, false]) {
      testWidgets(
        'action row keyboard focus is exposed to accessibility in ${brightness.name}, enabled=$enabled',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final before = FocusNode(), after = FocusNode();
          var activated = 0;
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: brightness,
                  accentColor: Colors.blue,
                ),
                home: Scaffold(
                  body: Column(
                    children: [
                      TextField(focusNode: before),
                      BusyApiActionRow(
                        title: 'Use exact example',
                        enabled: enabled,
                        onTap: () => activated++,
                      ),
                      TextField(focusNode: after),
                    ],
                  ),
                ),
              ),
            );
            before.requestFocus();
            await tester.pumpAndSettle();
            final control = find.bySemanticsLabel('Use exact example');
            final controlNode = tester.getSemantics(control);
            expect(
              controlNode.getSemanticsData().hasAction(
                ui.SemanticsAction.focus,
              ),
              enabled,
            );
            expect(
              controlNode.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              enabled,
            );
            expect(
              tester
                  .getSemantics(control)
                  .getSemanticsData()
                  .flagsCollection
                  .isButton,
              isTrue,
            );
            expect(
              tester
                  .getSemantics(control)
                  .getSemanticsData()
                  .flagsCollection
                  .isFocused,
              enabled ? ui.Tristate.isFalse : ui.Tristate.none,
            );
            if (enabled) {
              tester.binding.platformDispatcher.onSemanticsActionEvent!(
                ui.SemanticsActionEvent(
                  type: ui.SemanticsAction.focus,
                  viewId: tester.view.viewId,
                  nodeId: controlNode.id,
                ),
              );
              await tester.pumpAndSettle();
              expect(
                tester
                    .getSemantics(control)
                    .getSemanticsData()
                    .flagsCollection
                    .isFocused,
                ui.Tristate.isTrue,
              );
              before.requestFocus();
              await tester.pumpAndSettle();
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            if (enabled) {
              expect(
                tester
                    .getSemantics(control)
                    .getSemanticsData()
                    .flagsCollection
                    .isFocused,
                ui.Tristate.isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(activated, 1);
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
              expect(
                tester
                    .getSemantics(control)
                    .getSemanticsData()
                    .flagsCollection
                    .isFocused,
                ui.Tristate.isFalse,
              );
            }
            expect(after.hasPrimaryFocus, isTrue);
            expect(activated, enabled ? 1 : 0);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            before.dispose();
            after.dispose();
            semantics.dispose();
          }
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    testWidgets(
      'action row retains child button focus and activation in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final before = FocusNode(), child = FocusNode(), after = FocusNode();
        var rowActivations = 0, childActivations = 0;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: brightness,
                accentColor: Colors.blue,
              ),
              home: Scaffold(
                body: Column(
                  children: [
                    TextField(focusNode: before),
                    BusyApiActionRow(
                      title: 'Example action',
                      onTap: () => rowActivations++,
                      trailing: IconButton(
                        tooltip: 'More actions',
                        focusNode: child,
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () => childActivations++,
                      ),
                    ),
                    TextField(focusNode: after),
                  ],
                ),
              ),
            ),
          );
          before.requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          final row = find.bySemanticsLabel('Example action');
          expect(
            tester
                .getSemantics(row)
                .getSemanticsData()
                .flagsCollection
                .isFocused,
            ui.Tristate.isTrue,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(child.hasPrimaryFocus, isTrue);
          expect(
            tester
                .getSemantics(row)
                .getSemanticsData()
                .flagsCollection
                .isFocused,
            ui.Tristate.isFalse,
          );
          expect(
            tester
                .getSemantics(find.byTooltip('More actions'))
                .getSemanticsData()
                .flagsCollection
                .isButton,
            isTrue,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect((rowActivations, childActivations), (0, 1));
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(after.hasPrimaryFocus, isTrue);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          before.dispose();
          child.dispose();
          after.dispose();
          semantics.dispose();
        }
      },
    );
  }
  for (final brightness in Brightness.values) {
    for (final enabled in [true, false]) {
      testWidgets(
        'combo keyboard focus is exposed to accessibility in ${brightness.name}, enabled=$enabled',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final before = FocusNode(), after = FocusNode();
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: brightness,
                  accentColor: Colors.blue,
                ),
                home: Scaffold(
                  body: Column(
                    children: [
                      TextField(focusNode: before),
                      BusyApiComboRow<String>(
                        title: 'Target specification',
                        values: const ['3.0.4', '3.2.1'],
                        selected: '3.2.1',
                        labelFor: (value) => value,
                        enabled: enabled,
                        onSelected: (_) {},
                      ),
                      TextField(focusNode: after),
                    ],
                  ),
                ),
              ),
            );
            before.requestFocus();
            await tester.pumpAndSettle();
            final control = find.bySemanticsLabel('Target specification');
            expect(
              tester
                  .getSemantics(control)
                  .getSemanticsData()
                  .flagsCollection
                  .isFocused,
              enabled ? ui.Tristate.isFalse : ui.Tristate.none,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            if (enabled) {
              expect(
                tester
                    .getSemantics(control)
                    .getSemanticsData()
                    .flagsCollection
                    .isFocused,
                ui.Tristate.isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
              expect(
                tester
                    .getSemantics(control)
                    .getSemanticsData()
                    .flagsCollection
                    .isFocused,
                ui.Tristate.isFalse,
              );
            }
            expect(after.hasPrimaryFocus, isTrue);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            before.dispose();
            after.dispose();
            semantics.dispose();
          }
        },
      );
    }
  }

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
