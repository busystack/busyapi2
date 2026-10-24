import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'engine_process.dart';
import 'model.dart';
import 'project.dart';
import 'storage.dart';

const gitOutputLimitBytes = 32 * 1024 * 1024;

class GitFailure extends CoreFailure {
  GitFailure(super.code, super.message, {this.command, this.exitCode});
  final String? command;
  final int? exitCode;
}

class GitRepositoryInfo {
  const GitRepositoryInfo({
    required this.root,
    required this.gitDirectory,
    required this.commit,
    required this.branch,
    required this.detached,
    required this.bare,
    required this.inProgress,
  });
  final String root, gitDirectory;
  final String? commit;
  bool get unborn => commit == null && branch != null;
  final String? branch;
  final bool detached, bare;
  final String? inProgress;
}

class GitChange {
  const GitChange({
    required this.path,
    required this.index,
    required this.worktree,
    this.originalPath,
    this.untracked = false,
    this.ignored = false,
  });
  final String path, index, worktree;
  final String? originalPath;
  final bool untracked, ignored;
  bool get staged => index != '.' && index != ' ' && index != '?';
  bool get unstaged => worktree != '.' && worktree != ' ' || untracked;
}

class GitStatus {
  const GitStatus({
    required this.commit,
    required this.branch,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.changes,
  });
  final String? commit;
  bool get unborn => commit == null && branch != null;
  final String? branch, upstream;
  final int ahead, behind;
  final List<GitChange> changes;
  bool get clean => changes.where((value) => !value.ignored).isEmpty;
}

class GitCommit {
  const GitCommit({
    required this.id,
    required this.parents,
    required this.author,
    required this.email,
    required this.timestamp,
    required this.subject,
  });
  final String id, author, email, timestamp, subject;
  final List<String> parents;
}

enum GitPullStrategy { fastForwardOnly, merge, rebase }

class _GitResult {
  const _GitResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final Uint8List stdout, stderr;
  String get out => utf8.decode(stdout, allowMalformed: true);
  String get err => utf8.decode(stderr, allowMalformed: true);
}

/// Immutable bytes displayed by one repository/path/mode review. Only its
/// originating repository can stage it; a staged-only review never authorizes
/// a working-tree update.
class GitFileReview {
  GitFileReview._(
    this._owner,
    this.path,
    this.staged,
    this.diff,
    this._bytes,
    this._mode,
    this._indexPath,
    this._index,
    this._head,
    this._stagedBytes,
    this._stagedMode,
    this.stagingReady,
  );
  final GitRepository _owner;
  final String path, diff, _indexPath, _head;
  final bool staged;
  final Uint8List? _bytes, _index;
  final int? _mode;
  final Uint8List? _stagedBytes;
  final String _stagedMode;
  final bool stagingReady;
  String? get worktreeIdentity =>
      _bytes == null ? null : contentIdentity(_bytes);
}

class GitRepository {
  GitRepository._(this.info, this.executable, this._trusted);
  final GitRepositoryInfo info;
  final String executable;

  /// Local synchronization observer; no observer is installed by the UI.
  Future<void> Function(String phase)? onPhase;
  bool _trusted;
  bool get trusted => _trusted;
  void trust() => _trusted = true;

