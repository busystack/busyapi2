part of 'project.dart';

/// Captured source-only review, not permission to run project code. Instances
/// retain their owner and freshness observations; navigation cannot retarget one.
class PolicyCodeReview {
  PolicyCodeReview._(
    this._owner,
    this.root,
    this.saved,
    this._inputs,
    Map<String, dynamic> result,
    Map<String, Map<String, Object?>> resources,
    this._metadata,
  ) : result = _freezeResult(result),
      resources = List.unmodifiable(
        resources.values.map(
          (value) => _freezeProjection(value) as Map<String, Object?>,
        ),
      );
  final BusyProject _owner;
  final _PolicyInputs _inputs;
  final Map<String, (String, ResourceMetadata)> _metadata;
  final String root;
  final bool saved;
  final Map<String, dynamic> result;
  final List<Map<String, Object?>> resources;
  String get identity => result['identity'] as String;
  bool get complete => result['complete'] == true;
  bool get unsaved =>
      !saved &&
      _inputs.observed.keys.any(
        (id) => _owner.store.buffers[id]?.dirty == true,
      );
}

/// Explicit, one-run local authority. It is never serialized into the project,
/// manifest, resource lock, output or personal display preferences.
class PolicyCodeApproval {
  PolicyCodeApproval._(this.review, this.identity, this.runtimeIdentity);
  final PolicyCodeReview review;
  final String identity, runtimeIdentity;
  bool _consumed = false;
}

