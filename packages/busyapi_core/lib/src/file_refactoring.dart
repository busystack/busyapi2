part of 'project.dart';

/// Captured source plans and a virtual path transition. Applying this plan
/// changes no file on disk; Save publishes all required repairs as a group.
class FileMovePlan extends RefactoringPlan {
  FileMovePlan._(
    super.owner,
    super.revision,
    super.snapshots,
    super.data,
    this.pathEdit,
    this._policyInputs,
  ) : super._();
  final BufferPathEdit pathEdit;
  final _PolicyInputs? _policyInputs;
  @override
  bool get hasChanges =>
      super.hasChanges || pathEdit.buffer != pathEdit.destination;
}

class FileCreationPlan extends RefactoringPlan {
  FileCreationPlan._(
    super.owner,
    super.revision,
    super.snapshots,
    super.data,
    this.creation,
  ) : super._();
  final BufferCreation creation;
  @override
  bool get hasChanges => true;
}

class FileDeletionPlan extends RefactoringPlan {
  FileDeletionPlan._(
    super.owner,
    super.revision,
    super.snapshots,
    super.data,
    this.presence,
    this._policyInputs,
  ) : super._();
  final BufferPresenceEdit presence;
  final _PolicyInputs? _policyInputs;
  @override
  bool get hasChanges => true;
}

extension FileRefactoring on BusyProject {
  Future<({_PolicyInputs? inputs, String? failure})> _captureFilePolicy({
    void Function(String resource)? onResourceRefreshed,
  }) async {
    try {
      return (
        inputs: await _capturePolicyInputs(
          active: () {
            if (_closed)
              throw CoreFailure('access.closed', 'The project is closed');
          },
          onResourceRefreshed: onResourceRefreshed,
        ),
        failure: null,
      );
    } on CoreFailure catch (failure) {
      if (failure.code == 'access.closed' || failure.code.startsWith('limit.'))
        rethrow;
      return (inputs: null, failure: failure.code);
    }
  }

  Future<void> _verifyFilePolicy(_PolicyInputs? captured, int revision) async {
    if (captured == null)
      throw CoreFailure(
        'refactor.blocked',
        'The reviewed policy dependency graph is incomplete',
      );
    final current = await _capturePolicyInputs(
      active: () {
        if (_closed)
          throw CoreFailure('access.closed', 'The project is closed');
      },
    );
    if (current.identity != captured.identity || current.revision != revision) {
      throw CoreFailure(
        'refactor.stale',
        'Governance configuration changed after the file-impact review',
      );
    }
  }

  FileRecoveryOwner get recoveryOwner => FileRecoveryOwner(
    boundary: access.boundary,
    location: location,
    store: store,
    restore: restoreFileSnapshot,
    matches: matchesRecoveredFileSnapshot,
  );
  bool matchesRecoveredFileSnapshot(List<Map<String, dynamic>> entries) =>
      entries.every((e) {
        final owned = _fileRecoveries[e['id']], b = owned?.$1;
        return owned != null &&
            store.ownsFileBuffer(b!) &&
            (store.buffers[b.id] == null ||
                identical(store.buffers[b.id], b)) &&
            owned.$2 == b.generation &&
            (owned.$3 == e['expected'] && owned.$4 == e['sourcePath'] ||
                b.pendingFilePublication &&
                    b.diskIdentity == e['expected'] &&
                    b.publishedPath == e['sourcePath'] &&
                    b.publishedPresent == (e['sourcePresent'] != false) &&
                    b.baseline == e['baseline']) &&
            b.text == e['text'] &&
            b.hasBom == e['hasBom'] &&
            b.present == (e['present'] != false);
      });

