part of 'publication.dart';

class _FilePublication {
  _FilePublication(this.journal, this.plan, this.buffers);
  final String journal;
  final List<Map<String, dynamic>> plan;
  final Map<String, DocumentBuffer> buffers;
  final Set<String> published = {}, archived = {};
}

extension FilePublication on PublicationStore {
  bool hasPendingFileMoves(BusyProject project) =>
      _filePublications.containsKey(project);

  Set<DocumentBuffer> pendingFileBuffers(BusyProject project) =>
      _filePublications[project]?.buffers.values.toSet() ?? {};

  /// Retired workspaces leave their durable journal, not a live buffer graph.
  void releaseProject(BusyProject project) {
    _filePublications.remove(project);
  }

  /// Discard abandons only unsaved intent. It never rolls back saved files.
  Future<void> abandonFileMoves(BusyProject project) async {
    final batch = _filePublications[project];
    if (batch == null) return;
    await writePrivateJson(
      p.join(directory, 'archives', p.basename(batch.journal)),
      {
        'version': 1,
        'kind': 'abandoned-file-publication',
        'boundary': project.access.boundary,
        // Retain the frozen versions too: a newer external destination may have
        // replaced the published copy before the user chose Discard.
        'planned': batch.plan,
        'files': [
          for (final e in batch.plan)
            {
              'sourcePath': e['sourcePath'],
              'path': e['path'],
              'archive': e['archive'],
              'expected': e['expected'],
              'identity': e['identity'],
              'published': batch.published.contains(e['id']),
              'archived': batch.archived.contains(e['id']),
            },
        ],
      },
    );
    await File(batch.journal).delete();
    _filePublications.remove(project);
    for (final b in batch.buffers.values) {
      b.pendingFilePublication = false;
    }
    for (final e in batch.plan.where((e) => e['archive'] != null)) {
      final source = e['sourcePath'] as String;
      if (!await project.accessFor(source).missing(source) &&
          !project.files.contains(source))
        project.files.add(source);
    }
  }

