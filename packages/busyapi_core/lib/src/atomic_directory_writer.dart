import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'atomic_file_writer.dart';
import 'linux_atomic_file_api.dart';
import 'model.dart';
import 'storage.dart';
import 'publication_staging.dart';

Future<List<int>> _encodeOutputReceipt(
  Map<String, String> files,
  Map<String, Object?> metadata,
  Set<String> executableFiles,
  Set<String> emptyDirectories,
) => Isolate.run(
  () => utf8.encode(
    jsonEncode({
          'version': 1,
          'owner': 'io.busystack.busyapi',
          'files': files,
          'metadata': metadata,
          if (executableFiles.isNotEmpty)
            'executableFiles': executableFiles.toList()..sort(),
          if (emptyDirectories.isNotEmpty)
            'emptyDirectories': emptyDirectories.toList()..sort(),
        }) +
        '\n',
  ),
);

Future<Object?> _decodeOutputReceipt(List<int> bytes) => bytes.length < 65536
    ? Future.value(jsonDecode(utf8.decode(bytes)))
    : Isolate.run(() => jsonDecode(utf8.decode(bytes)));

/// Output directories have an explicit, bounded ownership receipt. Source and
/// ruleset directories are never replacement candidates merely by selection.
class OutputDirectoryReceipt {
  OutputDirectoryReceipt(this.identity, this.files, this.metadata);
  final String identity;
  final Map<String, String> files;
  final Map<String, dynamic> metadata;
}

class OutputDirectoryResult {
  const OutputDirectoryResult({this.previous});
  final String? previous;
}

class OutputDirectoryChanged implements Exception {
  OutputDirectoryChanged(
    this.path, {
    this.published = false,
    this.recoveryPath,
  });
  final String path;
  final bool published;
  final String? recoveryPath;
  @override
  String toString() =>
      'Output ownership changed at "$path"; no version was discarded.'
      '${recoveryPath == null ? '' : ' A preserved version is available at "$recoveryPath".'}';
}

/// The same anchored, no-replace / exchange boundary as source publication.
/// A replacement retains its displaced output; it never recursively deletes
/// a selected directory. Only an unpublished, self-created stage is cleaned.
class AtomicDirectoryWriter {
  static const receiptName = 'busyapi-output.json';
  static const maxFiles = 4096, maxBytes = 256 * 1024 * 1024;

  static bool safeName(String name) =>
      name.isNotEmpty &&
      !p.isAbsolute(name) &&
      name.length <= 4096 &&
      !name.contains('\\') &&
      !name.contains('\u0000') &&
      !name
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..');

