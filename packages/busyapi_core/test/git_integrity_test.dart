import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  Future<ProcessResult> git(List<String> args) async {
    final r = await Process.run(
      '/usr/bin/git',
      args,
      workingDirectory: temp.path,
      environment: {
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
      },
      includeParentEnvironment: true,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return r;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-git-integrity-');
    await git(['init', '-b', 'main']);
    await git(['config', 'user.name', 'BusyAPI Test']);
    await git(['config', 'user.email', 'test@example.invalid']);
  });
  tearDown(() => temp.delete(recursive: true));
  for (final unborn in [true, false])
    test(
      'R08 literal filenames stage unstage and diff exactly unborn=$unborn',
      () async {
        final pairs = [
          ['api[1].yaml', 'api1.yaml'],
          ['star*.yaml', 'starA.yaml'],
          ['question?.yaml', 'questionA.yaml'],
          [':(glob)api*.yaml', 'apix.yaml'],
          [':!literal.yaml', 'literal.yaml'],
          ['-leading.yaml', 'leading.yaml'],
          ['white space.yaml', 'white-space.yaml'],
        ];
        for (final pair in pairs)
          for (final name in pair) {
            await File('${temp.path}/$name').writeAsString('before\n');
          }
        if (!unborn) {
          await git(['add', '.']);
          await git(['commit', '-m', 'baseline']);
          for (final pair in pairs)
            for (final name in pair) {
              await File('${temp.path}/$name').writeAsString('after\n');
            }
        }
        final repo = (await GitRepository.discover(temp.path, trusted: true))!;
        for (final pair in pairs) {
          await repo.stagePaths([pair.first]);
          final paths =
              (await git(['diff', '--cached', '--name-only', '-z'])).stdout
                  as String;
          expect(paths.split('\u0000').where((s) => s.isNotEmpty), [
            pair.first,
          ]);
          final diff = await repo.diff(staged: true, paths: [pair.first]);
          expect(diff, contains(pair.first));
          expect(diff, isNot(contains('b/${pair.last}')));
          await repo.stagePaths([pair.last]);
          final both = await repo.diff(staged: true, paths: [pair.first]);
          expect(both, isNot(contains('b/${pair.last}')));
          await repo.unstage([pair.first]);
          expect(
            (await git(['diff', '--cached', '--name-only', '-z'])).stdout,
            '${pair.last}\u0000',
          );
          await repo.unstage([pair.last]);
          expect((await git(['diff', '--cached', '--name-only'])).stdout, '');
        }
      },
    );
  for (final split in [false, true])
    test(
      'R07-B review matches Git owner execute semantics split=$split',
      () async {
        final file = File('${temp.path}/mode.yaml');
        await file.writeAsString('BASE\n');
        privatePermissions(file.path, 420);
        await git(['config', 'core.fileMode', 'true']);
        await git(['add', '.']);
        await git(['commit', '-m', 'mode baseline']);
        if (split) await git(['update-index', '--split-index']);
        final repo = (await GitRepository.discover(temp.path, trusted: true))!;
        for (final mode in [420, 421, 428, 484, 493]) {
          privatePermissions(file.path, mode);
          await file.writeAsString('MODE $mode\n');
          await git(['add', '--', 'mode.yaml']);
          final expected = (await git([
            'ls-files',
            '--stage',
            '--',
            'mode.yaml',
          ])).stdout;
          await git(['restore', '--staged', '--', 'mode.yaml']);
          final review = await repo.reviewFile('mode.yaml');
          expect(review.diff.contains('new mode 100755'), mode & 64 != 0);
          await repo.stageReview(review);
          expect(
            (await git(['ls-files', '--stage', '--', 'mode.yaml'])).stdout,
            expected,
          );
          await git(['restore', '--staged', '--', 'mode.yaml']);
        }
      },
    );
  test(
    'R07 stageShown cannot let Git reread bytes after identity acceptance',
    () async {
      final source = File('${temp.path}/api.yaml');
      await source.writeAsString('BASE\n');
      await git(['add', '.']);
      await git(['commit', '-m', 'baseline']);
      await source.writeAsString('REVIEWED\n');
      final repo = (await GitRepository.discover(temp.path, trusted: true))!;
      final entered = Completer<void>(), release = Completer<void>();
      repo.onPhase = (phase) async {
        if (phase == 'stage:captured') {
          entered.complete();
          await release.future;
        }
      };
      final staging = repo.stageShown(
        'api.yaml',
        contentIdentity(utf8.encode('REVIEWED\n')),
      );
      await entered.future;
      await source.writeAsString('UNREVIEWED\n');
      release.complete();
      await staging;
      expect((await git(['show', ':api.yaml'])).stdout, 'REVIEWED\n');
      expect(await source.readAsString(), 'UNREVIEWED\n');
    },
  );

  test('R07 capture rejects intervening writes and binds review to owner mode index and base', () async {
    final file = File('${temp.path}/api.yaml');
    await file.writeAsString('BASE\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'base']);
    await file.writeAsString('REVIEWED\n');
    final repo = (await GitRepository.discover(temp.path, trusted: true))!;
    final entered = Completer<void>(), release = Completer<void>();
    repo.onPhase = (phase) async {
      if (phase == 'review:captured') {
        entered.complete();
        await release.future;
      }
    };
    final capture = repo.reviewFile('api.yaml');
    final rejected = expectLater(
      capture,
      throwsA(
        isA<GitFailure>().having((e) => e.code, 'code', 'git.source.changed'),
      ),
    );
    await entered.future;
    await file.writeAsString('UNREVIEWED\n');
    release.complete();
    await rejected;
    repo.onPhase = null;
    final review = await repo.reviewFile('api.yaml');
    expect(review.diff, contains('+UNREVIEWED'));
    await file.writeAsString('LATER\n');
    await expectLater(repo.stageReview(review), throwsA(isA<GitFailure>()));
    await file.writeAsString('UNREVIEWED\n');
    final foreign = (await GitRepository.discover(temp.path, trusted: true))!;
    await expectLater(
      foreign.stageReview(review),
      throwsA(isA<GitFailure>().having((e) => e.code, 'code', 'git.review')),
    );
    await File('${temp.path}/other').writeAsString('unrelated');
    await repo.stagePaths(['other']);
    await expectLater(repo.stageReview(review), throwsA(isA<GitFailure>()));
    expect((await git(['show', ':api.yaml'])).stdout, 'BASE\n');
    final current = await repo.reviewFile('api.yaml');
    await repo.stageReview(current);
    final staged = await repo.reviewFile('api.yaml', staged: true);
    await expectLater(repo.stageReview(staged), throwsA(isA<GitFailure>()));
    expect((await git(['show', ':other'])).stdout, 'unrelated');
    final branchReview = await repo.reviewFile('api.yaml');
    await git(['switch', '-c', 'feature']);
    await expectLater(
      repo.stageReview(branchReview),
      throwsA(isA<GitFailure>()),
    );
  });
  test('R07 reviewed deletion and partially staged content preserve other entries and Git normalization', () async {
    final file = File('${temp.path}/api.yaml');
    await file.writeAsString('BASE\n');
    await File('${temp.path}/other').writeAsString('keep');
    await File('${temp.path}/.gitattributes')
        .writeAsString('api.yaml text eol=lf\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'base']);
    final repo = (await GitRepository.discover(temp.path, trusted: true))!;
    await file.writeAsString('INDEX\n');
    await repo.stagePaths(['api.yaml']);
    await file.writeAsString('REVIEWED\r\n');
    final review = await repo.reviewFile('api.yaml');
    expect(review.diff, contains('-INDEX'));
    expect(review.diff, contains('+REVIEWED'));
    await repo.stageReview(review);
    expect((await git(['show', ':api.yaml'])).stdout, 'REVIEWED\n');
    expect((await git(['show', ':other'])).stdout, 'keep');
    await file.delete();
    final deletion = await repo.reviewFile('api.yaml');
    expect(deletion.diff, contains('-REVIEWED'));
    await repo.stageReview(deletion);
    expect((await git(['ls-files', '-z', '--', 'api.yaml'])).stdout, '');
    expect((await git(['show', ':other'])).stdout, 'keep');
    await File('${temp.path}/renamed.yaml').writeAsString('REVIEWED\n');
    final rename = await repo.reviewFile('renamed.yaml');
    await repo.stageReview(rename);
    expect((await git(['show', ':renamed.yaml'])).stdout, 'REVIEWED\n');
  });

  test(
    'R07 review freezes Git clean-filter bytes and executable mode',
    () async {
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString('BASE\n');
      await File('${temp.path}/.gitattributes')
          .writeAsString('api.yaml filter=busyreview\n');
      await git([
        'config',
        'filter.busyreview.clean',
        'sed s/REVIEWED/NORMALIZED/g',
      ]);
      await git(['add', '.']);
      await git(['commit', '-m', 'base']);
      await file.writeAsString('REVIEWED\n');
      privatePermissions(file.path, 493);
      final repo = (await GitRepository.discover(temp.path, trusted: true))!;
      final review = await repo.reviewFile('api.yaml');
      expect(review.diff, contains('+NORMALIZED'));
      expect(review.diff, contains('100755'));
      await git([
        'config',
        'filter.busyreview.clean',
        'sed s/REVIEWED/LATER/g',
      ]);
      await repo.stageReview(review);
      expect((await git(['show', ':api.yaml'])).stdout, 'NORMALIZED\n');
      expect(
        (await git(['ls-files', '--stage', '--', 'api.yaml'])).stdout,
        startsWith('100755 '),
      );
      await git(['config', 'core.fileMode', 'false']);
      privatePermissions(file.path, 420);
      final ignoredMode = await repo.reviewFile('api.yaml');
      await repo.stageReview(ignoredMode);
      expect(
        (await git(['ls-files', '--stage', '--', 'api.yaml'])).stdout,
        startsWith('100755 '),
      );
    },
  );
  test(
    'R07 cancelled staging releases its index lock without partial index edits',
    () async {
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString('BASE\n');
      await git(['add', '.']);
      await git(['commit', '-m', 'base']);
      await file.writeAsString('REVIEWED\n');
      final repo = (await GitRepository.discover(temp.path, trusted: true))!,
          review = await (await GitRepository.discover(
            temp.path,
            trusted: true,
          ))!.reviewFile('api.yaml');
      // A foreign owner cannot authorize this path, even with identical bytes.
      await expectLater(repo.stageReview(review), throwsA(isA<GitFailure>()));
      final owned = await repo.reviewFile('api.yaml'),
          entered = Completer<void>(),
          release = Completer<void>(),
          cancel = RunCancellation();
      repo.onPhase = (phase) async {
        if (phase == 'stage:captured') {
          entered.complete();
          await release.future;
        }
      };
      final staging = repo.stageReview(owned, cancellation: cancel),
          stopped = expectLater(
            staging,
            throwsA(
              isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled'),
            ),
          );
      await entered.future;
      cancel.cancel();
      release.complete();
      await stopped;
      expect((await git(['show', ':api.yaml'])).stdout, 'BASE\n');
      expect(await File('${temp.path}/.git/index.lock').exists(), false);
    },
  );
}
