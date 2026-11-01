import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/tool_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'request tool traversal reaches scrolled fields beside Design and navigation in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final entry = FocusNode();
        var activated = 0;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: brightness,
                accentColor: Colors.blue,
              ),
              home: Scaffold(
                body: Row(
                  children: [
                    SizedBox(
                      width: 300,
                      child: Column(
                        children: [
                          for (var i = 0; i < 6; i++)
                            BusyApiActionRow(
                              title: 'Navigation $i',
                              onTap: () {},
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: BusyApiEditorScrollBody(
                              child: Column(
                                children: [
                                  for (var i = 0; i < 20; i++)
                                    BusyApiActionRow(
                                      title: 'Design $i',
                                      onTap: () {},
                                    ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 300,
                            child: BusyApiToolSurface(
                              title: 'Request',
                              status: 'Ready to send',
                              expanded: true,
                              onToggle: () {},
                              child: Column(
                                children: [
                                  TextField(
                                    focusNode: entry,
                                    decoration: const InputDecoration(
                                      labelText: 'Request field',
                                    ),
                                  ),
                                  for (var i = 0; i < 8; i++)
                                    BusyApiActionRow(
                                      title: 'Request $i',
                                      onTap: () {},
                                    ),
                                  BusyApiActionRow(
                                    title: 'Exact example',
                                    onTap: () => activated++,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          entry.requestFocus();
          await tester.pumpAndSettle();
          final trace = <String>[];
          var found = false;
          for (var step = 0; step < 64; step++) {
            final row = FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<BusyApiActionRow>();
            trace.add(row?.title ?? 'other');
            if (row?.title == 'Exact example') {
              found = true;
              break;
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
          }
          expect(found, isTrue, reason: trace.join(' → '));
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(activated, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          entry.dispose();
        }
      },
    );
  }
}