  static Future<OutputDirectoryReceipt> inspect(String path) async {
    final api = LinuxAtomicFileApi.instance, fd = api.openDirectory(path);
    ProjectAccess? access;
    try {
      final held = Directory('/proc/self/fd/$fd');
      final canonical = await held.resolveSymbolicLinks();
      access = await ProjectAccess.open(held.path);
      final bytes = await access.read(p.join(canonical, receiptName));
      if (bytes.length > 4 * 1024 * 1024) throw const FormatException();
      final receipt = await _decodeOutputReceipt(bytes);
      if (receipt is! Map ||
          receipt['version'] != 1 ||
          receipt['owner'] != 'io.busystack.busyapi' ||
          receipt['files'] is! Map ||
          (receipt['files'] as Map).length > maxFiles ||
          receipt['metadata'] is! Map)
        throw const FormatException();
      final files = <String, String>{}, directories = <String>{};
      for (final entry in (receipt['files'] as Map).entries) {
        final Object? name = entry.key, identity = entry.value;
        if (name is! String ||
            !safeName(name) ||
            name == receiptName ||
            identity is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(identity))
          throw const FormatException();
        files[name] = identity;
        var parent = p.posix.dirname(name);
        while (parent != '.') {
          directories.add(parent);
          parent = p.posix.dirname(parent);
        }
      }
      final emptyDirectories = receipt['emptyDirectories'] ?? const [];
      if (emptyDirectories is! List ||
          emptyDirectories.length + files.length > maxFiles ||
          emptyDirectories.toSet().length != emptyDirectories.length ||
          emptyDirectories.any(
            (name) =>
                name is! String ||
                !safeName(name) ||
                name == receiptName ||
                files.keys.any(
                  (file) => file == name || file.startsWith('$name/'),
                ) ||
                emptyDirectories.any(
                  (other) => other is String && other.startsWith('$name/'),
                ),
          ))
        throw const FormatException();
      for (final name in emptyDirectories.cast<String>()) {
        var at = name;
        while (at != '.') {
          directories.add(at);
          at = p.posix.dirname(at);
        }
      }
      final executableFiles = receipt['executableFiles'] ?? const [];
      if (executableFiles is! List ||
          executableFiles.length > files.length ||
          executableFiles.toSet().length != executableFiles.length ||
          executableFiles.any(
            (name) => name is! String || !files.containsKey(name),
          ))
        throw const FormatException();
      var count = 0, size = 0;
      final found = <String>{}, foundDirectories = <String>{};
      await for (final entity in held.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++count > maxFiles * 129) throw const FormatException();
        final name = p.relative(entity.path, from: held.path);
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          if (!directories.contains(name)) throw const FormatException();
          foundDirectories.add(name);
        } else if (type == FileSystemEntityType.file) {
          if (name == receiptName) continue;
          if (!files.containsKey(name)) throw const FormatException();
          if (executableFiles.contains(name) &&
              await access.mode(
                    p.join(canonical, name),
                    maxBytes: 128 * 1024 * 1024,
                  ) !=
                  493)
            throw const FormatException();
          final contents = executableFiles.contains(name)
              ? await access.readVerifiedArtifact(
                  p.join(canonical, name),
                  files[name]!,
                )
              : await access.read(p.join(canonical, name));
          size += contents.length;
          if (size > maxBytes ||
              !executableFiles.contains(name) &&
                  await contentIdentityAsync(contents) != files[name])
            throw const FormatException();
          found.add(name);
        } else {
          throw const FormatException();
        }
      }
      if (found.length != files.length) throw const FormatException();
      if (!foundDirectories.containsAll(emptyDirectories.cast<String>()))
        throw const FormatException();
      return OutputDirectoryReceipt(
        await contentIdentityAsync(bytes),
        Map.unmodifiable(files),
        Map.unmodifiable(Map<String, dynamic>.from(receipt['metadata'] as Map)),
      );
    } on Object {
      throw CoreFailure(
        'output.ownership',
        'The directory is not an unchanged BusyAPI-owned output',
      );
    } finally {
      access?.close();
      api.closeDirectory(fd);
    }
  }

  Future<OutputDirectoryResult> publish(
    String target,
    Map<String, List<int>> files,
    Map<String, Object?> metadata, {
    String? replaceIdentity,
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
    FutureOr<void> Function()? verifyParent,
    bool Function()? cancelled,
    Set<String> executableFiles = const {},
    Set<String> emptyDirectories = const {},
  }) async {
    emptyDirectories = Set.unmodifiable(emptyDirectories);
    if (files.isEmpty ||
        files.length > maxFiles ||
        files.length + emptyDirectories.length > maxFiles ||
        emptyDirectories.any(
          (name) =>
              !safeName(name) ||
              name == receiptName ||
              files.keys.any(
                (file) => file == name || file.startsWith('$name/'),
              ) ||
              emptyDirectories.any((other) => other.startsWith('$name/')),
        ) ||
        files.containsKey(receiptName) ||
        files.keys.any((name) => !safeName(name)) ||
        executableFiles.any((name) => !files.containsKey(name)) ||
        files.entries.any(
          (entry) =>
              entry.value.length >
              (executableFiles.contains(entry.key) ? 128 : 16) * 1024 * 1024,
        ) ||
        files.values.fold<int>(0, (sum, bytes) => sum + bytes.length) >
            maxBytes)
      throw CoreFailure(
        'output.limit',
        'Generated output exceeds its bounded file or byte limits',
      );
    void active() {
      if (cancelled?.call() ?? false)
        throw CoreFailure('cancelled', 'Output publication was cancelled');
    }

    active();
    if (replaceIdentity != null) {
      final previous = await inspect(target);
      if (previous.metadata['operation'] == 'import')
        throw CoreFailure(
          'output.source',
          'An imported project is source, not replaceable derived output',
        );
      if (previous.identity != replaceIdentity)
        throw OutputDirectoryChanged(target);
    }
    final api = LinuxAtomicFileApi.instance;
    if (!api.isAvailable)
      throw CoreFailure(
        'output.atomic',
        'Safe directory publication requires Linux renameat2',
      );
    final stage = await Directory(p.dirname(target))
        .createTemp(outputStagingPrefix);
    privatePermissions(stage.path, 448);
    final fd = api.openDirectory(stage.path),
        anchor = Directory('/proc/self/fd/$fd');
    final created = <String>[], directories = <String>{};
    var published = false;
    String? recovery;
    try {
      for (final name in emptyDirectories.toList()..sort()) {
        active();
        await Directory(p.join(anchor.path, name)).create(recursive: true);
        var at = name;
        while (at != '.') {
          directories.add(at);
          at = p.posix.dirname(at);
        }
      }
      final sorted = files.keys.toList()..sort();
      for (final name in sorted) {
        active();
        final parent = p.dirname(name);
        if (parent != '.') {
          await Directory(p.join(anchor.path, parent)).create(recursive: true);
          var at = parent;
          while (at != '.') {
            directories.add(at);
            at = p.dirname(at);
          }
        }
        final file = File(p.join(anchor.path, name));
        await file.writeAsBytes(files[name]!, flush: true);
        privatePermissions(
          file.path,
          executableFiles.contains(name) ? 493 : 420,
        );
        created.add(name);
      }
      final digests = <String, String>{};
      for (final name in sorted)
        digests[name] = await contentIdentityAsync(files[name]!);
      final receipt = await _encodeOutputReceipt(
        digests,
        metadata,
        executableFiles,
        emptyDirectories,
      );
      if (receipt.length > 4 * 1024 * 1024)
        throw CoreFailure(
          'output.limit',
          'Output provenance exceeds its bounded receipt size',
        );
      final marker = File(p.join(anchor.path, receiptName));
      await marker.writeAsBytes(receipt, flush: true);
      privatePermissions(marker.path, 420);
      created.add(receiptName);
      final parents = directories.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final parent in parents) {
        final held = api.openDirectory(p.join(anchor.path, parent));
        try {
          await api.syncDirectoryFd(held);
        } finally {
          api.closeDirectory(held);
        }
      }
      await api.syncDirectoryFd(fd);
      await beforePublish?.call();
      active();
      await verifyParent?.call();
      if (replaceIdentity == null) {
        final error = api.publishNoReplace(stage.path, target);
        if (error == LinuxAtomicFileApi.fileExistsError)
          throw AtomicFileAlreadyExistsException(target);
        if (error != null)
          throw CoreFailure(
            'output.publish',
            'The staged output directory could not be published',
          );
        published = true;
        await afterPublish?.call();
      } else {
        if ((await inspect(target)).identity != replaceIdentity)
          throw OutputDirectoryChanged(target);
        final error = api.exchange(stage.path, target);
        if (error != null) throw OutputDirectoryChanged(target);
        published = true;
        recovery = await Directory(stage.path).resolveSymbolicLinks();
        await afterPublish?.call();
        // Inspect what was actually exchanged, not the earlier path occupant.
        if ((await inspect(stage.path)).identity != replaceIdentity)
          throw OutputDirectoryChanged(
            target,
            published: true,
            recoveryPath: recovery,
          );
      }
      await verifyParent?.call();
      final current = await anchor.resolveSymbolicLinks(),
          destination = await Directory(target).resolveSymbolicLinks();
      if (current != destination ||
          (await inspect(target)).identity !=
              await contentIdentityAsync(receipt))
        throw OutputDirectoryChanged(
          target,
          published: true,
          recoveryPath: recovery,
        );
      await api.syncParent(p.dirname(target));
      return OutputDirectoryResult(previous: recovery);
    } on Object catch (error) {
      if (published && error is! OutputDirectoryChanged)
        throw OutputDirectoryChanged(
          target,
          published: true,
          recoveryPath: recovery,
        );
      rethrow;
    } finally {
      if (!published) {
        // Only names created in this held stage; no recursive deletion and no
        // cleanup of a disputed displaced directory after publication.
        for (final name in created.reversed) {
          try {
            await File(p.join(anchor.path, name)).delete();
          } on Object {}
        }
        final parents = directories.toList()
          ..sort((a, b) => b.length.compareTo(a.length));
        for (final parent in parents) {
          try {
            await Directory(p.join(anchor.path, parent)).delete();
          } on Object {}
        }
        try {
          await Directory(await anchor.resolveSymbolicLinks()).delete();
        } on Object {}
      }
      api.closeDirectory(fd);
    }
  }
}
