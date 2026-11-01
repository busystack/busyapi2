import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/migration_review.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('yaru_window'),
      (call) async => call.method == 'state' ? {'active': true, 'visible': true, 'closable': true} : null);
    messenger.setMockMethodCallHandler(const MethodChannel('yaru_window/events'), (_) async => null);
  });
  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in ['yaru_window', 'yaru_window/events']) messenger.setMockMethodCallHandler(MethodChannel(channel), null);
  });
  for (final format in ['yaml', 'json']) for (final stale in [false, true]) {
    testWidgets('$format native example copy review ${stale ? 'rejects stale source' : 'publishes exact bytes'}', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('busyapi-example-review-');
      final file = File('${directory.path}/api.$format'), payload = File('${directory.path}/payload.bin');
      const type = 'text/plain; charset=iso-8859-1';
      const bytes = [99, 97, 102, 233];
      final value = {
        'openapi': '3.0.4',
        'info': {'title': 'Original', 'version': 'business'},
        'servers': [{'url': 'https://api.invalid'}],
        'paths': {
          '/': {
            'get': {
              'responses': {
                '200': {
                  'description': 'Reply',
                  'content': {
                    type: {
                      'schema': {'type': 'string', 'enum': ['café']},
                      'examples': {'External': {'externalValue': './payload.bin'}},
                    },
                  },
                },
              },
            },
          },
        },
      };
      final original = (format == 'yaml' ? '# Keep original\r\n' : '') + jsonEncode(value) + '\r\n';
      file.writeAsStringSync(original);payload.writeAsBytesSync(bytes);
      final controller = WorkspaceController(EngineProcess(executable: runtimeNode, helper: runtimeHelper),
        StateLocations(config: '${directory.path}/config', state: '${directory.path}/state', cache: '${directory.path}/cache'));
      Future<void>? dialog;
      Future<void> ready(bool Function() condition) async {
        final watch = Stopwatch()..start();await tester.pump();
        while (!condition() && watch.elapsed < const Duration(seconds: 20)) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(condition(), true, reason: '${controller.error}');await tester.pumpAndSettle();
      }
      try {
        await tester.runAsync(() async {await controller.initialize();await controller.open(file.path);await controller.analyse();});
        await tester.pumpWidget(MaterialApp(
          theme: buildBusyApiTheme(brightness: Brightness.light, accentColor: Colors.blue),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => dialog = showMigrationReview(context, controller, reveal: (_) async {}),
            child: const Text('Migrate'),
          ))),
        ));
        await tester.runAsync(() => tester.tap(find.text('Migrate')));
        final review = find.widgetWithText(BusyApiDialogButton, 'Review migration');
        await ready(() => review.evaluate().isNotEmpty);await tester.runAsync(() => tester.tap(review));
        final destination = find.widgetWithText(BusyApiDialogButton, 'Review output');
        await ready(() => destination.evaluate().isNotEmpty);await tester.runAsync(() => tester.tap(destination));
        final copy = find.byWidgetPredicate((widget) => widget is SelectableText &&
          widget.data?.startsWith('Copy 4 bytes unchanged: ${payload.uri} → ') == true);
        await ready(() => copy.evaluate().isNotEmpty);await tester.ensureVisible(copy);
        expect(tester.widget<SelectableText>(copy).data, contains('/examples/'));
        final publish = find.widgetWithText(BusyApiDialogButton, 'Create migrated copy');
        expect(tester.widget<BusyApiDialogButton>(publish).onPressed, isNotNull);
        final output = Directory('${directory.path}/busyapi-migrated');expect(output.existsSync(), false);
        if (stale) {
          await tester.runAsync(() async {
            controller.sourceEdit(controller.root!, controller.buffer!.text.replaceFirst('Original', 'Changed'));
            await controller.analyse();
          });
          await ready(() => tester.widget<BusyApiDialogButton>(publish).onPressed == null);
          expect(output.existsSync(), false);
        } else {
          await tester.runAsync(() => tester.tap(publish));
          await ready(() => output.existsSync() && find.text('The migrated copy was created. Original documents are preserved.').evaluate().isNotEmpty);
          final copies = Directory('${output.path}/examples').listSync().whereType<File>().toList();
          expect(copies, hasLength(1));expect(copies.single.readAsBytesSync(), bytes);
          expect(File('${output.path}/openapi.$format').readAsStringSync(), contains('examples/'));
        }
        expect(file.readAsStringSync(), original);expect(payload.readAsBytesSync(), bytes);
        final close = find.widgetWithText(BusyApiDialogButton, 'Close');
        await ready(() => close.evaluate().isNotEmpty);await tester.runAsync(() => tester.tap(close));
        await tester.pumpAndSettle();await tester.runAsync(() => dialog!);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());await tester.runAsync(controller.shutdown);
        controller.dispose();directory.deleteSync(recursive: true);
      }
    });
  }
}
