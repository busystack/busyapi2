import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  testWidgets(
    'scoped toggle flushes its owned pending fields and never paints a stale source model',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
            'busyapi-scoped-toggle-',
          ),
          file = File('${temp.path}/root.json');
      const pointer = '/paths/~1value/get';
      const original =
          '{"openapi":"3.2.1","info":{"title":"Scoped toggle","version":"1"},"paths":{"/value":{"get":{"summary":"Safe original","parameters":"invalid declaration","responses":{"204":{"description":"Bodyless"}}}}},"x-kept":{"n":9007199254740993.00}}';
      file.writeAsStringSync(original);
      final c = WorkspaceController(
        EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(
          config: '${temp.path}/config',
          state: '${temp.path}/state',
          cache: '${temp.path}/cache',
        ),
      );
      final errors = <Object>[];
      Future<void>? pending;
      var menuCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('busyapi/native_menus');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'show') return null;
        menuCalls++;
        final entries = (call.arguments as Map)['entries'] as List;
        final index = entries.indexWhere((entry) => entry['label'] == 'false');
        expect(index, greaterThanOrEqualTo(0));
        return index;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      Finder summary() => find.descendant(
        of: find.widgetWithText(BusyApiGroupedTextEntry, 'Summary'),
        matching: find.byType(TextField),
      );
      Finder toggle() => find.byWidgetPredicate(
        (widget) =>
            widget is BusyApiComboRow<String> &&
            widget.title.contains('deprecated'),
      );
      Future<void> ready(bool Function() condition) async {
        await tester.pump();
        final watch = Stopwatch()..start();
        while (!condition() &&
            errors.isEmpty &&
            watch.elapsed < const Duration(seconds: 10)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(errors, isEmpty);
        expect(condition(), true, reason: 'Current error=${c.error}');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      try {
        await tester.runAsync(() async {
          await c.initialize();
          await c.open(file.path);
          await c.selectObject({
            'root': c.root,
            'resource': c.root,
            'pointer': pointer,
            'occurrence': 'details:${c.root}#$pointer',
          });
          await c.analyse();
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
              body: ListenableBuilder(
                listenable: c,
                builder: (_, _) => Designer(
                  controller: c,
                  run: (action) =>
                      pending = action().catchError((Object error) {
                        errors.add(error);
                      }),
                  reveal: (_) {},
                ),
              ),
            ),
          ),
        );
        await ready(
          () =>
              summary().evaluate().isNotEmpty && toggle().evaluate().isNotEmpty,
        );
        expect(tester.widget<BusyApiComboRow<String>>(toggle()).enabled, true);
        await tester.runAsync(
          () => tester.enterText(summary(), 'Pending metadata'),
        );
        expect(c.draft!.pending, true);
        await tester.runAsync(() => tester.ensureVisible(toggle()));
        await tester.pumpAndSettle();
        bool applied() =>
            (jsonDecode(c.buffer!.text)['paths']['/value']['get']
                as Map)['deprecated'] ==
            false;
        await tester.runAsync(() async {
          await tester.tap(toggle());
          // Normal asynchronous field work can finish between paint frames.
          // Hold no fake parser/transaction boundary; use the actual native
          // menu route and complete core/worker operation before the next frame.
          final watch = Stopwatch()..start();
          while (!applied() &&
              errors.isEmpty &&
              watch.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(errors, isEmpty);
          expect(applied(), true);
          await pending;
        });
        expect(menuCalls, 1);
        expect(c.buffer!.text, contains('Pending metadata'));
        expect(c.buffer!.text, contains('"parameters":"invalid declaration"'));
        expect(c.buffer!.text, contains('9007199254740993.00'));
        await tester.pump();
        expect(
          tester.widget<TextField>(summary()).controller!.text,
          'Pending metadata',
          reason: 'The old page projection must not roll back a committed field for an intermediate frame',
        );
        await ready(
          () =>
              !c.checking &&
              tester.widget<BusyApiComboRow<String>>(toggle()).selected ==
                  'false',
        );
        final before = c.buffer!.text,
            fresh = await tester.runAsync(
              () => c.project!.inspectObject(c.root!, c.root!, pointer),
            );
        await tester.runAsync(() async {
          await expectLater(
            c.mutate(fresh!, [
              {'kind': 'remove', 'pointer': '$pointer/parameters'},
            ], authoredField: 'deprecated'),
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'draft.scope'),
            ),
          );
        });
        expect(
          c.buffer!.text,
          before,
          reason: 'A field-scoped action cannot remove an invalid sibling',
        );
        await tester.runAsync(() async {
          await c.undo();
          await c.analyse();
        });
        expect(c.buffer!.text, contains('Pending metadata'));
        expect(c.buffer!.text, isNot(contains('deprecated')));
        await tester.runAsync(() async {
          await c.undo();
          await c.analyse();
        });
        expect(c.buffer!.text, original);
        await tester.runAsync(() async {
          await c.redo();
          await c.redo();
          await c.analyse();
          await c.saveBuffers();
        });
        expect(file.readAsStringSync(), before);
        expect(c.analysis!['status'], isNot('complete'));
        expect(errors, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(c.shutdown);
        c.dispose();
        temp.deleteSync(recursive: true);
      }
    },
  );
}