  Future<PublicationBatchResult> _saveFileMoves(
    BusyProject project,
    List<DocumentBuffer> requested, {
    PublicationBoundary? beforePublish,
  }) async {
    var batch = _filePublications[project];
    if (batch == null) {
      final selected = project
          .fileMoveBuffersFor(requested)
          .where((b) => b.dirty)
          .toList();
      if (selected.length > 512)
        throw CoreFailure(
          'publication.limit',
          'Too many files in the grouped move',
        );
      final plan = <Map<String, dynamic>>[],
          buffers = <String, DocumentBuffer>{};
      // Verify every source and destination before the first project write.
      for (final b in selected) {
        await project.refreshDisk(b);
        if (b.externalConflict)
          throw CoreFailure(
            'save.conflict',
            'A required file changed; no grouped publication started',
          );
        final sourceMode = b.publishedPresent
            ? await project.accessFor(b.publishedPath).mode(b.publishedPath)
            : b.mode;
        if (sourceMode != b.mode || sourceMode & 0x80 == 0)
          throw CoreFailure(
            'save.permissions',
            'Required file permissions changed or the source is read-only; no grouped publication started',
          );
        if ((b.hasPathIntent || !b.publishedPresent) &&
            !await project.accessFor(b.path).missing(b.path)) {
          throw CoreFailure(
            'file.move.collision',
            'The moved file destination is no longer empty',
          );
        }
        final bytes = b.present ? checkedResourceBytes(b.bytes()) : b.bytes();
        final entry = <String, dynamic>{
          'id': b.id,
          'path': b.path,
          'sourcePath': b.publishedPath,
          'sourcePresent': b.publishedPresent,
          'present': b.present,
          'generation': b.generation,
          'text': b.text,
          'baseline': b.baseline,
          'expected': b.diskIdentity,
          'hasBom': b.hasBom,
          'mode': b.mode,
          'identity': contentIdentity(bytes),
          if (b.publishedPresent && (!b.present || b.hasPathIntent))
            'archive': await project
                .accessFor(b.publishedPath)
                .prepareFileArchive(b.publishedPath),
        };
        plan.add(entry);
        buffers[b.id] = b;
      }
      if (utf8.encode(jsonEncode(plan)).length > 128 * 1024 * 1024)
        throw CoreFailure(
          'publication.limit',
          'The grouped file intent exceeds its private storage budget',
        );
      void verifyPlan() {
        if (plan.any((e) {
          final b = buffers[e['id']];
          return b == null ||
              !project.store.ownsFileBuffer(b) ||
              b.pendingFilePublication ||
              b.id != e['id'] ||
              b.path != e['path'] ||
              b.present != e['present'] ||
              b.publishedPresent != e['sourcePresent'] ||
              b.publishedPath != e['sourcePath'] ||
              b.generation != e['generation'] ||
              b.text != e['text'] ||
              b.baseline != e['baseline'] ||
              b.diskIdentity != e['expected'] ||
              b.hasBom != e['hasBom'] ||
              b.mode != e['mode'];
        })) {
          throw CoreFailure(
            'publication.stale',
            'The file group changed during publication preflight',
          );
        }
      }

      verifyPlan();
      await Directory(directory).create(recursive: true);
      privatePermissions(directory, 448);
      final existing = Directory(directory)
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (existing.length >= 64 ||
          existing.fold<int>(0, (n, f) => n + f.lengthSync()) +
                  utf8.encode(jsonEncode(plan)).length >
              256 * 1024 * 1024) {
        throw CoreFailure(
          'publication.limit',
          'Recover unresolved publication intents before another grouped move',
        );
      }
      // Directory preparation also yields to Undo/input. Pin only a plan that
      // still owns its exact participants, then keep them joined through the
      // initial checkpoint as well as physical publication.
      verifyPlan();
      batch = _FilePublication(
        p.join(
          directory,
          '$owner-${DateTime.now().microsecondsSinceEpoch}-files.json',
        ),
        plan,
        buffers,
      );
      for (final b in batch.buffers.values) {
        b.pendingFilePublication = true;
      }
      try {
        await _fileCheckpoint(project, batch, const {});
      } on Object {
        // No project bytes have changed. Release the temporary ownership while
        // retaining participants of any still-staged intent for a fresh retry.
        project.finishFilePublication(batch.buffers.values);
        rethrow;
      }
      _filePublications[project] = batch;
    }
    final outside = [
      for (final b in requested)
        if (b.dirty && !batch.buffers.values.contains(b)) b.id,
    ];
    final failures = <String, String>{};
    try {
      for (final entry in batch.plan) {
        final id = entry['id'] as String;
        if (batch.buffers[id]?.externalConflict == true)
          throw CoreFailure(
            'save.conflict',
            'The recovered file group contains an unresolved external version',
          );
        final deleted = entry['present'] == false;
        if (batch.published.contains(id) &&
            (deleted
                ? !await project
                          .accessFor(entry['sourcePath'] as String)
                          .missing(entry['sourcePath'] as String) ||
                      await _fileIdentity(
                            project,
                            entry['archive'] as String,
                          ) !=
                          entry['expected'] ||
                      await project
                              .accessFor(entry['archive'] as String)
                              .mode(entry['archive'] as String) !=
                          entry['mode']
                : await _fileIdentity(project, entry['path'] as String) !=
                          entry['identity'] ||
                      await project
                              .accessFor(entry['path'] as String)
                              .mode(entry['path'] as String) !=
                          entry['mode'])) {
          batch.buffers[id]?.externalConflict = true;
          throw CoreFailure(
            'save.conflict',
            'An already published group member changed; both versions are preserved',
          );
        }
      }
      // New destinations precede reference/manifest repairs; the old names are
      // removed only after every captured output has been published.
      final ordered = [...batch.plan]
        ..sort(
          (a, b) =>
              (a['archive'] == null && a['sourcePresent'] != false ? 1 : 0)
                  .compareTo(
                    b['archive'] == null && b['sourcePresent'] != false ? 1 : 0,
                  ),
        );
      for (final entry in ordered) {
        final id = entry['id'] as String;
        if (batch.published.contains(id)) continue;
        if (entry['present'] == false) continue;
        final path = entry['path'] as String, access = project.accessFor(path);
        // A restart/receipt-gap can recognize exact bytes, but never overwrite
        // a different destination. The initial write remains no-replace.
        await beforePublish?.call(path);
        await access.publish(
          path,
          _fileBytes(entry),
          expected: entry['archive'] != null || entry['sourcePresent'] == false
              ? null
              : entry['expected'] as String,
          mode: entry['mode'] as int,
        );
        _filePublished(project, batch, entry);
        await afterPublish?.call(id);
        await _fileCheckpoint(project, batch, failures);
      }
      for (final entry in batch.plan.where((e) => e['archive'] != null)) {
        final id = entry['id'] as String;
        if (batch.archived.contains(id)) continue;
        if (entry['present'] == false)
          await beforePublish?.call(entry['sourcePath'] as String);
        await project
            .accessFor(entry['sourcePath'] as String)
            .archiveFile(
              entry['sourcePath'] as String,
              entry['archive'] as String,
              expected: entry['expected'] as String,
              mode: entry['mode'] as int,
            );
        batch.archived.add(id);
        if (entry['present'] == false) _filePublished(project, batch, entry);
        await afterPublish?.call('archive:$id');
        await _fileCheckpoint(project, batch, failures);
      }
      await _fileCheckpoint(project, batch, failures, completed: true);
      await writePrivateJson(
        p.join(directory, 'archives', p.basename(batch.journal)),
        {
          'version': 1,
          'kind': 'source-archive-receipt',
          'boundary': project.access.boundary,
          'archives': [
            for (final e in batch.plan)
              if (e['archive'] != null)
                {
                  'sourcePath': e['sourcePath'],
                  'path': e['path'],
                  'archive': e['archive'],
                  'expected': e['expected'],
                  'identity': e['identity'],
                  'mode': e['mode'],
                  if (e['present'] == false)
                    'deletedWorkingCopy': {
                      'text': e['text'],
                      'hasBom': e['hasBom'],
                      'identity': e['identity'],
                    },
                },
          ],
        },
      );
      await File(batch.journal).delete();
      project.finishFilePublication(batch.buffers.values);
      _filePublications.remove(project);
      // Deleting a virtually moved resource removes its original disk name,
      // not a different owner's file which appeared at the never-published
      // destination. Expose that retained physical version for explicit open;
      // it must acquire a new buffer owner, never inherit the deleted buffer.
      for (final entry in batch.plan.where(
        (e) => e['present'] == false && e['path'] != e['sourcePath'],
      )) {
        final path = entry['path'] as String;
        try {
          if (!await project.accessFor(path).missing(path) &&
              !project.files.contains(path))
            project.files.add(path);
        } on Object {
          /* Listing a separate retained version is not publication. */
        }
      }
      // The small completion receipt retains the exact recoverable old-name
      // archive identity. Archives are not silently deleted or rediscovered as
      // API files. The receipt is not a globally-atomic publication claim.
    } on Object catch (error) {
      final pending = batch.plan
          .where((e) => !batch!.published.contains(e['id']))
          .map((e) => e['id'] as String)
          .firstOrNull;
      failures[pending ?? 'file-archive'] = error.toString();
      try {
        await _fileCheckpoint(project, batch, failures);
      } on Object {
        /* Keep the preceding durable intent. */
      }
    }
    return PublicationBatchResult(batch.published.toList(), failures, [
      ...outside,
      for (final e in batch.plan)
        if (!batch.published.contains(e['id']) &&
            !failures.containsKey(e['id']))
          e['id'] as String,
    ], journal: failures.isEmpty ? null : batch.journal);
  }

