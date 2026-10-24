part of 'project.dart';

enum RunPhase {
  preparing,
  ready,
  running,
  cancelling,
  cancelled,
  failed,
  complete,
  incomplete,
}

/// One-use cancellation ownership shared by request, OAuth, mock and test
/// work. Closing a project invalidates the higher-level owner; this token makes
/// the in-flight socket/process stop independently of presentation selection.
class RunCancellation {
  bool _cancelled = false;
  final Completer<void> _signal = Completer<void>();
  bool get cancelled => _cancelled;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _signal.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw CoreFailure('cancelled', 'Execution was cancelled');
  }
}

class ExecutionConfiguration {
  const ExecutionConfiguration({
    required this.environments,
    required this.tests,
    required this.mock,
    required this.comparison,
    this.source,
  });
  final Map<String, ExecutionEnvironment> environments;
  final List<Map<String, Object?>> tests;
  final Map<String, Object?> mock, comparison;
  final Map<String, Object?>? source;

  static ExecutionConfiguration parse(
    Map<String, Object?>? source,
    String boundary,
  ) {
    if (source == null) {
      return const ExecutionConfiguration(
        environments: {},
        tests: [],
        mock: {},
        comparison: {},
      );
    }
    Object? value;
    try {
      value = loadYaml(source['text'] as String);
    } on Object {
      throw CoreFailure(
        'manifest.syntax',
        'Project configuration has invalid or ambiguous syntax; inspect busyapi.yaml',
      );
    }
    if (value is! YamlMap || value['version'] != 1) {
      throw CoreFailure(
        'manifest.version',
        'Expected project configuration version 1',
      );
    }
    Object? plain(Object? input, [int depth = 0]) {
      if (depth > 32) {
        throw CoreFailure(
          'manifest.limit',
          'Execution configuration nesting exceeds 32 levels',
        );
      }
      if (input is YamlMap) {
        if (input.length > 2048 || input.keys.any((key) => key is! String)) {
          throw CoreFailure(
            'manifest.execution',
            'Execution configuration requires bounded string-keyed mappings',
          );
        }
        return <String, Object?>{
          for (final entry in input.entries)
            entry.key as String: plain(entry.value, depth + 1),
        };
      }
      if (input is YamlList) {
        if (input.length > 2048) {
          throw CoreFailure(
            'manifest.execution',
            'Execution configuration sequences exceed 2048 entries',
          );
        }
        return <Object?>[for (final item in input) plain(item, depth + 1)];
      }
      if (input == null || input is String || input is bool || input is num) {
        return input;
      }
      throw CoreFailure(
        'manifest.execution',
        'Execution configuration contains an unsupported value',
      );
    }

    Map<String, Object?> mapping(Object? input, String name) {
      final converted = plain(input);
      if (converted == null) return const {};
      if (converted is! Map<String, Object?>) {
        throw CoreFailure('manifest.execution', '$name must be a mapping');
      }
      return converted;
    }

    final environments = <String, ExecutionEnvironment>{};
    for (final entry in mapping(
      value['environments'],
      'environments',
    ).entries) {
      if (entry.key.isEmpty || entry.key.length > 128) {
        throw CoreFailure(
          'environment.name',
          'Environment names must contain 1 to 128 characters',
        );
      }
      final definition = entry.value;
      if (definition is! Map<String, Object?>) {
        throw CoreFailure(
          'environment.definition',
          'Each environment must be a mapping',
        );
      }
      environments[entry.key] = ExecutionEnvironment.parse(
        entry.key,
        definition,
        boundary,
      );
    }
    final rawTests = plain(value['tests']);
    if (rawTests != null && rawTests is! List) {
      throw CoreFailure('test.configuration', 'tests must be a sequence');
    }
    final tests = <Map<String, Object?>>[];
    for (final item in rawTests as List? ?? const []) {
      if (item is! Map<String, Object?>) {
        throw CoreFailure(
          'test.configuration',
          'Each contract test must be a mapping',
        );
      }
      tests.add(Map.unmodifiable(item));
    }
    return ExecutionConfiguration(
      environments: Map.unmodifiable(environments),
      tests: List.unmodifiable(tests),
      mock: Map.unmodifiable(mapping(value['mock'], 'mock')),
      comparison: Map.unmodifiable(mapping(value['comparison'], 'comparison')),
      source: source,
    );
  }
}

