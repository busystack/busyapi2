part of 'project.dart';

const _policySeverities = ['error', 'warning', 'information', 'hint'];
const _policyProducerVersion = '1.24.0+8';

/// Required categories dominate findings when aggregating CLI/GUI outcomes.
/// Display filters never enter this decision or mutate project configuration.
int lintExitCode(Map<String, dynamic> result) => result['complete'] != true
    ? 2
    : result['status'] == 'invalid'
    ? 1
    : 0;

class _PolicyInputs {
  _PolicyInputs(
    this.revision,
    this.observed,
    this.unavailable,
    this.resources,
    this.configurationSource,
    this.manifest,
    this.entries,
    this.threshold,
    this.dependenciesComplete,
    this.read,
  ) : identity = textIdentity(
        jsonEncode({
          'observed': [
            for (final id in observed.keys.toList()..sort())
              {
                'id': id,
                'identity': observed[id]?['identity'],
                'generation': observed[id]?['generation'],
              },
          ],
          'resources': [
            for (final id in resources.keys.toList()..sort())
              {'id': id, 'aliases': resources[id]?['aliases']},
          ],
          'entries': entries,
          'threshold': threshold,
          'unavailable': unavailable.toList()..sort(),
          'dependenciesComplete': dependenciesComplete,
        }),
      );
  final int revision;
  final Map<String, Map<String, Object?>?> observed;
  final Set<String> unavailable;
  final Map<String, Map<String, Object?>> resources;
  final String configurationSource, threshold, identity;
  final Map<String, Object?>? manifest;
  final List<String> entries;
  final bool dependenciesComplete;
  final Future<Map<String, Object?>?> Function(String, {bool optional}) read;
}

