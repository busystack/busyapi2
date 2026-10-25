import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_file_writer.dart';
import 'model.dart';
import 'project.dart';
import 'storage.dart';
import 'publication_staging.dart';

part 'file_publication.dart';

/// Optional platform boundary for deterministic filesystem failure tests.
/// Called immediately before actual anchored publication; it cannot replace it.
typedef PublicationBoundary = Future<void> Function(String path);

class PublicationBatchResult {
  PublicationBatchResult(
    this.published,
    this.failed,
    this.notAttempted, {
    this.journal,
  });
  final List<String> published, notAttempted;
  final Map<String, String> failed;
  final String? journal;
  bool get complete => failed.isEmpty && notAttempted.isEmpty;
}

/// A frozen plan is persisted before any project file is replaced. Receipts
/// describe per-file publication, never a globally atomic filesystem operation.
class PublicationStore {
  PublicationStore(this.directory, {this.beforeCheckpoint, this.afterPublish});
  final String directory;
  final Future<void> Function()? beforeCheckpoint;
  final Future<void> Function(String id)? afterPublish;
  final String owner = '$pid-${DateTime.now().microsecondsSinceEpoch}';
  final Map<BusyProject, _FilePublication> _filePublications = {};

  Future<PublicationBatchResult> save(
    BusyProject project,
    Iterable<DocumentBuffer> buffers, {
    PublicationBoundary? beforePublish,
  }) async {
    final selected = project.publicationBuffersFor(buffers).toList();
    final groupOwners = [
      for (final group in project.store.publicationGroups)
        if (group.any(selected.contains)) group,
    ];
    final groups = [
      for (final group in groupOwners) [for (final buffer in group) buffer.id],
    ];
    final coupled = groups.isNotEmpty;
    // A virtual path/presence transaction can run while disk publication is
    // pending. The captured object owns its receipt, even after its map key moves.
    final owners = {for (final buffer in selected) buffer.id: buffer};
    if (!_filePublications.containsKey(project) &&
        selected.any((b) => b.pendingFilePublication))
      throw CoreFailure(
        'file.publication.owner',
        'Recover the owning file-operation journal before saving this pending publication',
      );
    final pending =
        _filePublications[project]?.buffers.values.toSet() ??
        <DocumentBuffer>{};
    if (selected.any(pending.contains) ||
        project.fileMoveBuffersFor(selected).any((b) => b.hasFileIntent))
      return _saveFileMoves(project, selected, beforePublish: beforePublish);
    final clean = selected.where((b) => !b.dirty).toList();
    final captured = <Map<String, Object?>>[
      for (final b in selected)
        if (b.dirty || coupled)
          {
            'id': b.id,
            'path': b.path,
            'generation': b.generation,
            'text': b.text,
            'baseline': b.baseline,
            'expected': b.diskIdentity,
            'hasBom': b.hasBom,
            'mode': b.mode,
            'identity': contentIdentity(checkedResourceBytes(b.bytes())),
            'blocked': b.externalConflict,
          },
    ];
    final plan = captured.where((entry) => owners[entry['id']]!.dirty).toList();
    final requiredIds = groups.expand((group) => group).toSet();
    final dependencies = captured
        .where((entry) => requiredIds.contains(entry['id']))
        .toList();
    final cleanFailures = <String, String>{};
    for (final b in clean) {
      if (coupled) continue;
      await project.refreshDisk(b);
      if (b.externalConflict) {
        cleanFailures[b.id] =
            'Saved source changed or is unavailable; its buffer was preserved';
      }
    }
    if (plan.isEmpty) return PublicationBatchResult([], cleanFailures, []);
    if (plan.length > 512 ||
        utf8.encode(jsonEncode(plan)).length > 128 * 1024 * 1024) {
      throw CoreFailure(
        'publication.limit',
        'Publication intent exceeds the private state budget',
      );
    }
    if (coupled) {
      // A published peer still owns the reviewed meaning of an outstanding
      // repair. Do not reload a changed clean peer and silently accept it.
      String? failure;
      for (final entry in captured) {
        try {
          final path = entry['path'] as String;
          if (entry['blocked'] == true ||
              await contentIdentityAsync(
                    await project.accessFor(path).read(path),
                  ) !=
                  entry['expected']) {
            failure = 'A required source changed; resolve its external conflict before publishing the linked transaction';
            break;
          }
        } on CoreFailure catch (error) {
          failure = '${error.code}: ${error.message}';
          break;
        } on FileSystemException {
          failure = 'A required source is unavailable; no linked source was published';
          break;
        }
      }
      if (failure != null) {
        return PublicationBatchResult([], {
          for (final entry in captured) entry['id'] as String: failure,
        }, []);
      }
    }
    final intent = {
      'version': 1,
      'owner': owner,
      'pid': pid,
      'processIdentity': processIdentity(pid),
      'project': project.location,
      'boundary': project.access.boundary,
      'planned': plan,
      if (coupled) ...{
        'publicationGroups': groups,
        'publicationDependencies': dependencies,
      },
    };
    final intentBytes = utf8.encode(jsonEncode(intent)).length;
    if (intentBytes > 128 * 1024 * 1024) {
      throw CoreFailure(
        'publication.limit',
        'Linked publication intent exceeds its recoverable state budget',
      );
    }
    await Directory(directory).create(recursive: true);
    privatePermissions(directory, 448);
    final entries = Directory(directory)
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    if (entries.length >= 64 ||
        entries.fold<int>(0, (n, f) => n + f.lengthSync()) + intentBytes >
            256 * 1024 * 1024) {
      throw CoreFailure(
        'publication.limit',
        'Unresolved publication intents must be recovered before more grouped saves',
      );
    }
    final journal = p.join(
      directory,
      '$owner-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    final published = <String>[], failed = <String, String>{...cleanFailures};
    Future<void> checkpoint() async {
      await beforeCheckpoint?.call();
      final record = {...intent, 'published': published, 'failed': failed};
      if (utf8.encode(jsonEncode(record)).length > 128 * 1024 * 1024)
        throw CoreFailure(
          'publication.limit',
          'The publication checkpoint exceeds its recoverable state budget',
        );
      await writePrivateJson(journal, record);
    }

    // Failure here leaves every project file untouched.
    await checkpoint();
    for (final entry in plan) {
      if (failed.isNotEmpty) break;
      final id = entry['id'] as String;
      try {
        if (entry['blocked'] == true) {
          throw CoreFailure(
            'save.conflict',
            'Resolve the external conflict explicitly before publishing',
          );
        }
        final path = entry['path'] as String, text = entry['text'] as String;
        final bytes = [
          if (entry['hasBom'] == true) ...[239, 187, 191],
          ...utf8.encode(text),
        ];
        await beforePublish?.call(path);
        await project
            .accessFor(path)
            .publish(
              path,
              bytes,
              expected: entry['expected'] as String,
              mode: entry['mode'] as int,
            );
        // Update the baseline to exactly what was saved, even if later input exists.
        final b = owners[id];
        if (b != null &&
            project.store.ownsFileBuffer(b) &&
            b.publishedPresent &&
            b.publishedPath == path &&
            b.diskIdentity == entry['expected']) {
          b.baseline = text;
          b.diskIdentity = entry['identity'] as String;
          project.resourceFingerprints[b.id] = b.diskIdentity;
          b.externalConflict = false;
        }
        project.store.retainPublicationGroups(groupOwners);
        published.add(id);
        await afterPublish?.call(id);
        await checkpoint();
      } on Object catch (e) {
        failed[published.contains(id) ? 'recovery' : id] = e.toString();
        final b = owners[id];
        if (b != null &&
            project.store.ownsFileBuffer(b) &&
            !published.contains(id))
          b.externalConflict = true;
        // Preserve the previous durable intent if recording the receipt fails.
        try {
          await checkpoint();
        } on Object {
          /* Initial intent remains recoverable. */
        }
        break;
      }
    }
    final notAttempted = plan
        .map((e) => e['id'] as String)
        .where((id) => !published.contains(id) && !failed.containsKey(id))
        .toList();
    if (failed.isEmpty && notAttempted.isEmpty) await File(journal).delete();
    return PublicationBatchResult(
      published,
      failed,
      notAttempted,
      journal: failed.isEmpty ? null : journal,
    );
  }

  Future<Map<String, dynamic>> _inspectSource(
    BusyProject project,
    Map<String, dynamic> entry,
  ) async {
    final text = entry['text'];
    if (entry['path'] is! String ||
        entry['id'] != Uri.file(entry['path'] as String).toString() ||
        text is! String ||
        text.length > resourceByteLimit ||
        entry['baseline'] is! String ||
        entry['expected'] is! String ||
        entry['generation'] is! int ||
        entry['mode'] is! int ||
        entry['hasBom'] is! bool ||
        entry['identity'] !=
            contentIdentity(
              checkedResourceBytes([
                if (entry['hasBom'] == true) ...[239, 187, 191],
                ...utf8.encode(text),
              ]),
            )) {
      throw const FormatException('Unsafe publication intent');
    }
    String? actual;
    try {
      actual = contentIdentity(
        await project
            .accessFor(entry['path'] as String)
            .read(entry['path'] as String),
      );
    } on Object {
      /* Missing or inaccessible is an explicit outcome. */
    }
    return {
      ...entry,
      'outcome': actual == entry['identity']
          ? 'published'
          : actual == entry['expected']
          ? 'not-published'
          : actual == null
          ? 'unavailable'
          : 'conflict',
    };
  }

  /// Startup inspection never replays writes. Current bytes identify a completed
  /// publication even when the process died before recording its receipt.
  Future<List<Map<String, dynamic>>> inspect(BusyProject project) async {
    if (!Directory(directory).existsSync()) return [];
    final results = <Map<String, dynamic>>[];
    var total = 0;
    for (final file in Directory(
      directory,
    ).listSync(followLinks: false).whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      try {
        final size = file.lengthSync();
        total += size;
        if (size > 128 * 1024 * 1024 ||
            total > 256 * 1024 * 1024 ||
            results.length >= 64) {
          break;
        }
        final record = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map,
        );
        if (![1, 2].contains(record['version']) ||
            record['boundary'] != project.access.boundary) {
          continue;
        }
        if (record['owner'] != owner &&
            processIdentity(record['pid'] as int) ==
                record['processIdentity'] &&
            record['processIdentity'] != null) {
          continue;
        }
        if (record['version'] == 2) {
          final inspected = await _inspectFileMove(project, record, file.path);
          if (inspected != null) results.add(inspected);
          continue;
        }
        if (record['owner'] != owner &&
            record['processIdentity'] == null &&
            Directory('/proc/${record['pid']}').existsSync()) {
          continue;
        }
        final outcomes = <Map<String, dynamic>>[];
        for (final raw in record['planned'] as List) {
          outcomes.add(
            await _inspectSource(
              project,
              Map<String, dynamic>.from(raw as Map),
            ),
          );
        }
        final dependencies = <String, Map<String, dynamic>>{};
        if (record['publicationGroups'] != null) {
          final values = record['publicationDependencies'];
          if (values is! List || values.length > 512)
            throw const FormatException('Invalid publication dependencies');
          for (final raw in values) {
            final entry = Map<String, dynamic>.from(raw as Map);
            final id = entry['id'] as String;
            if (dependencies.containsKey(id))
              throw const FormatException('Duplicate publication dependency');
            dependencies[id] = await _inspectSource(project, entry);
          }
        }
        final groups = decodePublicationGroups(
          record['publicationGroups'],
          dependencies.keys.toSet(),
        );
        for (final entry in outcomes) {
          for (final group in groups) {
            if (group.contains(entry['id'])) {
              final dependency = dependencies[entry['id']]!;
              if (entry.keys
                  .where((key) => key != 'outcome')
                  .any((key) => entry[key] != dependency[key]))
                throw const FormatException(
                  'Mismatched publication dependency',
                );
              entry['publicationGroup'] = group;
              entry['publicationPeers'] = [
                for (final id in group)
                  {
                    ...dependencies[id]!,
                    'sourcePath': dependencies[id]!['path'],
                  },
              ];
            }
          }
        }
        results.add({...record, 'recordPath': file.path, 'outcomes': outcomes});
      } on Object {
        /* Corrupt/unowned intent is retained; it never becomes executable. */
      }
    }
    return results;
  }

