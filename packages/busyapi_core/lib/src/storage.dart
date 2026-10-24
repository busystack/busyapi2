import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'atomic_file_writer.dart';
import 'atomic_directory_writer.dart';
import 'model.dart';
import 'linux_atomic_file_api.dart';
import 'publication_staging.dart';

const resourceByteLimit = 16 * 1024 * 1024;

List<int> checkedResourceBytes(List<int> bytes) {
  if (bytes.length > resourceByteLimit) {
    throw CoreFailure('limit.bytes', 'Resource exceeds its bounded byte limit');
  }
  return bytes;
}

/// The disputed original remains in its owned adjacent archive. Never move it
/// back speculatively: another writer may already own the original filename.
class FileArchiveChanged extends CoreFailure {
  FileArchiveChanged(this.archivePath, String code, String message)
    : super(code, message);
  final String archivePath;
}

final _libc = DynamicLibrary.open('libc.so.6');
final _openat = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32),
      int Function(int, Pointer<Utf8>, int)
    >('openat');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__errno_location',
    );
final _chmod = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');
Future<List<int>> _readBounded(
  File file,
  int initialLength, {
  int maxBytes = resourceByteLimit,
}) async {
  final input = await file.open();
  try {
    final bytes = BytesBuilder(copy: false);
    while (true) {
      // Avoid hundreds of native-isolate wakeups for large documents without
      // allocating MiB buffers for tiny fragments. Probe past the initial size;
      // a growing file is still read to EOF and checked against the byte bound.
      final remaining = initialLength - bytes.length;
      final count = remaining >= 1024 * 1024 || remaining < 0
          ? 1024 * 1024
          : remaining + 1;
      final chunk = await input.read(count);
      if (chunk.isEmpty) return bytes.takeBytes();
      bytes.add(chunk);
      if (bytes.length > maxBytes) {
        throw CoreFailure(
          'limit.bytes',
          'Resource exceeds its bounded byte limit',
        );
      }
    }
  } finally {
    await input.close();
  }
}

void privatePermissions(String path, int mode) {
  final ptr = path.toNativeUtf8();
  try {
    if (_chmod(ptr, mode) != 0) {
      throw CoreFailure(
        'storage.permissions',
        'Cannot set private state permissions',
      );
    }
  } finally {
    malloc.free(ptr);
  }
}

/// Captured filesystem facts. This value itself grants no access capability.
class ResourceMetadata {
  const ResourceMetadata(
    this.kind, {
    this.size,
    this.mode,
    this.modified,
    this.changed,
  });
  final String kind;
  final int? size, mode, modified, changed;
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (size != null) 'size': size,
    if (mode != null) 'mode': mode,
    if (modified != null) 'modified': modified,
    if (changed != null) 'changed': changed,
  };
  String get identity => textIdentity(jsonEncode(toJson()));
}

/// Each parent is opened relative to its held directory fd with O_NOFOLLOW.
/// Reads and publication use /proc/self/fd anchors, surviving path replacement.
class ProjectAccess {
  ProjectAccess._(this.boundary, this._fd);
  final String boundary;
  final int _fd;
  bool _closed = false;
  static Future<ProjectAccess> open(String directory) async {
    final canonical = await Directory(directory).resolveSymbolicLinks();
    final ptr = canonical.toNativeUtf8();
    try {
      final fd = _openat(-100, ptr, 0x10000 | 0x20000 | 0x80000);
      if (fd < 0) {
        throw CoreFailure('access.boundary', 'Cannot open project directory');
      }
      return ProjectAccess._(canonical, fd);
    } finally {
      malloc.free(ptr);
    }
  }

  String pathFor(String input) {
    final path = p.normalize(p.absolute(input));
    if (path != boundary && !p.isWithin(boundary, path)) {
      throw CoreFailure(
        'access.outside',
        'Resource is outside the approved project boundary',
      );
    }
    return path;
  }