  /// Restore a whole captured virtual file operation, without publishing it.
  /// Publication inspection can mark exact already-written outputs; ordinary
  /// unsaved recovery cannot infer ownership of a newly occupied destination.
  Future<Map<String, DocumentBuffer>> restoreFileSnapshot(
    List<Map<String, dynamic>> entries, {
    Future<void> Function()? beforeApply,
  }) async {
    if (_closed || entries.isEmpty || entries.length > 512)
      throw CoreFailure('recovery.files', 'Invalid grouped file snapshot');
    final restored = <String, DocumentBuffer>{},
        replaced = <DocumentBuffer>{},
        paths = <String, String>{};
    final owners = {for (final b in store.fileBuffers) b: b.generation};
    var bytes = 0;
    for (final e in entries) {
      final id = e['id'], path = e['path'], source = e['sourcePath'];
      if (id is! String ||
          path is! String ||
          source is! String ||
          Uri.file(path).toString() != id ||
          e['text'] is! String ||
          e['baseline'] is! String ||
          e['expected'] is! String ||
          e['hasBom'] is! bool ||
          e['mode'] is! int ||
          e['generation'] is! int ||
          e.containsKey('present') && e['present'] is! bool ||
          e.containsKey('sourcePresent') && e['sourcePresent'] is! bool ||
          restored.containsKey(id)) {
        throw CoreFailure(
          'recovery.files',
          'The grouped file snapshot contains unsafe identities or values',
        );
      }
      accessFor(path).pathFor(path);
      accessFor(source).pathFor(source);
      bytes += (e['text'] as String).length * 2;
      if ((e['text'] as String).length > 16 * 1024 * 1024 ||
          bytes > 256 * 1024 * 1024)
        throw CoreFailure(
          'limit.buffers',
          'The recovered source exceeds the buffer budget',
        );
      final sourceId = Uri.file(source).toString(),
          at = store.buffers[id],
          old = store.buffers[sourceId];
      if (at != null && old != null && !identical(at, old) ||
          store.fileBuffers.any(
            (b) => (b.id == id || b.id == sourceId) && b.dirty,
          ))
        throw CoreFailure(
          'recovery.pending',
          'Resolve current buffer owners before restoring the whole file operation',
        );
      final existing = at ?? old;
      if (existing != null) replaced.add(existing);
      String? actual;
      try {
        actual = await contentIdentityAsync(
          await accessFor(source).read(source),
        );
      } on Object {
        /* Explicit conflict below. */
      }
      final b = DocumentBuffer(
        id: id,
        path: path,
        text: e['text'] as String,
        baseline: e['baseline'] as String,
        diskIdentity: e['expected'] as String,
        hasBom: e['hasBom'] as bool,
        mode: e['mode'] as int,
        present: e['present'] != false,
        publishedPresent: e['sourcePresent'] != false,
        generation:
            ((e['generation'] as int) > (existing?.generation ?? 0)
                ? e['generation'] as int
                : existing!.generation) +
            1,
      );
      b.publishedPath = source;
      b.externalConflict = b.publishedPresent
          ? actual != e['expected']
          : !await accessFor(source).missing(source);
      if (source != path && !await accessFor(path).missing(path))
        b.externalConflict = true;
      if (e['outcome'] == 'published') {
        final current = b.present
            ? await contentIdentityAsync(await accessFor(path).read(path))
            : '';
        if (b.present
            ? current != e['identity']
            : !await accessFor(source).missing(source))
          throw CoreFailure(
            'recovery.stale',
            'A published output changed during recovery inspection',
          );
        b.baseline = b.text;
        b.diskIdentity = current;
        b.publishedPath = b.present ? path : source;
        b.publishedPresent = b.present;
        b.externalConflict = e['sourceOutcome'] == 'conflict';
      } else if (e['outcome'] == 'conflict' ||
          e['sourceOutcome'] == 'conflict') {
        b.externalConflict = true;
      }
      if (existing != null) {
        b.selection = existing.selection;
        b.scroll = existing.scroll;
      }
      restored[id] = b;
      paths[sourceId] = id;
    }
    if (store.fileBuffers.length - replaced.length + restored.length > 512 ||
        store.fileBuffers
                .where((b) => !replaced.contains(b))
                .fold<int>(bytes, (n, b) => n + b.text.length * 2) >
            256 * 1024 * 1024)
      throw CoreFailure(
        'limit.buffers',
        'Recovered operation exceeds the buffer budget',
      );
    await beforeApply?.call();
    // Recheck every clean owner after asynchronous disk inspection.
    if (_closed ||
        replaced.any(
          (b) =>
              b.dirty || !store.ownsFileBuffer(b) || owners[b] != b.generation,
        ) ||
        restored.keys.any(
          (id) => store.fileBuffers.any(
            (b) =>
                b.id == id && !replaced.contains(b) && (b.present || b.dirty),
          ),
        ) ||
        _loadingBuffers.keys.any(
          (id) => restored.containsKey(id) || paths.containsKey(id),
        ))
      throw CoreFailure(
        'recovery.stale',
        'A buffer changed during grouped recovery',
      );
    store.restoreFileOwners(restored.values, replacing: replaced);
    _pathsChanged(paths, restored.values.toSet());
    for (final e in entries) {
      final b = restored[e['id']]!;
      _fileRecoveries[b.id] = (
        b,
        b.generation,
        e['expected'] as String,
        e['sourcePath'] as String,
      );
    }
    for (final b in restored.values) {
      if (b.present &&
          p.isWithin(access.boundary, b.path) &&
          !files.contains(b.path))
        files.add(b.path);
    }
    return restored;
  }