extension BusyProjectPolicyCode on BusyProject {
  Future<Map<String, dynamic>> policyCodeTrust(PolicyCodeReview review) async {
    await verifyPolicyCodeReview(review);
    final runtime = await engine.request('policyRuntime', {});
    if (runtime['version'] != 1 ||
        runtime['profile'] != 'busyapi-node-captured-v1' ||
        runtime['node'] != '24.15.0' ||
        runtime['identity'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(runtime['identity'] as String))
      throw CoreFailure(
        'policy.protocol',
        'Isolated governance runtime returned malformed identity',
      );
    await verifyPolicyCodeReview(review);
    return {
      'version': 1,
      'identity': textIdentity(
        jsonEncode({
          'code': review.identity,
          'runtime': runtime['identity'],
          'engine': engine.assetIdentity,
          'project': access.boundary,
          'root': review.root,
        }),
      ),
      'codeIdentity': review.identity,
      'runtime': runtime,
      'scope': 'one-run',
    };
  }

  /// Call only from an explicit approval action after displaying the source and
  /// transitive bindings. A hash from a different review/profile cannot approve.
  Future<PolicyCodeApproval> approvePolicyCode(
    PolicyCodeReview review, {
    required String expectedIdentity,
  }) async {
    if (!review.complete)
      throw CoreFailure(
        'policy.code.incomplete',
        'The required code dependency review is incomplete',
      );
    final trust = await policyCodeTrust(review);
    if (trust['identity'] != expectedIdentity)
      throw CoreFailure(
        'policy.code.approval.changed',
        'Code or runtime identity does not match the explicit approval',
      );
    return PolicyCodeApproval._(
      review,
      expectedIdentity,
      (trust['runtime'] as Map)['identity'] as String,
    );
  }

  Future<void> _verifyPolicyApproval(
    PolicyCodeApproval approval,
    String root,
    bool saved, {
    required bool consume,
  }) async {
    if (approval._consumed ||
        approval.review.root != root ||
        approval.review.saved != saved ||
        !identical(approval.review._owner, this))
      throw CoreFailure(
        'policy.code.approval.changed',
        'Code approval is spent or belongs to another source scope',
      );
    final current = await policyCodeTrust(approval.review);
    // Another caller can consume this same token across the awaited resource /
    // runtime checks. Recheck at the synchronous consume boundary too.
    if (approval._consumed)
      throw CoreFailure(
        'policy.code.approval.changed',
        'Code approval was already consumed by another run',
      );
    if (current['identity'] != approval.identity)
      throw CoreFailure(
        'policy.code.approval.changed',
        'Code or runtime changed after explicit approval',
      );
    if (consume) approval._consumed = true;
  }

  ProjectAccess _policyCodeAccess(String path) {
    for (final capability in [access, ..._approvedContexts.values]) {
      if (path == capability.boundary || p.isWithin(capability.boundary, path))
        return capability;
    }
    throw CoreFailure(
      'access.outside',
      'Code resource needs local context approval',
    );
  }

  /// Collect declarations, module code and lookup metadata through the same
  /// anchored resource/mapping boundary as lint. Nothing is evaluated/imported.
  Future<PolicyCodeReview> reviewPolicyCode(
    String root, {
    bool saved = false,
    List<String>? rulesets,
    String? failSeverity,
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    void active() {
      if (_closed)
        throw CoreFailure('access.closed', 'Code review owner is closed');
      if (cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Code review was cancelled');
    }

    active();
    if (!roots.any((value) => value.id == root))
      throw CoreFailure('policy.root', 'Choose a configured project root');
    final inputs = await _capturePolicyInputs(
      active: active,
      saved: saved,
      rulesets: rulesets,
      failSeverity: failSeverity,
      requestId: requestId,
      onResourceRefreshed: onResourceRefreshed,
    );
    final mappings = Map<String, String>.from(_resourceMappings);
    final scopes = <String>{
      for (final directory in approvedContexts)
        Uri.directory('$directory/').toString(),
      // API-resource mappings are not code-module environment scopes. Only
      // actual captured policy aliases can add a logical code base here.
      for (final resource in inputs.resources.values)
        for (final identity in resource['aliases'] as List? ?? const [])
          Uri.parse(identity as String).resolve('.').toString(),
    }.toList()..sort();
    final resources = <String, Map<String, Object?>>{
      for (final entry in inputs.resources.entries)
        entry.key: {...entry.value, 'kind': 'file'},
    };
    final metadata = <String, (String, ResourceMetadata)>{};
    Future<void> acquire(Map request) async {
      active();
      final id = request['id'] as String;
      final physical = mappings[id] ?? id;
      final uri = Uri.parse(physical);
      Map<String, Object?> record;
      if (uri.scheme != 'file' || uri.hasQuery || uri.hasFragment) {
        record = {'id': physical, 'kind': 'denied'};
      } else {
        try {
          if (!saved) _verifyVirtualResource(physical);
          final path = uri.toFilePath(), capability = _policyCodeAccess(path);
          final buffer = !saved ? store.buffers[physical] : null;
          final description = await capability.describe(path);
          active();
          final before = metadata[physical];
          if (before != null && before.$2.identity != description.identity)
            throw CoreFailure(
              'policy.stale',
              'Code lookup metadata changed during review',
            );
          metadata[physical] = (path, description);
          final kind = buffer?.present == true ? 'file' : description.kind;
          record = {'id': physical, 'kind': kind};
          if (kind == 'file' && request['capability'] == 'content') {
            final source = await inputs.read(id, optional: true);
            active();
            record = source == null
                ? {'id': physical, 'kind': 'denied'}
                : {...source, 'kind': 'file'};
          }
        } on CoreFailure catch (error) {
          if (error.code == 'policy.stale' ||
              error.code == 'access.closed' ||
              error.code == 'cancelled' ||
              error.code.startsWith('limit.'))
            rethrow;
          record = {'id': physical, 'kind': 'denied'};
        } on FileSystemException {
          record = {'id': physical, 'kind': 'denied'};
        }
      }
      final before = resources[physical];
      if (before != null && before['kind'] != record['kind'])
        throw CoreFailure(
          'policy.stale',
          'Code resource presence changed during review',
        );
      resources[physical] = {
        ...?before,
        ...record,
        'aliases': {
          ...?before?['aliases'] as List?,
          ...?record['aliases'] as List?,
          if (physical != id) id,
        }.toList()..sort(),
      };
    }

    for (var round = 0; round < 128; round++) {
      active();
      final result = await engine.request('reviewPolicyCode', {
        'policy': {
          'entries': inputs.entries,
          'resources': inputs.resources.values.toList(),
        },
        'resources': resources.values.toList(),
        'scopes': scopes,
      }, requestId: requestId == null ? null : '$requestId-code-$round');
      active();
      final requests = result['requests'];
      if (result['version'] != 1 ||
          result['complete'] is! bool ||
          result['identity'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(result['identity'] as String) ||
          requests is! List ||
          requests.length > 2048 ||
          requests.any(
            (value) =>
                value is! Map ||
                value['id'] is! String ||
                (value['id'] as String).length > 16384 ||
                !['metadata', 'content'].contains(value['capability']),
          ) ||
          result['modules'] is! List ||
          (result['modules'] as List).length > 1024 ||
          result['bindings'] is! List ||
          (result['bindings'] as List).length > 4096 ||
          result['issues'] is! List ||
          (result['issues'] as List).length > 4096 ||
          result['complete'] == true &&
              (requests.isNotEmpty || (result['issues'] as List).isNotEmpty))
        throw CoreFailure(
          'policy.protocol',
          'Code dependency review returned malformed work',
        );
      if (requests.isEmpty) {
        final review = PolicyCodeReview._(
          this,
          root,
          saved,
          inputs,
          result,
          resources,
          metadata,
        );
        await verifyPolicyCodeReview(review, cancelled: cancelled);
        return review;
      }
      final before = textIdentity(jsonEncode(resources));
      await _resourceBatch(requests.cast<Map>(), acquire);
      if (resources.length > 2048 ||
          resources.values.fold<int>(
                0,
                (size, value) =>
                    size + ((value['text'] as String?)?.length ?? 0) * 2,
              ) >
              2 * 1024 * 1024)
        throw CoreFailure(
          'limit.policy.code.resources',
          'Code review exceeds its captured resource bound',
        );
      if (before == textIdentity(jsonEncode(resources)))
        throw CoreFailure(
          'policy.protocol',
          'Code review made no progress acquiring requested capabilities',
        );
    }
    throw CoreFailure(
      'limit.policy.code.closure',
      'Code dependency closure exceeds its bound',
    );
  }

  /// Revalidate every source and negative/directory observation before trust or
  /// execution. Source generations matter here, but not in reusable code trust.
  Future<void> verifyPolicyCodeReview(
    PolicyCodeReview review, {
    bool Function()? cancelled,
  }) async {
    void active() {
      if (_closed)
        throw CoreFailure('access.closed', 'Code review owner is closed');
      if (!identical(review._owner, this) ||
          review._inputs.revision != _resourceRevision)
        throw CoreFailure(
          'policy.stale',
          'Code review belongs to an earlier project context',
        );
      if (cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Code review was cancelled');
    }

    active();
    for (final entry in Map<String, Map<String, Object?>?>.from(
      review._inputs.observed,
    ).entries) {
      final source = await review._inputs.read(entry.key, optional: true);
      active();
      if (source?['identity'] != entry.value?['identity'] ||
          !review.saved && source?['generation'] != entry.value?['generation'])
        throw CoreFailure(
          'policy.stale',
          'Code or configuration changed after review',
        );
    }
    await _resourceBatch(review._metadata.values, (entry) async {
      final current = await _policyCodeAccess(entry.$1).describe(entry.$1);
      active();
      if (current.identity != entry.$2.identity)
        throw CoreFailure(
          'policy.stale',
          'Code lookup metadata changed after review',
        );
    });
    active();
  }
}
