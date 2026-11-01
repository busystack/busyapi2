import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/bundle_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

class _HeldBundleEngine extends EngineProcess {
  _HeldBundleEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  CoreFailure? fault;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if ([
          'deriveBundle',
          'referenceDocument',
          'referenceDisplay',
          'describeResourcePackage',
        ].contains(method) &&
        fault != null) {
      throw fault!;
    }
    final gate = release;
    if ([
          'deriveBundle',
          'referenceDocument',
          'referenceDisplay',
          'describeResourcePackage',
        ].contains(method) &&
        gate != null) {
      release = null;
      entered!.complete();
      await gate.future;
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      (call) async => call.method == 'state'
          ? {'active': true, 'visible': true, 'closable': true}
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      (_) async => null,
    );
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('yaru_window/events'),
      null,
    );
  });
  for (final (documentation, preset) in [
    (false, 'native-reference'),
    (false, 'resource-package'),
    (true, 'native-reference'),
    (true, 'redoc'),
    (true, 'swagger'),
  ]) {
    final format = preset == 'resource-package'
        ? BundleFormat.resourcePackage
        : BundleFormat.singleFile;
    final workBound = format == BundleFormat.resourcePackage
        ? const Duration(seconds: 60)
        : const Duration(seconds: 8);
    final action = documentation ? 'Create documentation' : 'Create bundle',
        entry = documentation
            ? 'index.html'
            : format == BundleFormat.resourcePackage
            ? 'resource-package.json'
            : 'openapi.json';
    for (final behavior in [
      'publish',
      'source',
      'switch',
      'dispose',
      'reload',
      if (preset == 'native-reference') 'template-context',
      if (documentation || format == BundleFormat.resourcePackage) 'assets',
    ]) {
      testWidgets(
        '${documentation
            ? '$preset documentation'
            : preset == 'resource-package'
            ? 'resource-package'
            : 'bundle'} native run $behavior keeps captured source, output and asynchronous ownership',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-bundle-widget-',
          );
          final source = File('${temp.path}/root.json');
          final original = jsonEncode({
            'openapi': '3.2.1',
            'info': {'title': 'Native bundle', 'version': '1'},
            'paths': <String, Object?>{},
            if (behavior == 'template-context')
              'servers': [
                {
                  'url': '{endpoint}',
                  'variables': {
                    'endpoint': {'default': 'https://api.example'},
                  },
                },
              ],
            'components': {
              'schemas': {
                'Value': {'type': 'integer', 'minimum': 1},
              },
            },
          });
          source.writeAsStringSync(original);
          final held = _HeldBundleEngine();
          final c = WorkspaceController(
            held,
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final run = BundleRunController(c),
              destination = '${temp.path}/output 雪';
          Completer<void>? pendingGate;
          Future<void>? pending;
          var removed = false;
          String? opened;
          final publicationPhases = <String>[];
          final publicationClock = Stopwatch()..start();
          run.addListener(() {
            publicationPhases.add(
              '${publicationClock.elapsedMilliseconds}:${run.phase}',
            );
          });
          Future<void> waitForPublication() async {
            final finished = Completer<void>();
            void observe() {
              if (['published', 'failed', 'partial'].contains(run.phase) &&
                  !finished.isCompleted) {
                finished.complete();
              }
            }

            run.addListener(observe);
            observe();
            try {
              await runWidgetIo(
                tester,
                () => finished.future,
                timeout: workBound,
                describeState: () =>
                    '${run.failure}; ${run.phase}; $publicationPhases',
              );
            } finally {
              run.removeListener(observe);
            }
            expect(
              run.phase,
              'published',
              reason:
                  '${run.failure}; ${run.phase}; $publicationPhases; '
                  '${temp.listSync(recursive: true, followLinks: false).map((entry) => entry.path.substring(temp.path.length)).take(100).toList()}',
            );
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(source.path);
              await c.analyse();
            });
            await tester.pumpWidget(
              MaterialApp(
                theme: buildBusyApiTheme(
                  brightness: Brightness.dark,
                  accentColor: Colors.blue,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Column(
                    children: [
                      Expanded(
                        child: SourceEditor(
                          buffer: c.buffer!,
                          owner: c.project,
                          changes: c,
                          onEdit: c.sourceDelta,
                          onChanged: (text) => c.sourceEdit(c.active!, text),
                          undo: c.undo,
                          redo: c.redo,
                        ),
                      ),
                      BundleRunPanel(
                        run: run,
                        openResult: (directory) async {
                          opened = directory;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
            if (behavior == 'template-context') {
              await tester.runAsync(
                () => run.prepare(
                  destination,
                  documentation: documentation,
                  preset: preset,
                  format: format,
                ),
              );
              await tester.pumpAndSettle();
              if (documentation) {
                expect(run.phase, 'ready', reason: run.failure);
                await tester.runAsync(() => tester.tap(find.byTooltip(action)));
                await waitForPublication();
                expect(
                  File('$destination/index.html').readAsStringSync(),
                  contains('{endpoint}'),
                );
              } else {
                expect(run.phase, 'failed');
                expect(run.failure, 'bundle.server.template-context');
                expect(run.failureCategory, 2);
                expect(
                  find.textContaining(
                    'different relative or absolute URL forms',
                  ),
                  findsOneWidget,
                );
                expect(Directory(destination).existsSync(), false);
                expect(find.text('Create bundle'), findsNothing);
              }
              expect(source.readAsStringSync(), original);
              expect(c.buffer!.text, original);
              expect(tester.takeException(), isNull);
              return;
            }
            if (behavior == 'assets') {
              held.fault = format == BundleFormat.resourcePackage
                  ? ResourcePackageAssetsFailure(
                      'share/licenses/busyapi-dart/DART-LICENSE',
                    )
                  : DocumentationAssetsFailure(
                      'THIRD_PARTY_NOTICES.txt',
                      preset: preset == 'swagger' ? 'swagger' : 'redoc',
                    );
              await tester.runAsync(
                () => run.prepare(
                  destination,
                  documentation: documentation,
                  preset: preset,
                  format: format,
                ),
              );
              await tester.pumpAndSettle();
              expect(run.phase, 'failed');
              expect(run.failureCategory, 3);
              expect(
                run.failureAssetComponent,
                format == BundleFormat.resourcePackage
                    ? 'share/licenses/busyapi-dart/DART-LICENSE'
                    : '${preset == 'swagger' ? 'swagger' : 'redoc'}/THIRD_PARTY_NOTICES.txt',
              );
              expect(run.failureAnalysis!['checkedRoots'], [c.root]);
              expect(run.failureAnalysis!['sourceSnapshot'], isA<String>());
              expect(
                find.textContaining(
                  format == BundleFormat.resourcePackage
                      ? 'DART-LICENSE'
                      : 'THIRD_PARTY_NOTICES.txt',
                ),
                findsOneWidget,
              );
              expect(find.text(action), findsNothing);
              expect(Directory(destination).existsSync(), false);
              expect(source.readAsStringSync(), original);
              expect(c.buffer!.text, original);
              return;
            }
            if (behavior == 'publish') {
              await tester.runAsync(
                () => run.prepare(
                  destination,
                  documentation: documentation,
                  preset: preset,
                  format: format,
                ),
              );
              await tester.pumpAndSettle();
              expect(run.phase, 'ready', reason: run.failure);
              expect(find.text(action), findsOneWidget);
              expect(Directory(destination).existsSync(), false);
              final capturedOutput = run.output;
              await tester.tap(find.byTooltip('Output'));
              await tester.pumpAndSettle();
              expect(run.expanded, false);
              expect(run.output, same(capturedOutput));
              expect(run.phase, 'ready');
              await tester.runAsync(() => tester.tap(find.byTooltip(action)));
              await waitForPublication();
              await tester.pumpAndSettle();
              expect(run.phase, 'published', reason: run.failure);
              expect(File('$destination/$entry').existsSync(), true);
              if (documentation && preset != 'native-reference') {
                final inventory = jsonDecode(
                  File('$destination/third-party.json').readAsStringSync(),
                );
                expect(inventory['preset'], preset);
                expect(
                  File('$destination/THIRD_PARTY_NOTICES.txt')
                      .readAsStringSync(),
                  contains('Permission is hereby granted, free of charge'),
                );
              }
              expect(source.readAsStringSync(), original);
              expect(c.buffer!.dirty, false);
              await tester.runAsync(
                () => tester.tap(find.byTooltip('Open Result')),
              );
              expect(opened, destination);
              final first = File('$destination/$entry').readAsBytesSync();
              await tester.runAsync(
                () => run.prepare(
                  destination,
                  documentation: documentation,
                  preset: preset,
                  format: format,
                ),
              );
              await tester.pumpAndSettle();
              // The first button starts the async dialog/publication flow.
              // Its continuation must retain the real IO zone, not only the
              // later confirmation tap (large recursive listings yield batches).
              await tester.runAsync(
                () => tester.tap(find.byTooltip('Replace owned output')),
              );
              await tester.pumpAndSettle();
              expect(
                find.textContaining('previous output is retained'),
                findsOneWidget,
              );
              await tester.tap(
                find.widgetWithText(BusyApiDialogButton, 'Cancel'),
              );
              await tester.pumpAndSettle();
              expect(File('$destination/$entry').readAsBytesSync(), first);
              expect(run.phase, 'ready');
              await tester.runAsync(
                () => tester.tap(find.byTooltip('Replace owned output')),
              );
              await tester.pumpAndSettle();
              await tester.runAsync(
                () => tester.tap(
                  find
                      .widgetWithText(
                        BusyApiDialogButton,
                        'Replace owned output',
                      )
                      .last,
                ),
              );
              await waitForPublication();
              await tester.pumpAndSettle();
              expect(run.phase, 'published', reason: run.failure);
              expect(run.previous, isNotNull);
              expect(File('${run.previous}/$entry').readAsBytesSync(), first);
            } else {
              final reloaded = original.replaceFirst(
                'Native bundle',
                'Reloaded while exporting',
              );
              if (behavior == 'reload') source.writeAsStringSync(reloaded);
              await tester.runAsync(() async {
                held.entered = Completer<void>();
                final gate = Completer<void>();
                pendingGate = gate;
                held.release = gate;
                pending = run.prepare(
                  destination,
                  documentation: documentation,
                  preset: preset,
                  format: format,
                );
                await held.entered!.future.timeout(workBound);
              });
              if (behavior == 'reload') {
                await tester.pump();
                await tester.pump();
                expect(run.phase, 'generating');
                expect(c.buffer!.text, reloaded);
                expect(
                  tester
                      .widget<EditableText>(find.byType(EditableText))
                      .controller
                      .text,
                  reloaded,
                  reason: 'A clean resource reload during export must reach the mounted Source owner before its adapter completes',
                );
                await tester.runAsync(() async {
                  pendingGate!.complete();
                  await pending!.timeout(workBound);
                });
                await tester.pumpAndSettle();
                expect(run.phase, 'ready', reason: run.failure);
                expect(
                  run.output!.snapshot.resources.singleWhere(
                    (r) => r['id'] == source.uri.toString(),
                  )['text'],
                  reloaded,
                );
                expect(source.readAsStringSync(), reloaded);
                expect(c.buffer!.dirty, false);
                return;
              }
              await tester.pumpAndSettle();
              expect(run.phase, 'generating');
              if (behavior == 'source') {
                final changed = original.replaceFirst(
                  'Native bundle',
                  'Typed while bundling',
                );
                await tester.runAsync(
                  () => tester.enterText(find.byType(EditableText), changed),
                );
                expect(c.buffer!.text, changed);
                await tester.runAsync(() async {
                  pendingGate!.complete();
                  await pending!.timeout(workBound);
                });
                await tester.pumpAndSettle();
                expect(run.phase, 'ready', reason: run.failure);
                expect(run.output!.outdated, true);
                expect(
                  find.textContaining('Source changed after capture'),
                  findsOneWidget,
                );
                await tester.runAsync(() => tester.tap(find.byTooltip(action)));
                await waitForPublication();
                await tester.pumpAndSettle();
                expect(run.phase, 'published', reason: run.failure);
                if (format == BundleFormat.resourcePackage) {
                  final manifest = jsonDecode(
                    File('$destination/$entry').readAsStringSync(),
                  ) as Map;
                  final root = (manifest['resources'] as List).singleWhere(
                    (r) => r['resource'] == source.uri.toString(),
                  );
                  expect(
                    File('$destination/${root['path']}').readAsStringSync(),
                    original,
                  );
                } else {
                  expect(
                    File('$destination/$entry').readAsStringSync(),
                    contains('Native bundle'),
                  );
                }
                expect(c.buffer!.text, changed);
                expect(source.readAsStringSync(), original);
              } else {
                await tester.pumpWidget(const SizedBox());
                if (behavior == 'switch') {
                  final next = File('${temp.path}/next.json')
                    ..writeAsStringSync(
                      original.replaceFirst('Native bundle', 'Next owner'),
                    );
                  await tester.runAsync(() => c.open(next.path));
                  expect(run.phase, 'idle');
                } else {
                  run.dispose();
                  removed = true;
                }
                await tester.runAsync(() async {
                  pendingGate!.complete();
                  await pending!.timeout(workBound);
                });
                expect(Directory(destination).existsSync(), false);
                expect(source.readAsStringSync(), original);
              }
            }
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            if (pendingGate != null && !pendingGate!.isCompleted) {
              await tester.runAsync(() async {
                pendingGate!.complete();
                await pending;
              });
            }
            if (!removed) run.dispose();
            c.dispose();
            await tester.runAsync(() async {
              await c.engine.close();
              await temp.delete(recursive: true);
            });
          }
        },
      );
    }
  }
}