  /// Discard unsaved path/text changes together; published bytes are untouched.
  List<SemanticTransition> discardFileChanges({
    Iterable<DocumentBuffer>? additionally,
  }) {
    final selected = fileMoveBuffersFor(additionally ?? store.fileBuffers)
        .where((b) => b.dirty)
        .toList();
    final paths = <BufferPathEdit>[];
    for (final b in selected.where(
      (b) => b.publishedPresent && b.path != b.publishedPath,
    )) {
      paths.add(
        BufferPathEdit(
          buffer: b.id,
          generation: b.generation,
          expectedPath: b.path,
          expectedText: b.text,
          expectedBom: b.hasBom,
          destination: Uri.file(b.publishedPath).toString(),
          path: b.publishedPath,
        ),
      );
    }
    final transitions = [
      for (final b in selected)
        if (b.present != b.publishedPresent)
          SemanticTransition(
            b.id,
            '',
            '',
            mode: b.publishedPresent ? 'restoration' : 'removal',
            destinationResource: b.publishedPresent && b.path != b.publishedPath
                ? Uri.file(b.publishedPath).toString()
                : null,
          ),
      for (final p in paths)
        if (!selected.any(
          (b) => b.id == p.buffer && b.present != b.publishedPresent,
        ))
          SemanticTransition(
            p.buffer,
            '',
            '',
            destinationResource: p.destination,
          ),
    ];
    store.apply(
      [
        for (final b in selected)
          if (b.text != b.baseline)
            TextEdit(
              buffer: b.id,
              generation: b.generation,
              start: 0,
              end: b.text.length,
              expected: b.text,
              replacement: b.baseline,
            ),
      ],
      paths: paths,
      presences: [
        for (final b in selected)
          if (b.present != b.publishedPresent)
            BufferPresenceEdit(
              buffer: b.id,
              generation: b.generation,
              expectedPath: b.path,
              expectedText: b.text,
              expectedBom: b.hasBom,
              expectedPresent: b.present,
              present: b.publishedPresent,
            ),
      ],
      label: 'Discard file changes',
      transitions: transitions,
    );
    store.retireHistory(selected.map((b) => b.id).toSet());
    return transitions;
  }

