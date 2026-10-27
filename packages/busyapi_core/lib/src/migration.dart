part of 'project.dart';

void _verifyMigrationReview(
  Map<String, dynamic> result,
  _OutputInput input,
  String targetVersion,
) {
  Never invalid() => throw CoreFailure(
    'migration.protocol',
    'Migration returned an incomplete or unrelated review',
  );
  if (result['version'] != 1 ||
      result['snapshot'] != input.snapshot.identity ||
      result['producer'] != 'busyapi-native-migration' ||
      result['producerVersion'] != '12' ||
      result['problems'] is! List ||
      result['outputs'] is! List ||
      result['changes'] is! List ||
      result['presentationChanges'] is! List ||
      result['affectedResources'] is! List ||
      result['entryRoutes'] is! List)
    invalid();
  final target = SpecificationContext.fromJson(result['target']);
  if (target.declaredVersion != targetVersion) invalid();
  final status = result['status'], complete = result['complete'];
  if (!const [
        'faithfully-convertible',
        'requires-decision',
        'blocked',
      ].contains(status) ||
      complete is! bool ||
      (status == 'faithfully-convertible') != complete)
    invalid();
  final resources = {
    for (final resource in input.snapshot.resources)
      resource['id'] as String: resource,
  };
  final entries = result['entryRoutes'] as List, entryResources = <String>{};
  if (entries.isEmpty || entries.length > resources.length) invalid();
  for (final value in entries) {
    if (value is! Map ||
        value['resource'] is! String ||
        !resources.containsKey(value['resource']) ||
        !entryResources.add(value['resource'] as String))
      invalid();
    final entry = MigrationEntryRoute._(value);
    if (entry.target.declaredVersion != targetVersion) invalid();
  }
  if (!entryResources.contains(input.snapshot.root)) invalid();
  for (final value in result['problems'] as List) {
    if (value case {
      'id': String _,
      'resource': String resource,
      'pointer': String _,
      'code': String _,
      'message': String _,
      'reason': String reason,
      'range': [int start, int end],
    }) {
      final source = resources[resource];
      if (source == null ||
          start < 0 ||
          end < start ||
          end > (source['text'] as String).length ||
          !const [
            'target-representation',
            'implementation',
            'source-incomplete',
            'decision',
          ].contains(reason))
        invalid();
      final choices = value['choices'];
      if (choices != null &&
          (choices is! List || choices.any((choice) => choice is! String)))
        invalid();
    } else {
      invalid();
    }
  }
  if (!complete) {
    if ((result['outputs'] as List).isNotEmpty ||
        (result['problems'] as List).isEmpty)
      invalid();
    return;
  }
  if ((result['problems'] as List).isNotEmpty ||
      (result['outputs'] as List).isEmpty)
    invalid();
  if (result['validation'] case {'complete': true, 'family': String _}) {
  } else {
    invalid();
  }
  final paths = <String>{};
  final outputTexts = <String, String>{};
  for (final value in result['outputs'] as List) {
    if (value case {
      'path': String path,
      'id': String id,
      'text': String text,
      'identity': String identity,
      'hasBom': bool _,
    }) {
      if (path != p.posix.normalize(path) ||
          p.posix.isAbsolute(path) ||
          p.posix.split(path).any((part) => part == '..' || part == '.') ||
          path.contains('\\') ||
          !paths.add(path) ||
          id != Uri.directory(input.target).resolve(path).toString() ||
          textIdentity(text) != identity)
        invalid();
      outputTexts[id] = text;
    } else {
      invalid();
    }
  }
  if (!paths.contains(result['entry']) ||
      paths.contains('busyapi.yaml') ||
      paths.contains('migration.json') ||
      result['manifest'] is! Map ||
      result['identity'] is! String)
    invalid();
  final reviewed = <String>{};
  for (final value in result['changes'] as List) {
    if (value case {
      'resource': String resource,
      'destination': String destination,
      'before': String before,
      'after': String after,
    }) {
      if (!reviewed.add(resource) ||
          resources[resource]?['text'] != before ||
          outputTexts[destination] != after)
        invalid();
    } else {
      invalid();
    }
  }
  if (reviewed.length != resources.length ||
      outputTexts.length != reviewed.length)
    invalid();
}

