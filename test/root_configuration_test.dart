import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';
import 'widget_io.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final nativeRemoval in [false, true]) {
        testWidgets(
          'working root removal $version $json native=$nativeRemoval retains source and requires explicit native selection',
          (tester) async {
            for (final name in ['yaru_window', 'yaru_window/events']) {
              final channel = MethodChannel(name);
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                channel,
                (_) async => null,
              );
              addTearDown(
                () => tester.binding.defaultBinaryMessenger
                    .setMockMethodCallHandler(channel, null),
              );
            }
            tester.view.physicalSize = const Size(1400, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final temp = Directory.systemTemp.createTempSync(
              'busyapi-root-controls 雪 ',
            );
            final first = File('${temp.path}/first.${json ? 'json' : 'yaml'}'),
                second = File('${temp.path}/second.${json ? 'json' : 'yaml'}');
            final text = json
                ? '{"openapi":"$version","info":{"title":"Exact 😀","version":"1"},"paths":{}}'
                : '# retained 😀\r\nopenapi: $version\ninfo: {title: "Exact 😀", version: "1"}\r\npaths: {}';
            first.writeAsStringSync(text);
            second.writeAsStringSync(text);
            final config = File('${temp.path}/busyapi.yaml');
            final before =
                'version: 1\r\nroots:\n  - {name: First, path: ${first.uri.pathSegments.last}}\r\n  - {name: Second, path: ${second.uri.pathSegments.last}}\nunknown: {number: 900719925474099312345, value: "kept"}';
            config.writeAsStringSync(before);
            final after = before.replaceFirst(
              '  - {name: First, path: ${first.uri.pathSegments.last}}\r\n',
              '',
            );
            final original = {
              for (final file in [first, second, config])
                file.path: file.readAsBytesSync(),
            };
            final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            );
            final c = WorkspaceController(
              engine,
              StateLocations(
                config: '${temp.path}/config',
                state: '${temp.path}/state',
                cache: '${temp.path}/cache',
              ),
            );
            final previousErrorHandler = FlutterError.onError;
            FlutterError.onError = (details) {
              if (details.exception is RangeError) {
                debugPrintStack(
                  label: 'Root-control RangeError origin',
                  stackTrace: details.stack,
                );
              }
              previousErrorHandler?.call(details);
            };
            try {
              await runWidgetIo(tester, () async {
                await c.initialize();
                await c.open(temp.path);
                await c.selectRoot(first.uri.toString());
                await c.analyse();
                await c.openProjectConfiguration();
              });
              await tester.pumpWidget(
                ProviderScope(
                  overrides: [
                    linuxAccentPlatformProvider.overrideWithValue(false),
                  ],
                  child: BusyApiApp(controller: c),
                ),
              );
              await tester.pumpAndSettle();
              final l = AppLocalizations.of(
                tester.element(find.byType(WorkspaceScreen)),
              )!;
              final input = find.descendant(
                of: find.byType(SourceEditor),
                matching: find.byType(EditableText),
              );
              expect(input, findsOneWidget);
              if (nativeRemoval) {
                const menuChannel = MethodChannel('busyapi/native_menus');
                tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                  menuChannel,
                  (call) async {
                    if (call.method != 'show') return true;
                    final entries = (call.arguments as Map)['entries'] as List;
                    final selected = entries.indexWhere(
                      (entry) => entry['label'] == l.selectRoot,
                    );
                    expect(selected, greaterThanOrEqualTo(0));
                    return selected;
                  },
                );
                addTearDown(
                  () => tester.binding.defaultBinaryMessenger
                      .setMockMethodCallHandler(menuChannel, null),
                );
                Future<void> review(bool apply, {bool blocked = false}) async {
                  final header = find.byWidgetPredicate(
                    (widget) =>
                        widget is BusyApiHeaderPopupMenuButton<String> &&
                        widget.tooltip == l.appTitle,
                  );
                  await tester.runAsync(() => tester.tap(header));
                  await tester.pumpAndSettle();
                  final row = find.descendant(
                    of: find.byType(BusyApiDialogShell),
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is BusyApiActionRow && widget.title == 'First',
                    ),
                  );
                  final remove = find.descendant(
                    of: row,
                    matching: find.byTooltip(l.removeContractRoot),
                  );
                  expect(remove, findsOneWidget);
                  await tester.tap(remove);
                  await tester.pump();
                  await runWidgetIo(tester, () async {
                    while (find.text(l.reviewRootRemoval).evaluate().isEmpty) {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 20),
                      );
                    }
                  });
                  await tester.pumpAndSettle();
                  expect(find.text(l.rootRemovalImpact), findsOneWidget);
                  expect(find.text(l.rootRemovalScope), findsOneWidget);
                  expect(c.project!.roots.map((root) => root.name), [
                    'First',
                    'Second',
                  ]);
                  if (blocked) {
                    expect(find.text(l.rootRemovalBlocked), findsOneWidget);
                    final applyButton = tester.widget<BusyApiDialogButton>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is BusyApiDialogButton &&
                            widget.label == l.apply,
                      ),
                    );
                    expect(applyButton.onPressed, isNull);
                    await tester.tap(
                      find.descendant(
                        of: find.byType(BusyApiDialogShell),
                        matching: find.byType(BusyApiSwitchRow),
                      ),
                    );
                    await tester.pumpAndSettle();
                    final usage = find.byWidgetPredicate(
                      (widget) =>
                          widget is BusyApiActionRow &&
                          widget.title == second.uri.pathSegments.last &&
                          (widget.subtitle?.startsWith(
                                '/components/schemas/Use/\$ref\n',
                              ) ??
                              false),
                    );
                    expect(usage, findsOneWidget);
                    await tester.tap(usage);
                    await tester.pump();
                    await runWidgetIo(tester, () async {
                      while (c.active != second.uri.toString()) {
                        await Future<void>.delayed(
                          const Duration(milliseconds: 20),
                        );
                      }
                    });
                    await tester.pumpAndSettle();
                    expect(c.mode, 'Source');
                    expect(c.root, first.uri.toString());
                    expect(
                      c.project!.store.get(config.uri.toString()).text,
                      before,
                    );
                    final source = c.buffer!;
                    expect(
                      source.selection.base,
                      source.text.indexOf('"busyapi.yaml#/roots/0"'),
                    );
                    return;
                  }
                  await tester.tap(find.text(apply ? l.apply : l.cancel));
                  await tester.pump();
                  await runWidgetIo(tester, () async {
                    while (find
                        .text(l.reviewRootRemoval)
                        .evaluate()
                        .isNotEmpty) {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 20),
                      );
                    }
                  });
                  await tester.pumpAndSettle();
                }

                final consumer = json
                    ? '${text.substring(0, text.length - 1)},"components":{"schemas":{"Use":{"\$ref":"busyapi.yaml#/roots/0"}}}}'
                    : '$text\ncomponents: {schemas: {Use: {\$ref: "busyapi.yaml#/roots/0"}}}';
                await runWidgetIo(tester, () async {
                  await c.project!.buffer(second.uri.toString());
                  c.sourceEdit(second.uri.toString(), consumer);
                });
                await review(false, blocked: true);
                await runWidgetIo(tester, () async {
                  c.sourceEdit(second.uri.toString(), text);
                  await c.openProjectConfiguration();
                });
                await tester.pumpAndSettle();
                await review(false);
                expect(
                  tester.widget<EditableText>(input).controller.text,
                  before,
                );
                expect(
                  c.project!.store.get(config.uri.toString()).dirty,
                  false,
                );
                await review(true);
              } else {
                await tester.enterText(input, after);
              }
              final selection = TextSelection.collapsed(
                offset: after.indexOf('Second'),
              );
              tester.widget<EditableText>(input).controller.selection =
                  selection;
              await tester.pump();
              await runWidgetIo(tester, c.analyse);
              await tester.pumpAndSettle();
              expect(c.project!.roots.map((root) => root.name), ['Second']);
              expect(c.root, first.uri.toString());
              expect(c.active, config.uri.toString());
              expect(tester.widget<EditableText>(input).controller.text, after);
              expect(
                tester.widget<EditableText>(input).controller.selection,
                selection,
              );
              expect(find.text(l.unconfiguredRoot), findsOneWidget);
              await runWidgetIo(tester, () async {
                await expectLater(
                  c.selectRoot(first.uri.toString()),
                  throwsA(
                    isA<CoreFailure>().having(
                      (error) => error.code,
                      'code',
                      'root.unconfigured',
                    ),
                  ),
                );
                await c.undo();
                await c.analyse();
              });
              await tester.pumpAndSettle();
              expect(c.root, first.uri.toString());
              expect(c.project!.roots.map((root) => root.name), [
                'First',
                'Second',
              ]);
              expect(
                tester.widget<EditableText>(input).controller.text,
                before,
              );
              await runWidgetIo(tester, () async {
                await c.redo();
                await c.analyse();
              });
              await tester.pumpAndSettle();
              final choose = find.byWidgetPredicate(
                (widget) =>
                    widget is BusyApiBanner &&
                    widget.actionLabel == l.selectRoot &&
                    widget.title == l.unconfiguredRoot,
              );
              expect(choose, findsOneWidget);
              await tester.tap(
                find.descendant(of: choose, matching: find.text(l.selectRoot)),
              );
              await tester.pumpAndSettle();
              final next = find.descendant(
                of: find.byType(BusyApiDialogShell),
                matching: find.text('Second'),
              );
              expect(next, findsOneWidget);
              await tester.tap(next);
              await tester.pump();
              await runWidgetIo(tester, () async {
                while (c.root != second.uri.toString()) {
                  await Future<void>.delayed(const Duration(milliseconds: 20));
                }
              });
              await tester.pumpAndSettle();
              expect(c.project!.store.get(config.uri.toString()).text, after);
              for (final entry in original.entries) {
                expect(File(entry.key).readAsBytesSync(), entry.value);
              }
              expect(tester.takeException(), isNull);
            } finally {
              FlutterError.onError = previousErrorHandler;
              await tester.pumpWidget(const SizedBox());
              await tester.pump();
              await runWidgetIo(tester, c.shutdown);
              c.dispose();
              await tester.runAsync(engine.close);
              temp.deleteSync(recursive: true);
            }
          },
        );
      }
    }
  }
}