class ExecutionEnvironment {
  const ExecutionEnvironment({
    required this.name,
    required this.variables,
    required this.headers,
    required this.authentication,
    required this.tls,
    this.baseUrl,
  });
  final String name;
  final String? baseUrl;
  final Map<String, String> variables, headers;
  final Map<String, Object?> authentication, tls;

  static ExecutionEnvironment parse(
    String name,
    Map<String, Object?> value,
    String boundary,
  ) {
    String? optionalString(String key) {
      final item = value[key];
      if (item == null) return null;
      if (item is! String || item.length > 16384 || item.contains('\u0000')) {
        throw CoreFailure(
          'environment.value',
          'Environment $name has an invalid $key value',
        );
      }
      return item;
    }

    Map<String, String> strings(String key) {
      final item = value[key];
      if (item == null) return const {};
      if (item is! Map<String, Object?> || item.length > 512) {
        throw CoreFailure(
          'environment.value',
          'Environment $name $key must be a bounded mapping',
        );
      }
      final output = <String, String>{};
      for (final entry in item.entries) {
        if (entry.key.isEmpty ||
            entry.key.length > 1024 ||
            entry.value is! String ||
            (entry.value as String).length > 65536 ||
            (entry.value as String).contains('\u0000')) {
          throw CoreFailure(
            'environment.value',
            'Environment $name $key contains an invalid literal value',
          );
        }
        output[entry.key] = entry.value as String;
      }
      return Map.unmodifiable(output);
    }

    Map<String, Object?> objects(String key) {
      final item = value[key];
      if (item == null) return const {};
      if (item is! Map<String, Object?> || item.length > 512) {
        throw CoreFailure(
          'environment.value',
          'Environment $name $key must be a bounded mapping',
        );
      }
      return Map.unmodifiable(item);
    }

    final baseUrl = optionalString('baseUrl');
    if (baseUrl != null && baseUrl.isNotEmpty) {
      final parsed = Uri.tryParse(baseUrl);
      if (parsed == null ||
          !parsed.isAbsolute ||
          !const ['http', 'https'].contains(parsed.scheme) ||
          parsed.userInfo.isNotEmpty) {
        throw CoreFailure(
          'environment.base-url',
          'Environment $name baseUrl must be an absolute HTTP(S) URL without credentials',
        );
      }
    }
    final tls = objects('tls');
    for (final key in ['caFile', 'clientCertificateFile', 'clientKeyFile']) {
      final path = tls[key];
      if (path == null) continue;
      if (path is! String || path.isEmpty || path.length > 4096) {
        throw CoreFailure(
          'environment.tls',
          'Environment $name has an invalid $key path',
        );
      }
      // A declaration is only a name. Individual external-file capabilities
      // must still be granted by a picker or explicit headless input.
    }
    return ExecutionEnvironment(
      name: name,
      baseUrl: baseUrl,
      variables: strings('variables'),
      headers: strings('headers'),
      authentication: objects('authentication'),
      tls: tls,
    );
  }
}

class OperationRequestPlan {
  OperationRequestPlan._(
    this._owner,
    this.snapshot,
    this.configuration,
    this.result,
    this.saved,
    this._revision,
  );
  final BusyProject _owner;
  final AnalysisSnapshot snapshot;
  final ExecutionConfiguration configuration;
  final Map<String, dynamic> result;
  final bool saved;
  final int _revision;
  bool _closed = false;
  bool get closed => _closed;
  bool get outdated =>
      _owner._closed ||
      _revision != _owner._resourceRevision ||
      !saved && !snapshot.current(_owner.store);
  String get identity => result['identity'] as String;
  Map<String, dynamic> get operation =>
      Map<String, dynamic>.from(result['operation'] as Map);
  void close() => _closed = true;
  void ensureCurrentOwner() {
    if (_closed || _owner._closed) {
      throw CoreFailure(
        'request.closed',
        'The captured request owner is closed',
      );
    }
  }