/// One captured API description's explicit source and target specifications.
class MigrationEntryRoute {
  MigrationEntryRoute._(Map value)
    : resource = value['resource'] as String,
      from = SpecificationContext.fromJson(value['from']),
      target = SpecificationContext.fromJson(value['target']);
  final String resource;
  final SpecificationContext from, target;
}

enum MigrationStatus { faithfullyConvertible, requiresDecision, blocked }

enum MigrationProblemReason {
  targetRepresentation,
  implementation,
  sourceIncomplete,
  decision,
}

class MigrationProblem {
  MigrationProblem._(Map value)
    : id = value['id'] as String,
      resource = value['resource'] as String,
      pointer = value['pointer'] as String,
      code = value['code'] as String,
      message = value['message'] as String,
      reason = switch (value['reason']) {
        'target-representation' => MigrationProblemReason.targetRepresentation,
        'implementation' => MigrationProblemReason.implementation,
        'source-incomplete' => MigrationProblemReason.sourceIncomplete,
        'decision' => MigrationProblemReason.decision,
        _ => throw CoreFailure(
          'migration.protocol',
          'Unknown migration problem classification',
        ),
      },
      range = SourceRange(
        (value['range'] as List)[0] as int,
        (value['range'] as List)[1] as int,
      ),
      choices = List.unmodifiable(
        (value['choices'] as List? ?? const []).cast<String>(),
      );
  final String id, resource, pointer, code, message;
  final MigrationProblemReason reason;
  final SourceRange range;
  final List<String> choices;
}

class MigrationChange {
  MigrationChange._(Map value)
    : resource = value['resource'] as String,
      destination = value['destination'] as String,
      before = value['before'] as String,
      after = value['after'] as String;
  final String resource, destination, before, after;
}

/// A review of one captured graph. Publishing owns a separate directory and
/// rechecks source buffers, disk inputs and destination ownership at the last
/// publication boundary. Original source is never an output target.
class MigrationOutput extends BundleOutput {
  MigrationOutput._(
    BusyProject owner,
    _OutputInput input,
    Map<String, dynamic> result,
    Map<String, Object?> metadata,
  ) : status = switch (result['status']) {
        'faithfully-convertible' => MigrationStatus.faithfullyConvertible,
        'requires-decision' => MigrationStatus.requiresDecision,
        'blocked' => MigrationStatus.blocked,
        _ => throw CoreFailure(
          'migration.protocol',
          'Unknown migration status',
        ),
      },
      problems = List.unmodifiable(
        (result['problems'] as List).cast<Map>().map(MigrationProblem._),
      ),
      changes = List.unmodifiable(
        (result['changes'] as List).cast<Map>().map(MigrationChange._),
      ),
      target = SpecificationContext.fromJson(result['target']),
      entryRoutes = List.unmodifiable(
        (result['entryRoutes'] as List).cast<Map>().map(MigrationEntryRoute._),
      ),
      super._(
        owner,
        input.access,
        input.target,
        input.snapshot,
        input.saved,
        input.checked['unsaved'] == true,
        input.revision,
        result,
        metadata,
      );
  final MigrationStatus status;
  final List<MigrationProblem> problems;
  final List<MigrationChange> changes;
  final SpecificationContext target;
  final List<MigrationEntryRoute> entryRoutes;
  bool get publishable =>
      status == MigrationStatus.faithfullyConvertible &&
      result['complete'] == true;
  @override
  String get identity =>
      result['identity'] as String? ?? textIdentity(jsonEncode(result));