  /// An explicit clone does not trust repository hooks, filters or submodules.
  /// Caller owns a new private stage and publishes it only after inspection.
  static Future<({String version, String? commit})> cloneIntoStage(
    String source,
    String stage, {
    RunCancellation? cancellation,
    String? sourceDirectory,
  }) async {
    final parsed = Uri.tryParse(source);
    if (source.isNotEmpty &&
        !source.startsWith('-') &&
        parsed != null &&
        !parsed.hasScheme &&
        (!source.contains(':') ||
            source.startsWith('./') ||
            source.startsWith('../') ||
            p.isAbsolute(source))) {
      source = p.normalize(p.join(sourceDirectory ?? p.current, source));
    }
    final uri = Uri.tryParse(source);
    if (source.isEmpty ||
        source.startsWith('-') ||
        source.contains(RegExp(r'[\x00\r\n]')) ||
        RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*::').hasMatch(source) ||
        uri != null &&
            uri.hasScheme &&
            !['http', 'https', 'ssh', 'file'].contains(uri.scheme) ||
        uri != null &&
            (uri.userInfo.contains(':') || uri.hasQuery || uri.hasFragment) ||
        uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment)) {
      throw GitFailure(
        'git.clone.source',
        'Choose a local path or a supported credential-free Git transport',
      );
    }
    final executable = await _locate();
    if (executable == null)
      throw GitFailure(
        'git.executable',
        'Trusted Git executable is unavailable',
      );
    await _runStatic(
      executable,
      p.dirname(stage),
      [
        '-c',
        'core.hooksPath=/dev/null',
        '-c',
        'protocol.ext.allow=never',
        'clone',
        '--no-recurse-submodules',
        '--',
        source,
        stage,
      ],
      isolatedConfiguration: true,
      cancellation: cancellation,
    );
    final version = await _runStatic(
      executable,
      stage,
      const ['--version'],
      isolatedConfiguration: true,
      cancellation: cancellation,
    );
    return (
      version: version.out.trim(),
      commit: await _head(
        executable,
        stage,
        cancellation,
        isolatedConfiguration: true,
      ),
    );
  }

  static Future<GitRepository?> discover(
    String workspace, {
    String? executable,
    bool trusted = false,
    RunCancellation? cancellation,
  }) async {
    executable ??= await _locate();
    if (executable == null) return null;
    final directory = FileSystemEntity.isDirectorySync(workspace)
        ? p.absolute(workspace)
        : p.dirname(p.absolute(workspace));
    final root = await _runStatic(
      executable,
      directory,
      const ['rev-parse', '--show-toplevel'],
      readOnly: true,
      allowFailure: true,
      cancellation: cancellation,
    );
    if (root.exitCode != 0) return null;
    final rootPath = p.normalize(root.out.trimRight());
    final gitDir = await _required(
      executable,
      rootPath,
      const ['rev-parse', '--git-dir'],
      readOnly: true,
      cancellation: cancellation,
    );
    final commit = await _head(executable, rootPath, cancellation);
    final branchResult = await _runStatic(
      executable,
      rootPath,
      const ['symbolic-ref', '--quiet', '--short', 'HEAD'],
      readOnly: true,
      allowFailure: true,
      cancellation: cancellation,
    );
    final bare = await _required(
      executable,
      rootPath,
      const ['rev-parse', '--is-bare-repository'],
      readOnly: true,
      cancellation: cancellation,
    );
    String? progress;
    for (final candidate in const [
      ('MERGE_HEAD', 'merge'),
      ('REBASE_HEAD', 'rebase'),
      ('CHERRY_PICK_HEAD', 'cherry-pick'),
    ]) {
      final result = await _runStatic(
        executable,
        rootPath,
        ['rev-parse', '--verify', '--quiet', candidate.$1],
        readOnly: true,
        allowFailure: true,
        cancellation: cancellation,
      );
      if (result.exitCode == 0) {
        progress = candidate.$2;
        break;
      }
    }
    return GitRepository._(
      GitRepositoryInfo(
        root: rootPath,
        gitDirectory: p.isAbsolute(gitDir.out.trim())
            ? p.normalize(gitDir.out.trim())
            : p.normalize(p.join(rootPath, gitDir.out.trim())),
        commit: commit,
        branch: branchResult.exitCode == 0
            ? branchResult.out.trimRight()
            : null,
        detached: branchResult.exitCode != 0,
        bare: bare.out.trim() == 'true',
        inProgress: progress,
      ),
      executable,
      trusted,
    );
  }

  static Future<String?> _head(
    String executable,
    String root,
    RunCancellation? cancellation, {
    bool isolatedConfiguration = false,
  }) async {
    final result = await _runStatic(
      executable,
      root,
      const ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'],
      readOnly: true,
      allowFailure: true,
      cancellation: cancellation,
      isolatedConfiguration: isolatedConfiguration,
    );
    if (result.exitCode == 0 &&
        RegExp(r'^[0-9a-f]{40,64}$').hasMatch(result.out.trim()))
      return result.out.trim();
    if (result.exitCode == 1) {
      final symbolic = await _runStatic(
        executable,
        root,
        const ['symbolic-ref', '--quiet', 'HEAD'],
        readOnly: true,
        allowFailure: true,
        cancellation: cancellation,
        isolatedConfiguration: isolatedConfiguration,
      );
      if (symbolic.exitCode == 0 &&
          symbolic.out.trim().startsWith('refs/heads/')) {
        final ref = await _runStatic(
          executable,
          root,
          ['show-ref', '--verify', '--quiet', symbolic.out.trim()],
          readOnly: true,
          allowFailure: true,
          cancellation: cancellation,
          isolatedConfiguration: isolatedConfiguration,
        );
        if (ref.exitCode == 1)
          return null; // Exactly an absent symbolic branch.
      }
    }
    throw GitFailure(
      'git.head',
      'Cannot read the repository HEAD',
      exitCode: result.exitCode,
    );
  }

  static Future<String?> _locate() async {
    final candidates = <String>[
      if (Platform.environment['SNAP'] case final snap?) '$snap/usr/bin/git',
      '/usr/bin/git',
      '/bin/git',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<GitStatus> status({RunCancellation? cancellation}) async {
    final results = await Future.wait([
      _command(
        const ['status', '--porcelain=v2', '-z', '--untracked-files=all'],
        readOnly: true,
        cancellation: cancellation,
      ),
      _command(
        const ['status', '--porcelain=v2', '--branch', '--untracked-files=no'],
        readOnly: true,
        cancellation: cancellation,
      ),
    ]);
    final result = results.first;
    final branchResult = results.last;
    await onPhase?.call('status:captured');
    var commit = info.commit, ahead = 0, behind = 0;
    String? branch = info.branch, upstream;
    for (final field in const LineSplitter().convert(branchResult.out)) {
      if (field.startsWith('# branch.oid ')) {
        final value = field.substring(13);
        commit = value == '(initial)' ? null : value;
      }
      if (field.startsWith('# branch.head ')) {
        final value = field.substring(14);
        branch = value == '(detached)' ? null : value;
      }
      if (field.startsWith('# branch.upstream ')) {
        upstream = field.substring(18);
      }
      if (field.startsWith('# branch.ab ')) {
        final match = RegExp(r'^# branch\.ab \+(\d+) -(\d+)$')
            .firstMatch(field);
        if (match != null) {
          ahead = int.parse(match.group(1)!);
          behind = int.parse(match.group(2)!);
        }
      }
    }
    final fields = utf8
        .decode(result.stdout, allowMalformed: false)
        .split('\u0000');
    final changes = <GitChange>[];
    for (var index = 0; index < fields.length; index++) {
      final field = fields[index];
      if (field.isEmpty) continue;
      if (field.startsWith('? ')) {
        changes.add(
          GitChange(
            path: field.substring(2),
            index: '?',
            worktree: '?',
            untracked: true,
          ),
        );
      } else if (field.startsWith('! ')) {
        changes.add(
          GitChange(
            path: field.substring(2),
            index: '!',
            worktree: '!',
            ignored: true,
          ),
        );
      } else if (field.startsWith('1 ')) {
        final match = RegExp(
          r'^1 ([^ ]{2}) (?:[^ ]+ ){6}(.*)$',
          dotAll: true,
        ).firstMatch(field);
        if (match == null) {
          throw GitFailure(
            'git.protocol',
            'Git returned malformed status data',
          );
        }
        changes.add(
          GitChange(
            path: match.group(2)!,
            index: match.group(1)![0],
            worktree: match.group(1)![1],
          ),
        );
      } else if (field.startsWith('2 ')) {
        final match = RegExp(
          r'^2 ([^ ]{2}) (?:[^ ]+ ){7}(.*)$',
          dotAll: true,
        ).firstMatch(field);
        if (match == null || index + 1 >= fields.length) {
          throw GitFailure(
            'git.protocol',
            'Git returned malformed rename status data',
          );
        }
        changes.add(
          GitChange(
            path: match.group(2)!,
            originalPath: fields[++index],
            index: match.group(1)![0],
            worktree: match.group(1)![1],
          ),
        );
      } else if (field.startsWith('u ')) {
        final match = RegExp(
          r'^u ([^ ]{2}) (?:[^ ]+ ){8}(.*)$',
          dotAll: true,
        ).firstMatch(field);
        if (match == null) {
          throw GitFailure(
            'git.protocol',
            'Git returned malformed conflict status data',
          );
        }
        changes.add(
          GitChange(
            path: match.group(2)!,
            index: match.group(1)![0],
            worktree: match.group(1)![1],
          ),
        );
      }
    }
    return GitStatus(
      commit: commit,
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      changes: List.unmodifiable(changes),
    );
  }

  Future<String> diff({
    bool staged = false,
    List<String> paths = const [],
    RunCancellation? cancellation,
  }) async {
    for (final path in paths) _path(path);
    final result = await _command(
      [
        '--literal-pathspecs',
        'diff',
        if (staged) '--cached',
        '--no-ext-diff',
        '--no-textconv',
        '--no-color',
        '--find-renames',
        '--find-copies',
        if (paths.isNotEmpty) ...['--', ...paths],
      ],
      readOnly: true,
      cancellation: cancellation,
    );
    return utf8.decode(result.stdout, allowMalformed: true);
  }

  Future<void> stageShown(
    String relativePath,
    String expectedIdentity, {
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    final review = await reviewFile(relativePath, cancellation: cancellation);
    if (review._bytes == null) {
      throw GitFailure(
        'git.path',
        'Only the reviewed regular file can be staged',
      );
    }
    if (review.worktreeIdentity != expectedIdentity) {
      throw GitFailure(
        'git.source.changed',
        'Save and review the current file before staging; disk no longer matches the shown source',
      );
    }
    await stageReview(review, cancellation: cancellation);
  }

  Future<Uint8List?> _indexBytes(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        (await File(path).length()) > gitOutputLimitBytes)
      throw GitFailure(
        'git.index',
        'The Git index is not a bounded regular file',
      );
    return File(path).readAsBytes();
  }

  Future<String> _reviewHead(RunCancellation? cancellation) async {
    final commit = await _head(executable, info.root, cancellation);
    final branch = await _command(
      ['symbolic-ref', '--quiet', 'HEAD'],
      readOnly: true,
      allowFailure: true,
      cancellation: cancellation,
    );
    return '$commit:${branch.out.trim()}';
  }

  Future<(Uint8List?, int?)> _worktree(String relative) async {
    final path = _path(relative),
        type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return (null, null);
    if (type != FileSystemEntityType.file)
      throw GitFailure(
        'git.path',
        'Review requires a regular file or its deletion',
      );
    final access = await ProjectAccess.open(info.root);
    try {
      return (
        Uint8List.fromList(await access.read(path)),
        await access.mode(path),
      );
    } finally {
      access.close();
    }
  }

  static bool _sameBytes(Uint8List? a, Uint8List? b) => a == null || b == null
      ? a == b
      : contentIdentity(a) == contentIdentity(b);

  Future<bool> _reviewCurrent(
    GitFileReview review,
    RunCancellation? cancellation,
  ) async {
    if (!identical(review._owner, this) ||
        await _reviewHead(cancellation) != review._head ||
        !_sameBytes(await _indexBytes(review._indexPath), review._index))
      return false;
    final current = await _worktree(review.path);
    return _sameBytes(current.$1, review._bytes) && current.$2 == review._mode;
  }

  Future<GitFileReview> reviewFile(
    String path, {
    bool staged = false,
    RunCancellation? cancellation,
  }) async {
    _path(path);
    final indexPath = (await _command(
      ['rev-parse', '--path-format=absolute', '--git-path', 'index'],
      readOnly: true,
      cancellation: cancellation,
    )).out.trim();
    final index = await _indexBytes(indexPath),
        head = await _reviewHead(cancellation),
        working = await _worktree(path);
    final entry = await _command(
      ['--literal-pathspecs', 'ls-files', '--stage', '-z', '--', path],
      readOnly: true,
      cancellation: cancellation,
    );
    int? indexMode;
    Uint8List? indexSource;
    if (entry.stdout.isNotEmpty) {
      final match = RegExp(r'^(100644|100755) ([0-9a-f]{40,64}) 0\t')
          .firstMatch(entry.out);
      if (match == null || entry.out.substring(match.end) != '$path\u0000')
        throw GitFailure(
          'git.index',
          'Resolve this non-regular or conflicted index entry before reviewing',
        );
      indexMode = int.parse(match.group(1)!, radix: 8) & 511;
      indexSource = (await _command(
        ['cat-file', 'blob', match.group(2)!],
        readOnly: true,
        cancellation: cancellation,
      )).stdout;
    }
    var before = indexSource, beforeMode = indexMode, after = working.$1;
    var stagedMode = working.$2 != null && working.$2! & 0x40 != 0
        ? '100755'
        : '100644';
    int? afterMode = working.$2 == null
        ? null
        : working.$2! & 0x40 != 0
        ? 493
        : 420;
    if (staged) {
      after = indexSource;
      afterMode = indexMode;
      final commit = await _head(executable, info.root, cancellation);
      before = null;
      beforeMode = null;
      if (commit != null) {
        final old = await _command(
          ['--literal-pathspecs', 'ls-tree', '-z', commit, '--', path],
          readOnly: true,
          cancellation: cancellation,
        );
        if (old.stdout.isNotEmpty) {
          final match = RegExp(r'^(100644|100755) blob ([0-9a-f]{40,64})\t')
              .firstMatch(old.out);
          if (match == null || old.out.substring(match.end) != '$path\u0000')
            throw GitFailure(
              'git.path',
              'Review requires a regular historical file',
            );
          before = (await _command(
            ['cat-file', 'blob', match.group(2)!],
            readOnly: true,
            cancellation: cancellation,
          )).stdout;
          beforeMode = int.parse(match.group(1)!, radix: 8) & 511;
        }
      }
    }
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-git-review-',
    );
    String diff;
    try {
      privatePermissions(directory.path, 448);
      if (_trusted && !staged && after != null) {
        final objects = p.join(directory.path, 'objects');
        await Directory(objects).create();
        final hash = (await _command(
          ['hash-object', '-w', '--path=$path', '--stdin'],
          input: after,
          objectDirectory: objects,
          cancellation: cancellation,
        )).out.trim();
        if (!RegExp(r'^[0-9a-f]{40,64}$').hasMatch(hash))
          throw GitFailure(
            'git.protocol',
            'Git returned an invalid review blob',
          );
        after = (await _command(
          ['cat-file', 'blob', hash],
          objectDirectory: objects,
          readOnly: true,
          cancellation: cancellation,
        )).stdout;
        final fileMode =
            (await _command(
              ['config', '--bool', 'core.fileMode'],
              readOnly: true,
              allowFailure: true,
              cancellation: cancellation,
            )).out.trim() !=
            'false';
        if (!fileMode) stagedMode = indexMode == 493 ? '100755' : '100644';
        afterMode = stagedMode == '100755' ? 493 : 420;
      }
      Future<String> source(String prefix, Uint8List? bytes, int? mode) async {
        if (bytes == null) return '/dev/null';
        final relative = p.join(prefix, path),
            file = File(p.join(directory.path, relative));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        privatePermissions(file.path, mode == 493 ? 493 : 420);
        return relative;
      }

      final a = await source('a', before, beforeMode),
          b = await source('b', after, afterMode);
      await onPhase?.call('review:captured');
      final result = await _runStatic(
        executable,
        directory.path,
        [
          'diff',
          '--no-index',
          '--binary',
          '--no-ext-diff',
          '--no-textconv',
          '--no-color',
          '--no-prefix',
          '--',
          a,
          b,
        ],
        readOnly: true,
        allowFailure: true,
        cancellation: cancellation,
      );
      if (result.exitCode > 1)
        throw GitFailure('git.diff', 'Captured file diff failed');
      diff = result.out;
    } finally {
      await directory.delete(recursive: true);
    }
    final review = GitFileReview._(
      this,
      path,
      staged,
      diff,
      working.$1,
      working.$2,
      indexPath,
      index,
      head,
      after,
      stagedMode,
      _trusted && !staged,
    );
    if (!await _reviewCurrent(review, cancellation))
      throw GitFailure(
        'git.source.changed',
        'The review inputs changed during capture; review the current file again',
      );
    return review;
  }

  Future<void> stageReview(
    GitFileReview review, {
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    if (!identical(review._owner, this) ||
        review.staged ||
        !review.stagingReady)
      throw GitFailure(
        'git.review',
        'Choose this repository’s working-tree review before staging',
      );
    final lock = File('${review._indexPath}.lock');
    await lock.create(exclusive: true);
    Directory? directory;
    var published = false;
    try {
      directory = await Directory.systemTemp.createTemp('busyapi-git-index-');
      privatePermissions(directory.path, 448);
      if (!await _reviewCurrent(review, cancellation))
        throw GitFailure(
          'git.source.changed',
          'Disk or index changed since review; review the current file again',
        );
      // Everything below consumes captured bytes. Later worktree writes cannot
      // change the blob Git cleans or the index entry that is published.
      await onPhase?.call('stage:captured');
      final indexFile = p.join(directory.path, 'index');
      if (review._index != null) {
        await File(indexFile).writeAsBytes(review._index);
      } else {
        await _command(
          ['read-tree', '--empty'],
          indexFile: indexFile,
          cancellation: cancellation,
        );
      }
      if (review._bytes == null) {
        await _command(
          [
            '--literal-pathspecs',
            'update-index',
            '--force-remove',
            '--',
            review.path,
          ],
          indexFile: indexFile,
          cancellation: cancellation,
        );
      } else {
        final hash = (await _command(
          ['hash-object', '-w', '--no-filters', '--stdin'],
          input: review._stagedBytes,
          cancellation: cancellation,
        )).out.trim();
        if (!RegExp(r'^[0-9a-f]{40,64}$').hasMatch(hash))
          throw GitFailure(
            'git.protocol',
            'Git returned an invalid staged blob',
          );
        await _command(
          ['update-index', '--add', '-z', '--index-info'],
          indexFile: indexFile,
          input: Uint8List.fromList(
            utf8.encode('${review._stagedMode} $hash\t${review.path}\u0000'),
          ),
          cancellation: cancellation,
        );
      }
      if (await _reviewHead(cancellation) != review._head ||
          !_sameBytes(await _indexBytes(review._indexPath), review._index))
        throw GitFailure(
          'git.source.changed',
          'The reviewed index or branch changed before staging',
        );
      cancellation?.throwIfCancelled();
      await lock.writeAsBytes(await File(indexFile).readAsBytes(), flush: true);
      cancellation?.throwIfCancelled();
      privatePermissions(
        lock.path,
        await File(review._indexPath).exists()
            ? (await File(review._indexPath).stat()).mode & 511
            : 420,
      );
      await lock.rename(review._indexPath);
      published = true;
    } finally {
      if (!published && await lock.exists()) await lock.delete();
      await directory?.delete(recursive: true);
    }
  }

  Future<void> stagePaths(
    List<String> paths, {
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    if (paths.isEmpty) return;
    for (final path in paths) _path(path);
    await _command([
      '--literal-pathspecs',
      'add',
      '--',
      ...paths,
    ], cancellation: cancellation);
  }

  Future<void> unstage(
    List<String> paths, {
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    if (paths.isEmpty) return;
    for (final path in paths) _path(path);
    final head = await _head(executable, info.root, cancellation);
    await _command(
      head == null
          ? ['--literal-pathspecs', 'rm', '--cached', '--', ...paths]
          : ['--literal-pathspecs', 'restore', '--staged', '--', ...paths],
      cancellation: cancellation,
    );
  }

  Future<String> commit(String message, {RunCancellation? cancellation}) async {
    _requireTrust();
    if (message.trim().isEmpty ||
        message.length > 1024 * 1024 ||
        message.contains('\u0000')) {
      throw GitFailure('git.commit.message', 'Enter a bounded commit message');
    }
    await _command(['commit', '-m', message], cancellation: cancellation);
    return resolveRevision('HEAD', cancellation: cancellation);
  }

  Future<List<String>> branches({RunCancellation? cancellation}) async {
    final result = await _command(
      const ['for-each-ref', '--format=%(refname:short)', 'refs/heads'],
      readOnly: true,
      cancellation: cancellation,
    );
    return const LineSplitter()
        .convert(utf8.decode(result.stdout, allowMalformed: false))
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<void> createBranch(
    String name, {
    bool hasUnsavedBuffers = false,
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    _branch(name);
    await _protectCheckout(
      hasUnsavedBuffers: hasUnsavedBuffers,
      cancellation: cancellation,
    );
    await _command(['switch', '-c', name], cancellation: cancellation);
  }

  Future<void> switchBranch(
    String name, {
    bool hasUnsavedBuffers = false,
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    _branch(name);
    await _protectCheckout(
      hasUnsavedBuffers: hasUnsavedBuffers,
      cancellation: cancellation,
    );
    await _command(['switch', name], cancellation: cancellation);
  }

  Future<void> _protectCheckout({
    bool hasUnsavedBuffers = false,
    RunCancellation? cancellation,
  }) async {
    if (hasUnsavedBuffers) {
      throw GitFailure(
        'git.unsaved',
        'Save or discard editor buffers and request drafts before changing the checkout',
      );
    }
    if (!(await status(cancellation: cancellation)).clean) {
      throw GitFailure(
        'git.dirty',
        'Save, stage or discard working-tree changes before changing branches',
      );
    }
    if (info.inProgress != null)
      throw GitFailure(
        'git.in-progress',
        'Resolve the current ${info.inProgress} before changing branches',
      );
  }

  Future<List<GitCommit>> history({
    int limit = 100,
    RunCancellation? cancellation,
  }) async {
    if (limit < 1 || limit > 1000)
      throw GitFailure(
        'git.history.limit',
        'History limit must be between 1 and 1000',
      );
    if (await _head(executable, info.root, cancellation) == null)
      return const [];
    final result = await _command(
      [
        'log',
        '-$limit',
        '--date=iso-strict',
        '--format=%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s',
      ],
      readOnly: true,
      cancellation: cancellation,
    );
    final commits = <GitCommit>[];
    for (final record in result.out.split('\u001e')) {
      if (record.trim().isEmpty) continue;
      final fields = record.trimLeft().split('\u001f');
      if (fields.length != 6)
        throw GitFailure('git.protocol', 'Git returned malformed history data');
      commits.add(
        GitCommit(
          id: fields[0],
          parents: fields[1].isEmpty ? const [] : fields[1].split(' '),
          author: fields[2],
          email: fields[3],
          timestamp: fields[4],
          subject: fields[5].trimRight(),
        ),
      );
    }
    return commits;
  }

  Future<void> fetch({String? remote, RunCancellation? cancellation}) async {
    _requireTrust();
    if (remote != null) _remote(remote);
    await _command(
      ['fetch', if (remote != null) remote],
      interactive: true,
      cancellation: cancellation,
    );
  }

  Future<void> pull(
    GitPullStrategy strategy, {
    String? remote,
    String? branch,
    bool hasUnsavedBuffers = false,
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    if (remote != null) _remote(remote);
    if (branch != null) _branch(branch);
    await _protectCheckout(
      hasUnsavedBuffers: hasUnsavedBuffers,
      cancellation: cancellation,
    );
    await _command(
      [
        'pull',
        switch (strategy) {
          GitPullStrategy.fastForwardOnly => '--ff-only',
          GitPullStrategy.merge => '--no-rebase',
          GitPullStrategy.rebase => '--rebase',
        },
        if (remote != null) remote,
        if (branch != null) branch,
      ],
      interactive: true,
      cancellation: cancellation,
    );
  }

  Future<void> push({
    String? remote,
    String? branch,
    RunCancellation? cancellation,
  }) async {
    _requireTrust();
    if (remote != null) _remote(remote);
    if (branch != null) _branch(branch);
    await _command(
      ['push', if (remote != null) remote, if (branch != null) branch],
      interactive: true,
      cancellation: cancellation,
    );
  }

  Future<String> resolveRevision(
    String revision, {
    RunCancellation? cancellation,
  }) async {
    if (revision.isEmpty ||
        revision.length > 4096 ||
        revision.contains('\u0000'))
      throw GitFailure('git.revision', 'Choose a bounded revision');
    if (RegExp(r'^HEAD(?:$|[~^])').hasMatch(revision) &&
        await _head(executable, info.root, cancellation) == null) {
      throw GitFailure(
        'git.baseline.missing',
        'This repository has no commits yet; a historical comparison needs an existing baseline',
      );
    }
    final result = await _command(
      ['rev-parse', '--verify', '$revision^{commit}'],
      readOnly: true,
      cancellation: cancellation,
    );
    final value = result.out.trim();
    if (!RegExp(r'^[0-9a-f]{40,64}$').hasMatch(value))
      throw GitFailure(
        'git.protocol',
        'Git returned an invalid commit identity',
      );
    return value;
  }

  Future<String> mergeBase(
    String left,
    String right, {
    RunCancellation? cancellation,
  }) async {
    final a = await resolveRevision(left, cancellation: cancellation),
        b = await resolveRevision(right, cancellation: cancellation);
    final result = await _command(
      ['merge-base', a, b],
      readOnly: true,
      cancellation: cancellation,
    );
    final value = result.out.trim();
    if (!RegExp(r'^[0-9a-f]{40,64}$').hasMatch(value))
      throw GitFailure(
        'git.merge-base',
        'The selected revisions have no merge base',
      );
    return value;
  }

  Future<GitHistoricalSnapshot> historicalSnapshot({
    required String revision,
    required String projectBoundary,
    required String rootPath,
    required EngineProcess engine,
    RunCancellation? cancellation,
    void Function(String path, int bytes)? onBlobRead,
  }) async {
    final commit = await resolveRevision(revision, cancellation: cancellation);
    final boundary = p.normalize(p.absolute(projectBoundary));
    if (boundary != info.root && !p.isWithin(info.root, boundary))
      throw GitFailure(
        'git.project',
        'Project boundary is outside this repository',
      );
    final projectPrefix = p.relative(boundary, from: info.root) == '.'
        ? ''
        : p.posix.joinAll(p.split(p.relative(boundary, from: info.root)));
    final rootRelative = p.posix.joinAll(p.split(p.normalize(rootPath)));
    if (p.isAbsolute(rootPath) || rootRelative.startsWith('../'))
      throw GitFailure('git.path', 'Historical root must be project-relative');
    final resources = <String, Map<String, Object?>>{};
    Map<String, Object?>? configuration;
    var bytes = 0;
    final clock = Stopwatch()..start();
    final wantedRoot = projectPrefix.isEmpty
        ? rootRelative
        : '$projectPrefix/$rootRelative';
    Future<Map<String, Object?>?> read(
      String path, {
      bool manifest = false,
    }) async {
      cancellation?.throwIfCancelled();
      if (clock.elapsed > const Duration(minutes: 2))
        throw GitFailure(
          'limit.git.snapshot',
          'Historical graph collection exceeded its time budget',
        );
      // Look up only an acquired graph resource. Neither enumerate the tree nor
      // read unrelated blobs; immutable object IDs close subsequent path races.
      final entry = await _command(
        ['--literal-pathspecs', 'ls-tree', '-z', commit, '--', path],
        readOnly: true,
        cancellation: cancellation,
      );
      if (entry.stdout.isEmpty) return null;
      final record = utf8.decode(entry.stdout, allowMalformed: false);
      final match = RegExp(r'^100(?:644|755) blob ([0-9a-f]{40,64})\t')
          .firstMatch(record);
      if (match == null || record.substring(match.end) != '$path\u0000')
        throw GitFailure(
          'git.historical.resource',
          'A historical dependency is not a regular blob',
        );
      final object = match.group(1)!;
      final size = await _command(
        ['cat-file', '-s', object],
        readOnly: true,
        cancellation: cancellation,
      );
      final length = int.tryParse(size.out.trim());
      if (length == null || length > (manifest ? 65536 : 16 * 1024 * 1024))
        throw GitFailure(
          'limit.git.snapshot',
          'An acquired historical resource exceeds its byte budget',
        );
      final result = await _command(
        ['cat-file', 'blob', object],
        readOnly: true,
        cancellation: cancellation,
      );
      bytes += result.stdout.length;
      onBlobRead?.call(path, result.stdout.length);
      if (bytes > 48 * 1024 * 1024)
        throw GitFailure(
          'limit.git.snapshot',
          'Historical project exceeds the 48 MiB snapshot budget',
        );
      String text;
      final hasBom =
          result.stdout.length >= 3 &&
          result.stdout[0] == 239 &&
          result.stdout[1] == 187 &&
          result.stdout[2] == 191;
      try {
        text = utf8.decode(
          hasBom ? result.stdout.sublist(3) : result.stdout,
          allowMalformed: false,
        );
      } on FormatException {
        throw GitFailure(
          'git.historical.encoding',
          'A historical contract dependency is not UTF-8',
        );
      }
      final absolute = p.normalize(
            p.joinAll([info.root, ...p.posix.split(path)]),
          ),
          id = Uri.file(absolute).toString();
      return <String, Object?>{
        'id': id,
        'text': text,
        'generation': 0,
        'hasBom': hasBom,
        'identity': contentIdentity(result.stdout),
      };
    }

    configuration = await read(
      projectPrefix.isEmpty ? 'busyapi.yaml' : '$projectPrefix/busyapi.yaml',
      manifest: true,
    );
    final mappings = <String, String>{};
    if (configuration != null) {
      final Object? parsed;
      try {
        parsed = loadYaml(configuration['text'] as String);
      } on Object {
        throw GitFailure(
          'manifest.syntax',
          'Historical project configuration has invalid YAML syntax',
        );
      }
      if (parsed is! YamlMap || parsed['version'] != 1)
        throw GitFailure(
          'manifest.version',
          'Historical project configuration is invalid',
        );
      final raw = parsed['resourceMappings'];
      if (raw != null) {
        if (raw is! YamlMap ||
            raw.length > 256 ||
            raw.entries.any(
              (entry) => entry.key is! String || entry.value is! String,
            ))
          throw GitFailure(
            'resource.configuration',
            'Historical resource mappings must be bounded string mappings',
          );
        final keys = raw.keys.cast<String>().toList();
        final normalized = await engine.request('normalizeResourceUris', {
          'base': configuration['id'],
          'values': keys,
        });
        if (normalized['version'] != 1 ||
            normalized['uris'] is! List ||
            (normalized['uris'] as List).length != keys.length)
          throw GitFailure(
            'git.protocol',
            'Invalid historical resource identity projection',
          );
        for (var i = 0; i < keys.length; i++) {
          final path = p.normalize(p.join(boundary, raw[keys[i]] as String));
          if (!p.isWithin(boundary, path))
            throw GitFailure(
              'resource.unavailable',
              'Historical mapping needs an attributable resource inside the selected tree',
            );
          final identity = (normalized['uris'] as List)[i] as String;
          final id = Uri.file(path).toString();
          if (mappings.containsKey(identity) && mappings[identity] != id ||
              mappings.entries.any((e) => e.value == id && e.key != identity))
            throw GitFailure(
              'resource.collision',
              'Historical resource mappings are ambiguous',
            );
          mappings[identity] = id;
        }
      }
    }
    final rootId = Uri.file(
      p.normalize(p.joinAll([info.root, ...p.posix.split(wantedRoot)])),
    ).toString();
    final root = await read(wantedRoot);
    if (root == null)
      throw GitFailure(
        'git.historical.root',
        'The selected root does not exist in the historical tree',
      );
    resources[rootId] = {
      ...root,
      'aliases': mappings.entries
          .where((entry) => entry.value == rootId)
          .map((entry) => entry.key)
          .toList(),
    };
    final unavailable = <String>{};
    late AnalysisSnapshot snapshot;
    late Map<String, dynamic> analysis;
    for (var depth = 0; ; depth++) {
      cancellation?.throwIfCancelled();
      snapshot = AnalysisSnapshot(
        root: rootId,
        resources: resources.values.toList(),
        configuration: [if (configuration != null) configuration],
        engineIdentity: engine.assetIdentity,
        boundaries: [boundary],
      );
      analysis = await engine.request('analyse', snapshot.toJson());
      if (analysis['snapshot'] != snapshot.identity)
        throw GitFailure(
          'git.protocol',
          'Historical analysis returned an unrelated snapshot',
        );
      final missing = <String>{
        for (final ref in analysis['references'] as List? ?? [])
          if (ref['targetResource'] is String &&
              !resources.containsKey(
                mappings[ref['targetResource']] ?? ref['targetResource'],
              ) &&
              !unavailable.contains(ref['targetResource']))
            ref['targetResource'] as String,
      };
      if (missing.isEmpty) break;
      if (depth >= 128 || resources.length + missing.length > 2048)
        throw GitFailure(
          'limit.git.resources',
          'Historical contract graph exceeds its resource/depth budget',
        );
      for (final target in missing) {
        final id = mappings[target] ?? target;
        final uri = Uri.tryParse(id);
        if (uri == null || uri.scheme != 'file') {
          unavailable.add(target);
          continue;
        }
        final path = uri.toFilePath();
        if (!p.isWithin(boundary, path)) {
          unavailable.add(target);
          continue;
        }
        final source = await read(
          p.posix.joinAll(p.split(p.relative(path, from: info.root))),
        );
        if (source == null) {
          unavailable.add(target);
          continue;
        }
        final aliases = mappings.entries
            .where((e) => e.value == id)
            .map((e) => e.key)
            .toList();
        resources[id] = {...source, if (aliases.isNotEmpty) 'aliases': aliases};
      }
    }
    return GitHistoricalSnapshot(
      commit: commit,
      snapshot: snapshot,
      analysis: Map.unmodifiable(analysis),
      projectBoundary: boundary,
      rootPath: rootRelative,
    );
  }

  void _requireTrust() {
    if (!_trusted)
      throw GitFailure(
        'git.trust',
        'Trust this repository before an operation that can use hooks, helpers or remotes',
      );
  }

  String _path(String relative) {
    if (relative.isEmpty ||
        p.isAbsolute(relative) ||
        relative.contains('\u0000'))
      throw GitFailure('git.path', 'Choose a repository-relative path');
    final value = p.normalize(p.join(info.root, relative));
    if (value != info.root && !p.isWithin(info.root, value))
      throw GitFailure('git.path', 'Path leaves the repository');
    return value;
  }

  static void _branch(String value) {
    if (value.isEmpty ||
        value.length > 1024 ||
        value.startsWith('-') ||
        value.contains('\u0000') ||
        value.contains('..'))
      throw GitFailure('git.branch', 'Choose a bounded branch name');
  }

  static void _remote(String value) {
    if (value.isEmpty ||
        value.length > 1024 ||
        value.startsWith('-') ||
        value.contains('\u0000'))
      throw GitFailure('git.remote', 'Choose a configured remote name');
  }

  Future<_GitResult> _command(
    List<String> arguments, {
    bool readOnly = false,
    bool interactive = false,
    bool allowFailure = false,
    RunCancellation? cancellation,
    String? indexFile,
    String? objectDirectory,
    Uint8List? input,
  }) => _runStatic(
    executable,
    info.root,
    arguments,
    readOnly: readOnly,
    interactive: interactive,
    allowFailure: allowFailure,
    cancellation: cancellation,
    indexFile: indexFile,
    objectDirectory: objectDirectory,
    input: input,
  );
  static Future<_GitResult> _required(
    String executable,
    String directory,
    List<String> args, {
    required bool readOnly,
    RunCancellation? cancellation,
  }) => _runStatic(
    executable,
    directory,
    args,
    readOnly: readOnly,
    cancellation: cancellation,
  );

  static Future<_GitResult> _runStatic(
    String executable,
    String directory,
    List<String> arguments, {
    bool readOnly = false,
    bool interactive = false,
    bool allowFailure = false,
    RunCancellation? cancellation,
    bool isolatedConfiguration = false,
    String? indexFile,
    String? objectDirectory,
    Uint8List? input,
  }) async {
    cancellation?.throwIfCancelled();
    final prefix = <String>[
      if (readOnly) ...[
        '--no-optional-locks',
        '-c',
        'core.fsmonitor=false',
        '-c',
        'core.untrackedCache=false',
      ],
    ];
    final snap = Platform.environment['SNAP'],
        setsid = snap != null && File('$snap/usr/bin/setsid').existsSync()
            ? '$snap/usr/bin/setsid'
            : '/usr/bin/setsid';
    final grouped = Platform.isLinux && File(setsid).existsSync();
    final environment = <String, String>{
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('GIT_') &&
            (!isolatedConfiguration ||
                const {'HOME', 'SSH_AUTH_SOCK'}.contains(entry.key) ||
                snap != null &&
                    const {
                      'LD_LIBRARY_PATH',
                      'SSL_CERT_FILE',
                      'SSL_CERT_DIR',
                    }.contains(entry.key)))
          entry.key: entry.value,
      if (isolatedConfiguration)
        'PATH': snap == null ? '/usr/bin:/bin' : '$snap/usr/bin:/usr/bin:/bin',
      'GIT_PAGER': 'cat',
      'LC_ALL': 'C.UTF-8',
      if (indexFile != null) 'GIT_INDEX_FILE': indexFile,
      if (objectDirectory != null) 'GIT_OBJECT_DIRECTORY': objectDirectory,
      if (!interactive) 'GIT_TERMINAL_PROMPT': '0',
      if (isolatedConfiguration) ...{
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
      },
      if (snap != null) ...{
        'GIT_EXEC_PATH': '$snap/usr/lib/git-core',
        'GIT_TEMPLATE_DIR': '$snap/usr/share/git-core/templates',
        'GIT_SSH': '$snap/usr/bin/ssh',
      },
    };
    final process = await Process.start(
      grouped ? setsid : executable,
      grouped
          ? ['--wait', '--', executable, ...prefix, ...arguments]
          : [...prefix, ...arguments],
      workingDirectory: directory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    final output = BytesBuilder(copy: false),
        errors = BytesBuilder(copy: false);
    var total = 0, limited = false;
    Future<void> collect(
      Stream<List<int>> stream,
      BytesBuilder destination,
    ) async {
      await for (final chunk in stream) {
        if (limited) continue;
        final remaining = gitOutputLimitBytes - total;
        if (chunk.length > remaining) {
          if (remaining > 0) destination.add(chunk.sublist(0, remaining));
          limited = true;
          _terminate(process, grouped);
          continue;
        }
        destination.add(chunk);
        total += chunk.length;
      }
    }

    final out = collect(process.stdout, output),
        err = collect(process.stderr, errors);
    if (input != null) process.stdin.add(input);
    await process.stdin.close();
    final cancelled = cancellation?.whenCancelled.then((_) {
      _terminate(process, grouped);
      return -1;
    });
    final code =
        await Future.any<int>([
          process.exitCode,
          if (cancelled != null) cancelled,
        ]).timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            _terminate(process, grouped);
            return -2;
          },
        );
    await Future.wait([out, err]);
    if (cancellation?.cancelled == true)
      throw GitFailure('cancelled', 'Git operation was cancelled');
    if (code == -2)
      throw GitFailure(
        'git.timeout',
        'Git command exceeded two minutes',
        command: arguments.first,
      );
    if (limited)
      throw GitFailure(
        'git.output.limit',
        'Git output exceeded 32 MiB',
        command: arguments.first,
      );
    final result = _GitResult(code, output.takeBytes(), errors.takeBytes());
    if (code != 0 && !allowFailure)
      throw GitFailure(
        'git.command',
        'Git ${arguments.first} failed: ${_boundedError(result.err)}',
        command: arguments.first,
        exitCode: code,
      );
    return result;
  }

  static void _terminate(Process process, bool group) {
    if (group) {
      Process.killPid(-process.pid, ProcessSignal.sigterm);
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        () => Process.killPid(-process.pid, ProcessSignal.sigkill),
      );
    } else {
      process.kill(ProcessSignal.sigterm);
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        () => process.kill(ProcessSignal.sigkill),
      );
    }
  }

  static String _boundedError(String value) {
    final clean = value
        .replaceAllMapped(
          RegExp(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@'),
          (match) => '${match.group(1)}[redacted]@',
        )
        .replaceAll(
          RegExp(
            r'(authorization:|password|token|secret)[^\r\n]*',
            caseSensitive: false,
          ),
          '[redacted]',
        )
        .trim();
    return clean.length <= 2000 ? clean : '${clean.substring(0, 2000)}…';
  }
}

class GitHistoricalSnapshot {
  const GitHistoricalSnapshot({
    required this.commit,
    required this.snapshot,
    required this.analysis,
    required this.projectBoundary,
    required this.rootPath,
  });
  final String commit, projectBoundary, rootPath;
  final AnalysisSnapshot snapshot;
  final Map<String, dynamic> analysis;
}
