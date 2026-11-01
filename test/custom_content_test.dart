import 'dart:async';
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
import 'package:path/path.dart' as p;

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _CustomContentEngine extends EngineProcess {
  _CustomContentEngine()
    : super(executable: runtimeNode, helper: runtimeHelper);
  final watch = Stopwatch()..start();
  final trace = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    void note(String value) {
      trace.add('${watch.elapsedMilliseconds} $value');
      if (trace.length > 60) trace.removeAt(0);
    }

    note('start $method');
    try {
      return await super.request(method, params, requestId: requestId);
    } on CoreFailure catch (failure) {
      note('failed ${failure.code}');
      rethrow;
    } finally {
      note('end $method');
    }
  }
}

class _CheckpointTrace {
  final clock = Stopwatch()..start(), events = <String>[];
  void note(String phase) {
    events.add('${clock.elapsedMilliseconds} $phase');
    if (events.length > 100) events.removeAt(0);
    if (Platform.environment['BUSYAPI_TEST_TRACE'] == '1') {
      debugPrint('checkpoint ${events.last}');
    }
  }
}

class _ObservedCustomController extends WorkspaceController {
  _ObservedCustomController(EngineProcess engine, StateLocations locations)
    : this._(engine, locations, _CheckpointTrace());
  _ObservedCustomController._(super.engine, super.locations, this.checkpoints)
    : super(
        recovery: RecoveryStore(
          p.join(locations.state, 'recovery'),
          onCheckpointPhase: checkpoints.note,
        ),
      );
  final _CheckpointTrace checkpoints;
  final clock = Stopwatch()..start(), events = <String>[];
  int serial = 0;
  Future<T> observe<T>(String stage, Future<T> Function() operation) {
    final id = ++serial;
    void note(String state) {
      events.add('${clock.elapsedMilliseconds} $id $stage:$state');
      if (events.length > 100) events.removeAt(0);
    }

    note('start');
    final pending = operation();
    unawaited(
      pending.then<void>(
        (_) => note('end'),
        onError: (Object error, StackTrace stack) => note('failed'),
      ),
    );
    return pending;
  }