  Future<Uint8List> readProjectFile(String relative) async {
    ensureCurrentOwner();
    final path = p.normalize(
      p.isAbsolute(relative)
          ? relative
          : p.join(_owner.access.boundary, relative),
    );
    final approved = _owner._executionFiles[path];
    final List<int> bytes;
    if (approved != null) {
      bytes = await approved.$1.read(path);
      if (contentIdentity(bytes) != approved.$2) {
        throw CoreFailure(
          'access.file.changed',
          'The selected TLS file changed; select it again before execution',
        );
      }
    } else {
      bytes = await _owner.access.read(_owner.access.pathFor(path));
    }
    if (bytes.length > 4 * 1024 * 1024) {
      throw CoreFailure('limit.tls.material', 'TLS material exceeds 4 MiB');
    }
    return Uint8List.fromList(bytes);
  }

  Future<Map<String, dynamic>> parameterValues(
    Map<String, String> values,
  ) async {
    ensureCurrentOwner();
    if (values.isEmpty) return const {};
    final result = await _owner.engine.request('requestParameterValues', {
      'values': values,
    });
    ensureCurrentOwner();
    if (result['version'] != 1 ||
        result['values'] is! Map ||
        (result['values'] as Map).length != values.length ||
        !(result['values'] as Map).keys.every(values.containsKey)) {
      throw CoreFailure(
        'request.value.protocol',
        'Invalid structured parameter projection',
      );
    }
    return Map<String, dynamic>.from(result['values'] as Map);
  }

  Future<RequestFormData> formData(
    String text, {
    required String requestId,
    RunCancellation? cancellation,
  }) async {
    final result = await _formProjection(
      'requestFormDataValues',
      {'text': text},
      requestId,
      cancellation,
    );
    return RequestFormData.fromJson(result, text);
  }

  List<FormPartMediaOptions> formMediaOptions(String? mediaType) {
    final body = result['requestBody'];
    final content = body is Map ? body['content'] : null;
    if (content is! List) return const [];
    final declaration = content
        .whereType<Map>()
        .where((item) => item['mediaType'] == mediaType)
        .singleOrNull;
    final form = declaration?['form'];
    return FormPartMediaOptions.fromJson(form is Map ? form['parts'] : null);
  }

  Future<ResolvedFormMediaTypes> formMediaTypes(
    String mediaType,
    Iterable<String> parts,
    Map<String, String> choices, {
    List<Map<String, String>> files = const [],
    required String requestId,
    RunCancellation? cancellation,
  }) async {
    final capturedParts = parts.toSet().toList(),
        selected = Map<String, String>.of(choices);
    final result = await _formProjection(
      'requestFormMediaTypes',
      {
        ...snapshot.toJson(),
        'resource': (operation['source'] as Map)['resource'],
        'pointer': (operation['source'] as Map)['pointer'],
        'occurrence': operation['occurrence'],
        'mediaType': mediaType,
        'parts': capturedParts,
        'choices': selected,
        'files': files,
      },
      requestId,
      cancellation,
    );
    final types = result['types'], fileTypes = result['files'];
    if (result['version'] != 1 ||
        result['snapshot'] != snapshot.identity ||
        result['identity'] != identity ||
        types is! Map ||
        types.keys.any(
          (name) =>
              name is! String ||
              !capturedParts.contains(name) && !selected.containsKey(name),
        ) ||
        types.values.any((value) => value is! String) ||
        fileTypes is! List ||
        fileTypes.length != files.length ||
        fileTypes.any((value) => value is! String)) {
      throw CoreFailure(
        'request.form.protocol',
        'Invalid resolved part media types.',
      );
    }
    return ResolvedFormMediaTypes(
      Map.unmodifiable(types.cast<String, String>()),
      List.unmodifiable(fileTypes.cast<String>()),
    );
  }