  Future<void> _verifyCurrent() async {
    if (_closed || outdated)
      throw CoreFailure(
        'migration.stale',
        'The reviewed migration inputs changed; create a new review',
      );
    final inputs = snapshot.allInputs
        .where((input) => input['bundled'] != true)
        .map((input) => input['id'] as String)
        .toSet();
    await _resourceBatch(inputs, (id) async {
      final buffer = await _owner.buffer(id);
      await _owner.refreshDisk(buffer);
    });
    if (_closed ||
        outdated ||
        inputs.any((id) => _owner.store.get(id).externalConflict))
      throw CoreFailure(
        'migration.stale',
        'A source file changed after migration review; no output was published',
      );
  }

  @override
  Future<OutputDirectoryResult> publish({
    String? replaceIdentity,
    bool Function()? cancelled,
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
  }) async {
    if (!publishable)
      throw CoreFailure(
        'migration.blocked',
        'Resolve every migration decision and blocker before publication',
      );
    if (cancelled?.call() == true)
      throw CoreFailure('cancelled', 'Migration publication was cancelled');
    await _verifyCurrent();
    final files = <String, List<int>>{};
    for (final output in (result['outputs'] as List).cast<Map>()) {
      final text = output['text'] as String, path = output['path'] as String;
      if (textIdentity(text) != output['identity'])
        throw CoreFailure(
          'migration.protocol',
          'Migrated source identity changed',
        );
      files[path] = [
        if (output['hasBom'] == true) ...const [239, 187, 191],
        ...utf8.encode(text),
      ];
    }
    files['busyapi.yaml'] = utf8.encode('${jsonEncode(result['manifest'])}\n');
    files['migration.json'] = utf8.encode('${jsonEncode(metadata)}\n');
    return _access.publishOutput(
      destination,
      files,
      metadata,
      replaceIdentity: replaceIdentity,
      cancelled: () => cancelled?.call() == true || _closed || outdated,
      beforePublish: () async {
        await beforePublish?.call();
        await _verifyCurrent();
      },
      afterPublish: afterPublish,
    );
  }
}

extension ContractMigration on BusyProject {
  Future<MigrationOutput> prepareMigration(
    String root,
    String destination, {
    required String targetVersion,
    Map<String, String> decisions = const {},
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    final captured = await _captureOutputInput(
      root,
      destination,
      operation: 'migration',
      requestId: requestId,
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
    );
    try {
      final result = await engine.request('planMigration', {
        ...captured.snapshot.toJson(),
        'targetVersion': targetVersion,
        'destination': Uri.directory(captured.target).toString(),
        'decisions': decisions,
      }, requestId: requestId);
      if (_closed || cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Migration planning was cancelled');
      if (captured.revision != _resourceRevision ||
          !captured.snapshot.current(store))
        throw CoreFailure(
          'migration.stale',
          'The graph changed while preparing migration',
        );
      _verifyMigrationReview(result, captured, targetVersion);
      final metadata = <String, Object?>{
        'version': 1,
        'operation': 'migration',
        'root': root,
        'snapshot': captured.snapshot.sourceIdentity,
        'input': captured.checked['unsaved'] == true
            ? 'working-copy'
            : 'saved-source',
        'unsaved': captured.checked['unsaved'] == true,
        'target': result['target'],
        'stages': result['stages'],
        'status': result['status'],
        'entry': result['entry'],
        'outputIdentity': result['identity'],
        'producer': result['producer'],
        'producerVersion': result['producerVersion'],
        'decisions': decisions,
        'presentationChanges': result['presentationChanges'],
        'invariants': result['invariants'],
        'sources': [
          for (final source in captured.snapshot.resources)
            {'resource': source['id'], 'identity': source['identity']},
        ],
      };
      return MigrationOutput._(this, captured, result, metadata);
    } on Object {
      captured.access.close();
      rethrow;
    }
  }
}
