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

class _ObservedEngine extends EngineProcess {
  _ObservedEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final trace = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    trace.add('start $method');
    try {
      return await super.request(method, params, requestId: requestId);
    } finally {
      trace.add('end $method');
      if (trace.length > 60) trace.removeRange(0, trace.length - 60);
    }
  }
}

class _ObservedDeletionController extends WorkspaceController {
  _ObservedDeletionController(super.engine, super.locations);
  final watch = Stopwatch()..start(), events = <String>[];
  int serial = 0;
  Future<T> observe<T>(String stage, Future<T> Function() action) async {
    final id = ++serial;
    void note(String value) {
      events.add('${watch.elapsedMilliseconds} $id $stage:$value');
      if (events.length > 80) events.removeAt(0);
    }

    note('start');
    try {
      return await action();
    } finally {
      note('end');
    }
  }

  @override
  Future<void> persist() => observe('recovery', super.persist);
  @override
  Future<void> persistView() => observe('view', super.persistView);
  @override
  Future<bool> flush() => observe('flush', super.flush);
  @override
  Future<void> applyRefactoring(BusyProject owner, RefactoringPlan plan) =>
      observe('apply', () => super.applyRefactoring(owner, plan));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      testWidgets(
        'native deletion $version $json reviews consumers and retains one-step ownership',
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
            'busyapi-native-delete-',
          );
          final c = _ObservedDeletionController(
            _ObservedEngine(),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final errors = <Object>[];
          Future<void>? pending;
          Future<void> waitFor(bool Function() condition) async {
            await tester.pump();
            final timer = Stopwatch()..start();
            while (!condition() &&
                errors.isEmpty &&
                timer.elapsed < const Duration(seconds: 8)) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(errors, isEmpty);
            expect(
              condition(),
              true,
              reason:
                  'checking=${c.checking}/${c.checkingSemantics}; error=${c.error}; selection=${c.selectedPointer}; dirty=${c.buffer?.dirty}; trace=${(c.engine as _ObservedEngine).trace}; persistence=${c.events}; status=${find.byType(BusyApiStatusBox).evaluate().map((e) => (e.widget as BusyApiStatusBox).message).toList()}',
            );
            await tester.pumpAndSettle();
          }

          Future<void> settleAction() async {
            var done = false;
            await tester.runAsync(() async {
              pending!.then((_) => done = true);
            });
            await waitFor(() => done);
          }

          Future<void> review() async {
            await waitFor(
              () => find
                  .widgetWithText(BusyApiActionRow, 'Delete object…')
                  .evaluate()
                  .any((e) => (e.widget as BusyApiActionRow).onTap != null),
            );
            await tester.runAsync(
              () => tester.tap(find.text('Delete object…')),
            );
            await waitFor(
              () => find
                  .text('Review object deletion')
                  .evaluate()
                  .any((e) => ModalRoute.of(e)?.isCurrent == true),
            );
          }

          try {
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}'),
                part = File('${temp.path}/part.json');
            final value = {
              'openapi': version,
              'info': {'title': 'Delete', 'version': '1'},
              'paths': {
                '/items': {
                  'get': {
                    'responses': {
                      '200': {
                        'description': 'OK',
                        'content': {
                          'application/json': {
                            'schema': {r'$ref': '#/components/schemas/Shared'},
                          },
                        },
                      },
                    },
                  },
                },
              },
              'components': {
                'schemas': {
                  'Shared': {r'$ref': 'part.json#/Model'},
                },
              },
            };
            final original =
                '${json ? '' : '# retained\r\n'}${const JsonEncoder.withIndent('  ').convert(value)}';
            const fragment =
                '{ "Model": { "type": "object", "properties": { "old": { "type": "string", "maxLength": 12 }, "keep": { "type": "number" } }, "required": ["old", "keep"], "example": {"old":9007199254740993}, "x-kept": 1.00 } }\r\n';
            await tester.runAsync(() async {
              await file.writeAsString(original);
              await part.writeAsString('\ufeff$fragment');
              await c.initialize();
              await c.open(file.path);
              await c.selectObject({
                'root': c.root,
                'resource': c.root,
                'pointer': '/components/schemas/Shared',
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
                          pending = action().catchError((Object error) {
                            errors.add(error);
                          }),
                      reveal: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await review();
            expect(find.textContaining('Cannot apply:'), findsOneWidget);
            expect(
              tester
                  .widget<BusyApiDialogButton>(
                    find.widgetWithText(BusyApiDialogButton, 'Apply'),
                  )
                  .onPressed,
              isNull,
            );
            expect(c.buffer!.text, original);
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiDialogButton, 'Cancel'),
              ),
            );
            await settleAction();
            await tester.runAsync(
              () => c.selectObject({
                'root': c.root,
                'resource': part.uri.toString(),
                'pointer': '/Model/properties/old',
                'occurrence': 'definition:${part.uri}#/Model/properties/old',
              }),
            );
            final source = c.buffer!, before = source.bytes();
            await review();
            expect(find.textContaining('Cannot apply:'), findsNothing);
            expect(
              find.textContaining('required-list membership'),
              findsOneWidget,
            );
            expect(source.bytes(), before);
            final retiredApply = tester
                .widget<BusyApiDialogButton>(
                  find.widgetWithText(BusyApiDialogButton, 'Apply'),
                )
                .onPressed!;
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiDialogButton, 'Cancel'),
              ),
            );
            // Route.popped precedes teardown. A retained callback from this
            // closing review must not acquire the next object's ownership.
            retiredApply();
            expect(source.bytes(), before);
            await settleAction();
            expect(source.bytes(), before);
            await review();
            await tester.runAsync(
              () =>
                  tester.tap(find.widgetWithText(BusyApiDialogButton, 'Apply')),
            );
            await settleAction();
            final accepted = source.bytes();
            expect(
              jsonDecode(source.text)['Model']['properties'].containsKey('old'),
              false,
            );
            expect(jsonDecode(source.text)['Model']['required'], ['keep']);
            expect(source.text, contains('9007199254740993'));
            expect(source.text, contains('1.00'));
            expect(c.selectedResource, source.id);
            expect(c.selectedPointer, '/Model/properties');
            await tester.runAsync(c.undo);
            expect(source.bytes(), before);
            expect(c.selectedPointer, '/Model/properties/old');
            await tester.runAsync(c.redo);
            expect(source.bytes(), accepted);
            expect(c.selectedPointer, '/Model/properties');
            await tester.runAsync(() async {
              await c.project!.save(source);
            });
            expect(part.readAsBytesSync(), accepted);
            expect(file.readAsStringSync(), original);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(c.shutdown);
            c.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