  /// Names only, from an anchored directory. Import still reads each regular
  /// file through this capability; a renamed directory cannot redirect IO.
  Future<List<(String, FileSystemEntityType)>> importEntries(String path) =>
      _anchored(path, (target) async {
        final api = LinuxAtomicFileApi.instance, fd = api.openDirectory(target);
        try {
          final entries = <(String, FileSystemEntityType)>[];
          await for (final entry in Directory(
            '/proc/self/fd/$fd',
          ).list(followLinks: false)) {
            if (entries.length >= 4096)
              throw CoreFailure(
                'limit.import',
                'Import directory has too many entries',
              );
            entries.add((
              p.basename(entry.path),
              await FileSystemEntity.type(entry.path, followLinks: false),
            ));
          }
          await _stableParent(target, path == boundary ? '$path/.' : path);
          return entries;
        } finally {
          api.closeDirectory(fd);
        }
      });

  Future<T> _anchored<T>(
    String path,
    Future<T> Function(String) action, {
    Future<T> Function()? missingParent,
  }) async {
    path = pathFor(path);
    final parts = p.split(p.relative(path, from: boundary));
    if (_closed) {
      throw CoreFailure('access.closed', 'Project resource access is closed');
    }
    final dot = '.'.toNativeUtf8();
    late int parent;
    try {
      parent = _openat(_fd, dot, 0x10000 | 0x20000 | 0x80000);
    } finally {
      malloc.free(dot);
    }
    if (parent < 0) {
      throw CoreFailure(
        'access.closed',
        'Cannot retain project access for this operation',
      );
    }
    final owned = <int>[parent];
    var observedParent = boundary;
    try {
      for (final part in parts.take(parts.length - 1)) {
        final ptr = part.toNativeUtf8();
        try {
          final fd = _openat(parent, ptr, 0x10000 | 0x20000 | 0x80000);
          if (fd < 0) {
            final number = _errnoLocation().value;
            if (number == 2 && missingParent != null) {
              await _stableParent(
                '/proc/self/fd/$parent/$part',
                p.join(observedParent, part),
              );
              return await missingParent();
            }
            throw CoreFailure(
              'access.parent',
              'Project parent is inaccessible or a symlink',
            );
          }
          owned.add(fd);
          parent = fd;
          if (missingParent != null)
            observedParent = p.join(observedParent, part);
        } finally {
          malloc.free(ptr);
        }
      }
      final target = '/proc/self/fd/$parent/${parts.last}';
      await _stableParent(target, path == boundary ? '$path/.' : path);
      if (await FileSystemEntity.type(target, followLinks: false) ==
          FileSystemEntityType.link) {
        throw CoreFailure(
          'access.symlink',
          'Symlink resources require explicit independent access',
        );
      }
      return await action(target);
    } finally {
      for (final fd in owned.reversed) {
        _close(fd);
      }
    }
  }

  Future<void> _stableParent(String target, String original) async {
    final current = await Directory(p.dirname(target)).resolveSymbolicLinks();
    if (p.normalize(current) != p.dirname(original)) {
      throw CoreFailure(
        'access.replaced',
        'The project directory or resource parent moved or was replaced; buffers remain open',
      );
    }
  }

