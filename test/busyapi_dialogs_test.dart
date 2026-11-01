// Ported BusyMark modal assertions, Copyright 2026 BusyStack, Apache-2.0.
import 'dart:async';

import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_dialogs.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_toast.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'JSON field errors retain the draft without echoing its source excerpt',
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
      final result = editForm(
        context,
        'Data',
        const [
          FormFieldSpec('value', 'Data value', json: true, multiline: true),
        ],
        {'value': '{}'},
      );
      await tester.pumpAndSettle();
      final canary = 'ghp_${List.filled(36, 'a').join()}';
      final invalid = '{"token":"$canary",';
      await tester.enterText(find.byType(TextFormField), invalid);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextFormField>(find.byType(TextFormField));
      expect(field.controller!.text, invalid);
      expect(
        find.textContaining('Invalid JSON data near character'),
        findsOneWidget,
      );
      expect(
        find
            .byType(Text)
            .evaluate()
            .map((element) => (element.widget as Text).data)
            .whereType<String>()
            .any((value) => value.contains(canary)),
        isFalse,
      );
      await tester.enterText(
        find.byType(TextFormField),
        '{"kept":9007199254740993}',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(await result, {'value': '{"kept":9007199254740993}'});
      expect(tester.takeException(), isNull);
    },
  );
  for (final reducedMotion in [false, true]) {
    testWidgets('shared form keeps controllers through exit ($reducedMotion)', (
      tester,
    ) async {
      late BuildContext hostContext;
      late StateSetter updateHost;
      var accent = Colors.blue;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: accent,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reducedMotion),
                child: BusyApiToastOverlay(child: child!),
              ),
              home: Builder(
                builder: (context) {
                  hostContext = context;
                  return const Scaffold(body: Text('Workspace'));
                },
              ),
            );
          },
        ),
      );
      final result = editForm(
        hostContext,
        'Create project',
        const [
          FormFieldSpec('title', 'Title'),
          FormFieldSpec('version', 'API version'),
          FormFieldSpec('folder', 'Name'),
        ],
        {'title': 'test', 'version': '1.0.0', 'folder': 'api'},
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextFormField, 'Title'));
      await tester.pump();
      final route =
          ModalRoute.of(tester.element(find.byType(TextFormField).first))!
              as TransitionRoute;
      await tester.tap(find.text('Apply'));
      await tester.pump();
      expect(await result, containsPair('title', 'test'));
      BusyApiToastOverlay.show(
        hostContext,
        message: 'Project created',
        duration: const Duration(milliseconds: 400),
      );
      // The result is detached, but the outgoing native fields are still alive.
      if (!reducedMotion) expect(route.animation!.value, greaterThan(0));
      updateHost(() => accent = Colors.green);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      await route.completed;
      expect(tester.takeException(), isNull);
      expect(find.byType(TextFormField), findsNothing);
      // Immediate reopening also exercises focus restoration and the barrier.
      final next = editForm(
        hostContext,
        'Next form',
        const [FormFieldSpec('x', 'Value')],
        {'x': 'kept'},
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await next, isNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'submission is guarded before rebuild and Escape cannot race it',
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
      final completion = Completer<void>();
      var calls = 0;
      Map<String, dynamic>? accepted;
      final result = editForm(
        context,
        'Delayed form',
        const [FormFieldSpec('x', 'Value')],
        {'x': 'original'},
        onApply: (values) async {
          calls++;
          accepted = values;
          await completion.future;
        },
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'accepted');
      final apply = tester
          .widget<BusyApiDialogButton>(
            find.widgetWithText(BusyApiDialogButton, 'Apply'),
          )
          .onPressed!;
      final cancel = tester
          .widget<BusyApiDialogButton>(
            find.widgetWithText(BusyApiDialogButton, 'Cancel'),
          )
          .onPressed!;
      apply();
      apply();
      cancel(); // All callbacks captured before disabled rebuild.
      expect(calls, 1);
      expect(accepted, {'x': 'accepted'});
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Delayed form'), findsOneWidget);
      completion.complete();
      await tester.pump();
      expect(await result, {'x': 'accepted'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failure retains inputs for correction; Escape and Cancel release presentation',
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
      var calls = 0;
      final result = editForm(
        context,
        'Retry',
        const [FormFieldSpec('x', 'Value')],
        {'x': 'original'},
        onApply: (values) async {
          if (++calls == 1) throw StateError('Publication failed');
        },
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'first input');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Publication failed'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'first input',
      );
      await tester.enterText(find.byType(TextFormField), 'corrected');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(await result, {'x': 'corrected'});
      for (var i = 0; i < 3; i++) {
        final next = editForm(
          context,
          'Cancel form',
          const [FormFieldSpec('x', 'Value')],
          {'x': 'pending'},
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextFormField));
        await tester.pump();
        if (i.isEven) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.tap(find.text('Cancel'));
        }
        await tester.pumpAndSettle();
        expect(await next, isNull);
        expect(find.byType(TextFormField), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'late completion after host removal cannot update disposed State',
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
      final completion = Completer<void>();
      var calls = 0;
      unawaited(
        editForm(
          context,
          'Pending',
          const [FormFieldSpec('x', 'Value')],
          {'x': 'draft'},
          onApply: (_) async {
            calls++;
            await completion.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      completion.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'late Remove completes its own route and leaves a newer dialog intact',
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
      final completion = Completer<void>();
      var calls = 0;
      final result = editForm(
        context,
        'Remove form',
        const [FormFieldSpec('x', 'Value')],
        {'x': 'original'},
        removable: true,
        onApply: (values) async {
          expect(values, {'remove': true});
          calls++;
          await completion.future;
        },
      );
      await tester.pumpAndSettle();
      final remove = tester
          .widget<BusyApiDialogButton>(
            find.widgetWithText(BusyApiDialogButton, 'Remove'),
          )
          .onPressed!;
      remove();
      remove();
      await tester.pump();
      final newer = showBusyApiModalDialog<void>(
        context: context,
        builder: (context) => BusyApiDialogShell(
          title: 'Newer dialog',
          actions: [
            BusyApiDialogButton(
              label: 'Close',
              onPressed: () => Navigator.pop(context),
            ),
          ],
          children: const [Text('Still open')],
        ),
      );
      await tester.pumpAndSettle();
      completion.complete();
      await tester.pumpAndSettle();
      expect(await result, {'remove': true});
      expect(calls, 1);
      expect(find.text('Still open'), findsOneWidget);
      expect(find.text('Remove form'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await newer;
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Escape closes a modal without an initially focused control', (
    tester,
  ) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );

    final result = showBusyApiModalDialog<void>(
      context: hostContext,
      barrierDismissible: false,
      builder: (_) => const Dialog(child: Text('Modal content')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Modal content'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Modal content'), findsNothing);
    await result;
  });

  testWidgets('modal fallback does not steal a child autofocus request', (
    tester,
  ) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );

    final result = showBusyApiModalDialog<void>(
      context: hostContext,
      builder: (_) => const Dialog(
        child: TextField(
          autofocus: true,
          decoration: InputDecoration(labelText: 'Modal input'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final input = tester.widget<EditableText>(find.byType(EditableText));
    expect(input.focusNode.hasPrimaryFocus, isTrue);

    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await tester.pumpAndSettle();
    await result;
  });
}

Widget _host(Widget child) => MaterialApp(
  theme: buildBusyApiTheme(
    brightness: Brightness.light,
    accentColor: Colors.blue,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (_, child) => BusyApiToastOverlay(child: child!),
  home: Scaffold(body: child),
);