  @override
  Future<void> persist() => observe('recovery', super.persist);
  @override
  Future<void> persistView() => observe('view', super.persistView);
  @override
  Future<void> mutate(
    Map<String, dynamic> item,
    List<Map<String, Object?>> actions, {
    String? authoredField,
  }) => observe(
    'mutate',
    () => super.mutate(item, actions, authoredField: authoredField),
  );
  @override
  Future<void> applyForm(FormSession owner, Future<void> Function() apply) =>
      observe('form', () => super.applyForm(owner, apply));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'custom content $version $json has native creation, exact data and deliberate empty schema names',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final channel in ['yaru_window', 'yaru_window/events']) {
            messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              (_) async => null,
            );
            addTearDown(
              () => messenger.setMockMethodCallHandler(
                MethodChannel(channel),
                null,
              ),
            );
          }
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-custom-content-',
          );
          final c = _ObservedCustomController(
            _CustomContentEngine(),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final errors = <Object>[];
          Future<void>? pending;
          void stage(String value) {
            if (Platform.environment['BUSYAPI_TEST_TRACE'] == '1') {
              debugPrint(
                'custom:$version:$json:$value checking=${c.checking}/${c.checkingSemantics} form=${c.formApplying} trace=${(c.engine as _CustomContentEngine).trace.reversed.take(6).toList().reversed.toList()}',
              );
            }
          }

          Future<void> waitFor(bool Function() ready) async {
            await tester.pump();
            final watch = Stopwatch()..start();
            while (!ready() &&
                errors.isEmpty &&
                watch.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(
              ready(),
              true,
              reason:
                  'selection=${c.selectedPointer} error=${c.error} formApplying=${c.formApplying} checking=${c.checking} generation=${c.buffer?.generation} formGeneration=${c.form?.target.generation} trace=${(c.engine as _CustomContentEngine).trace} persistence=${c.events} checkpoints=${c.checkpoints.events} messages=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).whereType<String>().where((s) => s.contains(RegExp(r"(?:draft|proposal|edit|queue|worker|protocol)\.|Invalid JSON|retained"))).toList()}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> tap(String label) async {
            stage('tap:$label');
            final row = find.text(label).last;
            await tester.ensureVisible(row);
            await tester.runAsync(() => tester.tap(row));
            await tester.pump();
          }

          Future<void> enter(String label, String value) => tester.enterText(
            find
                .descendant(
                  of: find.widgetWithText(BusyApiGroupedTextEntry, label),
                  matching: find.byType(EditableText),
                )
                .last,
            value,
          );
          Future<void> finish() async {
            stage('finish:start');
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await waitFor(() => done);
            stage('finish:end');
          }

          Future<void> select(String pointer) async {
            stage('select:start:$pointer');
            await tester.runAsync(() async {
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': pointer,
              });
              await c.analyse();
            });
            await tester.pump();
            stage('select:end:$pointer');
          }

          try {
            stage('open:start');
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final kept = jsonEncode({
              for (var i = 0; i < 251; i++)
                'x-kept-$i': {'value': i, r'$ref': 'payload literal'},
            });
            stage('open:end');
            final original =
                '${json ? '' : '# retained 😀\r\n'}{"openapi":"$version","info":{"title":"T","version":"1","contact":$kept},"paths":{},"components":{"schemas":{"Model":{"properties":{}}}},"x-number":9007199254740993.00}';
            await tester.runAsync(() async {
              await file.writeAsBytes([
                239,
                187,
                191,
                ...utf8.encode(original),
              ]);
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/info/contact',
              });
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
                          pending = action().catchError((Object e) {
                            errors.add(e);
                          }),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await waitFor(
              () => find.text('Add extension…').evaluate().isNotEmpty,
            );
            await tap('Add extension…');
            await waitFor(() => c.form != null);
            await enter('Name', 'not-an-extension');
            await tap('Apply');
            await waitFor(
              () => find
                  .text(
                    'An extension name must start with x- and contain at most 4096 characters.',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            expect(c.buffer!.text, original);
            await tap('Cancel');
            await finish();
            expect(c.buffer!.text, original);
            await tap('Add extension…');
            await waitFor(() => c.form != null);
            await enter('Name', 'x-authored');
            const raw =
                '{"\$ref":"payload literal","paths":{"get":false},"n":9007199254740993,"d":1.00,"note":"😀\\nnext"}';
            await enter('JSON-compatible data value', raw);
            await tap('Apply');
            await finish();
            final authored = c.buffer!.text;
            expect(authored, contains(raw));
            expect(authored, contains('9007199254740993.00'));
            expect(c.analysis!['references'] as List, isEmpty);
            await runWidgetIo(tester, c.undo);
            stage('first-undo:end');
            expect(c.buffer!.text, original);
            await runWidgetIo(tester, c.redo);
            stage('first-redo:end');
            expect(c.buffer!.text, authored);
            await waitFor(
              () => find
                  .widgetWithText(BusyApiDialogButton, 'Last')
                  .evaluate()
                  .any(
                    (e) => (e.widget as BusyApiDialogButton).onPressed != null,
                  ),
            );
            await tap('Last');
            await waitFor(() => find.text('x-authored').evaluate().isNotEmpty);
            expect(find.text('x-kept-250'), findsOneWidget);
            expect(find.text('x-kept-0'), findsNothing);
            await select('/components/schemas/Model');
            await waitFor(
              () =>
                  find.text('Add custom schema keyword…').evaluate().isNotEmpty,
            );
            await tap('Add custom schema keyword…');
            await waitFor(() => c.form != null);
            await enter('Name', 'minimum');
            await tap('Apply');
            await waitFor(
              () => find
                  .text(
                    'Use the typed editor for this standard schema keyword.',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            expect(c.buffer!.text, authored);
            await enter('Name', 'custom-vocabulary');
            await enter('JSON-compatible data value', raw);
            await tap('Apply');
            await finish();
            final withCustom = c.buffer!.text;
            expect(withCustom, contains('"custom-vocabulary": $raw'));
            expect(c.analysis!['references'] as List, isEmpty);
            await select('/components/schemas/Model/properties');
            await waitFor(() => find.text('Add entry').evaluate().isNotEmpty);
            await tap('Add entry');
            await waitFor(() => c.form != null);
            await tap('Apply');
            await waitFor(
              () => find
                  .text('Enter a name or required URL before adding the entry.')
                  .evaluate()
                  .isNotEmpty,
            );
            await tap('Use an empty name');
            await tap('Apply');
            await finish();
            expect(c.selectedPointer, '/components/schemas/Model/properties/');
            await select('/components/schemas/Model/properties');
            await waitFor(
              () => find.text('(empty name)').evaluate().isNotEmpty,
            );
            final withEmpty = c.buffer!.text;
            await runWidgetIo(tester, c.undo);
            expect(c.buffer!.text, withCustom);
            await runWidgetIo(tester, c.redo);
            expect(c.buffer!.text, withEmpty);
            await tester.runAsync(() async {
              await c.project!.save(c.buffer!);
              await c.open(file.path);
            });
            expect(c.buffer!.text, withEmpty);
            expect(c.buffer!.hasBom, true);
            expect(c.buffer!.text.endsWith('\n'), false);
            expect(file.readAsBytesSync().take(3), [239, 187, 191]);
          } finally {
            stage('cleanup:start');
            await tester.pumpWidget(const SizedBox.shrink());
            await runWidgetIo(tester, c.shutdown);
            c.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