  void _verifyVirtualResource(String id) {
    if (store.fileBuffers.any(
      (b) =>
          !b.present &&
          (b.publishedPresent || b.pendingFilePublication) &&
          b.id == id,
    )) {
      throw CoreFailure(
        'file.virtual.deleted',
        'This physical filename is hidden by an unsaved file deletion',
      );
    }
    if (store.fileBuffers.any(
      (b) =>
          (b.publishedPresent || b.pendingFilePublication) &&
          b.path != b.publishedPath &&
          Uri.file(b.publishedPath).toString() == id,
    )) {
      throw CoreFailure(
        'file.virtual.moved',
        'This physical filename is hidden by an unsaved file move',
      );
    }
  }

  Set<DocumentBuffer> get fileMoveBuffers => {
    for (final b in store.fileBuffers.where(
      (b) => b.hasFileIntent || b.pendingFilePublication,
    )) ...{b, ...?_fileParticipants[b]},
  };

  /// Join only connected intents: a shared repaired buffer joins groups,
  /// while independent roots do not authorize one another's publication.
  Set<DocumentBuffer> fileMoveBuffersFor(Iterable<DocumentBuffer> selected) {
    final result = selected.toSet(),
        moves = store.fileBuffers
            .where((b) => b.hasFileIntent || b.pendingFilePublication)
            .toList();
    var changed = true;
    while (changed) {
      changed = false;
      for (final move in moves) {
        final members = {move, ...?_fileParticipants[move]};
        if (members.any(result.contains)) {
          final length = result.length;
          result.addAll(members);
          changed |= result.length != length;
        }
      }
    }
    return result;
  }

  Set<DocumentBuffer> publicationBuffersFor(Iterable<DocumentBuffer> selected) {
    var result = store.publicationBuffersFor(selected);
    while (true) {
      final next = store.publicationBuffersFor(fileMoveBuffersFor(result));
      if (next.length == result.length && next.containsAll(result)) return next;
      result = next;
    }
  }

  void finishFilePublication(Iterable<DocumentBuffer> moved) {
    for (final b in moved) {
      b.pendingFilePublication = false;
      // Input/Undo during publication can stage an inverse or later intent.
      // Its repaired buffers must remain joined after the frozen save ends.
      if (!b.hasFileIntent) _fileParticipants.remove(b);
    }
  }

  /// After partial saving, working configuration—not an imagined disk rollback—
  /// determines which physical files remain configured API roots.
  void reconcileRootConfiguration() {
    final manifest =
        store.buffers[Uri.file(p.join(access.boundary, 'busyapi.yaml'))
            .toString()];
    if (manifest == null) return;
    _adoptRootConfiguration(_parseRootConfiguration(manifest.snapshot()));
  }

  void _pathsChanged(
    Map<String, String> paths,
    Set<DocumentBuffer> participants,
  ) {
    _fileRecoveries.removeWhere((id, value) => !store.ownsFileBuffer(value.$1));
    for (final b in participants) {
      if (b.hasFileIntent || b.pendingFilePublication) {
        _fileParticipants[b] = {...?_fileParticipants[b], ...participants};
      } else {
        _fileParticipants.remove(b);
      }
    }
    String map(String id) => paths[id] ?? id;
    for (var i = 0; i < roots.length; i++) {
      final root = roots[i];
      roots[i] = ProjectRoot(root.name, map(root.id));
    }
    for (var i = 0; i < files.length; i++) {
      files[i] = Uri.parse(map(Uri.file(files[i]).toString())).toFilePath();
    }
    for (final b in participants) {
      if (!b.present) {
        files.remove(b.path);
      } else if (p.isWithin(access.boundary, b.path) &&
          !files.contains(b.path)) {
        files.add(b.path);
      }
    }
    final locationId = Uri.file(location).toString();
    if (paths.containsKey(locationId))
      location = Uri.parse(map(locationId)).toFilePath();
    void remapSets(Map<String, Set<String>> values) {
      final mapped = {
        for (final e in values.entries) map(e.key): e.value.map(map).toSet(),
      };
      values
        ..clear()
        ..addAll(mapped);
    }

    remapSets(dependencies);
    remapSets(_policyDependencies);
    final fingerprints = {
      for (final e in resourceFingerprints.entries) map(e.key): e.value,
    };
    resourceFingerprints
      ..clear()
      ..addAll(fingerprints);
    for (final key in _approvedResources.keys.toList()) {
      _approvedResources[key] = map(_approvedResources[key]!);
    }
    final config = store.buffers[_manifestResource];
    if (config != null) {
      try {
        _configureResourceMappings(config.snapshot());
      } on CoreFailure {
        // A synchronous history observer must not throw after verified buffer
        // mutation. Collection re-establishes missing canonical URI projections
        // before any consumer can analyse, publish or export this configuration.
        _configuredResources.clear();
        _resourceConfigurationText = null;
      }
    }
    _workingSnapshot = null;
    _resourceRevision++;
  }