  Future<T> _regular<T>(
    String target,
    Future<T> Function(File, FileStat) action, {
    int maxBytes = resourceByteLimit,
  }) async {
    final ptr = target.toNativeUtf8();
    var fd = -1;
    try {
      fd = _openat(-100, ptr, 0x20000 | 0x80000 | 0x800);
      if (fd < 0) {
        throw CoreFailure(
          'access.read',
          'Cannot open regular resource without following links',
        );
      }
      final file = File('/proc/self/fd/$fd'),
          stat = await File('/proc/self/fd/$fd').stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.mode & 0xf000 != 0x8000) {
        throw CoreFailure('access.type', 'Resource is not a regular file');
      }
      if (maxBytes <= 0 ||
          maxBytes > 128 * 1024 * 1024 ||
          stat.size > maxBytes) {
        throw CoreFailure(
          'limit.bytes',
          'Resource exceeds its bounded byte limit',
        );
      }
      return await action(file, stat);
    } finally {
      malloc.free(ptr);
      if (fd >= 0) _close(fd);
    }
  }

  /// Capture the selected regular file through a held no-follow descriptor.
  /// Two bounded passes verify that the captured bytes match that descriptor;
  /// later pathname replacement cannot redirect a prepared upload.
  Future<int> captureUpload(
    String path,
    File destination, {
    required int maximumBytes,
    void Function()? checkCurrent,
  }) => _anchored(
    path,
    (target) => _regular(target, (file, initial) async {
      final output = await destination.open(mode: FileMode.write);
      var count = 0;
      final captured = <Digest>[];
      final hash = sha256.startChunkedConversion(_UploadDigestSink(captured));
      try {
        await for (final chunk in file.openRead()) {
          checkCurrent?.call();
          if (count + chunk.length > maximumBytes ||
              count + chunk.length > initial.size)
            throw CoreFailure(
              'request.file.changed',
              'The upload file grew while being captured. Select it again.',
            );
          await output.writeFrom(chunk);
          hash.add(chunk);
          count += chunk.length;
        }
        hash.close();
        if (count != initial.size)
          throw CoreFailure(
            'request.file.changed',
            'The upload file was truncated while being captured.',
          );
        final verified = <Digest>[];
        final verify = sha256.startChunkedConversion(
          _UploadDigestSink(verified),
        );
        var secondCount = 0;
        await for (final chunk in file.openRead()) {
          checkCurrent?.call();
          secondCount += chunk.length;
          if (secondCount > count)
            throw CoreFailure(
              'request.file.changed',
              'The upload file changed during capture.',
            );
          verify.add(chunk);
        }
        verify.close();
        if (secondCount != count || verified.single != captured.single)
          throw CoreFailure(
            'request.file.changed',
            'The upload file changed during capture. Select it again.',
          );
        await output.flush();
        return count;
      } finally {
        await output.close();
      }
    }, maxBytes: maximumBytes),
  );

  Future<List<int>> read(String path) => _anchored(
    path,
    (target) => _regular(target, (file, stat) => _readBounded(file, stat.size)),
  );

  /// Exact installed/output binaries are not contract input. Keep the normal
  /// 16-MiB resource bound; this separate anchored path requires a captured
  /// digest and a hard 128-MiB limit, including a file that grows during read.
  Future<List<int>> readVerifiedArtifact(String path, String identity) =>
      _anchored(
        path,
        (target) => _regular(target, (file, stat) async {
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(identity))
            throw CoreFailure(
              'access.artifact.identity',
              'Invalid artifact identity',
            );
          final bytes = await _readBounded(
            file,
            stat.size,
            maxBytes: 128 * 1024 * 1024,
          );
          if (await contentIdentityAsync(bytes) != identity)
            throw CoreFailure(
              'access.artifact.changed',
              'The captured ordinary artifact changed',
            );
          return bytes;
        }, maxBytes: 128 * 1024 * 1024),
      );
  Future<int> mode(String path, {int maxBytes = resourceByteLimit}) =>
      _anchored(
        path,
        (target) => _regular(
          target,
          (file, stat) async => stat.mode & 0x1ff,
          maxBytes: maxBytes,
        ),
      );
  Future<bool> missing(String path) => _anchored(
    path,
    (target) async =>
        await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.notFound,
  );

  /// Metadata is a read capability, not permission to follow a symlink, read
  /// content, enumerate directories or acquire a resource outside this anchor.
  /// Missing parents are a known absence only on ENOENT, never on denial.
  Future<ResourceMetadata> describe(String path) =>
      _anchored(path, (target) async {
        final ptr = target.toNativeUtf8();
        var fd = -1;
        try {
          fd = _openat(
            -100,
            ptr,
            0x200000 | 0x20000 | 0x80000,
          ); // O_PATH, NOFOLLOW, CLOEXEC
          if (fd < 0) {
            final number = _errnoLocation().value;
            if (number == 2) return const ResourceMetadata('absent');
            throw CoreFailure(
              'access.metadata',
              'Cannot inspect the approved resource metadata',
            );
          }
          final stat = await File('/proc/self/fd/$fd').stat();
          final kind = switch (stat.mode & 0xf000) {
            0x8000 => 'file',
            0x4000 => 'directory',
            0xa000 => throw CoreFailure(
              'access.symlink',
              'A metadata capability cannot follow a symlink',
            ),
            _ => throw CoreFailure(
              'access.type',
              'Unsupported resource metadata type',
            ),
          };
          return ResourceMetadata(
            kind,
            size: stat.size,
            mode: stat.mode,
            modified: stat.modified.microsecondsSinceEpoch,
            changed: stat.changed.microsecondsSinceEpoch,
          );
        } finally {
          if (fd >= 0) _close(fd);
          malloc.free(ptr);
        }
      }, missingParent: () async => const ResourceMetadata('absent'));

  /// Allocate only an empty, private adjacent archive. Its exact path can be
  /// recorded durably before a planned move removes the old source name.
  Future<String> prepareFileArchive(String path) => _anchored(path, (
    target,
  ) async {
    await _regular(target, (file, stat) async => stat.mode);
    final stage = await Directory(p.dirname(target))
        .createTemp(fileArchivePrefix);
    privatePermissions(stage.path, 448);
    await _stableParent(target, path);
    await LinuxAtomicFileApi.instance.syncParent(p.dirname(target));
    return p.join(p.dirname(pathFor(path)), p.basename(stage.path), 'source');
  });

  /// Planned old-name removal is an atomic no-replace rename, not unlink or a
  /// copy followed by deletion. Even a racing newer source is retained. This
  /// primitive is used only after the grouped publication owner checkpoints
  /// the original bytes, desired output and this preallocated archive path.
  Future<void> archiveFile(
    String path,
    String archive, {
    required String expected,
    required int mode,
    Future<void> Function()? beforeArchive,
    Future<void> Function()? afterArchive,
  }) async {
    path = pathFor(path);
    archive = pathFor(archive);
    if (p.dirname(p.dirname(archive)) != p.dirname(path) ||
        p.basename(archive) != 'source' ||
        !isFileArchiveDirectoryName(p.basename(p.dirname(archive)))) {
      throw CoreFailure(
        'file.archive.path',
        'The archive is not an owned adjacent source slot',
      );
    }
    await _anchored(
      path,
      (target) => _anchored(archive, (destination) async {
        Future<bool> matches(String candidate) => _regular(
          candidate,
          (file, stat) async =>
              stat.mode & 0x1ff == mode &&
              await contentIdentityAsync(await _readBounded(file, stat.size)) ==
                  expected,
        );
        if (!await matches(target)) {
          throw CoreFailure(
            'file.archive.stale',
            'The original source changed before its planned removal',
          );
        }
        await beforeArchive?.call();
        await _stableParent(target, path);
        await _stableParent(destination, archive);
        final result = LinuxAtomicFileApi.instance.publishNoReplace(
          target,
          destination,
          renameOnly: true,
        );
        if (result != null)
          throw CoreFailure(
            'file.archive.rename',
            'Atomic no-replace source archival failed ($result)',
          );
        await LinuxAtomicFileApi.instance.syncParent(p.dirname(destination));
        await LinuxAtomicFileApi.instance.syncParent(p.dirname(target));
        await afterArchive?.call();
        if (!await matches(destination)) {
          throw FileArchiveChanged(
            archive,
            'file.archive.changed',
            'A newer original was retained in the archive; no rollback was attempted',
          );
        }
        await _stableParent(target, path);
        await _stableParent(destination, archive);
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw FileArchiveChanged(
            archive,
            'file.archive.reappeared',
            'Another writer recreated the original filename; both versions were retained',
          );
        }
      }),
    );
  }

  Future<void> publish(
    String path,
    List<int> bytes, {
    String? expected,
    int mode = 420,
  }) => _anchored(path, (target) async {
    checkedResourceBytes(bytes);
    Future<bool> matches(String candidate) => _regular(candidate, (
      file,
      stat,
    ) async {
      final actualMode = stat.mode & 0x1ff;
      if (actualMode != mode || actualMode & 0x92 == 0) {
        throw CoreFailure(
          'save.permissions',
          'File permissions changed or the contract is read-only',
        );
      }
      return contentIdentity(await _readBounded(file, stat.size)) == expected;
    });
    if (expected != null && !await matches(target)) {
      throw CoreFailure(
        'save.conflict',
        'Disk content changed; the draft and external version are preserved',
      );
    }
    await const AtomicFileWriter().writeBytes(
      target,
      bytes,
      overwrite: expected != null,
      prepareStaged: (stage) => privatePermissions(stage, mode),
      beforePublish: () async {
        await _stableParent(target, path);
        if (expected != null && !await matches(target)) {
          throw CoreFailure(
            'save.conflict',
            'Disk content changed before publication',
          );
        }
      },
      acceptReplaced: (displaced) async {
        await _stableParent(target, path);
        return matches(displaced);
      },
    );
  });
  Future<OutputDirectoryReceipt> inspectOutput(String path) =>
      _anchored(path, AtomicDirectoryWriter.inspect);

  Future<OutputDirectoryResult> publishOutput(
    String path,
    Map<String, List<int>> files,
    Map<String, Object?> metadata, {
    String? replaceIdentity,
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
    bool Function()? cancelled,
    Set<String> executableFiles = const {},
    Set<String> emptyDirectories = const {},
  }) => _anchored(path, (target) async {
    try {
      return await AtomicDirectoryWriter().publish(
        target,
        files,
        metadata,
        replaceIdentity: replaceIdentity,
        beforePublish: beforePublish,
        afterPublish: afterPublish,
        cancelled: cancelled,
        executableFiles: executableFiles,
        emptyDirectories: emptyDirectories,
        verifyParent: () => _stableParent(target, path),
      );
    } on OutputDirectoryChanged catch (error) {
      throw OutputDirectoryChanged(
        path,
        published: error.published,
        recoveryPath: error.recoveryPath,
      );
    } on AtomicFileAlreadyExistsException {
      throw CoreFailure(
        'output.exists',
        'Output destination already exists: $path. Review its ownership receipt before explicit replacement.',
      );
    }
  });

  void close() {
    if (_closed) return;
    _closed = true;
    _close(_fd);
  }
}