  List<int> _fileBytes(Map<String, dynamic> entry) => [
    if (entry['hasBom'] == true) ...[239, 187, 191],
    ...utf8.encode(entry['text'] as String),
  ];

  void _filePublished(
    BusyProject project,
    _FilePublication batch,
    Map<String, dynamic> entry,
  ) {
    final id = entry['id'] as String, b = batch.buffers[id];
    if (b != null) {
      b.publishedPath =
          entry[entry['present'] == false ? 'sourcePath' : 'path'] as String;
      b.publishedPresent = entry['present'] != false;
      b.baseline = entry['text'] as String;
      b.diskIdentity = b.publishedPresent ? entry['identity'] as String : '';
      b.externalConflict = false;
      project.resourceFingerprints[b.id] = b.publishedPresent
          ? b.diskIdentity
          : null;
    }
    batch.published.add(id);
  }

  Future<void> _fileCheckpoint(
    BusyProject project,
    _FilePublication batch,
    Map<String, String> failures, {
    bool completed = false,
  }) async {
    await beforeCheckpoint?.call();
    await writePrivateJson(batch.journal, {
      'version': 2,
      'kind': 'file-operations',
      'owner': owner,
      'pid': pid,
      'processIdentity': processIdentity(pid),
      'project': project.location,
      'boundary': project.access.boundary,
      'planned': batch.plan,
      'published': batch.published.toList(),
      'archived': batch.archived.toList(),
      'failed': failures,
      'completed': completed,
    });
  }