  Future<Map<String, MultipartPartEncoding>> multipartEncoding(
    String mediaType,
    List<Map<String, String>> parts,
    List<String> files, {
    required String requestId,
    RunCancellation? cancellation,
  }) async {
    final result = await _formProjection(
      'requestMultipartEncoding',
      {
        ...snapshot.toJson(),
        'resource': (operation['source'] as Map)['resource'],
        'pointer': (operation['source'] as Map)['pointer'],
        'occurrence': operation['occurrence'],
        'mediaType': mediaType,
        'parts': parts,
        'files': files,
      },
      requestId,
      cancellation,
    );
    final values = result['parts'];
    final names = {...parts.map((part) => part['name']), ...files};
    if (result['version'] != 1 ||
        result['snapshot'] != snapshot.identity ||
        result['identity'] != identity ||
        values is! Map ||
        values.length != names.length ||
        values.keys.any((name) => name is! String || !names.contains(name))) {
      throw CoreFailure(
        'request.multipart.protocol',
        'Invalid captured multipart transfer projection.',
      );
    }
    return Map.unmodifiable({
      for (final entry in values.entries)
        entry.key as String: MultipartPartEncoding.fromJson(entry.value),
    });
  }

  Future<Map<String, dynamic>> _formProjection(
    String method,
    Map<String, Object?> params,
    String requestId,
    RunCancellation? cancellation,
  ) async {
    ensureCurrentOwner();
    if (outdated)
      throw CoreFailure(
        'request.draft.stale',
        'Reconcile the changed operation before preparing form data.',
      );
    cancellation?.throwIfCancelled();
    final work = _owner.engine.request(method, params, requestId: requestId);
    final result = cancellation == null
        ? await work
        : await Future.any<Map<String, dynamic>>([
            work,
            cancellation.whenCancelled.then((_) async {
              await _owner.engine.cancel(requestId);
              throw CoreFailure(
                'cancelled',
                'Form preparation cancelled; late results are discarded.',
              );
            }),
          ]);
    cancellation?.throwIfCancelled();
    ensureCurrentOwner();
    if (outdated)
      throw CoreFailure(
        'request.draft.stale',
        'The operation changed during form preparation; no request was sent.',
      );
    return result;
  }