  /// Captures a new local buffer only. No defaults, manifest, directories or
  /// project files are written; Save later uses the grouped publication owner.
  Future<FileCreationPlan> planFileCreation(
    String destination, {
    String text = '',
    bool hasBom = false,
    int mode = 420,
  }) async {
    if (_closed) throw CoreFailure('access.closed', 'The project is closed');
    final path = accessFor(destination).pathFor(destination),
        id = Uri.file(destination).toString();
    if (Uri.file(path).toString() != id ||
        !['.yaml', '.yml', '.json'].contains(p.extension(path).toLowerCase()) ||
        id == _manifestResource) {
      throw CoreFailure(
        'file.create.path',
        'Choose a YAML or JSON source file, not project configuration',
      );
    }
    if (mode < 0 || mode > 511 || text.length > 16 * 1024 * 1024) {
      throw CoreFailure(
        'file.create.value',
        'The proposed source or file permissions exceed their limits',
      );
    }
    final revision = _resourceRevision;
    final resources = <Map<String, Object?>>[];
    for (final b in store.buffers.values.toList()) {
      resources.add(await b.snapshotAsync());
    }
    final snapshot = AnalysisSnapshot(
      root: roots.first.id,
      resources: resources,
    );
    final identity = textIdentity(
      jsonEncode({
        'snapshot': snapshot.identity,
        'revision': revision,
        'destination': id,
        'text': textIdentity(text),
        'bom': hasBom,
        'mode': mode,
      }),
    );
    final plan = FileCreationPlan._(
      this,
      revision,
      [snapshot],
      {
        'version': 1,
        'snapshot': identity,
        'kind': 'file-create',
        'checkedRoots': <String>[],
        'edits': <Object?>[],
        'usages': <Object?>[],
        'blockers': <Object?>[],
        'from': {'resource': id, 'pointer': ''},
        'to': {'resource': id, 'pointer': ''},
        'changes': [
          {'resource': id, 'before': '', 'after': text, 'fileAction': 'create'},
        ],
        'transitions': [
          {'resource': id, 'from': '', 'to': '', 'mode': 'restoration'},
        ],
      },
      BufferCreation(
        id: id,
        path: path,
        text: text,
        hasBom: hasBom,
        mode: mode,
      ),
    );
    await _verifyFileCreation(plan);
    if (_closed || revision != _resourceRevision || !snapshot.current(store)) {
      throw CoreFailure(
        'refactor.stale',
        'The captured project changed while preparing the file creation',
      );
    }
    return plan;
  }

  Future<void> _verifyFileCreation(FileCreationPlan plan) async {
    final addition = plan.creation;
    if (_loadingBuffers.isNotEmpty ||
        store.buffers.containsKey(addition.id) ||
        store.fileBuffers.any((b) => b.id == addition.id && b.dirty) ||
        !await accessFor(addition.path).missing(addition.path)) {
      throw CoreFailure(
        'file.create.collision',
        'The reviewed file destination is occupied or has pending ownership',
      );
    }
  }

