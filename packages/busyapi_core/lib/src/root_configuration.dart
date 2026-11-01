part of 'project.dart';

/// A declaration-only source transaction with captured API-consumer impact.
/// It never removes a physical file, buffer, draft/view owner or reference.
/// Save retains the normal writer.
class RootRemovalPlan extends RefactoringPlan {
  RootRemovalPlan._(
    super.owner,
    super.revision,
    super.snapshots,
    super.data,
    this._configured,
  ) : super._();
  final List<ProjectRoot> _configured;
}

extension RootConfiguration on BusyProject {
  void _rootConfigurationCommitted(Set<DocumentBuffer> participants) {
    if (_closed || _standalone) return;
    final manifest = participants
        .where((buffer) => buffer.id == _manifestResource)
        .firstOrNull;
    if (manifest == null) return;
    _workingSnapshot = null;
    _resourceRevision++;
    if (!manifest.present) return;
    try {
      _adoptRootConfiguration(_parseRootConfiguration(manifest.snapshot()));
    } on CoreFailure {
      // Source may intentionally be incomplete. History has already committed;
      // retain its bytes and the last coherent root list. The shared collector
      // reports the configuration error before another plan/check can succeed.
    }
  }

  bool get hasRootConfiguration =>
      !_standalone && _resourceConfigurationPresent;

