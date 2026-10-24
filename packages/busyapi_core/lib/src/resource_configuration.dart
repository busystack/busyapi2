part of 'project.dart';

class _ResourceConfiguration {
  _ResourceConfiguration(this.source, this.mappings);
  final Map<String, Object?>? source;
  final Map<String, String> mappings;
}

extension ResourceConfiguration on BusyProject {
  Future<List<String>> _normalizedResourceUris(
    List<String> values, {
    String? base,
  }) async {
    final result = await engine.request('normalizeResourceUris', {
      'base': base,
      'values': values,
    });
    if (result['version'] != 1 ||
        result['base'] != base ||
        result['values'] is! List ||
        jsonEncode(result['values']) != jsonEncode(values) ||
        result['uris'] is! List ||
        (result['uris'] as List).length != values.length ||
        !(result['uris'] as List).every(
          (value) =>
              value is String &&
              value.length <= 262144 &&
              Uri.tryParse(value)?.hasScheme == true &&
              Uri.parse(value).userInfo.isEmpty &&
              !Uri.parse(value).hasFragment,
        ))
      throw CoreFailure(
        'resource.protocol',
        'The URI normalizer returned an unrelated or malformed result',
      );
    return List<String>.from(result['uris'] as List);
  }

  Future<void> _normalizeConfigurationKeys(Map<String, Object?>? source) async {
    if (source == null) return;
    Object? data;
    try {
      data = loadYaml(source['text'] as String);
    } on Object {
      throw CoreFailure(
        'manifest.syntax',
        'Project configuration has invalid or ambiguous syntax; inspect busyapi.yaml',
      );
    }
    if (data is! YamlMap || data['version'] != 1)
      throw CoreFailure(
        'manifest.version',
        'Expected project configuration version 1',
      );
    if (!data.containsKey('resourceMappings')) return;
    final mappings = data['resourceMappings'];
    if (mappings is! YamlMap ||
        mappings.length > 256 ||
        mappings.keys.any((key) => key is! String || key.length > 4096))
      throw CoreFailure(
        'resource.configuration',
        'Resource mappings require bounded URI keys',
      );
    final base = source['id'] as String,
        keys = mappings.keys.cast<String>().toList();
    final missing = keys
        .where((key) => !_resourceIdentityCache.containsKey('$base\u0000$key'))
        .toList();
    if (missing.isNotEmpty) {
      final normalized = await _normalizedResourceUris(missing, base: base);
      if (_closed)
        throw CoreFailure(
          'access.closed',
          'The resource owner closed during URI normalization',
        );
      for (var i = 0; i < missing.length; i++) {
        _resourceIdentityCache['$base\u0000${missing[i]}'] = normalized[i];
      }
    }
    final pinned = {for (final key in keys) '$base\u0000$key'};
    var bytes = _resourceIdentityCache.entries.fold<int>(
      0,
      (n, e) => n + (e.key.length + e.value.length) * 2,
    );
    while (_resourceIdentityCache.length > 1024 || bytes > 16 * 1024 * 1024) {
      final old = _resourceIdentityCache.keys
          .where((key) => !pinned.contains(key))
          .firstOrNull;
      if (old == null)
        throw CoreFailure(
          'resource.limit',
          'The configured URI identity cache exceeds its bounded budget',
        );
      bytes -= (old.length + _resourceIdentityCache.remove(old)!.length) * 2;
    }
  }

  void _configureResourceMappings(Map<String, Object?>? source) {
    final text = source?['text'] as String?;
    if (text == _resourceConfigurationText) {
      return;
    }
    final mappings = _parseResourceMappings(source, _approvedResources);
    _configuredResources
      ..clear()
      ..addAll(mappings);
    _resourceConfigurationText = text;
    _resourceRevision++;
    _workingSnapshot = null;
  }