extension BusyProjectGovernance on BusyProject {
  // Acquisition/discovery only: never invokes governance or project code.
  // Both lint and file-impact reviews use this exact approved-source boundary.
  Future<_PolicyInputs> _capturePolicyInputs({
    required void Function() active,
    bool saved = false,
    List<String>? rulesets,
    String? failSeverity,
    String? requestId,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    active();
    final configuration = await _refreshResourceConfiguration(
      saved: saved,
      onResourceRefreshed: onResourceRefreshed,
    );
    active();
    final revision = _resourceRevision;
    final observed = <String, Map<String, Object?>?>{},
        unavailable = <String>{};
    final resources = <String, Map<String, Object?>>{};
    final configurationSource = Uri.file(
      p.join(access.boundary, 'busyapi.yaml'),
    ).toString();
    Future<Map<String, Object?>?> read(
      String id, {
      bool optional = false,
    }) async {
      active();
      final uri = Uri.parse(id);
      final mapped = configuration.mappings[id];
      final physical = mapped ?? id;
      if (Uri.parse(physical).scheme != 'file') {
        unavailable.add(id);
        observed[physical] = null;
        return null;
      }
      final path = Uri.parse(physical).toFilePath();
      try {
        if (!saved) _verifyVirtualResource(physical);
        final capability = accessFor(path), buffer = store.buffers[physical];
        if (optional &&
            (saved || buffer == null) &&
            await capability.missing(path)) {
          if (observed.containsKey(physical) && observed[physical] != null)
            throw CoreFailure(
              'policy.stale',
              'Rules or configuration disappeared during collection',
            );
          observed[physical] = null;
          return null;
        }
        Map<String, Object?> result;
        if (!saved && buffer != null) {
          if (!buffer.dirty && !buffer.externalConflict) {
            final before = (buffer.generation, buffer.externalConflict);
            await refreshDisk(buffer);
            if (before != (buffer.generation, buffer.externalConflict))
              onResourceRefreshed?.call(physical);
          }
          result = await buffer.snapshotAsync();
        } else {
          result = DocumentBuffer.decode(
            path,
            await capability.read(path),
          ).snapshot();
        }
        active();
        if ((result['text'] as String).length > 256 * 1024)
          throw CoreFailure(
            'limit.policy.configuration',
            'Ruleset resource exceeds 256 KiB',
          );
        if (observed.containsKey(physical) &&
            (observed[physical]?['identity'] != result['identity'] ||
                !saved &&
                    observed[physical]?['generation'] != result['generation']))
          throw CoreFailure(
            'policy.stale',
            'Rules or configuration changed during collection',
          );
        observed[physical] = result;
        return {
          ...result,
          if (mapped != null) 'aliases': [uri.toString()],
        };
      } on FileSystemException catch (error) {
        if (optional && error.osError?.errorCode == 2) {
          observed[physical] = null;
          return null;
        }
        unavailable.add(id);
        observed[physical] = null;
        return null;
      } on CoreFailure catch (error) {
        if (error.code.startsWith('limit.') ||
            error.code == 'policy.stale' ||
            error.code == 'cancelled' ||
            error.code == 'access.closed')
          rethrow;
        unavailable.add(id);
        observed[physical] = null;
        return null;
      }
    }

    final manifest = await read(configurationSource, optional: true);
    Object? settings;
    if (manifest != null) {
      try {
        final data = loadYaml(manifest['text'] as String);
        if (data is Map) settings = data['policy'];
      } on Object {
        throw CoreFailure(
          'policy.configuration',
          'Project governance configuration is invalid',
        );
      }
    }
    if (settings != null && settings is! Map)
      throw CoreFailure(
        'policy.configuration',
        'Project policy must be a settings mapping',
      );
    final configured = settings is Map ? settings : const <String, Object?>{};
    final configuredRulesets = configured['rulesets'];
    if (configuredRulesets != null &&
        (configuredRulesets is! List ||
            configuredRulesets.any((value) => value is! String)))
      throw CoreFailure(
        'policy.configuration',
        'Policy rulesets must be an ordered list of identities',
      );
    final threshold = failSeverity ?? configured['failSeverity'] ?? 'warning';
    if (threshold is! String || !_policySeverities.contains(threshold))
      throw CoreFailure(
        'policy.threshold',
        'Use error, warning, information or hint as the failure threshold',
      );
    final selected =
        rulesets ??
        (configuredRulesets == null
            ? null
            : List<String>.from(configuredRulesets as List));
    final entries = <String>[];
    if (selected != null) {
      for (final entry in selected) {
        if (entry.length > 4096)
          throw CoreFailure(
            'limit.policy.entry',
            'Ruleset identity exceeds its bound',
          );
        entries.add(
          ['busyapi:recommended', 'spectral:oas'].contains(entry)
              ? entry
              : Uri.directory('${access.boundary}/').resolve(entry).toString(),
        );
      }
    } else {
      for (final name in [
        '.spectral.yaml',
        '.spectral.yml',
        '.spectral.json',
        '.spectral.js',
        '.spectral.mjs',
        '.spectral.cjs',
      ]) {
        final id = Uri.file(p.join(access.boundary, name)).toString();
        final source = await read(id, optional: true);
        if (source != null) {
          resources[id] = source;
          entries.add(id);
        }
      }
      if (entries.length > 1)
        throw CoreFailure(
          'policy.ambiguous',
          'Several default rulesets exist; select an ordered ruleset list explicitly',
        );
      if (entries.isEmpty) entries.add('busyapi:recommended');
    }
    if (entries.length > 16)
      throw CoreFailure(
        'limit.policy.entries',
        'At most 16 ordered rulesets are supported',
      );
    var dependenciesComplete = false;
    for (var depth = 0; depth < 65; depth++) {
      active();
      final discovered = await engine.request(
        'discoverPolicy',
        {'entries': entries, 'resources': resources.values.toList()},
        requestId: requestId == null
            ? null
            : '$requestId-policy-discovery-$depth',
      );
      final requests = discovered['requests'], issues = discovered['issues'];
      if (discovered['version'] != 1 ||
          discovered['complete'] is! bool ||
          issues is! List ||
          issues.length > 256 ||
          issues.any(
            (value) =>
                value is! Map ||
                value['resource'] is! String ||
                (value['resource'] as String).length > 16384 ||
                !resources.values.any(
                  (resource) => resource['id'] == value['resource'],
                ) ||
                value['pointer'] is! String ||
                (value['pointer'] as String).length > 16384 ||
                value['code'] is! String ||
                !(value['code'] as String).startsWith('policy.dependencies.') ||
                (value['code'] as String).length > 128,
          ) ||
          requests is! List ||
          requests.length > 64 ||
          requests.any((value) => value is! String || value.length > 16384))
        throw CoreFailure(
          'policy.protocol',
          'Policy dependency discovery returned malformed identities',
        );
      dependenciesComplete = discovered['complete'] == true;
      if (dependenciesComplete && (requests.isNotEmpty || issues.isNotEmpty))
        throw CoreFailure(
          'policy.protocol',
          'Policy dependency discovery claimed completeness with pending work',
        );
      if (!dependenciesComplete && requests.isEmpty && issues.isEmpty)
        throw CoreFailure(
          'policy.protocol',
          'Policy dependency discovery returned no explanation for incomplete work',
        );
      final missing = requests
          .cast<String>()
          .where((id) => !unavailable.contains(id))
          .toList();
      if (missing.isEmpty) break;
      for (final id in missing) {
        if (resources.length >= 64)
          throw CoreFailure(
            'limit.policy.resources',
            'Governance exceeds 64 approved resources',
          );
        final resource = await read(id);
        if (resource != null) {
          final physical = resource['id'] as String,
              previous = resources[physical];
          resources[physical] = {
            ...resource,
            'aliases': {
              ...?previous?['aliases'] as List?,
              ...?resource['aliases'] as List?,
            }.toList()..sort(),
          };
        }
      }
      if (depth == 64)
        throw CoreFailure(
          'limit.policy.extends',
          'Governance dependency closure exceeds its bound',
        );
    }
    active();
    return _PolicyInputs(
      revision,
      observed,
      unavailable,
      resources,
      configurationSource,
      manifest,
      entries,
      threshold,
      dependenciesComplete,
      read,
    );
  }

  Future<Map<String, dynamic>> lint(
    String root, {
    bool saved = false,
    List<String>? rulesets,
    String? failSeverity,
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
    void Function(Map<String, dynamic> result)? onProgress,
    PolicyCodeApproval? codeApproval,
    void Function(AnalysisSnapshot snapshot)? onSnapshot,
  }) async {
    void active() {
      if (_closed)
        throw CoreFailure('access.closed', 'Governance owner is closed');
      if (cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Governance was cancelled');
    }

    active();
    if (codeApproval != null)
      await _verifyPolicyApproval(codeApproval, root, saved, consume: false);
    AnalysisSnapshot? captured;
    final checked = await check(
      root,
      saved: saved,
      requestId: requestId,
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
      onProgress: onProgress,
      onSnapshot: (snapshot) => captured = snapshot,
    );
    final snapshot = captured;
    if (snapshot != null) onSnapshot?.call(snapshot);
    if (snapshot == null || checked['contextSnapshot'] != snapshot.identity)
      throw CoreFailure(
        'policy.snapshot',
        'Governance has no coherent source snapshot',
      );
    final inputs = await _capturePolicyInputs(
      active: active,
      saved: saved,
      rulesets: rulesets,
      failSeverity: failSeverity,
      requestId: requestId,
      onResourceRefreshed: onResourceRefreshed,
    );
    final revision = inputs.revision,
        observed = inputs.observed,
        unavailable = inputs.unavailable,
        resources = inputs.resources,
        configurationSource = inputs.configurationSource,
        manifest = inputs.manifest,
        entries = inputs.entries,
        threshold = inputs.threshold,
        read = inputs.read;
    final monitored = {...observed, ...?codeApproval?.review._inputs.observed};
    _policyDependencies[root] = monitored.keys.toSet();
    _policyLookupKinds[root] = {
      if (codeApproval != null)
        for (final resource in codeApproval.review.resources)
          if (resource['text'] == null)
            resource['id'] as String: resource['kind'] as String,
    };
    for (final entry in monitored.entries) {
      final buffer = store.buffers[entry.key];
      if (!saved &&
          buffer != null &&
          (buffer.dirty || buffer.externalConflict)) {
        resourceFingerprints.putIfAbsent(entry.key, () => buffer.diskIdentity);
      } else {
        resourceFingerprints[entry.key] = entry.value?['identity'] as String?;
      }
    }
    onProgress?.call({
      ...checked,
      'complete': false,
      'status': 'checking',
      'categories': {
        ...Map<String, dynamic>.from(checked['categories'] as Map? ?? {}),
        'policy': {'complete': false, 'required': true, 'status': 'checking'},
      },
    });
    Map<String, dynamic>? policy;
    String? executionFailure;
    try {
      if (codeApproval != null) {
        if (inputs.identity != codeApproval.review._inputs.identity)
          throw CoreFailure(
            'policy.code.approval.changed',
            'Policy settings changed after code review',
          );
        await _verifyPolicyApproval(codeApproval, root, saved, consume: true);
        active();
      }
      policy = await engine.request('govern', {
        ...snapshot.toJson(),
        'policy': {
          'source': configurationSource,
          'entries': entries,
          'resources': resources.values.toList(),
          if (codeApproval != null)
            'execution': {
              'identity': codeApproval.review.identity,
              'scopes': codeApproval.review.result['scopes'],
              'resources': codeApproval.review.resources,
            },
        },
      }, requestId: requestId == null ? null : '$requestId-policy');
      active();
      final available = {
        for (final resource in [...snapshot.resources, ...resources.values])
          resource['id']: resource,
      };
      bool located(dynamic value) {
        if (value is! Map ||
            value['resource'] is! String ||
            value['pointer'] is! String ||
            (value['pointer'] as String).length > 16384)
          return false;
        final resource = available[value['resource']], range = value['range'];
        if (resource == null ||
            range is! List ||
            range.length != 2 ||
            !range.every((value) => value is int))
          return false;
        final start = range[0] as int, end = range[1] as int;
        return start >= 0 &&
            end >= start &&
            end <= (resource['text'] as String).length;
      }

      bool declarations(dynamic values) =>
          values is List &&
          values.length <= 512 &&
          values.every(
            (value) =>
                value is Map &&
                value['resource'] is String &&
                value['pointer'] is String &&
                (value['pointer'] as String).length <= 16384 &&
                ([
                      'busyapi:recommended',
                      'spectral:oas',
                    ].contains(value['resource']) ||
                    located(value)),
          );
      bool validRule(dynamic value) =>
          value is Map &&
          value['name'] is String &&
          (value['name'] as String).length <= 128 &&
          [..._policySeverities, 'off'].contains(value['severity']) &&
          value['enabled'] is bool &&
          value['resolved'] is bool &&
          value['applicable'] is bool &&
          value['given'] is List &&
          (value['given'] as List).length <= 20000 &&
          (value['given'] as List).every(
            (expression) => expression is String && expression.length <= 16384,
          ) &&
          declarations(value['provenance']);

      if (policy['version'] != 1 ||
          policy['snapshot'] != snapshot.identity ||
          policy['complete'] is! bool ||
          policy['producer'] != 'spectral+busyapi-graph' ||
          policy['producerVersion'] != _policyProducerVersion ||
          policy['configuration'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$')
              .hasMatch(policy['configuration'] as String) ||
          policy['effectiveRules'] is! List ||
          (policy['effectiveRules'] as List).length > 1024 ||
          !(policy['effectiveRules'] as List).every(validRule) ||
          policy['findings'] is! List ||
          (policy['findings'] as List).length > 10000 ||
          !(policy['findings'] as List).every(
            (value) =>
                located(value) &&
                value['category'] == 'policy' &&
                value['root'] == root &&
                value['snapshot'] == snapshot.identity &&
                value['code'] is String &&
                (value['code'] as String).length <= 256 &&
                value['message'] is String &&
                (value['message'] as String).length <= 4096 &&
                _policySeverities.contains(value['severity']),
          ))
        throw CoreFailure(
          'policy.protocol',
          'Governance returned a malformed or unlocated result',
        );
    } on Object catch (error) {
      active();
      executionFailure = error is CoreFailure
          ? error.code
          : 'policy.execution.failed';
      policy = null;
    }
    // Re-collect actual API dependencies and every observed configuration,
    // including missing default candidates. No stale result becomes current.
    AnalysisSnapshot? verification;
    await check(
      root,
      saved: saved,
      schemaEvaluation: false,
      cancelled: cancelled,
      requestId: requestId == null ? null : '$requestId-policy-verify',
      onResourceRefreshed: onResourceRefreshed,
      onSnapshot: (value) => verification = value,
    );
    if (verification?.identity != snapshot.identity ||
        revision != _resourceRevision)
      throw CoreFailure(
        'policy.stale',
        'Source changed while governance was running',
      );
    for (final entry in Map<String, Map<String, Object?>?>.from(
      observed,
    ).entries) {
      final current = await read(entry.key, optional: true);
      if (current?['identity'] != entry.value?['identity'] ||
          !saved && current?['generation'] != entry.value?['generation'])
        throw CoreFailure(
          'policy.stale',
          'Rules or configuration changed while governance was running',
        );
    }
    active();
    if (codeApproval != null) {
      await verifyPolicyCodeReview(codeApproval.review, cancelled: cancelled);
      final runtime = await engine.request('policyRuntime', {});
      if (runtime['identity'] != codeApproval.runtimeIdentity)
        throw CoreFailure(
          'policy.stale',
          'Isolated governance runtime changed during execution',
        );
      active();
    }
    final configuration = textIdentity(
      jsonEncode({
        'rules': policy?['configuration'],
        'threshold': threshold,
        'manifest': manifest?['identity'],
        'entries': entries,
        'unavailable': unavailable.toList()..sort(),
      }),
    );
    final identity = textIdentity(
      jsonEncode({
        'source': snapshot.sourceIdentity,
        'configuration': configuration,
      }),
    );
    final findings = <dynamic>[
      for (final finding in checked['findings'] as List)
        {...Map<String, dynamic>.from(finding as Map), 'snapshot': identity},
      for (final finding in policy?['findings'] as List? ?? const [])
        {
          ...Map<String, dynamic>.from(finding as Map),
          'snapshot': identity,
          'configuration': configuration,
        },
      if (executionFailure != null)
        {
          'version': 1,
          'category': 'policy',
          'root': root,
          'resource': root,
          'pointer': '',
          'range': [0, 0],
          'code': 'policy.execution.incomplete',
          'severity': 'error',
          'message': 'Required governance execution did not complete. No clean policy result is inferred.',
          'producer': 'busyapi',
          'producerVersion': '0.1.0',
          'snapshot': identity,
          'failureCode': executionFailure,
        },
    ];
    final complete =
        checked['complete'] == true &&
        policy?['complete'] == true &&
        unavailable.isEmpty;
    final invalid = findings.any(
      (finding) => finding['category'] == 'policy'
          ? _policySeverities.indexOf(finding['severity'] as String) <=
                _policySeverities.indexOf(threshold)
          : finding['severity'] == 'error',
    );
    return {
      ...checked,
      'snapshot': identity,
      'sourceSnapshot': snapshot.sourceIdentity,
      'configuration': configuration,
      'complete': complete,
      'status': !complete
          ? 'incomplete'
          : invalid
          ? 'invalid'
          : 'complete',
      'unsaved':
          checked['unsaved'] == true ||
          !saved &&
              resources.keys.any((id) => store.buffers[id]?.dirty == true),
      'findings': findings,
      'effectiveRules': policy?['effectiveRules'] ?? const [],
      'policyResources': [
        for (final resource in resources.values)
          {
            for (final key in ['id', 'generation', 'identity'])
              key: resource[key],
          },
      ],
      'categories': {
        ...Map<String, dynamic>.from(checked['categories'] as Map? ?? {}),
        'policy': {
          'complete': policy?['complete'] == true && unavailable.isEmpty,
          'required': true,
          'status': policy?['complete'] == true && unavailable.isEmpty
              ? 'complete'
              : 'incomplete',
          'producer': policy?['producer'] ?? 'spectral+busyapi-graph',
          'producerVersion':
              policy?['producerVersion'] ?? _policyProducerVersion,
          'snapshot': identity,
          'configuration': configuration,
          'failSeverity': threshold,
          'coverage': policy?['coverage'] ?? 'incomplete',
          'unavailableResources': unavailable.length,
        },
      },
    };
  }
}