class StateLocations {
  const StateLocations({
    required this.config,
    required this.state,
    required this.cache,
  });
  final String config, state, cache;
  factory StateLocations.xdg({Map<String, String>? environment}) {
    final e = environment ?? Platform.environment;
    final home = e['HOME'] ?? Directory.current.path;
    return StateLocations(
      config: p.join(
        e['XDG_CONFIG_HOME'] ?? p.join(home, '.config'),
        'busyapi',
      ),
      state: p.join(
        e['XDG_STATE_HOME'] ?? p.join(home, '.local/state'),
        'busyapi',
      ),
      cache: p.join(e['XDG_CACHE_HOME'] ?? p.join(home, '.cache'), 'busyapi'),
    );
  }
  Future<void> prepare() async {
    for (final path in [config, state, cache]) {
      await Directory(path).create(recursive: true);
      privatePermissions(path, 448);
    }
  }
}

String? processIdentity(int ownerPid) {
  try {
    final stat = File('/proc/$ownerPid/stat').readAsStringSync();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return '${File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim()}:${fields[19]}';
  } on Object {
    return null;
  }
}

Object? _freezeRecovery(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: _freezeRecovery(entry.value),
    };
  }
  if (value is List) return value.map(_freezeRecovery).toList();
  return value;
}

class RecoveryStore {
  RecoveryStore(this.directory, {this.onCheckpointPhase})
    : owner = '$pid-${DateTime.now().microsecondsSinceEpoch}';
  final String directory, owner;

