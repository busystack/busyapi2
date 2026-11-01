import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _ReferenceStateEngine extends EngineProcess {
  _ReferenceStateEngine()
    : super(executable: runtimeNode, helper: runtimeHelper);
  String? heldRoot;
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final held = release;
    if (method == 'analyse' && params['root'] == heldRoot && held != null) {
      if (!entered!.isCompleted) entered!.complete();
      await held.future;
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'native Reference $version keeps root-specific search and reading position through reparse and remount',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-reference-state-',
        );
        WorkspaceController workspace() => WorkspaceController(
          _ReferenceStateEngine(),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        var c = workspace();
        Widget screen() => MaterialApp(
          theme: buildBusyApiTheme(
            brightness: Brightness.light,
            accentColor: Colors.blue,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => ReferenceView(controller: c, reveal: (_) {}),
            ),
          ),
        );
        try {
          final value = {
            'openapi': version,
            'info': {'title': 'Reference', 'version': '1'},
            'paths': {
              for (var i = 0; i < 60; i++)
                '/items/$i': {
                  'get': {
                    'operationId': 'fetchItem$i',
                    'summary': 'Item $i',
                    'tags': ['scope-group'],
                    'responses': {
                      '204': {'description': 'Bodyless'},
                    },
                  },
                },
            },
          };
          final text = const JsonEncoder.withIndent('  ').convert(value),
              a = File('${temp.path}/a.json'),
              b = File('${temp.path}/b.json');
          await tester.runAsync(() async {
            await a.writeAsString(text);
            await b.writeAsString(text);
            await File('${temp.path}/busyapi.yaml').writeAsString(
              'version: 1\nroots:\n  - name: first\n    path: a.json\n  - name: second\n    path: b.json\n',
            );
            await c.initialize();
            await c.open(temp.path);
            await c.selectRoot(c.project!.roots.first.id);
            c.mode = 'Reference';
            await c.analyse();
          });
          final first = c.root!;
          await tester.pumpWidget(screen());
          await tester.pumpAndSettle();
          final field = find.descendant(
            of: find.byType(BusyApiSearchField),
            matching: find.byType(TextField),
          );
          await tester.enterText(field, 'fetchItem23');
          await tester.pumpAndSettle();
          expect(find.text('GET /items/23'), findsOneWidget);
          expect(find.text('GET /items/0'), findsNothing);
          await tester.enterText(field, 'scope-group');
          await tester.pumpAndSettle();
          expect(find.text('GET /items/0'), findsOneWidget);
          final list = find.byType(ListView);
          ScrollController controller() =>
              tester.widget<ListView>(list).controller!;
          await tester.drag(list, const Offset(0, -1500));
          await tester.pumpAndSettle();
          final position = controller().position;
          final offset = position.pixels;
          expect(offset, greaterThan(500));
          var changed = text.replaceFirst('"Reference"', '"Current Reference"');
          await tester.runAsync(() async {
            c.store!.replace(first, changed);
            await c.analyse();
          });
          await tester.pumpAndSettle();
          expect(controller().position.pixels, closeTo(offset, 1));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(screen());
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.text,
            'scope-group',
          );
          expect(controller().position.pixels, closeTo(offset, 1));
          await tester.runAsync(() async {
            await c.selectRoot(c.project!.roots.last.id);
            await c.analyse();
          });
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(field).controller!.text, '');
          expect(controller().position.pixels, 0);
          // An inactive unsaved update invalidates the cached first root. Its
          // restored viewport must wait until the real analysis attaches it.
          changed = changed.replaceFirst(
            'Current Reference',
            'Updated elsewhere',
          );
          final engine = c.engine as _ReferenceStateEngine;
          engine.heldRoot = first;
          engine.entered = Completer<void>();
          engine.release = Completer<void>();
          await tester.runAsync(() async {
            c.store!.replace(first, changed);
            await c.selectRoot(first);
          });
          final wait = Stopwatch()..start();
          while (!engine.entered!.isCompleted &&
              wait.elapsed < const Duration(seconds: 5)) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(engine.entered!.isCompleted, true);
          expect(find.byType(BusyApiSearchField), findsNothing);
          await tester.runAsync(() async {
            engine.release!.complete();
            engine.release = null;
            await c.analyse();
          });
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.text,
            'scope-group',
          );
          expect(controller().position.pixels, closeTo(offset, 1));
          expect(a.readAsStringSync(), text);
          expect(b.readAsStringSync(), text);
          expect(c.store!.get(first).text, changed);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          c = workspace();
          await tester.runAsync(() async {
            await c.initialize();
            await c.open(temp.path);
            await c.analyse();
          });
          await tester.pumpWidget(screen());
          await tester.pumpAndSettle();
          expect(c.root, first);
          expect(c.mode, 'Reference');
          expect(
            tester.widget<TextField>(field).controller!.text,
            'scope-group',
          );
          expect(controller().position.pixels, closeTo(offset, 1));
          expect(a.readAsStringSync(), text);
        } finally {
          final engine = c.engine as _ReferenceStateEngine;
          if (engine.release != null && !engine.release!.isCompleted) {
            engine.release!.complete();
          }
          engine.release = null;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(c.shutdown);
          c.dispose();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
