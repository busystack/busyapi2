import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _HeldRevealController extends WorkspaceController {
  _HeldRevealController(super.engine, super.locations);
  Completer<void>? entered, release;
  Completer<void>? _waiting;
  void releaseWaiting() {
    final gate = _waiting;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<bool> flush() async {
    final gate = release;
    if (gate != null) {
      release = null;
      entered!.complete();
      _waiting = gate;
      try {
        await gate.future;
      } finally {
        _waiting = null;
      }
    }
    return super.flush();
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
  for (final preset in ['redoc', 'swagger']) {
    for (final version in ['3.1.2', '3.2.1']) {
      testWidgets(
        'installed $preset launcher $version binds current source, invalidates old windows and detaches on project switch',
        (tester) async {
          const channel = MethodChannel('io.busystack.busyapi/documentation');
          final messenger = TestDefaultBinaryMessengerBinding
                  .instance
                  .defaultBinaryMessenger,
              calls = <MethodCall>[];
          Map? opened, payload;
          Future<void> event(Map<String, Object?> value) async {
            final done = Completer<void>();
            messenger.handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(MethodCall('event', value)),
              (reply) {
                try {
                  channel.codec.decodeEnvelope(reply!);
                  done.complete();
                } on Object catch (error, stack) {
                  done.completeError(error, stack);
                }
              },
            );
            await done.future;
          }

          Map<String, Object?> identity(Map args) => {
            for (final key in ['version', 'owner', 'id', 'snapshot'])
              key: args[key],
          };
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final args = call.arguments as Map;
            if (call.method == 'attach') {
              return {'version': args['version'], 'owner': args['owner']};
            }
            if (call.method == 'open') {
              opened = args;
              final resources = args['resources'] as Map;
              expect(
                resources.keys,
                unorderedEquals([
                  'index.html',
                  '$preset.js',
                  'bootstrap.js',
                  if (preset == 'swagger') 'swagger.css',
                ]),
              );
              final html = utf8.decode(
                    (resources['index.html'] as List).cast<int>(),
                  ),
                  marker =
                      '<script id="busyapi-snapshot" type="application/json">',
                  start = html.indexOf(marker) + marker.length;
              payload = jsonDecode(
                html.substring(start, html.indexOf('</script>', start)),
              ) as Map;
              expect(payload!['snapshot'], args['snapshot']);
              expect(payload!['preset'], preset);
              expect(payload!['sourceActions'], isNotEmpty);
              expect(
                utf8.decode((resources['$preset.js'] as List).cast<int>()),
                contains(
                  preset == 'redoc'
                      ? 'THIRD_PARTY_NOTICES.txt'
                      : 'swagger-ui-es-bundle-core.js.LICENSE.txt',
                ),
              );
              // Deliberately ready before the native creation acknowledgement.
              await event({...identity(args), 'kind': 'ready'});
              return identity(args);
            }
            return null;
          });
          try {
            await _fixture(tester, version, 'json', (fixture) async {
              await tester.runAsync(
                preset == 'redoc'
                    ? fixture.screen.openRedocReference
                    : fixture.screen.openSwaggerReference,
              );
              expect(opened, isNotNull);
              final action = (payload!['sourceActions'] as List)
                      .cast<Map>()
                      .firstWhere(
                        (value) =>
                            value['role'] == 'node' &&
                            value['pointer'] == '/info',
                      ),
                  c = fixture.controller;
              await tester.runAsync(
                () => event({
                  ...identity(opened!),
                  'kind': 'source',
                  'index': action['index'],
                }),
              );
              await tester.pumpAndSettle();
              expect(c.active, fixture.root.uri.toString());
              expect(c.mode, 'Source');
              await tester.runAsync(() async {
                c.sourceEdit(
                  c.buffer!.id,
                  c.buffer!.text.replaceFirst('Public', 'Current'),
                );
              });
              final before = (
                c.buffer!.selection.base,
                c.buffer!.selection.extent,
              );
              expect(calls.any((call) => call.method == 'outdated'), true);
              await tester.runAsync(
                () => event({
                  ...identity(opened!),
                  'kind': 'source',
                  'index': action['index'],
                }),
              );
              expect((
                c.buffer!.selection.base,
                c.buffer!.selection.extent,
              ), before);
              await tester.runAsync(() => c.open(fixture.replacement.path));
              expect(calls.any((call) => call.method == 'detach'), true);
              expect(c.root, fixture.replacement.uri.toString());
            });
          } finally {
            messenger.setMockMethodCallHandler(channel, null);
          }
        },
      );
    }
  }
  for (final version in ['3.1.2', '3.2.1']) {
    testWidgets(
      'Documentation YAML alias $version reveals its authored occurrence, not its shared definition',
      (tester) async {
        await _fixture(tester, version, 'yaml', (fixture) async {
          final action = fixture.presentation.sourceActions.firstWhere(
            (action) =>
                action.role == 'node' &&
                action.source['pointer'] == '/components/schemas/Alias',
          );
          final text = fixture.controller.buffer!.text,
              offset = text.indexOf('*source_schema');
          expect(
            action.source['physicalPointer'],
            '/components/schemas/Shared',
          );
          expect(action.source['occurrenceRange'], [
            offset,
            offset + '*source_schema'.length,
          ]);
          expect(action.source['range'][0], isNot(offset));
          await tester.runAsync(
            () => fixture.screen.revealDocumentationSource(
              fixture.owner,
              fixture.presentation,
              action.index,
            ),
          );
          await tester.pumpAndSettle();
          expect(fixture.controller.active, fixture.root.uri.toString());
          expect(fixture.controller.buffer!.selection.base, offset);
          expect(
            fixture.controller.buffer!.text.substring(
              offset,
              offset + '*source_schema'.length,
            ),
            '*source_schema',
          );
          final definition = fixture.presentation.sourceActions.firstWhere(
            (action) =>
                action.role == 'node' &&
                action.source['pointer'] == '/components/schemas/Shared',
          );
          await tester.runAsync(
            () => fixture.screen.revealDocumentationSource(
              fixture.owner,
              fixture.presentation,
              definition.index,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            fixture.controller.buffer!.selection.base,
            definition.source['range'][0],
          );
          expect(fixture.controller.buffer!.selection.base, isNot(offset));
        }, alias: true);
      },
    );
  }
  testWidgets(
    'A later root command owns selection while an earlier flush is pending',
    (tester) async {
      await _fixture(tester, '3.2.1', 'json', (fixture) async {
        final c = fixture.controller,
            entered = Completer<void>(),
            release = Completer<void>();
        c.entered = entered;
        c.release = release;
        late Future<void> pending;
        try {
          await tester.runAsync(() async {
            pending = c
                .selectRoot(fixture.other.uri.toString())
                .then<void>(
                  (selected) {
                    if (!entered.isCompleted) {
                      entered.completeError(
                        StateError(
                          'Root selection returned $selected before entering the controlled flush',
                        ),
                      );
                    }
                  },
                  onError: (Object error, StackTrace stack) {
                    if (!entered.isCompleted) {
                      entered.completeError(error, stack);
                    }
                    Error.throwWithStackTrace(error, stack);
                  },
                );
            pending.ignore();
            await entered.future.timeout(const Duration(seconds: 15));
          });
          await tester.runAsync(
            () => c
                .selectRoot(fixture.root.uri.toString())
                .timeout(const Duration(seconds: 15)),
          );
          release.complete();
          await tester.runAsync(() => pending);
          expect(c.root, fixture.root.uri.toString());
          expect(c.active, fixture.root.uri.toString());
        } finally {
          if (!release.isCompleted) release.complete();
        }
      });
    },
  );
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        'Documentation source $version $format reveals an approved unopened fragment in its captured root without source writes',
        (tester) async {
          await _fixture(tester, version, format, (fixture) async {
            final action = fixture.presentation.sourceActions.firstWhere(
              (action) =>
                  action.role == 'node' &&
                  action.source['resource'] == fixture.part.uri.toString() &&
                  action.source['pointer'] == '/Thing',
            );
            expect(
              fixture.presentation.belongsTo(fixture.controller.project!),
              true,
            );
            expect(
              fixture.controller.store!.buffers.containsKey(
                fixture.part.uri.toString(),
              ),
              false,
            );
            await tester.runAsync(
              () => fixture.controller.selectRoot(fixture.other.uri.toString()),
            );
            await tester.pumpAndSettle();
            await tester.runAsync(
              () => fixture.screen.revealDocumentationSource(
                fixture.owner,
                fixture.presentation,
                action.index,
              ),
            );
            await tester.pumpAndSettle();
            expect(fixture.controller.root, fixture.root.uri.toString());
            expect(fixture.controller.active, fixture.part.uri.toString());
            expect(fixture.controller.mode, 'Source');
            expect(
              fixture.controller.buffer!.selection.base,
              action.source['range'][0],
            );
            expect(fixture.controller.buffer!.hasBom, true);
            expect(find.byType(SourceEditor), findsOneWidget);
            expect(fixture.presentation.outdated, false);
            expect(
              fixture.controller.store!.buffers.values.where((b) => b.dirty),
              isEmpty,
            );
          });
        },
      );
    }
  }
  for (final behavior in [
    'pending-form',
    'stale',
    'external-fragment',
    'wrong-owner',
    'switch',
    'later-reveal',
    'later-root',
    'dispose',
  ]) {
    testWidgets(
      'Documentation source $behavior cannot retarget captured ownership or change a declined view',
      (tester) async {
        await _fixture(tester, '3.2.1', 'json', (fixture) async {
          final c = fixture.controller,
              action = fixture.presentation.sourceActions.firstWhere(
                (action) =>
                    action.role == 'node' &&
                    action.source['pointer'] == '/Thing',
              );
          final before = (c.root, c.active, c.mode, c.buffer!.selection.base);
          BusyProject? different;
          try {
            if (behavior == 'pending-form') {
              final info = c.projection!['info'] as Map<String, dynamic>;
              c.beginForm('info', info, const {}, {
                'title': 'Public',
                'version': '1',
              });
              final form = c.form!;
              await tester.runAsync(
                () => fixture.screen.revealDocumentationSource(
                  fixture.owner,
                  fixture.presentation,
                  action.index,
                ),
              );
              expect(c.form, same(form));
              expect((
                c.root,
                c.active,
                c.mode,
                c.buffer!.selection.base,
              ), before);
              await tester.runAsync(() => c.cancelForm(form));
            } else if (behavior == 'stale') {
              await tester.runAsync(() async {
                c.sourceEdit(
                  c.buffer!.id,
                  c.buffer!.text.replaceFirst('Public', 'Unsaved'),
                );
              });
              await tester.runAsync(
                () => expectLater(
                  fixture.screen.revealDocumentationSource(
                    fixture.owner,
                    fixture.presentation,
                    action.index,
                  ),
                  throwsA(
                    isA<CoreFailure>().having(
                      (error) => error.code,
                      'code',
                      'navigation.outdated',
                    ),
                  ),
                ),
              );
              expect((
                c.root,
                c.active,
                c.mode,
                c.buffer!.selection.base,
              ), before);
              await tester.runAsync(c.undo);
            } else if (behavior == 'external-fragment') {
              final bytes = utf8.encode(
                '\ufeff${fixture.part.readAsStringSync().replaceFirst('Fragment', 'External')}',
              );
              await tester.runAsync(
                () => fixture.externalWrite(fixture.part, bytes),
              );
              await tester.runAsync(
                () => expectLater(
                  fixture.screen.revealDocumentationSource(
                    fixture.owner,
                    fixture.presentation,
                    action.index,
                  ),
                  throwsA(
                    isA<CoreFailure>().having(
                      (error) => error.code,
                      'code',
                      'navigation.outdated',
                    ),
                  ),
                ),
              );
              expect((
                c.root,
                c.active,
                c.mode,
                c.buffer!.selection.base,
              ), before);
              expect(fixture.part.readAsBytesSync(), bytes);
            } else if (behavior == 'wrong-owner') {
              different = await tester.runAsync(
                () => BusyProject.open(fixture.root.path, c.engine),
              );
              expect(fixture.presentation.belongsTo(different!), false);
              await tester.runAsync(
                () => expectLater(
                  fixture.screen.revealDocumentationSource(
                    different!,
                    fixture.presentation,
                    action.index,
                  ),
                  throwsA(
                    isA<CoreFailure>().having(
                      (error) => error.code,
                      'code',
                      'navigation.outdated',
                    ),
                  ),
                ),
              );
              expect((
                c.root,
                c.active,
                c.mode,
                c.buffer!.selection.base,
              ), before);
            } else {
              final entered = Completer<void>(), release = Completer<void>();
              c.entered = entered;
              c.release = release;
              late Future<void> pending;
              await tester.runAsync(() async {
                pending = fixture.screen.revealDocumentationSource(
                  fixture.owner,
                  fixture.presentation,
                  action.index,
                );
                pending.ignore();
                await entered.future;
              });
              if (behavior == 'switch') {
                await tester.runAsync(() => c.open(fixture.replacement.path));
              } else if (behavior == 'later-root') {
                await tester.runAsync(
                  () => c.selectRoot(fixture.other.uri.toString()),
                );
              } else if (behavior == 'dispose') {
                await tester.pumpWidget(const SizedBox.shrink());
              } else {
                final range = c.buffer!.text.indexOf('Public');
                await tester.runAsync(
                  () => fixture.screen.reveal({
                    'resource': c.buffer!.id,
                    'range': [range, range + 6],
                    'generation': c.buffer!.generation,
                  }),
                );
                expect(c.buffer!.selection.base, range);
              }
              release.complete();
              await tester.runAsync(
                () => expectLater(
                  pending,
                  throwsA(
                    isA<CoreFailure>().having(
                      (error) => error.code,
                      'code',
                      'navigation.outdated',
                    ),
                  ),
                ),
              );
              if (behavior == 'switch') {
                expect(c.root, fixture.replacement.uri.toString());
                expect(
                  c.store!.buffers.containsKey(fixture.part.uri.toString()),
                  false,
                );
              } else if (behavior == 'later-root') {
                expect(c.root, fixture.other.uri.toString());
                expect(c.active, fixture.other.uri.toString());
              } else if (behavior == 'later-reveal') {
                expect(c.active, fixture.root.uri.toString());
                expect(c.mode, 'Source');
                expect(
                  c.buffer!.selection.base,
                  c.buffer!.text.indexOf('Public'),
                );
              }
            }
            expect(tester.takeException(), isNull);
          } finally {
            different?.close();
          }
        });
      },
    );
  }
}