  /// Optional local boundary observation for tests/development diagnostics.
  /// Labels contain no source values, paths, identities or secrets. No logging
  /// or observer is installed by the application merely by opening a project.
  final void Function(String phase)? onCheckpointPhase;
  void _phase(String phase) => onCheckpointPhase?.call(phase);
  String _path(String id) =>
      p.join(directory, '$owner-${textIdentity(id)}.json');
  final Map<String, Map<String, Object?>?> _pending = {};
  final Map<String, bool Function()> _retireGuards = {};
  final Map<String, Object> _fileGroups = {};
  final Map<String, int> _writeVersions = {};
  Future<void>? _pumping;
  Future<void> _enqueue(
    String id,
    Map<String, Object?>? payload, {
    bool Function()? retireGuard,
  }) {
    _phase('queue:enqueue');
    if (retireGuard != null && !retireGuard())
      return _pumping ?? Future.value();
    _pending[id] = payload;
    if (payload != null) _writeVersions[id] = (_writeVersions[id] ?? 0) + 1;
    _retireGuards.remove(id);
    if (payload == null) {
      final version = _writeVersions[id];
      _retireGuards[id] = () =>
          _writeVersions[id] == version && (retireGuard?.call() ?? true);
    }
    if (_pumping != null) return _pumping!;
    final completion = _drain();
    _pumping = completion;
    return completion.whenComplete(() {
      _pumping = null;
    });
  }