  Future<RefactoringPlan> planEnvironment(
    String name,
    Map<String, Object?> definition,
  ) async {
    ensureCurrentOwner();
    if (outdated) {
      throw CoreFailure(
        'refactor.stale',
        'Reconcile this request before changing configuration.',
      );
    }
    ExecutionEnvironment.parse(name, definition, _owner.access.boundary);
    final source = configuration.source;
    if (source == null) {
      final text =
          '${const JsonEncoder.withIndent('  ').convert({
            'version': 1,
            'roots': [
              for (final root in _owner.roots) {'name': root.name, 'path': p.relative(Uri.parse(root.id).toFilePath(), from: _owner.access.boundary)},
            ],
            'environments': {name: definition},
          })}\n';
      if (utf8.encode(text).length > 65536) {
        throw CoreFailure('limit.manifest', 'Configuration exceeds 64 KiB.');
      }
      final id = _owner._manifestResource;
      final creation = FileCreationPlan._(
        _owner,
        _revision,
        [snapshot],
        {
          'version': 1,
          'snapshot': snapshot.identity,
          'kind': 'execution-environment-create',
          'checkedRoots': [snapshot.root],
          'edits': <Object?>[],
          'usages': <Object?>[],
          'changes': [
            {
              'resource': id,
              'before': '',
              'after': text,
              'fileAction': 'create',
            },
          ],
          'from': {'resource': id, 'pointer': ''},
          'to': {'resource': id, 'pointer': ''},
        },
        BufferCreation(id: id, path: Uri.parse(id).toFilePath(), text: text),
      );
      await _owner._verifyFileCreation(creation);
      return creation;
    }
    final prepared = await _owner.engine.request('planExecutionEnvironment', {
      ...snapshot.toJson(),
      'source': source,
      'name': name,
      'definition': definition,
    });
    ensureCurrentOwner();
    if (outdated || prepared['snapshot'] != snapshot.identity) {
      throw CoreFailure(
        'refactor.stale',
        'Configuration changed while preparing its review.',
      );
    }
    return RefactoringPlan._(_owner, _revision, [snapshot], prepared);
  }

  Future<Map<String, dynamic>> inspectJson(String text) async {
    ensureCurrentOwner();
    return _owner.engine.request('inspectExecutionJson', {'text': text});
  }

  Future<Map<String, dynamic>> caseValues(String name) async {
    ensureCurrentOwner();
    final values = await _owner.engine.request('executionCaseValues', {
      'source': configuration.source,
      'name': name,
    });
    ensureCurrentOwner();
    return values;
  }

  Future<Map<String, dynamic>> evaluateRuntime(
    List<RuntimeSchemaInstance> instances, {
    String? requestId,
    RunCancellation? cancellation,
  }) async {
    ensureCurrentOwner();
    cancellation?.throwIfCancelled();
    final work = _owner.engine.request('evaluateSchemas', {
      ...snapshot.toJson(),
      'runtimeInstances': [for (final instance in instances) instance.toJson()],
    }, requestId: requestId);
    final result = cancellation == null
        ? await work
        : await Future.any<Map<String, dynamic>>([
            work,
            cancellation.whenCancelled.then((_) {
              if (requestId != null) unawaited(_owner.engine.cancel(requestId));
              throw CoreFailure(
                'cancelled',
                'Evaluation cancelled; late results are discarded.',
              );
            }),
          ]);
    cancellation?.throwIfCancelled();
    if (_closed ||
        _owner._closed ||
        result['version'] != 1 ||
        result['snapshot'] != snapshot.identity ||
        result['complete'] is! bool ||
        result['runtimeEvaluations'] is! List ||
        result['runtimeFindings'] is! List ||
        result['producer'] is! String ||
        result['producerVersion'] is! String) {
      throw CoreFailure(
        'runtime.protocol',
        'The schema worker returned an unrelated or malformed runtime result',
      );
    }
    return _freezeResult(result);
  }

  Future<RefactoringPlan> planResponseExample(
    String reviewedJson, {
    required int status,
    required List<(String, String)> headers,
    required bool receiptComplete,
    required bool redacted,
  }) async {
    ensureCurrentOwner();
    if (!receiptComplete) {
      throw CoreFailure(
        'example.incomplete',
        'A truncated, cancelled or timed-out response cannot be saved as a complete example',
      );
    }
    final contentType = headers
        .where((header) => header.$1.toLowerCase() == 'content-type')
        .map((header) => header.$2)
        .firstOrNull;
    if (contentType == null ||
        !(contentType.split(';').first.trim().toLowerCase() ==
                'application/json' ||
            contentType
                .split(';')
                .first
                .trim()
                .toLowerCase()
                .endsWith('+json'))) {
      throw CoreFailure(
        'example.media-type',
        'Only an explicitly reviewed JSON response can be saved as an authored example',
      );
    }
    Map? declaration = (result['responses'] as List)
        .whereType<Map>()
        .where((value) => value['status'] == '$status')
        .firstOrNull;
    declaration ??= (result['responses'] as List).whereType<Map>().where((
      value,
    ) {
      final declaredStatus = '${value['status']}'.toUpperCase();
      return RegExp(r'^[1-5]XX$').hasMatch(declaredStatus) &&
          declaredStatus.codeUnitAt(0) - 48 == status ~/ 100;
    }).firstOrNull;
    declaration ??= (result['responses'] as List)
        .whereType<Map>()
        .where((value) => '${value['status']}'.toLowerCase() == 'default')
        .firstOrNull;
    final media = selectDeclaredMedia(
      (declaration?['content'] as List? ?? const []).whereType<Map>(),
      contentType,
    );
    final target = media?['definition'];
    if (target is! Map ||
        target['resource'] is! String ||
        target['pointer'] is! String ||
        target['generation'] is! int ||
        target['range'] is! List) {
      throw CoreFailure(
        'example.destination',
        'The received status and media type have no current authored response destination',
      );
    }
    final prepared = await _owner.engine.request('planResponseExample', {
      ...snapshot.toJson(),
      'target': Map<String, dynamic>.from(target),
      'raw': reviewedJson,
      'mediaType': contentType.split(';').first.trim(),
      'redacted': redacted,
    });
    if (_closed ||
        _owner._closed ||
        _revision != _owner._resourceRevision ||
        !snapshot.current(_owner.store) ||
        prepared['snapshot'] != snapshot.identity) {
      throw CoreFailure(
        'refactor.stale',
        'The contract changed while preparing the response example review',
      );
    }
    return RefactoringPlan._(_owner, _revision, [snapshot], prepared);
  }
}

