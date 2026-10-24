// Ported BusyMark control assertions, Copyright 2026 BusyStack (Apache-2.0).
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final native in [false, true]) {
    testWidgets(
      'selector forwards effective shortcut metadata to ${native ? 'GTK' : 'fallback'}',
      (tester) async {
        const channel = MethodChannel(nativeMenuChannelName);
        Map<Object?, Object?>? arguments;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (!native) throw MissingPluginException();
            if (call.method == 'show') {
              arguments = call.arguments as Map<Object?, Object?>;
              return 1;
            }
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BusyApiPopupSelector<String>(
                value: 'file',
                label: 'Document Text',
                tooltip: 'Search category',
                fullWidth: true,
                options: const [
                  BusyApiPopupSelectorOption(
                    value: 'file',
                    label: 'Document Text',
                    shortcut: 'F8',
                    gtkAccelerator: 'F8',
                  ),
                  BusyApiPopupSelectorOption(
                    value: 'actions',
                    label: 'Actions',
                  ),
                ],
                onSelected: (v) => selected = v,
              ),
            ),
          ),
        );
        final button = tester.widget<BusyApiMenuButton<String>>(
          find.byType(BusyApiMenuButton<String>),
        );
        final item = button.items.first as BusyApiPopupMenuItem<String>;
        expect(item.shortcut, 'F8');
        expect(item.gtkAccelerator, 'F8');
        await tester.tap(find.byTooltip('Search category'));
        await tester.pumpAndSettle();
        if (native) {
          final entries = arguments!['entries'] as List;
          expect((entries.first as Map)['shortcut'], 'F8');
          expect((entries.first as Map)['gtkAccelerator'], 'F8');
          expect((entries[1] as Map)['shortcut'], isNull);
          expect(selected, 'actions');
        } else {
          expect(find.text('F8'), findsOneWidget);
          expect(item.checked, isTrue);
          await tester.tap(find.text('Actions'));
          await tester.pumpAndSettle();
          expect(selected, 'actions');
        }
      },
    );
  }

  testWidgets('grouped list headings use the native semantic heading style', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final theme = buildBusyApiTheme(
        brightness: brightness,
        accentColor: const Color(0xFF3584E4),
      );
      final colors = theme.extension<BusyApiSurfaceColors>()!;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          darkTheme: theme,
          themeMode: brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          themeAnimationDuration: Duration.zero,
          home: const Scaffold(
            body: BusyApiGroupedList(
              title: 'Native heading',
              description: 'Secondary description',
              children: [BusyApiActionRow(title: 'Setting')],
            ),
          ),
        ),
      );

      final heading = tester.widget<Text>(find.text('Native heading'));
      expect(heading.style?.fontSize, theme.textTheme.bodyMedium?.fontSize);
      expect(heading.style?.fontWeight, FontWeight.w700);
      expect(heading.style?.color, colors.foreground);
      expect(heading.style?.color, isNot(colors.mutedForeground));

      final description = tester.widget<Text>(
        find.text('Secondary description'),
      );
      expect(description.style?.color, theme.colorScheme.onSurfaceVariant);
      expect(description.style?.fontWeight, isNot(FontWeight.w700));
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('sidebar and Settings selectors share borderless theme states '
        'in ${brightness.name}', (tester) async {
      final theme = buildBusyApiTheme(
        brightness: brightness,
        accentColor: const Color(0xFF3584E4),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Directionality(
              textDirection: TextDirection.rtl,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
                child: SizedBox(
                  width: 300,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Text('Search:'),
                          Expanded(
                            child: BusyApiPopupSelector<String>(
                              key: const ValueKey('sidebar-selector'),
                              value: 'document',
                              label: 'Document Text',
                              tooltip: 'Search category',
                              fullWidth: true,
                              maxLabelLines: 2,
                              options: const [
                                BusyApiPopupSelectorOption(
                                  value: 'document',
                                  label: 'Document Text',
                                ),
                              ],
                              onSelected: (_) {},
                            ),
                          ),
                        ],
                      ),
                      BusyApiGroupedList(
                        filled: true,
                        children: [
                          BusyApiActionRow(
                            title: 'Theme',
                            trailing: BusyApiPopupSelector<String>(
                              key: const ValueKey('settings-selector'),
                              value: 'system',
                              label: 'System',
                              tooltip: 'Theme',
                              options: const [
                                BusyApiPopupSelectorOption(
                                  value: 'system',
                                  label: 'System',
                                ),
                              ],
                              onSelected: (_) {},
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      for (final key in ['sidebar-selector', 'settings-selector']) {
        final button = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextButton),
        );
        final control = tester.widget<TextButton>(button);
        final materialFinder = find.descendant(
          of: button,
          matching: find.byType(Material),
        );
        void expectBorderless() {
          final material = tester.widget<Material>(materialFinder);
          expect((material.shape! as OutlinedBorder).side, BorderSide.none);
          expect(material.color, BusyApiLinuxPalette.transparent);
          expect(tester.takeException(), isNull);
        }

        expectBorderless();
        control.focusNode!.requestFocus();
        await tester.pumpAndSettle();
        expect(control.focusNode!.hasFocus, isTrue);
        expectBorderless();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(button));
        await tester.pumpAndSettle();
        expectBorderless();
        await mouse.removePointer();
        await tester.pumpAndSettle();
      }
    });
  }
}