  Future<String?> _fileIdentity(BusyProject project, String path) async {
    try {
      return await contentIdentityAsync(
        await project.accessFor(path).read(path),
      );
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _inspectFileMove(
    BusyProject project,
    Map<String, dynamic> record,
    String recordPath,
  ) async {
    if (record['kind'] != 'file-operations' ||
        record['planned'] is! List ||
        (record['planned'] as List).isEmpty ||
        (record['planned'] as List).length > 512)
      throw const FormatException('Invalid file intent');
    final outcomes = <Map<String, dynamic>>[];
    for (final raw in record['planned'] as List) {
      final e = Map<String, dynamic>.from(raw as Map),
          path = e['path'] as String,
          source = e['sourcePath'] as String;
      if (e['id'] != Uri.file(path).toString() ||
          e.containsKey('present') && e['present'] is! bool ||
          e.containsKey('sourcePresent') && e['sourcePresent'] is! bool ||
          e['text'] is! String ||
          e['baseline'] is! String ||
          (e['text'] as String).length > 16 * 1024 * 1024 ||
          e['mode'] is! int ||
          contentIdentity(_fileBytes(e)) != e['identity'])
        throw const FormatException('Unsafe file intent');
      project.accessFor(path).pathFor(path);
      project.accessFor(source).pathFor(source);
      final archive = e['archive'];
      if (archive != null &&
          (archive is! String ||
              p.dirname(p.dirname(archive)) != p.dirname(source) ||
              !isFileArchiveDirectoryName(p.basename(p.dirname(archive))) ||
              p.basename(archive) != 'source'))
        throw const FormatException('Unsafe source archive');
      final actual = await _fileIdentity(project, path),
          original = await _fileIdentity(project, source),
          archived = archive is String
              ? await _fileIdentity(project, archive)
              : null;
      e['outcome'] = e['present'] == false
          ? original == null && archived == e['expected']
                ? 'published'
                : original == e['expected'] && archived == null
                ? 'not-published'
                : 'conflict'
          : actual == e['identity']
          ? 'published'
          : e['sourcePresent'] == false &&
                await project.accessFor(path).missing(path)
          ? 'not-published'
          : actual == e['expected'] && archive == null
          ? 'not-published'
          : actual == null
          ? 'unavailable'
          : 'conflict';
      e['sourceOutcome'] = archive == null
          ? 'unchanged-path'
          : archived == e['expected'] && original == null
          ? 'archived'
          : original == e['expected'] && archived == null
          ? 'not-archived'
          : 'conflict';
      outcomes.add(e);
    }
    return {...record, 'recordPath': recordPath, 'outcomes': outcomes};
  }

  /// Recover the entire captured operation into virtual buffers. It never
  /// executes a path intent or writes a project file. Every newer disk version
  /// remains where inspection found it; conflicting groups cannot resume Save.
  Future<void> recoverFileMoves(
    BusyProject project,
    Map<String, dynamic> record,
  ) async {
    final path = p.normalize(p.absolute(record['recordPath'] as String));
    if (p.dirname(path) != p.normalize(p.absolute(directory)) ||
        !path.endsWith('.json'))
      throw CoreFailure(
        'publication.owner',
        'File intent is outside the private publication store',
      );
    final current = await _inspectFileMove(project, record, path);
    if (current == null) return;
    final entries = (current['outcomes'] as List).cast<Map<String, dynamic>>();
    final restored = await project.restoreFileSnapshot(entries);
    final batch = _FilePublication(path, [
      for (final e in entries)
        Map<String, dynamic>.from(e)
          ..remove('outcome')
          ..remove('sourceOutcome'),
    ], restored);
    for (final e in entries) {
      if (e['outcome'] == 'published') batch.published.add(e['id'] as String);
      if (e['sourceOutcome'] == 'archived')
        batch.archived.add(e['id'] as String);
    }
    _filePublications[project] = batch;
    for (final b in batch.buffers.values) {
      b.pendingFilePublication = true;
    }
  }
}