class RuntimeSchemaInstance {
  const RuntimeSchemaInstance({
    required this.subject,
    required this.location,
    required this.text,
    this.schemaResource,
    this.schemaPointer,
    this.itemSchemaResource,
    this.itemSchemaPointer,
    this.mediaType,
    this.mediaBase64 = false,
  });
  final String subject, location, text;
  final String? schemaResource, schemaPointer;
  final String? itemSchemaResource, itemSchemaPointer, mediaType;
  final bool mediaBase64;
  Map<String, Object?> toJson() => {
    'subject': subject,
    'location': location,
    'text': text,
    if (schemaResource != null)
      'schema': {'resource': schemaResource, 'pointer': schemaPointer},
    if (itemSchemaResource != null)
      'itemSchema': {
        'resource': itemSchemaResource,
        'pointer': itemSchemaPointer,
      },
    if (mediaType != null) 'mediaType': mediaType,
    if (mediaBase64) 'mediaBase64': true,
  };
}

extension RequestPlanning on BusyProject {
  Future<CapturedContractSnapshot> captureContractSnapshot(
    String root, {
    bool saved = false,
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    AnalysisSnapshot? captured;
    final result = await check(
      root,
      saved: saved,
      requestId: requestId,
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
      onSnapshot: (snapshot) => captured = snapshot,
    );
    if (captured == null) {
      throw CoreFailure(
        'snapshot.incomplete',
        'The selected contract did not produce a coherent snapshot',
      );
    }
    return CapturedContractSnapshot(
      snapshot: captured!,
      analysis: _freezeResult(result),
      saved: saved,
    );
  }

  Future<OperationRequestPlan> prepareRequest(
    String root, {
    required String resource,
    required String pointer,
    String? occurrence,
    bool saved = false,
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    AnalysisSnapshot? captured;
    final checked = await check(
      root,
      saved: saved,
      requestId: requestId == null ? null : '$requestId-check',
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
      onSnapshot: (snapshot) => captured = snapshot,
    );
    if (cancelled?.call() == true) {
      throw CoreFailure('cancelled', 'Request preparation was cancelled');
    }
    if (captured == null || checked['projection'] == null) {
      throw CoreFailure(
        'request.contract',
        'The captured contract could not produce an operation request plan',
      );
    }
    final snapshot = captured!, revision = _resourceRevision;
    final result = await engine.request('requestOperation', {
      ...snapshot.toJson(),
      'resource': resource,
      'pointer': pointer,
      if (occurrence != null) 'occurrence': occurrence,
    }, requestId: requestId == null ? null : '$requestId-plan');
    if (_closed ||
        cancelled?.call() == true ||
        result['snapshot'] != snapshot.identity ||
        result['version'] != 1 ||
        result['identity'] is! String ||
        result['complete'] != true ||
        result['operation'] is! Map ||
        result['servers'] is! List ||
        result['parameters'] is! List ||
        result['security'] is! Map ||
        result['responses'] is! List) {
      throw CoreFailure(
        'request.protocol',
        'The contract worker returned an unrelated or malformed request plan',
      );
    }
    final configuration = ExecutionConfiguration.parse(
      snapshot.configuration.singleOrNull,
      access.boundary,
    );
    return OperationRequestPlan._(
      this,
      snapshot,
      configuration,
      _freezeResult(result),
      saved,
      revision,
    );
  }
}

class CapturedContractSnapshot {
  const CapturedContractSnapshot({
    required this.snapshot,
    required this.analysis,
    required this.saved,
  });
  final AnalysisSnapshot snapshot;
  final Map<String, dynamic> analysis;
  final bool saved;
}