class _Fixture {
  _Fixture(
    this.controller,
    this.screen,
    this.owner,
    this.presentation,
    this.root,
    this.part,
    this.other,
    this.replacement,
    this.expected,
  );
  final _HeldRevealController controller;
  final WorkspaceScreenState screen;
  final BusyProject owner;
  final DocumentationPresentation presentation;
  final File root, part, other, replacement;
  final Map<String, List<int>> expected;
  Future<void> externalWrite(File file, List<int> bytes) async {
    if (!expected.containsKey(file.path)) {
      throw StateError('Unknown fixture file');
    }
    await file.writeAsBytes(bytes, flush: true);
    expected[file.path] = List.unmodifiable(bytes);
  }
}

Future<void> _fixture(
  WidgetTester tester,
  String version,
  String format,
  Future<void> Function(_Fixture) run, {
  bool alias = false,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final temp = Directory.systemTemp.createTempSync(
    'busyapi-documentation-reveal-',
  );
  final replacementDirectory = Directory.systemTemp.createTempSync(
    'busyapi-doc-replacement-',
  );
  final root = File('${temp.path}/root.$format'),
      other = File('${temp.path}/other.$format'),
      part = File('${temp.path}/part.$format'),
      replacement = File('${replacementDirectory.path}/replacement.json');
  final partBytes = utf8.encode(
    format == 'yaml'
        ? '\ufeffThing:\r\n  type: string\n  description: "Fragment 雪😀"\r\n  x-data: {large: 9007199254740993.00, "\$ref": "literal"}'
        : '\ufeff{\r\n"Thing":{"type":"string","description":"Fragment 雪😀","x-data":{"large":9007199254740993.00,"\$ref":"literal"}}\n}',
  );
  part.writeAsBytesSync(partBytes);
  root.writeAsStringSync(
    format == 'yaml'
        ? 'openapi: $version\r\ninfo: {title: Public, version: "1"}\npaths: {}\r\ncomponents:\n  schemas:\n    Use: {\$ref: "part.yaml#/Thing"}\n'
        : jsonEncode({
            'openapi': version,
            'info': {'title': 'Public', 'version': '1'},
            'paths': {},
            'components': {
              'schemas': {
                'Use': {r'$ref': 'part.json#/Thing'},
              },
            },
          }),
  );
  if (alias) {
    if (format != 'yaml') throw StateError('Aliases need the YAML fixture');
    root.writeAsStringSync(
      root.readAsStringSync().replaceFirst(
        '    Use:',
        '    Shared: &source_schema {type: string}\n    # Alias 雪😀\n    Alias: *source_schema\n    Use:',
      ),
    );
  }
  other.writeAsStringSync(
    format == 'yaml'
        ? 'openapi: $version\ninfo: {title: Other, version: "1"}\npaths: {}\n'
        : jsonEncode({
            'openapi': version,
            'info': {'title': 'Other', 'version': '1'},
            'paths': {},
          }),
  );
  replacement.writeAsStringSync(
    jsonEncode({
      'openapi': version,
      'info': {'title': 'Replacement', 'version': '1'},
      'paths': {},
    }),
  );
  File('${temp.path}/busyapi.yaml').writeAsStringSync(
    'version: 1\nroots:\n  - {name: public, path: root.$format}\n  - {name: other, path: other.$format}\n',
  );
  final originals = <String, List<int>>{
    for (final file in [root, part, other, replacement])
      file.path: file.readAsBytesSync(),
  };
  final c = _HeldRevealController(
    EngineProcess(executable: runtimeNode, helper: runtimeHelper),
    StateLocations(
      config: '${temp.path}/config',
      state: '${temp.path}/state',
      cache: '${temp.path}/cache',
    ),
  );
  try {
    late DocumentationPresentation presentation;
    late BusyProject owner;
    await tester.runAsync(() async {
      await c.initialize();
      await c.open(temp.path);
      await c.selectRoot(root.uri.toString());
      await c.analyse();
      owner = c.project!;
      presentation = await owner.captureDocumentationPresentation(c.root!);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
        child: BusyApiApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    final screen = tester.state<WorkspaceScreenState>(
      find.byType(WorkspaceScreen),
    );
    await run(
      _Fixture(
        c,
        screen,
        owner,
        presentation,
        root,
        part,
        other,
        replacement,
        originals,
      ),
    );
    for (final entry in originals.entries) {
      expect(File(entry.key).readAsBytesSync(), entry.value);
    }
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    c.releaseWaiting();
    await tester.runAsync(c.shutdown);
    c.dispose();
    await tester.runAsync(c.engine.close);
    temp.deleteSync(recursive: true);
    replacementDirectory.deleteSync(recursive: true);
  }
}
