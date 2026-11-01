import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _UnavailableDiscovery extends EngineProcess {
  _UnavailableDiscovery()
    : super(executable: runtimeNode, helper: runtimeHelper);
  @override
  Future<void> start() async {}
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    throw CoreFailure('engine.timeout', 'Controlled discovery timeout');
  }
}

void main() {
  late Directory temp;
  late EngineProcess engine;
  final plans = <ProjectImportPlan>[];
  const root =
      'openapi: 3.2.1\r\ninfo: {title: 雪, version: "1"}\r\npaths: {}\r\ncomponents: {schemas: {Thing: {\$ref: "./schema.yaml"}}}\r\n';
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-import-test-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    for (final plan in plans) {
      plan.close();
    }
    plans.clear();
    await engine.close();
    await temp.delete(recursive: true);
  });
  Future<Directory> fixture() async {
    final input = await Directory('${temp.path}/source 雪').create();
    await File('${input.path}/api.yaml').writeAsString('\uFEFF$root');
    await File('${input.path}/schema.yaml')
        .writeAsString('type: integer\nconst: 9007199254740993\n');
    return input;
  }

  test(
    'file acquisition preserves BOM, exact bytes and relative dependencies',
    () async {
      final input = await fixture();
      final plan = await ProjectImporter(engine).prepare(
        kind: ProjectImportKind.file,
        source: '${input.path}/api.yaml',
        destination: '${temp.path}/imported 雪',
      );
      plans.add(plan);
      expect(plan.complete, true);
      expect(plan.files, ['api.yaml', 'schema.yaml']);
      final acquired = await plan.publish();
      expect(acquired.destination, plan.destination);
      expect(acquired.root, '${plan.destination}/api.yaml');
      expect(
        await File(acquired.root).readAsBytes(),
        await File('${input.path}/api.yaml').readAsBytes(),
      );
      expect(
        await File('${plan.destination}/schema.yaml').readAsBytes(),
        await File('${input.path}/schema.yaml').readAsBytes(),
      );
      await expectLater(plan.publish(), throwsA(isA<CoreFailure>()));
    },
  );
  test(
    'unavailable discovery is not misreported as an ambiguous or absent root',
    () async {
      final input = await fixture(), unavailable = _UnavailableDiscovery();
      try {
        await expectLater(
          ProjectImporter(unavailable).prepare(
            kind: ProjectImportKind.file,
            source: '${input.path}/api.yaml',
            destination: '${temp.path}/not-published',
          ),
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'code',
              'engine.discovery',
            ),
          ),
        );
        expect(await Directory('${temp.path}/not-published').exists(), false);
      } finally {
        await unavailable.close();
      }
    },
  );
  test('directory root ambiguity requires selection; unknown files are copied unchanged', () async {
    final input = await fixture();
    await File('${input.path}/other.json').writeAsString(
      '{"openapi":"3.1.2","info":{"title":"Other","version":"1"},"paths":{}}',
    );
    final importer = ProjectImporter(engine);
    await expectLater(
      importer.prepare(
        kind: ProjectImportKind.directory,
        source: input.path,
        destination: '${temp.path}/ambiguous',
      ),
      throwsA(isA<ImportRootSelectionRequired>()),
    );
    await File('${input.path}/notes.txt').writeAsString('foreign notes\n');
    await Directory('${input.path}/empty 雪').create();
    final plan = await importer.prepare(
      kind: ProjectImportKind.directory,
      source: input.path,
      root: 'api.yaml',
      destination: '${temp.path}/selected',
    );
    plans.add(plan);
    expect(plan.files, contains('notes.txt'));
    await plan.publish();
    expect(
      await File('${plan.destination}/notes.txt').readAsString(),
      'foreign notes\n',
    );
    expect(await Directory('${plan.destination}/empty 雪').exists(), true);
  });
  test('directory import keeps captured graph and configuration despite later disk edits', () async {
    final input = await fixture();
    const configuration =
        '# retained comment\nversion: 1\nroots: [{name: selected, path: api.yaml}]\nfutureSetting: keep\n';
    await File('${input.path}/busyapi.yaml').writeAsString(configuration);
    final plan = await ProjectImporter(engine).prepare(
      kind: ProjectImportKind.directory,
      source: input.path,
      destination: '${temp.path}/frozen',
      onSnapshotCaptured: (_) async {
        await File('${input.path}/api.yaml')
            .writeAsString('later author input');
        await File('${input.path}/busyapi.yaml')
            .writeAsString('later configuration');
        await File('${input.path}/schema.yaml').delete();
      },
    );
    plans.add(plan);
    await plan.publish();
    expect(
      await File('${plan.destination}/api.yaml').readAsBytes(),
      utf8.encode('\uFEFF$root'),
    );
    expect(
      await File('${plan.destination}/busyapi.yaml').readAsString(),
      configuration,
    );
    expect(
      await File('${plan.destination}/schema.yaml').readAsString(),
      'type: integer\nconst: 9007199254740993\n',
    );
    expect(
      await File('${input.path}/api.yaml').readAsString(),
      'later author input',
    );
    expect(plan.metadata['snapshot'], isA<String>());
  });
  test('publication collision, cancellation and symlink acquisition leave originals intact', () async {
    final input = await fixture();
    final plan = await ProjectImporter(engine).prepare(
      kind: ProjectImportKind.file,
      source: '${input.path}/api.yaml',
      destination: '${temp.path}/raced',
    );
    plans.add(plan);
    await expectLater(
      plan.publish(
        beforePublish: () async {
          await Directory(plan.destination).create();
          await File('${plan.destination}/owner').writeAsString('concurrent');
        },
      ),
      throwsA(anything),
    );
    expect(
      await File('${plan.destination}/owner').readAsString(),
      'concurrent',
    );
    final cancel = RunCancellation()..cancel();
    await expectLater(
      plan.publish(cancellation: cancel),
      throwsA(isA<CoreFailure>()),
    );
    await Link('${input.path}/linked').create('${input.path}/schema.yaml');
    await expectLater(
      ProjectImporter(engine).prepare(
        kind: ProjectImportKind.directory,
        source: input.path,
        destination: '${temp.path}/linked-output',
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(await Directory('${temp.path}/linked-output').exists(), false);
    expect(
      await File('${input.path}/api.yaml').readAsBytes(),
      utf8.encode('\uFEFF$root'),
    );
  });
  test('HTTP import acquires only graph dependencies with exact URL approval, not example data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    final base = 'http://127.0.0.1:${server.port}';
    final subscription = server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path == '/api.yaml') {
        request.response.write('$root\nx-data: {\$ref: "$base/payload"}\n');
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '$base/api.yaml');
      } else {
        request.response.write('type: string\n');
      }
      await request.response.close();
    });
    try {
      final importer = ProjectImporter(engine);
      final denied = await importer.prepare(
        kind: ProjectImportKind.url,
        source: '$base/api.yaml',
        destination: '${temp.path}/denied',
      );
      plans.add(denied);
      expect(denied.complete, false);
      expect(denied.unavailable, ['$base/schema.yaml']);
      expect(requests, ['/api.yaml']);
      final approved = await importer.prepare(
        kind: ProjectImportKind.url,
        source: '$base/redirect',
        approvedUrls: {'$base/api.yaml', '$base/schema.yaml'},
        destination: '${temp.path}/approved',
      );
      plans.add(approved);
      expect(approved.complete, true);
      await approved.publish();
      expect(requests, ['/api.yaml', '/redirect', '/api.yaml', '/schema.yaml']);
      final reopened = await BusyProject.open(approved.destination, engine);
      try {
        final checked = await reopened.check(
          reopened.roots.single.id,
          schemaEvaluation: false,
        );
        expect(
          (checked['references'] as List).any(
            (r) => r['status'] == 'unavailable',
          ),
          false,
        );
      } finally {
        reopened.close();
      }
      await expectLater(
        importer.prepare(
          kind: ProjectImportKind.url,
          source: '$base/redirect',
          destination: '${temp.path}/unapproved-redirect',
        ),
        throwsA(isA<CoreFailure>()),
      );
      expect(requests.last, '/redirect');
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
  test('controlled Git clone preserves repository and never initializes submodules', () async {
    final input = await fixture();
    final executable = File('${input.path}/client-helper.sh')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    privatePermissions(executable.path, 493);
    for (final args in [
      ['init'],
      ['add', '.'],
      [
        '-c',
        'user.name=BusyAPI Test',
        '-c',
        'user.email=test@example.invalid',
        'commit',
        '-m',
        'fixture',
      ],
    ]) {
      final result = await Process.run(
        '/usr/bin/git',
        args,
        workingDirectory: input.path,
        environment: const {
          'PATH': '/usr/bin:/bin',
          'GIT_CONFIG_NOSYSTEM': '1',
          'GIT_CONFIG_GLOBAL': '/dev/null',
        },
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    final plan = await ProjectImporter(engine).prepare(
      kind: ProjectImportKind.git,
      source: input.path,
      destination: '${temp.path}/cloned',
    );
    plans.add(plan);
    await plan.publish();
    final repo = await GitRepository.discover(plan.destination);
    expect(repo, isNotNull);
    expect(repo!.trusted, false);
    expect(
      (await File('${plan.destination}/client-helper.sh').stat()).mode & 0x1ff,
      493,
    );
    expect(plan.metadata['git'], isA<Map>());
    expect(
      (await repo.status()).changes.every((change) => change.untracked),
      true,
    );
    expect(
      await File('${plan.destination}/api.yaml').readAsBytes(),
      await File('${input.path}/api.yaml').readAsBytes(),
    );
  });
}