  Future<void> retire(Map<String, dynamic> record) async {
    final path = p.normalize(p.absolute(record['recordPath'] as String));
    if (p.dirname(path) != p.normalize(p.absolute(directory)) ||
        !path.endsWith('.json')) {
      throw CoreFailure(
        'publication.owner',
        'Intent is outside the private publication store',
      );
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  /// Explicit recovery restores an owned buffer, never publishes project files.
  Future<void> recover(BusyProject project, Map<String, dynamic> entry) async {
    final rawGroup = entry['publicationGroup'];
    final groups = decodePublicationGroups(
      rawGroup == null ? null : [rawGroup],
      {
        if (rawGroup is List)
          for (final id in rawGroup)
            if (id is String) id,
      },
    );
    if (groups.isNotEmpty) {
      if (!groups.single.contains(entry['id']))
        throw CoreFailure(
          'recovery.groups',
          'The recovered source is outside its publication group',
        );
      final values = entry['publicationPeers'];
      if (values is! List || values.length != groups.single.length)
        throw CoreFailure(
          'recovery.groups',
          'A linked recovery requires its captured source peers',
        );
      final peers = [
        for (final value in values) Map<String, dynamic>.from(value as Map),
      ];
      if (peers.map((peer) => peer['id']).toSet().length != peers.length ||
          peers.any((peer) => !groups.single.contains(peer['id'])))
        throw CoreFailure(
          'recovery.groups',
          'Linked recovery peers do not match the captured dependency group',
        );
      if (!project.matchesRecoveredFileSnapshot(peers))
        await project.restoreFileSnapshot(peers);
      project.store.restorePublicationGroups(groups);
      return;
    }
    final b = await project.buffer(
      entry['id'] as String,
      recovery: {...entry, 'diskIdentity': entry['expected']},
    );
    project.store.retireHistory({b.id});
    String? current;
    try {
      current = contentIdentity(await project.accessFor(b.path).read(b.path));
    } on Object {
      /* Missing disk remains a conflict. */
    }
    b.update(entry['text'] as String);
    b.baseline = entry['baseline'] as String;
    b.diskIdentity = entry['expected'] as String;
    b.hasBom = entry['hasBom'] as bool;
    b.generation = b.generation > (entry['generation'] as int)
        ? b.generation
        : (entry['generation'] as int) + 1;
    b.externalConflict =
        current != entry['expected'] && current != entry['identity'];
    if (current == entry['identity']) {
      b.baseline = entry['text'] as String;
      b.diskIdentity = current!;
    }
    project.store.restorePublicationGroups(groups);
  }
}

Future<PublicationBatchResult> publishBatch(
  BusyProject project,
  List<DocumentBuffer> buffers,
  String stateDirectory,
) => PublicationStore(stateDirectory).save(project, buffers);

/// Private state replacement never truncates the sole recoverable copy.
Future<void> writePrivateJson(String path, Object value) async {
  await Directory(p.dirname(path)).create(recursive: true);
  privatePermissions(p.dirname(path), 448);
  final bytes = utf8.encode(jsonEncode(value));
  await const AtomicFileWriter().writeBytes(
    path,
    bytes,
    overwrite: File(path).existsSync(),
    prepareStaged: (f) => privatePermissions(f, 384),
  );
}
