import 'dart:async';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/workspace/project_import.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _NativeHttp extends HttpOverrides {}

WorkspaceController _workspace(Directory temp) => WorkspaceController(
  EngineProcess(executable: runtimeNode, helper: runtimeHelper),
  StateLocations(
    config: '${temp.path}/config',
    state: '${temp.path}/state',
    cache: '${temp.path}/cache',
  ),
);

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!condition() && elapsed.elapsed < const Duration(seconds: 12)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), true);
}

Future<void> _tap(WidgetTester tester, String label) => tester.runAsync(
  () => tester.tap(find.widgetWithText(BusyApiDialogButton, label)),
);

void _kind(WidgetTester tester, ProjectImportKind kind) {
  tester
      .widget<BusyApiComboRow<ProjectImportKind>>(
        find.byType(BusyApiComboRow<ProjectImportKind>),
      )
      .onSelected(kind);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => <String, Object?>{},
          );
    }
  });
  tearDown(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  for (final kind in [
    ProjectImportKind.directory,
    ProjectImportKind.git,
    ProjectImportKind.file,
    ProjectImportKind.url,
  ]) {
    testWidgets('${kind.name} handoff opens the acquired context and chosen root', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'busyapi-import-handoff-',
      );
      final source = Directory('${temp.path}/source 雪')..createSync();
      final destination = '${temp.path}/imported 雪';
      final configured = [
        ProjectImportKind.directory,
        ProjectImportKind.git,
      ].contains(kind);
      const document =
          'openapi: 3.2.1\r\ninfo: {title: Imported, version: "1"}\r\npaths: {}\r\n';
      final contents = configured
          ? <String, String>{
              'busyapi.yaml': '# original project\nversion: 1\nroots:\n  - name: Chosen nested\n    path: spec/openapi.yaml\n  - name: Another named root\n    path: other.yaml\nresourceMappings:\n  https://fixture.invalid/model: schemas/model.yaml\n',
              'spec/openapi.yaml':
                  '$document'
                  'components:\n  schemas:\n    Relative: {\$ref: ../schemas/model.yaml}\n    Mapped: {\$ref: https://fixture.invalid/model}\n',
              'other.yaml': document,
              'schemas/model.yaml': 'type: integer\nconst: 9007199254740993\n',
            }
          : <String, String>{
              'openapi.yaml':
                  '$document'
                  'components: {schemas: {Model: {\$ref: ./model.yaml}}}\n',
              'model.yaml': 'type: string\n',
            };
      for (final entry in contents.entries) {
        final file = File('${source.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      final originals = {
        for (final name in contents.keys)
          name: File('${source.path}/$name').readAsBytesSync(),
      };
      final owner = _workspace(temp);
      HttpServer? server;
      StreamSubscription<HttpRequest>? requests;
      final requested = <String>[];
      var input = configured ? source.path : '${source.path}/openapi.yaml';
      final errors = <Object>[];
      var completed = false;
      try {
        await tester.runAsync(() async {
          if (kind == ProjectImportKind.git) {
            for (final args in [
              ['init'],
              ['add', '.'],
              [
                '-c',
                'user.name=Fixture',
                '-c',
                'user.email=fixture@example.invalid',
                'commit',
                '-m',
                'original',
              ],
            ]) {
              final result = await Process.run(
                '/usr/bin/git',
                args,
                workingDirectory: source.path,
                environment: const {
                  'PATH': '/usr/bin:/bin',
                  'GIT_CONFIG_NOSYSTEM': '1',
                  'GIT_CONFIG_GLOBAL': '/dev/null',
                },
                includeParentEnvironment: false,
              );
              expect(result.exitCode, 0, reason: '${result.stderr}');
            }
          }
          if (kind == ProjectImportKind.url) {
            server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            input = 'http://127.0.0.1:${server!.port}/openapi.yaml';
            requests = server!.listen((request) async {
              requested.add(request.uri.path);
              request.response.write(contents[request.uri.path.substring(1)]);
              await request.response.close();
            });
          }
          await owner.initialize();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linuxAccentPlatformProvider.overrideWithValue(false)],
            child: BusyApiApp(controller: owner),
          ),
        );
        await tester.pumpAndSettle();
        final screen = tester.state<WorkspaceScreenState>(
          find.byType(WorkspaceScreen),
        );
        await tester.runAsync(() async {
          unawaited(
            screen.importProject().catchError(errors.add).whenComplete(() {
              completed = true;
            }),
          );
        });
        await tester.pumpAndSettle();
        _kind(tester, kind);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).at(0), input);
        await tester.enterText(find.byType(TextFormField).at(1), destination);
        if (kind == ProjectImportKind.url) {
          await tester.enterText(
            find.byType(TextFormField).at(2),
            'http://127.0.0.1:${server!.port}/model.yaml',
          );
        }
        await HttpOverrides.runWithHttpOverrides(() async {
          await _tap(tester, 'Acquire and review');
          if (configured) {
            await _until(
              tester,
              () => find.text('Chosen nested').evaluate().isNotEmpty,
            );
            await tester.runAsync(
              () => tester.tap(
                find.widgetWithText(BusyApiActionRow, 'Chosen nested'),
              ),
            );
          }
          await _until(
            tester,
            () => find.text('Import files').evaluate().isNotEmpty,
          );
        }, _NativeHttp());
        await _tap(tester, 'Import files');
        await _until(
          tester,
          () => find.textContaining('Acquired at').evaluate().isNotEmpty,
        );
        // Opening must use only the published destination, not the acquisition
        // source or a live HTTP fallback. Acquisition is not repeated by Open.
        final retired = source.renameSync('${temp.path}/retired source');
        await tester.runAsync(() async {
          await requests?.cancel();
          requests = null;
          await server?.close(force: true);
          server = null;
        });
        await _tap(tester, 'Open');
        await _until(tester, () => completed);
        expect(errors, isEmpty);
        expect(owner.project!.access.boundary, destination);
        final root =
            '$destination/${configured ? 'spec/openapi.yaml' : 'openapi.yaml'}';
        expect(owner.root, Uri.file(root).toString());
        if (configured) {
          expect(owner.project!.roots.map((r) => r.name), [
            'Chosen nested',
            'Another named root',
          ]);
          expect(
            owner.project!.configurationResource,
            Uri.file('$destination/busyapi.yaml').toString(),
          );
          expect(owner.project!.approvedResources, {
            'https://fixture.invalid/model': Uri.file(
              '$destination/schemas/model.yaml',
            ).toString(),
          });
        }
        await tester.runAsync(() async {
          final checked = await owner.project!.check(
            owner.root!,
            schemaEvaluation: false,
          );
          expect(checked['complete'], true);
          expect(
            (checked['references'] as List).any(
              (r) => r['status'] == 'unavailable',
            ),
            false,
          );
          expect(
            (checked['resources'] as List).every(
              (r) => (r['id'] as String).startsWith(
                Uri.directory(destination).toString(),
              ),
            ),
            true,
          );
        });
        for (final entry in originals.entries) {
          expect(
            File('${retired.path}/${entry.key}').readAsBytesSync(),
            entry.value,
          );
          if (kind != ProjectImportKind.url) {
            expect(
              File('$destination/${entry.key}').readAsBytesSync(),
              entry.value,
            );
          }
        }
        if (kind == ProjectImportKind.url) {
          expect(requested, ['/openapi.yaml', '/model.yaml']);
          expect(
            File('$destination/openapi.yaml').readAsBytesSync(),
            originals['openapi.yaml'],
          );
          expect(owner.project!.approvedResources.keys, contains(input));
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await owner.shutdown();
          owner.dispose();
          await owner.engine.close();
          await requests?.cancel();
          await server?.close(force: true);
          await temp.delete(recursive: true);
        });
      }
    });
  }

  for (final revise in [true, false]) {
    testWidgets(
      'publication collision permits ${revise ? 'revision and publication' : 'cancellation and disposal'}',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-import-revise-',
        );
        Directory('${temp.path}/source').createSync();
        final source = File('${temp.path}/source/api.yaml')
          ..writeAsStringSync(
            'openapi: 3.1.2\ninfo: {title: Copy, version: "1"}\npaths: {}\n',
          );
        final destination = '${temp.path}/competing', owner = _workspace(temp);
        Object? returned;
        HttpServer? server;
        StreamSubscription<HttpRequest>? requests;
        var input = source.path, approvals = '', acquisitions = 0;
        try {
          if (revise) {
            await tester.runAsync(() async {
              server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
              input = 'http://127.0.0.1:${server!.port}/api.yaml';
              approvals = 'http://127.0.0.1:${server!.port}/unused-resource';
              requests = server!.listen((request) async {
                acquisitions++;
                request.response.write(source.readAsStringSync());
                await request.response.close();
              });
            });
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async =>
                        returned = await showProjectImport(context, owner),
                    child: const Text('Import'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Import'));
          await tester.pumpAndSettle();
          if (revise) {
            _kind(tester, ProjectImportKind.url);
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextFormField).at(2), approvals);
          }
          await tester.enterText(find.byType(TextFormField).at(0), input);
          await tester.enterText(find.byType(TextFormField).at(1), destination);
          await HttpOverrides.runWithHttpOverrides(
            () => _tap(tester, 'Acquire and review'),
            _NativeHttp(),
          );
          await _until(
            tester,
            () => find.text('Import files').evaluate().isNotEmpty,
          );
          Directory(destination).createSync();
          final occupant = File('$destination/foreign')
            ..writeAsBytesSync([0, 255, 7, 13]);
          await _tap(tester, 'Import files');
          await _until(
            tester,
            () => find
                .textContaining('Import did not complete')
                .evaluate()
                .isNotEmpty,
          );
          expect(occupant.readAsBytesSync(), [0, 255, 7, 13]);
          expect(find.text(input), findsOneWidget);
          expect(find.text(destination), findsOneWidget);
          if (revise) {
            expect(find.text(approvals), findsOneWidget);
            expect(
              acquisitions,
              1,
            ); // Failure must not automatically reacquire.
          }
          expect(find.text('Change acquisition or approvals'), findsOneWidget);
          if (revise) {
            await _tap(tester, 'Change acquisition or approvals');
            await tester.pumpAndSettle();
            expect(find.text(input), findsOneWidget);
            expect(find.text(destination), findsOneWidget);
            expect(find.text(approvals), findsOneWidget);
            expect(acquisitions, 1);
            final replacement = '${temp.path}/different';
            await tester.enterText(
              find.byType(TextFormField).at(1),
              replacement,
            );
            await HttpOverrides.runWithHttpOverrides(
              () => _tap(tester, 'Acquire and review'),
              _NativeHttp(),
            );
            await _until(
              tester,
              () => find.text('Import files').evaluate().isNotEmpty,
            );
            await _tap(tester, 'Import files');
            await _until(
              tester,
              () => find.textContaining('Acquired at').evaluate().isNotEmpty,
            );
            expect(
              File('$replacement/openapi.yaml').readAsBytesSync(),
              source.readAsBytesSync(),
            );
            expect(acquisitions, 2);
            expect(find.text('Change acquisition or approvals'), findsNothing);
            expect(occupant.readAsBytesSync(), [0, 255, 7, 13]);
          }
          await _tap(tester, 'Cancel');
          await tester.pumpAndSettle();
          expect(returned, isNull);
          expect(find.text('Import Project…'), findsNothing);
          expect(occupant.readAsBytesSync(), [0, 255, 7, 13]);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          owner.dispose();
          await tester.runAsync(() async {
            await owner.engine.close();
            await requests?.cancel();
            await server?.close(force: true);
            await temp.delete(recursive: true);
          });
        }
      },
    );
  }

  test(
    'failed review retires its plan and disposal cancels held publication',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-import-dispose-',
      );
      await Directory('${temp.path}/source').create();
      final source = File('${temp.path}/source/api.yaml');
      await source.writeAsString(
        'openapi: 3.1.2\ninfo: {title: Copy, version: "1"}\npaths: {}\n',
      );
      final owner = _workspace(temp), destination = '${temp.path}/competing';
      final controller = ProjectImportController(owner);
      var disposed = false, notifications = 0;
      final release = Completer<void>();
      Future<void>? publication;
      try {
        await controller.prepare(
          kind: ProjectImportKind.file,
          source: source.path,
          destination: destination,
        );
        expect(controller.phase, 'review');
        final retired = controller.plan!;
        await Directory(destination).create();
        final competing = File('$destination/foreign');
        await competing.writeAsBytes([7, 0, 255]);
        await controller.publish();
        expect(controller.phase, 'failed');
        expect(controller.canRevise, true);
        controller.revise();
        expect(controller.plan, isNull);
        await expectLater(
          retired.publish(),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'import.closed'),
          ),
        );
        await controller.prepare(
          kind: ProjectImportKind.file,
          source: source.path,
          destination: '${temp.path}/replacement',
        );
        expect(controller.phase, 'review');
        final entered = Completer<void>();
        controller.addListener(() => notifications++);
        publication = controller.publish(
          beforePublish: () async {
            entered.complete();
            await release.future;
          },
        );
        await entered.future.timeout(const Duration(seconds: 5));
        controller.dispose();
        disposed = true;
        final before = notifications;
        release.complete();
        await publication.timeout(const Duration(seconds: 5));
        expect(notifications, before);
        expect(controller.phase, 'cancelled');
        expect(controller.acquired, isNull);
        expect(await Directory('${temp.path}/replacement').exists(), false);
        expect(await competing.readAsBytes(), [7, 0, 255]);
      } finally {
        if (!disposed) controller.dispose();
        if (!release.isCompleted) release.complete();
        await publication;
        owner.dispose();
        await owner.engine.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'published verification failure is not a retryable acquisition failure',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-import-partial-',
      );
      await Directory('${temp.path}/source').create();
      final source = File('${temp.path}/source/api.yaml');
      await source.writeAsString(
        'openapi: 3.1.2\ninfo: {title: Copy, version: "1"}\npaths: {}\n',
      );
      final owner = _workspace(temp), destination = '${temp.path}/published';
      final controller = ProjectImportController(owner);
      try {
        await controller.prepare(
          kind: ProjectImportKind.file,
          source: source.path,
          destination: destination,
        );
        expect(controller.phase, 'review');
        final captured = controller.plan!;
        await controller.publish(
          afterPublish: () {
            throw const FileSystemException(
              'Controlled post-publication check failure',
            );
          },
        );
        expect(controller.phase, 'partial');
        expect(controller.failure, 'output.published.uncertain');
        expect(captured.published, true);
        expect(controller.canRevise, false);
        expect(controller.acquired, isNull);
        expect(
          await File('$destination/api.yaml').readAsBytes(),
          await source.readAsBytes(),
        );
        await expectLater(
          captured.publish(),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'import.closed'),
          ),
        );
        controller.revise();
        await controller.prepare(
          kind: ProjectImportKind.file,
          source: source.path,
          destination: '${temp.path}/no-second-acquisition',
        );
        expect(controller.phase, 'partial');
        expect(controller.plan, same(captured));
        expect(
          await Directory('${temp.path}/no-second-acquisition').exists(),
          false,
        );
      } finally {
        controller.dispose();
        owner.dispose();
        await owner.engine.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