  Future<void> _drain() async {
    await Future<void>.delayed(Duration.zero);
    final superseded = <String>{};
    while (_pending.isNotEmpty) {
      _phase('record:start');
      final id = _pending.keys.first, payload = _pending.remove(id);
      final retireGuard = _retireGuards.remove(id);
      final destination = _path(id);
      if (payload == null) {
        _phase('retire:start');
        final f = File(destination);
        if (await f.exists() && (retireGuard?.call() ?? true)) await f.delete();
        superseded.remove(id);
        _phase('retire:end');
        continue;
      }
      _phase('directory:start');
      await Directory(directory).create(recursive: true);
      privatePermissions(directory, 448);
      _phase('directory:end');
      _phase('inventory:start');
      final existing = await Directory(directory)
          .list(followLinks: false)
          .where((f) => f is File && f.path.endsWith('.json'))
          .toList();
      if (existing.length >= 128 && !File(destination).existsSync()) {
        throw CoreFailure(
          'recovery.limit',
          'Recovery document limit reached; buffers remain in memory',
        );
      }
      var total = 0;
      for (final f in existing) {
        if (f.path != destination) total += (await f.stat()).size;
      }
      _phase('inventory:end');
      // Directory inspection may outlast several captured input updates. Do
      // not encode/flush an already superseded record merely to overwrite it
      // immediately afterwards. Skip at most one per resource before publishing
      // again: sustained input cannot indefinitely postpone recovery progress.
      // Every caller still awaits the complete coalesced drain, not an enqueue.
      if (_pending.containsKey(id) && superseded.add(id)) {
        _phase('record:superseded');
        continue;
      }
      // The queue owns a frozen record, not a live buffer. Encode only the
      // coalesced record in a worker so a keystroke never serializes megabytes.
      _phase('encode:start');
      final bytes = await Isolate.run(() => utf8.encode(jsonEncode(payload)));
      _phase('encode:end');
      if (bytes.length > 64 * 1024 * 1024 ||
          total + bytes.length > 128 * 1024 * 1024) {
        throw CoreFailure(
          'recovery.limit',
          'Recovery storage limit reached; buffers remain in memory',
        );
      }
      final stage = '$destination.tmp';
      _phase('write:start');
      await File(stage).writeAsBytes(bytes, flush: true);
      _phase('write:end');
      privatePermissions(stage, 384);
      _phase('rename:start');
      await File(stage).rename(destination);
      superseded.remove(id);
      _phase('rename:end');
    }
    _phase('drain:end');
  }