  /// One existing creation transaction publishes the new definition and every
  /// graph-proven repair together. Planning has no disk or intermediate-buffer
  /// side effects, and the ordinary creation guard rechecks the destination.
  Future<FileCreationPlan> planComponentExtractionToFile(
    Map<String, Object?> target,
    String name,
    String destination, {
    void Function(String resource)? onResourceRefreshed,
  }) async {
    final reservation = await planFileCreation(destination);
    final plan = await _planSemantic('planExtractToFile', target, {
      'name': name,
      'destinationResource': reservation.creation.id,
    }, onResourceRefreshed: onResourceRefreshed);
    if (reservation._revision != _resourceRevision ||
        reservation._snapshots.any((snapshot) => !snapshot.current(store))) {
      throw CoreFailure(
        'refactor.stale',
        'The source or file destination changed during extraction planning',
      );
    }
    final creations = plan.result['creations'];
    if (plan.result['kind'] != 'component-extract-file' ||
        creations is! List ||
        creations.length != 1) {
      throw CoreFailure(
        'refactor.protocol',
        'The worker did not return one captured definition creation',
      );
    }
    final created = creations.single;
    if (created is! Map ||
        created['resource'] != reservation.creation.id ||
        created['text'] is! String ||
        (created['text'] as String).length > 16 * 1024 * 1024 ||
        created['identity'] !=
            await textIdentityAsync(created['text'] as String) ||
        plan.edits.any((edit) => edit.buffer == reservation.creation.id)) {
      throw CoreFailure(
        'refactor.protocol',
        'The new definition is not bound to its reviewed source destination',
      );
    }
    return FileCreationPlan._(
      this,
      plan._revision,
      [...plan._snapshots, ...reservation._snapshots],
      plan.result,
      BufferCreation(
        id: reservation.creation.id,
        path: reservation.creation.path,
        text: created['text'] as String,
      ),
    );
  }

  Future<FileDeletionPlan> planFileDeletion(
    String resource, {
    void Function(String resource)? onResourceRefreshed,
  }) async {
    if (_closed) throw CoreFailure('access.closed', 'The project is closed');
    final source = await buffer(resource);
    if (source.id == _manifestResource)
      throw CoreFailure(
        'file.delete.configuration',
        'Project configuration is not a contract-file deletion target',
      );
    // Unused files are deliberately outside the semantic root closure. A
    // mounted clean Source view still needs the same immediate refresh signal
    // as a reachable dependency before its removal preview is captured.
    if (!source.dirty && !source.externalConflict) {
      final before = (source.generation, source.externalConflict);
      await refreshDisk(source);
      if (before != (source.generation, source.externalConflict))
        onResourceRefreshed?.call(source.id);
    }
    final captured = await source.snapshotAsync();
    final plan = await _planSemantic(
      'planFileDeletion',
      {'resource': source.id, 'generation': captured['generation']},
      {'deletionSource': captured},
      onResourceRefreshed: onResourceRefreshed,
    );
    final impact = await _captureFilePolicy(
          onResourceRefreshed: onResourceRefreshed,
        ),
        policy = impact.inputs,
        policyFailure = impact.failure;
    final extra = AnalysisSnapshot(root: source.id, resources: [captured]);
    if (!extra.current(store))
      throw CoreFailure(
        'refactor.stale',
        'The captured source changed while reviewing file deletion',
      );
    return FileDeletionPlan._(
      this,
      plan._revision,
      [
        ...plan._snapshots,
        extra,
        if (policy != null)
          AnalysisSnapshot(
            root: roots.first.id,
            resources: policy.observed.values
                .whereType<Map<String, Object?>>()
                .toList(),
          ),
      ],
      {
        ...plan.result,
        'identity': textIdentity(
          jsonEncode({
            'source': plan.identity,
            'policy': policy?.identity,
            'failure': policyFailure,
          }),
        ),
        'blockers': [
          ...plan.result['blockers'] as List,
          if (_resourceMappings.values.contains(source.id))
            {
              'resource': source.id,
              'pointer': '',
              'code': 'file.delete.mapping-consumer',
            },
          if (policyFailure != null ||
              policy?.unavailable.isNotEmpty == true ||
              policy?.dependenciesComplete != true)
            {
              'resource': source.id,
              'pointer': '',
              'code': 'file.delete.policy-analysis',
              'reasonCode': policyFailure,
            },
          if (policy?.observed[source.id] != null)
            {
              'resource': source.id,
              'pointer': '',
              'code': 'file.delete.policy-consumer',
            },
        ],
        'usages': [
          ...plan.result['usages'] as List,
          if (policy?.observed[source.id] != null)
            {
              'resource': source.id,
              'pointer': '',
              'connection': 'policy-input',
              'target': {'resource': source.id, 'pointer': ''},
              'roots': plan.checkedRoots,
            },
        ],
        'file': {
          'source': source.id,
          'publishedResource': Uri.file(source.publishedPath).toString(),
          'published': source.publishedPresent,
        },
      },
      BufferPresenceEdit(
        buffer: source.id,
        generation: source.generation,
        expectedPath: source.path,
        expectedText: source.text,
        expectedBom: source.hasBom,
        expectedPresent: true,
        present: false,
      ),
      policy,
    );
  }

