import 'dart:async';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/output_destination.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'output path preserves spaces and Unicode, validates composition',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (value) {
              context = value;
              return const Text('Workspace');
            },
          ),
        ),
      );
      final result = chooseOutputDestination(
        context,
        initialPath: '/tmp/New output 雪 ',
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextFormField);
      await tester.enterText(field, 'relative');
      // Invoke the command without a pointer focus transition: clicking a
      // button may legitimately finish composition before the command runs.
      tester
          .widget<BusyApiDialogButton>(
            find.widgetWithText(BusyApiDialogButton, 'Review output'),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Enter an absolute folder path'),
        findsOneWidget,
      );
      final controller = tester.widget<TextFormField>(field).controller!;
      controller.value = const TextEditingValue(
        text: '/tmp/New output 雪 ',
        selection: TextSelection.collapsed(offset: 18),
        composing: TextRange(start: 16, end: 17),
      );
      expect(controller.value.composing, const TextRange(start: 16, end: 17));
      tester
          .widget<BusyApiDialogButton>(
            find.widgetWithText(BusyApiDialogButton, 'Review output'),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.textContaining('Finish composing'), findsOneWidget);
      controller.value = controller.value.copyWith(composing: TextRange.empty);
      await tester.tap(find.text('Review output'));
      await tester.pumpAndSettle();
      expect(await result, '/tmp/New output 雪 ');
      expect(tester.takeException(), isNull);
    },
  );

  for (final parent in [false, true]) {
    testWidgets(
      'native directory selection captures ${parent ? 'parent' : 'existing output'}',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          _host(
            Builder(
              builder: (value) {
                context = value;
                return const Text('Workspace');
              },
            ),
          ),
        );
        String? opened;
        final result = chooseOutputDestination(
          context,
          initialPath: '/tmp/project/New output 雪 ',
          chooseDirectory: (directory) async {
            opened = directory;
            return '/tmp/Existing output 雪 ';
          },
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            parent ? 'Choose parent folder…' : 'Choose existing output…',
          ),
        );
        await tester.pumpAndSettle();
        expect(opened, '/tmp/project');
        await tester.tap(find.text('Review output'));
        await tester.pumpAndSettle();
        expect(
          await result,
          parent
              ? '/tmp/Existing output 雪 /New output 雪 '
              : '/tmp/Existing output 雪 ',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('dismissed output owner ignores a late native chooser result', (
    tester,
  ) async {
    late BuildContext context;
    final choice = Completer<String?>();
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (value) {
            context = value;
            return const Text('Workspace');
          },
        ),
      ),
    );
    final result = chooseOutputDestination(
      context,
      initialPath: '/tmp/output',
      chooseDirectory: (_) => choice.future,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose existing output…'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
    choice.complete('/tmp/Late folder');
    await tester.pumpAndSettle();
    expect(find.text('Workspace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child) => MaterialApp(
  theme: buildBusyApiTheme(
    brightness: Brightness.light,
    accentColor: Colors.blue,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);