  Future<void> persist(
    DocumentBuffer b, {
    PropertySession? draft,
    FormSession? form,
  }) {
    if (b.hasPathIntent)
      throw CoreFailure(
        'recovery.group.required',
        'A staged path must be checkpointed with its complete project file operation',
      );
    if (!b.dirty && !(draft?.pending ?? false) && !(form?.pending ?? false)) {
      return retireIfCurrent(
        b.id,
        () =>
            !b.dirty && !(draft?.pending ?? false) && !(form?.pending ?? false),
      );
    }
    _phase('capture:start');
    final payload = <String, Object?>{
      'version': 1,
      'owner': owner,
      'pid': pid,
      'processIdentity': processIdentity(pid),
      'id': b.id,
      'path': b.path,
      if (b.hasPathIntent) 'publishedPath': b.publishedPath,
      'text': b.text,
      'baseline': b.baseline,
      'diskIdentity': b.diskIdentity,
      'hasBom': b.hasBom,
      'generation': b.generation,
      'draft': _freezeRecovery(draft?.recovery()),
      'form': _freezeRecovery(form?.recovery()),
    };
    _phase('capture:end');
    return _enqueue(b.id, payload);
  }

  Future<void> retire(String id) => _enqueue(id, null);
  Future<void> retireIfCurrent(String id, bool Function() current) =>
      _enqueue(id, null, retireGuard: current);
  String _filesId(String boundary) => 'file-workspace:$boundary';

  /// A path move and its required text repairs recover as one record. Retire
  /// older individual records only after the complete group is durable.
  Future<bool> persistFileMoves(
    FileRecoveryOwner project, {
    PropertySession? draft,
    FormSession? form,
  }) async {
    final id = _filesId(project.boundary);
    if (!project.store.fileBuffers.any(
      (b) => b.hasFileIntent || b.pendingFilePublication,
    )) {
      if (!_fileGroups.containsKey(id)) return false;
      final transition = Object();
      _fileGroups[id] = transition;
      bool current() =>
          identical(_fileGroups[id], transition) &&
          !project.store.fileBuffers.any(
            (b) => b.hasFileIntent || b.pendingFilePublication,
          );
      // Keep the group until every replacement record is durable. A failed
      // write or a newer transition leaves the preceding checkpoint intact.
      for (final b in project.store.fileBuffers.toList()) {
        if (!current()) return true;
        await persist(
          b,
          draft: draft?.buffer == b.id ? draft : null,
          form: form?.target.buffer == b.id ? form : null,
        );
      }
      await retireIfCurrent(id, current);
      if (current()) _fileGroups.remove(id);
      return false;
    }
    final selected = project.store.fileBuffers.where((b) => b.dirty).toList();
    final payload = <String, Object?>{
      'version': 2,
      'kind': 'file-workspace',
      'owner': owner,
      'pid': pid,
      'processIdentity': processIdentity(pid),
      'id': id,
      'path': project.location,
      'boundary': project.boundary,
      'buffers': [
        for (final b in selected)
          {
            'id': b.id,
            'path': b.path,
            'sourcePath': b.publishedPath,
            'sourcePresent': b.publishedPresent,
            'present': b.present,
            'text': b.text,
            'baseline': b.baseline,
            'expected': b.diskIdentity,
            'hasBom': b.hasBom,
            'mode': b.mode,
            'generation': b.generation,
          },
      ],
      'draft': _freezeRecovery(draft?.recovery()),
      'form': _freezeRecovery(form?.recovery()),
    };
    final transition = Object();
    _fileGroups[id] = transition;
    final captured = {
      for (final b in selected) ...[b.id, Uri.file(b.publishedPath).toString()],
    };
    final versions = {for (final key in captured) key: _writeVersions[key]};
    await _enqueue(id, payload);
    // Retirement belongs to this successful replacement, never to a failed
    // queue drain or a later retry. Preserve any newer individual checkpoint.
    await Future.wait([
      for (final key in captured)
        retireIfCurrent(
          key,
          () =>
              identical(_fileGroups[id], transition) &&
              _writeVersions[key] == versions[key],
        ),
    ]);
    return true;
  }

  Future<void> retireFileMoves(FileRecoveryOwner project) {
    final id = _filesId(project.boundary);
    _fileGroups.remove(id);
    return retire(id);
  }

