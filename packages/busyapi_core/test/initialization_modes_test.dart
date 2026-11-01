import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _versions = [
  '2.0',
  '3.0.0',
  '3.0.1',
  '3.0.2',
  '3.0.3',
  '3.0.4',
  '3.1.0',
  '3.1.1',
  '3.1.2',
  '3.2.0',
  '3.2.1',
];

Future<ProcessResult> _cli(List<String> args) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    args,
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  var exited = false;
  final completion = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  try {
    await process.stdin.close();
    final code = await completion.timeout(const Duration(seconds: 60));
    return ProcessResult(process.pid, code, await output, await error);
  } finally {
    if (!exited) {
      process.kill();
      await completion.timeout(const Duration(seconds: 5));
    }
  }
}

void main() {
  late EngineProcess engine;
  setUpAll(() {
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDownAll(() => engine.close());

  for (final version in _versions) {
    for (final format in ['yaml', 'json']) {
      for (final mode in InitializationMode.values) {
        test(
          '$version $format ${mode.name} creation, CLI, editing and reopen retain family and ownership',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-init-modes-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final directory = '${temp.path}/core';
            final path = await Initializer.create(
              destination: directory,
              title: 'Original 雪😀',
              apiVersion: 'business-version',
              openapi: version,
              format: format,
              mode: mode,
            );
            expect(path, '$directory/openapi.$format');
            final file = File(path), manifest = File('$directory/busyapi.yaml');
            expect(manifest.existsSync(), mode == InitializationMode.project);
            expect(
              Directory(directory)
                  .listSync()
                  .map((f) => f.uri.pathSegments.last)
                  .toSet(),
              {
                'openapi.$format',
                if (mode == InitializationMode.project) 'busyapi.yaml',
              },
            );
            final original = file.readAsBytesSync();
            final project = await BusyProject.open(
              mode == InitializationMode.project ? directory : path,
              engine,
            );
            addTearDown(project.close);
            final root = project.roots.single.id,
                buffer = await project.buffer(project.roots.single.id);
            final checked = await project.check(root);
            final family = version == '2.0' ? '2.0' : version.substring(0, 3);
            expect(checked['status'], 'complete', reason: jsonEncode(checked));
            expect(checked['projection']['specification']['family'], family);
            expect(
              checked['projection']['specification']['declaredVersion'],
              version,
            );
            expect(
              checked['projection']['info']['value']['version'],
              'business-version',
            );
            await project.save(buffer);
            expect(file.readAsBytesSync(), original);
            final page = await project.inspectObject(root, root, '/info');
            final range = List<int>.from(page['range'] as List);
            await project.proposeAndApply(
              root,
              PropertySession(
                root: root,
                buffer: root,
                generation: buffer.generation,
                pointer: '/info',
                range: range,
                expected: buffer.text.substring(range[0], range[1]),
              ),
              [
                {
                  'kind': 'set',
                  'pointer': '/info/title',
                  'value': 'Edited 雪😀',
                },
              ],
            );
            final changed = buffer.text;
            expect(changed, contains('Edited 雪😀'));
            expect(file.readAsBytesSync(), original);
            project.store.undo();
            expect(utf8.encode(buffer.text), original);
            project.store.redo();
            expect(buffer.text, changed);
            expect((await project.check(root))['status'], 'complete');
            await project.save(buffer);
            expect(file.readAsStringSync(), changed);
            final sourceEdit = format == 'yaml'
                ? '$changed# Source edit\nx-exact: 9007199254740993.00\n'
                : changed.replaceFirst(
                    '"paths": {}',
                    '"x-exact": 9007199254740993.00, "paths": {}',
                  );
            project.store.replace(root, sourceEdit);
            expect((await project.check(root))['status'], 'complete');
            await project.save(buffer);
            expect(file.readAsStringSync(), sourceEdit);
            project.close();
            final reopened = await BusyProject.open(path, engine);
            addTearDown(reopened.close);
            expect(
              (await reopened.check(
                root,
              ))['projection']['info']['value']['title'],
              'Edited 雪😀',
            );
            expect(manifest.existsSync(), mode == InitializationMode.project);

            final cliDirectory = '${temp.path}/compiled';
            final cli = await _cli([
              'init',
              cliDirectory,
              '--title',
              'Original 雪😀',
              '--api-version',
              'business-version',
              '--openapi',
              version,
              '--format',
              format,
              if (mode == InitializationMode.standalone) '--standalone',
            ]);
            expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
            expect(cli.stdout, '$cliDirectory/openapi.$format\n');
            expect(cli.stderr, isEmpty);
            expect(
              File('$cliDirectory/openapi.$format').readAsBytesSync(),
              original,
            );
            expect(
              File('$cliDirectory/busyapi.yaml').existsSync(),
              mode == InitializationMode.project,
            );
            final cliCheck = await _cli([
              'check',
              mode == InitializationMode.project
                  ? cliDirectory
                  : '$cliDirectory/openapi.$format',
              '--json',
            ]);
            expect(
              cliCheck.exitCode,
              0,
              reason: '${cliCheck.stdout}\n${cliCheck.stderr}',
            );
            final report = jsonDecode(cliCheck.stdout as String) as Map;
            expect(report['complete'], true);
            expect(report['status'], 'complete');
            expect(
              File('$cliDirectory/openapi.$format').readAsBytesSync(),
              original,
            );
          },
        );
      }
    }
  }

  for (final format in ['yaml', 'json']) {
    test(
      'standalone $format refuses an existing manifest without publishing or altering it',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-init-neighbor-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final foreign = File('${temp.path}/busyapi.yaml')
          ..writeAsStringSync('foreign: [invalid project\n# retained\n');
        final bytes = foreign.readAsBytesSync();
        final touched = <String>[];
        await expectLater(
          Initializer.create(
            destination: temp.path,
            title: 'Isolated',
            apiVersion: '1',
            openapi: '2.0',
            format: format,
            mode: InitializationMode.standalone,
            beforePublish: (path) async => touched.add(path),
          ),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'init.collision'),
          ),
        );
        expect(touched, isEmpty);
        expect(File('${temp.path}/openapi.$format').existsSync(), false);
        expect(foreign.readAsBytesSync(), bytes);
        final cli = await _cli([
          'init',
          temp.path,
          '--standalone',
          '--format',
          format,
          '--title',
          'CLI isolated',
          '--api-version',
          '1',
        ]);
        expect(cli.exitCode, 3, reason: '${cli.stdout}\n${cli.stderr}');
        expect(cli.stdout, isEmpty);
        expect(cli.stderr, contains('init.collision'));
        expect(File('${temp.path}/openapi.$format').existsSync(), false);
        expect(foreign.readAsBytesSync(), bytes);
        expect(temp.listSync().length, 1);
      },
    );
    test(
      'standalone $format refuses a manifest appearing at its publication boundary',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-init-manifest-race-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final manifest = File('${temp.path}/busyapi.yaml');
        const concurrent = 'concurrent: [manifest\n# retained\n';
        final touched = <String>[];
        await expectLater(
          Initializer.create(
            destination: temp.path,
            title: 'Race',
            apiVersion: '1',
            format: format,
            mode: InitializationMode.standalone,
            beforePublish: (path) async {
              touched.add(path);
              manifest.writeAsStringSync(concurrent);
            },
          ),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'init.collision'),
          ),
        );
        expect(touched, ['${temp.path}/openapi.$format']);
        expect(File('${temp.path}/openapi.$format').existsSync(), false);
        expect(manifest.readAsStringSync(), concurrent);
        expect(temp.listSync().length, 1);
      },
    );
  }

  for (final mode in InitializationMode.values) {
    for (final moment in ['before-start', 'before-publication']) {
      test(
        '${mode.name} cancellation $moment leaves no contract or manifest',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-init-cancel-',
          );
          addTearDown(() => temp.delete(recursive: true));
          var cancelled = moment == 'before-start';
          final directory = Directory('${temp.path}/new');
          await expectLater(
            Initializer.create(
              destination: directory.path,
              title: 'Cancelled',
              apiVersion: '1',
              mode: mode,
              cancelled: () => cancelled,
              beforePublish: (_) async => cancelled = true,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'init.cancelled',
              ),
            ),
          );
          expect(directory.existsSync() ? directory.listSync() : [], isEmpty);
        },
      );
    }
    for (final race in ['file', 'symlink', 'boundary-error']) {
      test(
        '${mode.name} $race before publication preserves concurrent files',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-init-race-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final destination = Directory('${temp.path}/api');
          final external = File('${temp.path}/external')
            ..writeAsStringSync('external bytes');
          await expectLater(
            Initializer.create(
              destination: destination.path,
              title: 'Concurrent',
              apiVersion: '1',
              mode: mode,
              beforePublish: (path) async {
                if (race == 'boundary-error')
                  throw CoreFailure('fixture.failure', 'Before publication');
                if (race == 'file')
                  File(path).writeAsStringSync('concurrent bytes');
                if (race == 'symlink') Link(path).createSync(external.path);
              },
            ),
            throwsA(isA<CoreFailure>()),
          );
          expect(external.readAsStringSync(), 'external bytes');
          expect(File('${destination.path}/busyapi.yaml').existsSync(), false);
          if (race == 'file')
            expect(
              File('${destination.path}/openapi.yaml').readAsStringSync(),
              'concurrent bytes',
            );
          if (race == 'symlink')
            expect(
              Link('${destination.path}/openapi.yaml').targetSync(),
              external.path,
            );
          expect(
            destination.listSync().length,
            race == 'boundary-error' ? 0 : 1,
          );
        },
      );
    }
  }

  test('project cancellation after contract publication reports retained partial output', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-init-partial-cancel-',
    );
    addTearDown(() => temp.delete(recursive: true));
    var cancelled = false;
    await expectLater(
      Initializer.create(
        destination: temp.path,
        title: 'Retained',
        apiVersion: '1',
        cancelled: () => cancelled,
        beforePublish: (path) async {
          if (path.endsWith('busyapi.yaml')) cancelled = true;
        },
      ),
      throwsA(
        isA<CoreFailure>()
            .having((e) => e.code, 'code', 'init.partial')
            .having((e) => e.message, 'message', contains('init.cancelled')),
      ),
    );
    expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
    final file = File('${temp.path}/openapi.yaml');
    expect(file.readAsStringSync(), contains('Retained'));
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    expect(
      (await project.check(project.roots.single.id))['status'],
      'complete',
    );
  });

  for (final mode in InitializationMode.values) {
    test(
      '${mode.name} parent replacement cannot publish outside the captured directory',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-init-parent-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final destination = Directory('${temp.path}/api');
        final external = Directory('${temp.path}/external')..createSync();
        final sentinel = File('${external.path}/sentinel')
          ..writeAsStringSync('external bytes');
        final parked = Directory('${temp.path}/parked');
        await expectLater(
          Initializer.create(
            destination: destination.path,
            title: 'Captured',
            apiVersion: '1',
            mode: mode,
            beforePublish: (_) async {
              destination.renameSync(parked.path);
              Link(destination.path).createSync(external.path);
            },
          ),
          throwsA(isA<CoreFailure>()),
        );
        expect(sentinel.readAsStringSync(), 'external bytes');
        expect(external.listSync().map((f) => f.uri.pathSegments.last), [
          'sentinel',
        ]);
        expect(parked.listSync(), isEmpty);
        expect(Link(destination.path).targetSync(), external.path);
      },
    );
  }

  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format existing file opening retains project settings, root selection and configuration freshness',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-init-scope-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final path = await Initializer.create(
            destination: temp.path,
            title: 'Scoped',
            apiVersion: '1',
            openapi: version,
            format: format,
            mode: InitializationMode.standalone,
          );
          final file = File(path), root = File(path).uri.toString();
          const target = 'https://example.test/model';
          final data = <String, Object?>{
            (version == '2.0' ? 'swagger' : 'openapi'): version,
            'info': {'title': 'Scoped', 'version': '1'},
            'paths': {},
            if (version == '2.0')
              'definitions': {
                'Use': {r'$ref': target},
              }
            else
              'components': {
                'schemas': {
                  'Use': {r'$ref': target},
                },
              },
          };
          final text = format == 'json'
              ? jsonEncode(data)
              : '${version == '2.0' ? 'swagger' : 'openapi'}: "$version"\ninfo: {title: Scoped, version: "1"}\npaths: {}\n${version == '2.0' ? 'definitions:\n  Use:' : 'components:\n  schemas:\n    Use:'} {\$ref: "$target"}\n';
          file.writeAsStringSync(text);
          final model = File('${temp.path}/model.yaml')
            ..writeAsStringSync('type: integer\nenum: [9007199254740993]\n');
          final other = File('${temp.path}/other.json')
            ..writeAsStringSync(
              jsonEncode({
                (version == '2.0' ? 'swagger' : 'openapi'): version,
                'info': {'title': 'Other', 'version': '1'},
                'paths': {},
              }),
            );
          final manifest = File('${temp.path}/busyapi.yaml');
          final config =
              'version: 1\nroots: [{name: Main, path: openapi.$format}, {name: Other, path: other.json}]\nresourceMappings: {"$target": model.yaml}\n';
          manifest.writeAsStringSync(config);
          final selected = await BusyProject.open(path, engine);
          addTearDown(selected.close);
          expect(selected.configurationResource, manifest.uri.toString());
          expect(selected.hasRootConfiguration, false);
          expect(selected.roots.map((r) => r.id), [root]);
          expect((await selected.check(root))['status'], 'complete');
          expect(
            (await selected.check(root, saved: true))['status'],
            'complete',
          );
          await selected.approveResource(target, model.uri.toString());
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          expect(project.configurationResource, manifest.uri.toString());
          expect(project.hasRootConfiguration, true);
          expect(project.roots.map((r) => r.id).toSet(), {
            root,
            other.uri.toString(),
          });
          expect((await project.check(root))['status'], 'complete');
          final fresh = await BusyProject.open(path, engine);
          addTearDown(fresh.close);
          expect(fresh.roots.map((r) => r.id), [root]);
          expect((await fresh.check(root))['status'], 'complete');
          final buffer = await selected.buffer(root);
          final definition = version == '2.0'
              ? '/definitions/Use'
              : '/components/schemas/Use';
          Future<RefactoringPlan> rename() => selected.planComponentRename({
            'resource': root,
            'pointer': definition,
            'generation': buffer.generation,
          }, 'Renamed');
          final stale = await rename();
          final changedConfig = '$config# external configuration revision\n';
          manifest.writeAsStringSync(changedConfig);
          await expectLater(
            selected.applyRefactoring(stale),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'refactor.stale',
              ),
            ),
          );
          expect(buffer.text, text);
          expect(file.readAsStringSync(), text);
          await selected.applyRefactoring(await rename());
          expect(buffer.text, contains('Renamed'));
          await selected.save(buffer);
          for (final args in [
            ['check', path, '--json'],
            ['check', temp.path, '--json'],
            ['check', path, '--map-resource', target, model.path, '--json'],
          ]) {
            final result = await _cli(args);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
          }
          const invalidConfig =
              'invalid: [configuration\n# external writer retained\n';
          manifest.writeAsStringSync(invalidConfig);
          for (final owner in [selected, project]) {
            await expectLater(
              owner.check(root),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'manifest.syntax',
                ),
              ),
            );
          }
          final invalid = await _cli(['check', path, '--json']);
          expect(invalid.exitCode, 3);
          final report = jsonDecode(invalid.stdout as String) as Map;
          expect(report['complete'], false);
          expect(report['error']['code'], 'manifest.syntax');
          expect(manifest.readAsStringSync(), invalidConfig);
          expect(
            model.readAsStringSync(),
            'type: integer\nenum: [9007199254740993]\n',
          );
        },
      );
    }
  }

  test(
    'CLI standalone is init-only; collisions and help have explicit outcomes',
    () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-init-cli-');
      addTearDown(() => temp.delete(recursive: true));
      final help = await _cli(['--help']);
      expect(help.exitCode, 0);
      expect(help.stdout, contains('[--standalone]'));
      final target = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync('owned');
      final collision = await _cli([
        'init',
        temp.path,
        '--title',
        'Collision',
        '--api-version',
        '1',
        '--standalone',
      ]);
      expect(collision.exitCode, 3);
      expect(collision.stderr, contains('init.collision'));
      expect(target.readAsStringSync(), 'owned');
      final wrongCommand = await _cli([
        'check',
        target.path,
        '--standalone',
        '--json',
      ]);
      expect(wrongCommand.exitCode, 3);
      final report = jsonDecode(wrongCommand.stdout as String) as Map;
      expect(report['complete'], false);
      expect(report['error']['code'], 'cli.option');
      expect(target.readAsStringSync(), 'owned');
      expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
    },
  );
}