  Future<RootRemovalPlan> planRootRemoval(
    String name,
    String resource, {
    void Function(String resource)? onResourceRefreshed,
  }) async {
    await _refreshResourceConfiguration(
      onResourceRefreshed: onResourceRefreshed,
    );
    if (!hasRootConfiguration) {
      throw CoreFailure(
        'root.configuration',
        'Choose an existing named project-root configuration',
      );
    }
    await engine.start();
    final buffer = await this.buffer(_manifestResource);
    final configuration = await _refreshResourceConfiguration(
      onResourceRefreshed: onResourceRefreshed,
    );
    final source = configuration.source!;
    final configured = _parseRootConfiguration(source)!;
    final index = configured.indexWhere(
      (entry) => entry.name == name && entry.id == resource,
    );
    if (index < 0) {
      throw CoreFailure(
        'root.stale',
        'The selected named root declaration is no longer current',
      );
    }
    final revision = _resourceRevision;
    final semantic = await _planSemantic(
      'planRootRemoval',
      {'index': index, 'name': name, 'resource': resource},
      {
        'manifest': source,
        'manifestAliases': [
          for (final entry in configuration.mappings.entries)
            if (entry.value == buffer.id) entry.key,
        ],
        'configuredRoots': configured.map((entry) => entry.id).toList(),
      },
      onResourceRefreshed: onResourceRefreshed,
    );
    final result = semantic.result;
    if (_closed ||
        revision != _resourceRevision ||
        buffer.generation != source['generation'] ||
        buffer.sourceIdentity != source['identity']) {
      throw CoreFailure(
        'refactor.stale',
        'The root configuration changed while preparing the source review',
      );
    }
    final changes = result['changes'], edits = result['edits'];
    if (result['version'] != 1 ||
        result['kind'] != 'root-remove' ||
        result['identity'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(result['identity'] as String) ||
        result['remaining'] != configured.length - 1 ||
        result['removed'] is! Map ||
        result['removed']['name'] != name ||
        result['removed']['resource'] != resource ||
        result['removed']['pointer'] != '/roots/$index' ||
        result['from'] is! Map ||
        result['from']['resource'] != buffer.id ||
        result['from']['pointer'] != '/roots/$index' ||
        result['to'] is! Map ||
        result['to']['resource'] != buffer.id ||
        result['to']['pointer'] != '/roots' ||
        jsonEncode(result['checkedRoots']) !=
            jsonEncode(configured.map((entry) => entry.id).toList()) ||
        jsonEncode(result['configuredRoots']) !=
            jsonEncode(configured.map((entry) => entry.id).toList()) ||
        result['usages'] is! List ||
        result['blockers'] is! List ||
        result['transitions'] is! List ||
        (result['transitions'] as List).isNotEmpty ||
        changes is! List ||
        changes.length != 1 ||
        changes.single is! Map ||
        changes.single['resource'] != buffer.id ||
        changes.single['before'] != source['text'] ||
        changes.single['after'] is! String ||
        edits is! List ||
        edits.length != 1 ||
        edits.single is! Map) {
      throw CoreFailure(
        'root.protocol',
        'The worker returned an unrelated or malformed root edit',
      );
    }
    final inputs = {
      for (final snapshot in semantic._snapshots)
        for (final input in snapshot.resources) input['id']: input,
    };
    for (final raw in [
      ...result['usages'] as List,
      ...result['blockers'] as List,
    ]) {
      final input = raw is Map ? inputs[raw['resource']] : null;
      final Object? range = raw is Map ? raw['range'] : null;
      final Object? start = range is List && range.length == 2
              ? range[0]
              : null,
          end = range is List && range.length == 2 ? range[1] : null;
      if (raw is! Map ||
          input == null ||
          raw['pointer'] is! String ||
          raw['generation'] != input['generation'] ||
          raw['identity'] != input['identity'] ||
          raw['code'] is! String ||
          raw['connection'] is! String ||
          raw['target'] is! Map ||
          raw['target']['pointer'] is! String ||
          start is! int ||
          end is! int ||
          start < 0 ||
          end < start ||
          end > (input['text'] as String).length) {
        throw CoreFailure(
          'root.protocol',
          'The worker returned an unrelated consumer location',
        );
      }
    }
    final edit = edits.single as Map;
    final Object? start = edit['start'],
        end = edit['end'],
        expectedText = edit['expected'],
        replacement = edit['replacement'];
    if (edit['buffer'] != buffer.id ||
        edit['generation'] != source['generation'] ||
        start is! int ||
        end is! int ||
        start < 0 ||
        end < start ||
        end > buffer.text.length ||
        expectedText is! String ||
        replacement is! String ||
        buffer.text.substring(start, end) != expectedText ||
        buffer.text.replaceRange(start, end, replacement) !=
            changes.single['after']) {
      throw CoreFailure(
        'root.protocol',
        'The worker returned an unrelated or malformed source range',
      );
    }
    final remaining = _parseRootConfiguration({
      ...source,
      'text': changes.single['after'],
    })!;
    final expected = [...configured]..removeAt(index);
    if (remaining.length != expected.length ||
        List.generate(expected.length, (i) => i).any(
          (i) =>
              remaining[i].name != expected[i].name ||
              remaining[i].id != expected[i].id,
        )) {
      throw CoreFailure(
        'root.protocol',
        'The root edit would change a different named declaration',
      );
    }
    return RootRemovalPlan._(
      this,
      revision,
      semantic._snapshots,
      Map<String, dynamic>.from(result),
      List.unmodifiable(remaining),
    );
  }

  /// Revalidate named choices against the working (or explicitly saved)
  /// configuration. Selection/export callers must not reuse a stale list.
  Future<List<ProjectRoot>> configuredRoots({
    bool saved = false,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    final configuration = await _refreshResourceConfiguration(
      saved: saved,
      onResourceRefreshed: onResourceRefreshed,
    );
    return List.unmodifiable(
      _parseRootConfiguration(configuration.source) ?? roots,
    );
  }

  /// A source projection only. Explicitly opening a contract retains its
  /// standalone scope even when neighbouring configuration supplies mappings.
  /// Parse/validate the entire list before changing any working identity.
  List<ProjectRoot>? _parseRootConfiguration(Map<String, Object?>? source) {
    if (_standalone || source == null) return null;
    final text = source['text'] as String;
    if (text.length > 65536) {
      throw CoreFailure(
        'limit.manifest',
        'Project configuration exceeds 64 KiB',
      );
    }
    Object? data;
    try {
      data = loadYaml(text);
    } on Object {
      throw CoreFailure(
        'manifest.syntax',
        'Project configuration has invalid or ambiguous syntax; inspect busyapi.yaml',
      );
    }
    if (data is! YamlMap ||
        data['version'] != 1 ||
        data['roots'] is! YamlList) {
      throw CoreFailure(
        'manifest.version',
        'Expected project configuration version 1 with named roots',
      );
    }
    final entries = data['roots'] as YamlList;
    if (entries.length > 128) {
      throw CoreFailure(
        'limit.roots',
        'Project manifest exceeds 128 named roots',
      );
    }
    final result = <ProjectRoot>[];
    for (final value in entries) {
      if (value is! YamlMap ||
          value['name'] is! String ||
          value['path'] is! String) {
        throw CoreFailure('manifest.root', 'Invalid named root entry');
      }
      if (result.any((root) => root.name == value['name'])) {
        throw CoreFailure('manifest.duplicate', 'Root names must be unique');
      }
      final path = access.pathFor(
        p.join(access.boundary, value['path'] as String),
      );
      result.add(
        ProjectRoot(value['name'] as String, Uri.file(path).toString()),
      );
    }
    return result;
  }

  void _adoptRootConfiguration(List<ProjectRoot>? configured) {
    if (configured == null ||
        configured.length == roots.length &&
            List.generate(configured.length, (i) => i).every(
              (i) =>
                  configured[i].name == roots[i].name &&
                  configured[i].id == roots[i].id,
            )) {
      return;
    }
    roots
      ..clear()
      ..addAll(configured);
    // Removing a declaration never deletes a file, retires a buffer/history
    // owner, or chooses another current object. Native selection owns that.
    for (final root in configured) {
      final path = Uri.parse(root.id).toFilePath();
      if (!files.contains(path)) files.add(path);
    }
    _workingSnapshot = null;
    _resourceRevision++;
  }
}