  Map<String, String> _parseResourceMappings(
    Map<String, Object?>? source,
    Map<String, String> approved,
  ) {
    final mappings = <String, String>{};
    if (source != null) {
      Object? data;
      try {
        data = loadYaml(source['text'] as String);
      } on Object {
        throw CoreFailure(
          'manifest.syntax',
          'Project configuration has invalid or ambiguous syntax; inspect busyapi.yaml',
        );
      }
      if (data is! YamlMap || data['version'] != 1)
        throw CoreFailure(
          'manifest.version',
          'Expected project configuration version 1',
        );
      if (data.containsKey('resourceMappings')) {
        final values = data['resourceMappings'];
        if (values is! YamlMap || values.length > 256)
          throw CoreFailure(
            'resource.configuration',
            'resourceMappings must be a mapping of at most 256 URI identities to local file paths',
          );
        for (final entry in values.entries) {
          if (entry.key is! String ||
              entry.value is! String ||
              (entry.key as String).length > 4096 ||
              (entry.value as String).length > 4096 ||
              (entry.value as String).isEmpty ||
              (entry.value as String).contains('\u0000'))
            throw CoreFailure(
              'resource.configuration',
              'Resource mappings require bounded URI keys and local path values',
            );
          final identity =
              _resourceIdentityCache['${source['id']}\u0000${entry.key}'];
          if (identity == null)
            throw CoreFailure(
              'resource.identity.pending',
              'Resource URI identities need a current canonical projection',
            );
          // A configured local mapping names a resource, not permission to read
          // outside the approved context. accessFor/read enforce that later.
          final path = p.normalize(
                p.absolute(p.join(access.boundary, entry.value as String)),
              ),
              resource = Uri.file(path).toString();
          if (mappings.containsKey(identity) &&
                  mappings[identity] != resource ||
              approved.containsKey(identity) && approved[identity] != resource)
            throw CoreFailure(
              'resource.collision',
              'One configured identity names different local resources',
            );
          if ({
            ...mappings,
            ...approved,
          }.entries.any((e) => e.value == resource && e.key != identity))
            throw CoreFailure(
              'resource.base.ambiguous',
              'One local resource has different configured retrieval identities',
            );
          mappings[identity] = resource;
          if ({...approved, ...mappings}.length > 256)
            throw CoreFailure(
              'resource.limit',
              'Configured and session mappings exceed 256 resource identities',
            );
        }
      }
    }
    return mappings;
  }

  Future<_ResourceConfiguration> _refreshResourceConfiguration({
    bool saved = false,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    if (_closed)
      throw CoreFailure('access.closed', 'The configuration owner is closed');
    final requiredManifest = !_standalone && _resourceConfigurationPresent;
    final path = Uri.parse(_manifestResource).toFilePath(),
        b = store.buffers[_manifestResource];
    if (_standalone &&
        (location == path ||
            store.buffers.values.any(
              (candidate) =>
                  roots.any((root) => root.id == candidate.id) &&
                  (candidate.path == path || candidate.publishedPath == path),
            ))) {
      if (!saved) _resourceConfigurationPresent = false;
      if (!saved) _configureResourceMappings(null);
      return _ResourceConfiguration(null, Map.of(_approvedResources));
    }
    Map<String, Object?>? source;
    if (!saved && b != null) {
      if (!b.dirty && !b.externalConflict) {
        final before = (b.generation, b.externalConflict);
        await refreshDisk(b);
        if (!_closed && before != (b.generation, b.externalConflict))
          onResourceRefreshed?.call(b.id);
      }
      source = await b.snapshotAsync();
    } else if (!await access.missing(path)) {
      final bytes = await access.read(path);
      if (bytes.length > 65536)
        throw CoreFailure(
          'limit.manifest',
          'Project configuration exceeds 64 KiB',
        );
      try {
        source = await DocumentBuffer.decode(path, bytes).snapshotAsync();
      } on FormatException {
        throw CoreFailure(
          'manifest.encoding',
          'Project configuration is not valid UTF-8',
        );
      }
    }
    if (_closed)
      throw CoreFailure(
        'access.closed',
        'The configuration owner closed during collection',
      );
    if (source != null && (source['text'] as String).length > 65536)
      throw CoreFailure(
        'limit.manifest',
        'Project configuration exceeds 64 KiB',
      );
    if (source == null && requiredManifest) {
      throw CoreFailure(
        'manifest.missing',
        'The configured project manifest is unavailable; restore it or reopen the intended source scope',
      );
    }
    final configuredRoots = _parseRootConfiguration(source);
    await _normalizeConfigurationKeys(source);
    if (!saved) {
      final live = store.buffers[_manifestResource];
      if (live != null &&
          (source == null ||
              live.generation != source['generation'] ||
              live.text != source['text'] ||
              live.hasBom != source['hasBom'])) {
        throw CoreFailure(
          'manifest.changed',
          'Project configuration changed during collection; refresh the current source',
        );
      }
      _configureResourceMappings(source);
      _adoptRootConfiguration(configuredRoots);
      _resourceConfigurationPresent = source != null;
      return _ResourceConfiguration(source, _resourceMappings);
    }
    final approved = {
      for (final e in _approvedResources.entries)
        e.key: store.buffers[e.value]?.hasPathIntent == true
            ? Uri.file(store.buffers[e.value]!.publishedPath).toString()
            : e.value,
    };
    return _ResourceConfiguration(source, {
      ..._parseResourceMappings(source, approved),
      ...approved,
    });
  }
}