  Future<void> _verifyFileDeletion(FileDeletionPlan plan) =>
      _verifyFilePolicy(plan._policyInputs, plan._revision);

  Future<FileMovePlan> planFileMove(
    String resource,
    String destination, {
    bool retainIdentity = false,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    if (_closed) throw CoreFailure('access.closed', 'The project is closed');
    await _refreshResourceConfiguration(
      onResourceRefreshed: onResourceRefreshed,
    );
    final revision = _resourceRevision;
    final source = await buffer(resource);
    if (source.id == _manifestResource)
      throw CoreFailure(
        'file.move.configuration',
        'Project configuration is not a contract-file move target',
      );
    if (!source.dirty && !source.externalConflict) {
      final before = (source.generation, source.externalConflict);
      await refreshDisk(source);
      if (before != (source.generation, source.externalConflict))
        onResourceRefreshed?.call(source.id);
    }
    final path = accessFor(destination).pathFor(destination);
    if (path == Uri.parse(_manifestResource).toFilePath() &&
        source.path != path)
      throw CoreFailure(
        'file.move.configuration',
        'busyapi.yaml is reserved for project configuration',
      );
    final id = Uri.file(path).toString();
    if (source.path != path &&
        (store.buffers.containsKey(id) ||
            !await accessFor(path).missing(path))) {
      throw CoreFailure(
        'file.move.collision',
        'The destination already exists',
      );
    }
    if (_loadingBuffers.isNotEmpty)
      throw CoreFailure(
        'file.move.loading',
        'Wait for pending resource opens before reviewing a move',
      );
    Map<String, Object?>? manifest;
    final manifestPath = p.join(access.boundary, 'busyapi.yaml');
    if (!await access.missing(manifestPath)) {
      final b = await buffer(Uri.file(manifestPath).toString());
      if (b.text.length > 65536)
        throw CoreFailure('limit.manifest', 'Project manifest exceeds 64 KiB');
      manifest = await b.snapshotAsync();
    }
    final aliases =
        _resourceMappings.entries
            .where((entry) => entry.value == source.id)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    final captured = {
      ...await source.snapshotAsync(),
      if (aliases.isNotEmpty) 'aliases': aliases,
    };
    final plan = await _planSemantic(
      'planFileMove',
      {'resource': source.id, 'generation': captured['generation']},
      {
        'destinationResource': id,
        'retainIdentity': retainIdentity,
        'moveSource': captured,
        if (manifest != null) 'manifest': manifest,
      },
      onResourceRefreshed: onResourceRefreshed,
    );
    final impact = await _captureFilePolicy(
          onResourceRefreshed: onResourceRefreshed,
        ),
        policy = impact.inputs;
    final physical = AnalysisSnapshot(root: source.id, resources: [captured]);
    final extra = manifest == null
        ? null
        : AnalysisSnapshot(
            root: manifest['id'] as String,
            resources: [manifest],
          );
    if (revision != _resourceRevision ||
        !physical.current(store) ||
        source.id != captured['id'] ||
        source.generation != captured['generation'] ||
        extra != null && !extra.current(store)) {
      throw CoreFailure(
        'refactor.stale',
        'The source or configuration changed while preparing the move',
      );
    }
    return FileMovePlan._(
      this,
      plan._revision,
      List.unmodifiable([
        ...plan._snapshots,
        physical,
        if (extra != null) extra,
        if (policy != null)
          AnalysisSnapshot(
            root: roots.first.id,
            resources: policy.observed.values
                .whereType<Map<String, Object?>>()
                .toList(),
          ),
      ]),
      {
        ...plan.result,
        'identity': textIdentity(
          jsonEncode({
            'source': plan.identity,
            'policy': policy?.identity,
            'failure': impact.failure,
          }),
        ),
        'blockers': [
          ...plan.result['blockers'] as List? ?? const [],
          if (impact.failure != null ||
              policy?.unavailable.isNotEmpty == true ||
              policy?.dependenciesComplete != true)
            {
              'resource': source.id,
              'pointer': '',
              'code': 'file.move.policy-analysis',
              'reasonCode': impact.failure,
            },
          if (policy?.observed[source.id] != null)
            {
              'resource': source.id,
              'pointer': '',
              'code': 'file.move.policy-consumer',
            },
        ],
        'usages': [
          ...plan.result['usages'] as List,
          if (policy?.observed[source.id] != null)
            {
              'resource': source.id,
              'pointer': '',
              'connection': 'policy-input',
              'target': {'resource': source.id, 'pointer': ''},
              'roots': plan.checkedRoots,
            },
        ],
      },
      BufferPathEdit(
        buffer: source.id,
        generation: source.generation,
        expectedPath: source.path,
        expectedText: source.text,
        expectedBom: source.hasBom,
        destination: id,
        path: path,
      ),
      policy,
    );
  }

  Future<void> _verifyFileMove(FileMovePlan plan) async {
    await _verifyFilePolicy(plan._policyInputs, plan._revision);
    final edit = plan.pathEdit;
    if (_loadingBuffers.isNotEmpty || store.buffers[edit.buffer] == null) {
      throw CoreFailure(
        'file.move.stale',
        'Resource ownership changed after review',
      );
    }
    if (edit.destination != edit.buffer &&
        (store.buffers.containsKey(edit.destination) ||
            !await accessFor(edit.path).missing(edit.path))) {
      throw CoreFailure(
        'file.move.collision',
        'The reviewed destination is no longer empty',
      );
    }
    final config = store.buffers[_manifestResource];
    if (config != null) {
      var text = config.text;
      for (final change
          in plan.edits.where((e) => e.buffer == config.id).toList()
            ..sort((a, b) => b.start.compareTo(a.start))) {
        if (text.substring(change.start, change.end) != change.expected)
          throw CoreFailure(
            'refactor.stale',
            'Project configuration changed after review',
          );
        text =
            text.substring(0, change.start) +
            change.replacement +
            text.substring(change.end);
      }
      final source = {...config.snapshot(), 'text': text};
      await _normalizeConfigurationKeys(source);
      _parseResourceMappings(source, {
        for (final e in _approvedResources.entries)
          e.key: e.value == edit.buffer ? edit.destination : e.value,
      });
    }
  }
}