  Future<void> adoptFileMoves(
    Map<String, dynamic> record,
    FileRecoveryOwner project,
  ) async {
    final path = p.normalize(p.absolute(record['recordPath'] as String));
    if (p.dirname(path) != p.normalize(p.absolute(directory)) ||
        !path.endsWith('.json') ||
        record['boundary'] != project.boundary ||
        record['version'] != 2 ||
        record['kind'] != 'file-workspace')
      throw CoreFailure(
        'recovery.record',
        'The grouped file record does not belong to this project',
      );
    final draft = record['draft'] is Map
        ? PropertySession.restore(
            Map<String, dynamic>.from(record['draft'] as Map),
          )
        : null;
    final form = record['form'] is Map
        ? FormSession.restore(Map<String, dynamic>.from(record['form'] as Map))
        : null;
    final entries = [
      for (final value in record['buffers'] as List)
        Map<String, dynamic>.from(value as Map),
    ];
    // Publication recovery may already have restored this same frozen working
    // copy. Do not overwrite or falsely conflict its owned published baselines.
    final identicalSnapshot = project.matches(entries);
    if (!identicalSnapshot) await project.restore(entries);
    if (!await persistFileMoves(project, draft: draft, form: form)) {
      for (final e in entries) {
        final b = project.store.fileBuffer(e['id'] as String);
        if (!b.present) continue;
        await persist(
          b,
          draft: draft?.buffer == b.id ? draft : null,
          form: form?.target.buffer == b.id ? form : null,
        );
      }
    }
    if (path != p.normalize(p.absolute(_path(_filesId(project.boundary)))))
      await File(path).delete();
  }

  Future<List<Map<String, dynamic>>> available() async {
    if (!await Directory(directory).exists()) return [];
    final entries = <Map<String, dynamic>>[];
    var bytes = 0;
    await for (final f in Directory(directory).list(followLinks: false)) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final stat = await f.stat();
        bytes += stat.size;
        if (stat.size > 64 * 1024 * 1024 ||
            bytes > 128 * 1024 * 1024 ||
            entries.length >= 128) {
          break;
        }
        final value =
            jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final grouped =
            value['version'] == 2 &&
            value['kind'] == 'file-workspace' &&
            value['boundary'] is String &&
            value['id'] == _filesId(value['boundary'] as String) &&
            value['buffers'] is List &&
            (value['buffers'] as List).length <= 512;
        if (!grouped &&
            (value['version'] != 1 ||
                value['id'] != Uri.file(value['path'] as String).toString())) {
          continue;
        }
        if (value['owner'] == owner) continue;
        if (value['processIdentity'] != null &&
            value['processIdentity'] == processIdentity(value['pid'] as int)) {
          continue;
        }
        if (value['processIdentity'] == null &&
            Directory('/proc/${value['pid']}').existsSync()) {
          continue;
        }
        value['recordPath'] = f.path;
        entries.add(value);
      } on Object {
        /* Keep corrupt records for manual inspection, never publish. */
      }
    }
    return entries;
  }

  Future<void> adopt(
    Map<String, dynamic> record,
    DocumentBuffer b, {
    PropertySession? draft,
    FormSession? form,
  }) async {
    final recordPath = p.normalize(p.absolute(record['recordPath'] as String));
    if (p.dirname(recordPath) != p.normalize(p.absolute(directory)) ||
        !recordPath.endsWith('.json') ||
        await FileSystemEntity.type(recordPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw CoreFailure(
        'recovery.record',
        'Recovery record is outside the owning private store',
      );
    }
    b.update(record['text'] as String);
    final recordedGeneration = record['generation'] as int? ?? 0;
    if (b.generation <= recordedGeneration) {
      b.generation = recordedGeneration + 1;
    }
    b.hasBom = record['hasBom'] as bool;
    b.externalConflict =
        b.externalConflict || b.diskIdentity != record['diskIdentity'];
    b.baseline = record['baseline'] as String;
    b.diskIdentity = record['diskIdentity'] as String;
    await persist(b, draft: draft, form: form);
    if (recordPath != p.normalize(p.absolute(_path(b.id)))) {
      await File(recordPath).delete();
    }
  }
}

class _UploadDigestSink implements Sink<Digest> {
  _UploadDigestSink(this.result);
  final List<Digest> result;
  @override
  void add(Digest value) => result.add(value);
  @override
  void close() {}
}
