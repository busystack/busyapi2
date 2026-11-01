import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  BusyProject? project;

  Future<ProcessResult> git(String directory, List<String> arguments) async {
    final result = await Process.run(
      '/usr/bin/git',
      arguments,
      workingDirectory: directory,
      environment: const {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
    }
    return result;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-m3-git-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });

  tearDown(() async {
    project?.close();
    await engine.close();
    await temp.delete(recursive: true);
  });

  test(
    'unborn repository supports status, reviewed staging and its first commit',
    () async {
      await git(temp.path, ['init', '-b', 'new-api']);
      await git(temp.path, ['config', 'user.name', 'BusyAPI Test']);
      await git(temp.path, ['config', 'user.email', 'test@example.invalid']);
      final source = File('${temp.path}/openapi.yaml')
        ..writeAsStringSync(
          'openapi: 3.1.2\ninfo: {title: New, version: "1"}\npaths: {}\n',
        );
      final repository = (await GitRepository.discover(temp.path))!;
      expect(repository.info.commit, isNull);
      expect(repository.info.branch, 'new-api');
      expect((await repository.status()).commit, isNull);
      expect(await repository.history(), isEmpty);
      await expectLater(
        repository.resolveRevision('HEAD'),
        throwsA(isA<GitFailure>()),
      );
      repository.trust();
      await repository.stageShown(
        'openapi.yaml',
        contentIdentity(source.readAsBytesSync()),
      );
      await repository.unstage(['openapi.yaml']);
      expect((await repository.status()).changes.single.staged, false);
      await repository.stageShown(
        'openapi.yaml',
        contentIdentity(source.readAsBytesSync()),
      );
      final id = await repository.commit('First reviewed API');
      expect((await repository.status()).commit, id);
      expect((await repository.history()).single.id, id);
      final historical = await repository.historicalSnapshot(
        revision: id,
        projectBoundary: temp.path,
        rootPath: 'openapi.yaml',
        engine: engine,
      );
      expect(
        historical.snapshot.resources.single['text'],
        source.readAsStringSync(),
      );
    },
  );

  for (final unrelatedCount in [0, 2050])
    test(
      'historical graph ignores $unrelatedCount unrelated files and large binaries',
      () async {
        await git(temp.path, ['init', '-b', 'api-review']);
        await git(temp.path, ['config', 'user.name', 'BusyAPI Test']);
        await git(temp.path, ['config', 'user.email', 'test@example.invalid']);
        File('${temp.path}/openapi.yaml').writeAsStringSync('''
openapi: 3.2.1
info: {title: Small API, version: "1"}
paths: {}
components: {schemas: {Value: {\$ref: './schema.yaml'}}}
''');
        File('${temp.path}/schema.yaml').writeAsStringSync('type: string\n');
        final unrelated = Directory('${temp.path}/unrelated')..createSync();
        for (var i = 0; i < unrelatedCount; i++) {
          File('${unrelated.path}/$i.txt')
              .writeAsStringSync('not an API dependency\n');
        }
        final large = File('${unrelated.path}/large.bin')
            .openSync(mode: FileMode.write);
        large.truncateSync(50 * 1024 * 1024);
        large.closeSync();
        await git(temp.path, ['add', '.']);
        await git(temp.path, ['commit', '-m', 'Small API in large repository']);
        final repository = (await GitRepository.discover(temp.path))!;
        final before = await git(temp.path, ['status', '--porcelain=v2']);
        final reads = <String, int>{};
        final snapshot = await repository.historicalSnapshot(
          revision: 'HEAD',
          projectBoundary: temp.path,
          rootPath: 'openapi.yaml',
          engine: engine,
          onBlobRead: (path, bytes) => reads[path] = bytes,
        );
        expect(snapshot.snapshot.resources.length, 2);
        expect(reads.keys.toSet(), {'openapi.yaml', 'schema.yaml'});
        expect(
          reads.values.fold<int>(0, (n, size) => n + size),
          lessThan(1024),
        );
        expect(
          snapshot.snapshot.resources.map((r) => r['id']),
          everyElement(isNot(contains('/unrelated/'))),
        );
        expect(snapshot.analysis['complete'], true);
        expect(
          (await git(temp.path, ['status', '--porcelain=v2'])).stdout,
          before.stdout,
        );
      },
    );

  test('real repository stages reviewed bytes, branches, pushes and reads history without checkout', () async {
    final repository = Directory('${temp.path}/repo')..createSync();
    await git(repository.path, ['init', '-b', 'trunk']);
    await git(repository.path, ['config', 'user.name', 'BusyAPI Test']);
    await git(repository.path, [
      'config',
      'user.email',
      'busyapi@example.invalid',
    ]);
    File('${repository.path}/busyapi.yaml').writeAsStringSync(
      'version: 1\nroots: [{name: api, path: openapi.yaml}]\n',
    );
    final contract = File('${repository.path}/openapi.yaml')
      ..writeAsStringSync('''
openapi: 3.1.2
info: {title: Git, version: "1"}
paths:
  /old:
    get:
      responses: {"200": {description: ok}}
''');
    await git(repository.path, ['add', '--', 'busyapi.yaml', 'openapi.yaml']);
    await git(repository.path, ['commit', '-m', 'baseline']);
    final baseline = (await git(repository.path, [
      'rev-parse',
      'HEAD',
    ])).stdout.toString().trim();

    final gateway = await GitRepository.discover(repository.path);
    expect(gateway, isNotNull);
    expect(gateway!.info.branch, 'trunk');
    expect(gateway.trusted, false);
    final unicode = File('${repository.path}/雪.yaml')
      ..writeAsStringSync('value: exact\n');
    var status = await gateway.status();
    expect(status.changes.map((value) => value.path), contains('雪.yaml'));
    await expectLater(
      gateway.stageShown('雪.yaml', contentIdentity(utf8.encode('wrong'))),
      throwsA(isA<GitFailure>().having((e) => e.code, 'code', 'git.trust')),
    );
    gateway.trust();
    await expectLater(
      gateway.stageShown('雪.yaml', contentIdentity(utf8.encode('wrong'))),
      throwsA(
        isA<GitFailure>().having((e) => e.code, 'code', 'git.source.changed'),
      ),
    );
    await gateway.stageShown(
      '雪.yaml',
      contentIdentity(await unicode.readAsBytes()),
    );
    status = await gateway.status();
    expect(
      status.changes.singleWhere((value) => value.path == '雪.yaml').staged,
      true,
    );
    final committed = await gateway.commit('reviewed Unicode path');
    expect(committed, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect((await gateway.history()).first.subject, 'reviewed Unicode path');

    final bare = Directory('${temp.path}/remote.git')..createSync();
    await git(bare.path, ['init', '--bare']);
    await git(repository.path, ['remote', 'add', 'origin', bare.path]);
    await gateway.push(remote: 'origin', branch: 'trunk');
    expect(
      (await git(bare.path, [
        'rev-parse',
        'refs/heads/trunk',
      ])).stdout.toString().trim(),
      committed,
    );

    final peer = Directory('${temp.path}/peer');
    await git(temp.path, ['clone', '-b', 'trunk', bare.path, peer.path]);
    await git(peer.path, ['config', 'user.name', 'BusyAPI Peer']);
    await git(peer.path, ['config', 'user.email', 'peer@example.invalid']);
    File('${peer.path}/remote.txt').writeAsStringSync('fetched and pulled\n');
    await git(peer.path, ['add', '--', 'remote.txt']);
    await git(peer.path, ['commit', '-m', 'remote update']);
    await git(peer.path, ['push', 'origin', 'trunk']);
    await gateway.fetch(remote: 'origin');
    await gateway.pull(
      GitPullStrategy.fastForwardOnly,
      remote: 'origin',
      branch: 'trunk',
    );
    expect(
      File('${repository.path}/remote.txt').readAsStringSync(),
      'fetched and pulled\n',
    );
    final cancelled = RunCancellation()..cancel();
    await expectLater(
      gateway.fetch(remote: 'origin', cancellation: cancelled),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );

    contract.writeAsStringSync('${contract.readAsStringSync()}\n# dirty\n');
    await expectLater(
      gateway.createBranch('review', hasUnsavedBuffers: true),
      throwsA(isA<GitFailure>().having((e) => e.code, 'code', 'git.unsaved')),
    );
    await expectLater(
      gateway.createBranch('review'),
      throwsA(isA<GitFailure>().having((e) => e.code, 'code', 'git.dirty')),
    );
    contract.writeAsStringSync(
      contract.readAsStringSync().replaceFirst('\n# dirty\n', ''),
    );
    await gateway.createBranch('review');
    expect(await gateway.branches(), containsAll(['trunk', 'review']));

    final historical = await gateway.historicalSnapshot(
      revision: baseline,
      projectBoundary: repository.path,
      rootPath: 'openapi.yaml',
      engine: engine,
    );
    expect(historical.commit, baseline);
    expect(
      historical.snapshot.resources.map((value) => value['id']),
      contains(contract.uri.toString()),
    );
    expect(
      contract.readAsStringSync(),
      isNot(contains('/missing-current-fallback')),
    );

    await gateway.switchBranch('trunk');
    contract.writeAsStringSync(
      contract.readAsStringSync().replaceFirst('title: Git', 'title: Local'),
    );
    await git(repository.path, ['add', '--', 'openapi.yaml']);
    await git(repository.path, ['commit', '-m', 'local conflict']);
    final peerContract = File('${peer.path}/openapi.yaml');
    peerContract.writeAsStringSync(
      peerContract.readAsStringSync().replaceFirst(
        'title: Git',
        'title: Remote',
      ),
    );
    await git(peer.path, ['add', '--', 'openapi.yaml']);
    await git(peer.path, ['commit', '-m', 'remote conflict']);
    await git(peer.path, ['push', 'origin', 'trunk']);
    await expectLater(
      gateway.pull(GitPullStrategy.merge, remote: 'origin', branch: 'trunk'),
      throwsA(isA<GitFailure>().having((e) => e.code, 'code', 'git.command')),
    );
    final conflicted = await GitRepository.discover(repository.path);
    expect(conflicted!.info.inProgress, 'merge');
    expect(
      (await conflicted.status()).changes.any(
        (change) => change.path == 'openapi.yaml',
      ),
      true,
    );
  });

  test(
    'oasdiff reports consumer changes and ignores formatting-only revisions',
    () async {
      final repository = Directory('${temp.path}/semantic')..createSync();
      await git(repository.path, ['init', '-b', 'feature']);
      await git(repository.path, ['config', 'user.name', 'BusyAPI Test']);
      await git(repository.path, [
        'config',
        'user.email',
        'busyapi@example.invalid',
      ]);
      File('${repository.path}/busyapi.yaml').writeAsStringSync(
        'version: 1\nroots: [{name: api, path: openapi.yaml}]\n',
      );
      final schemas = Directory('${repository.path}/schemas')..createSync();
      final oldSchema = File('${schemas.path}/old.yaml')
        ..writeAsBytesSync([
          239,
          187,
          191,
          ...utf8.encode('type: object\nproperties: {id: {type: string}}\n'),
        ]);
      final contract = File('${repository.path}/openapi.yaml')
        ..writeAsStringSync(_baselineContract);
      await git(repository.path, ['add', '--', '.']);
      await git(repository.path, ['commit', '-m', 'baseline']);
      final baselineId = (await git(repository.path, [
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim();
      oldSchema.deleteSync();
      File('${schemas.path}/current.yaml')
          .writeAsStringSync('type: array\nitems: {type: string}\n');
      contract.writeAsStringSync(_breakingContract);
      project = await BusyProject.open(repository.path, engine);
      final gateway = (await GitRepository.discover(repository.path))!;
      final historical = await gateway.historicalSnapshot(
        revision: baselineId,
        projectBoundary: repository.path,
        rootPath: 'openapi.yaml',
        engine: engine,
      );
      expect(
        historical.snapshot.resources.map((value) => value['id']),
        contains(oldSchema.uri.toString()),
      );
      expect(
        historical.snapshot.resources.singleWhere(
          (value) => value['id'] == oldSchema.uri.toString(),
        )['hasBom'],
        true,
      );
      expect(
        historical.snapshot.resources.map((value) => value['id']),
        isNot(contains(File('${schemas.path}/current.yaml').uri.toString())),
      );
      final current = await project!.captureContractSnapshot(
        contract.uri.toString(),
        saved: true,
      );
      final review =
          await OasdiffAdapter(
            executable: '$testBundle/libexec/busyapi/oasdiff',
          ).compare(
            historical.snapshot,
            current.snapshot,
            engine,
            baselineAnalysis: historical.analysis,
            currentAnalysis: current.analysis,
          );
      expect(review.complete, true);
      expect(review.breaking, true);
      expect(
        review.changes.map((value) => value.rule),
        contains('api-path-removed-without-deprecation'),
      );
      expect(
        review.changes.map((value) => value.rule),
        containsAll([
          'request-parameter-became-required',
          'request-parameter-enum-value-removed',
          'response-body-type-changed',
          'oasdiff-authentication-changed',
          'oasdiff-response-added',
        ]),
      );
      expect(review.rawDiff, contains('--- baseline/openapi.json'));
      expect(
        review.changes.where((value) => value.path == '/old').first.before,
        isNotNull,
      );
      expect(
        review.changes
            .singleWhere(
              (value) => value.rule == 'oasdiff-authentication-changed',
            )
            .after,
        isNotNull,
      );

      final formatted = Directory('${temp.path}/formatted')..createSync();
      File('${formatted.path}/openapi.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(jsonDecode(_baselineJson)),
      );
      final first = await BusyProject.open(
        File('${formatted.path}/openapi.json').path,
        engine,
      );
      addTearDown(first.close);
      final left = await first.captureContractSnapshot(
        File('${formatted.path}/openapi.json').uri.toString(),
        saved: true,
      );
      File('${formatted.path}/openapi.json').writeAsStringSync(_baselineJson);
      final second = await BusyProject.open(
        File('${formatted.path}/openapi.json').path,
        engine,
      );
      addTearDown(second.close);
      final right = await second.captureContractSnapshot(
        File('${formatted.path}/openapi.json').uri.toString(),
        saved: true,
      );
      final formatting = await OasdiffAdapter(
        executable: '$testBundle/libexec/busyapi/oasdiff',
      ).compare(left.snapshot, right.snapshot, engine);
      expect(formatting.changes, isEmpty);
      expect(formatting.breaking, false);
    },
  );
}

const _baselineContract = '''
openapi: 3.1.2
info: {title: Diff, version: "1"}
components:
  securitySchemes:
    bearer: {type: http, scheme: bearer}
paths:
  /old:
    get:
      operationId: old
      responses: {"200": {description: ok}}
  /items:
    get:
      parameters:
        - name: mode
          in: query
          schema: {type: string, enum: [a, b]}
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                \$ref: "./schemas/old.yaml"
''';

const _breakingContract = '''
openapi: 3.1.2
info: {title: Diff, version: "2"}
components:
  securitySchemes:
    bearer: {type: http, scheme: bearer}
paths:
  /items:
    get:
      security: [{bearer: []}]
      parameters:
        - name: mode
          in: query
          required: true
          schema: {type: string, enum: [a]}
      responses:
        "200":
          description: changed shape
          content:
            application/json:
              schema:
                \$ref: "./schemas/current.yaml"
        "201":
          description: changed
          content: {application/json: {schema: {type: array}}}
''';

const _baselineJson =
    '{"openapi":"3.1.2","info":{"title":"Same","version":"1"},"paths":{"/same":{"get":{"responses":{"200":{"description":"ok"}}}}}}';
