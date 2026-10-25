import 'model.dart';
import 'project.dart';
import 'request.dart';
import 'form_media_types.dart';

class ContractCaseResult {
  const ContractCaseResult({
    required this.name,
    required this.operation,
    required this.snapshot,
    required this.status,
    required this.complete,
    required this.passed,
    required this.findings,
    required this.dispatched,
    this.responseStatus,
    this.mediaType,
    this.bodyIdentity,
    this.bodyLength,
    this.elapsed = Duration.zero,
    this.operationalFailure = false,
  });
  final String name, operation, snapshot, status;
  final bool complete, passed;
  final int? responseStatus, bodyLength;
  final String? mediaType, bodyIdentity;
  final Duration elapsed;
  final bool operationalFailure;
  final bool dispatched;
  final List<Map<String, Object?>> findings;
  Map<String, Object?> toJson() => {
    'name': name,
    'operation': operation,
    'snapshot': snapshot,
    'status': status,
    'complete': complete,
    'passed': passed,
    'dispatched': dispatched,
    'operationalFailure': operationalFailure,
    if (responseStatus != null) 'responseStatus': responseStatus,
    if (mediaType != null) 'mediaType': mediaType,
    if (bodyIdentity != null) 'bodyIdentity': bodyIdentity,
    if (bodyLength != null) 'bodyLength': bodyLength,
    'findings': findings,
  };
}

class ContractTestReport {
  const ContractTestReport({
    required this.snapshot,
    required this.complete,
    required this.passed,
    required this.cases,
    required this.executedOperations,
    required this.untestedOperations,
    this.saved = true,
  });
  final String snapshot;
  final bool complete, passed;
  final bool saved;
  final List<ContractCaseResult> cases;
  final List<String> executedOperations, untestedOperations;
  Map<String, Object?> toJson() => {
    'version': 1,
    'status': !complete
        ? 'incomplete'
        : passed
        ? 'complete'
        : 'failed',
    'complete': complete,
    'passed': passed,
    'snapshot': snapshot,
    'input': saved ? 'saved-source' : 'working-buffers',
    'unsaved': !saved,
    'producer': 'busyapi-contract-tests',
    'producerVersion': '1',
    'cases': cases.map((value) => value.toJson()).toList(),
    'executedOperations': executedOperations,
    'untestedOperations': untestedOperations,
    'coverage': {
      'selection': 'explicit-cases-only',
      'execution': 'transport-dispatched-attempts',
      'transport': 'native-dart-http',
      'schema': 'busyapi-contract-engine',
      'exhaustive': false,
    },
  };
}

class ContractTestRunner {
  const ContractTestRunner({this.executor = const ContractRequestExecutor()});
  final ContractRequestExecutor executor;

  Future<ContractTestReport> run(
    BusyProject project,
    String root, {
    required List<String> selectedCases,
    required SecretResolver resolveSecret,
    String? environment,
    RunCancellation? cancellation,
    bool saved = true,
    String? expectedSourceIdentity,
  }) async {
    if (selectedCases.isEmpty) {
      throw CoreFailure(
        'test.selection',
        'Select one or more named contract test cases; BusyAPI does not sweep operations automatically',
      );
    }
    final captured = await project.captureContractSnapshot(
      root,
      saved: saved,
      cancelled: () => cancellation?.cancelled == true,
    );
    cancellation?.throwIfCancelled();
    if (expectedSourceIdentity != null &&
        captured.snapshot.sourceIdentity != expectedSourceIdentity) {
      throw CoreFailure(
        'test.snapshot.changed',
        'The contract or configuration changed after case selection; reopen the test selection before executing.',
      );
    }
    final configuration = ExecutionConfiguration.parse(
      captured.snapshot.configuration.singleOrNull,
      project.access.boundary,
    );
    final definitions = <String, Map<String, Object?>>{};
    for (final item in configuration.tests) {
      final name = item['name'];
      if (name is! String || name.isEmpty || definitions.containsKey(name)) {
        throw CoreFailure(
          'test.configuration',
          'Every contract test requires a unique non-empty name',
        );
      }
      definitions[name] = item;
    }
    for (final name in selectedCases) {
      if (!definitions.containsKey(name)) {
        throw CoreFailure(
          'test.selection',
          'Configured test case $name was not found',
        );
      }
    }
    // Validate the entire selected run before its first network operation.
    for (final name in selectedCases) {
      _validateDefinition(
        definitions[name]!,
        configuration.tests.indexOf(definitions[name]!),
      );
    }
    final exactCases = <String, Map<String, dynamic>>{};
    for (final name in selectedCases) {
      cancellation?.throwIfCancelled();
      exactCases[name] = await project.engine.request('executionCaseValues', {
        'source': configuration.source,
        'name': name,
      });
    }
    final projection = captured.analysis['projection'];
    final operations = projection is Map && projection['operations'] is List
        ? (projection['operations'] as List).whereType<Map>().toList()
        : const <Map>[];
    final results = <ContractCaseResult>[], executed = <String>{};
    for (final name in selectedCases) {
      cancellation?.throwIfCancelled();
      final definition = definitions[name]!;
      Map? selected;
      final operation = definition['operation'];
      if (operation is Map) {
        if (operation['occurrence'] is String) {
          selected = operations
              .where(
                (candidate) =>
                    candidate['occurrence'] == operation['occurrence'],
              )
              .singleOrNull;
        } else {
          final candidates = operations
              .where(
                (candidate) =>
                    candidate['role'] == 'operation' &&
                    candidate['path'] == operation['path'],
              )
              .toList();
          // A custom token can differ from a fixed method only by case. Prefer
          // exact wire identity before normalizing an existing fixed-field name.
          selected = candidates
              .where(
                (candidate) =>
                    httpOperationMethod(candidate) == operation['method'],
              )
              .singleOrNull;
          selected ??= candidates
              .where(
                (candidate) =>
                    candidate['customMethod'] != true &&
                    httpOperationMethod(candidate) ==
                        '${operation['method']}'.toUpperCase(),
              )
              .singleOrNull;
        }
      }
      if (selected == null ||
          selected['resource'] is! String ||
          selected['pointer'] is! String) {
        results.add(
          _failedCase(
            name,
            'unresolved operation',
            captured.snapshot.identity,
            'test.operation',
            'The configured operation is not uniquely available in the captured contract.',
          ),
        );
        continue;
      }
      final label = '${httpOperationMethod(selected)} ${selected['path']}';
      final operationIdentity = selected['occurrence']?.toString() ?? label;
      var dispatched = false;
      OperationRequestPlan? plan;
      final clock = Stopwatch()..start();
      try {
        plan = await project.prepareRequest(
          root,
          resource: selected['resource'] as String,
          pointer: selected['pointer'] as String,
          occurrence: selected['occurrence'] as String?,
          saved: saved,
          requestId:
              'test-${captured.snapshot.identity.substring(0, 12)}-$name',
          cancelled: () => cancellation?.cancelled == true,
        );
        if (plan.snapshot.sourceIdentity != captured.snapshot.sourceIdentity) {
          throw CoreFailure(
            'test.snapshot.changed',
            'Project input changed while the selected test run was being captured',
          );
        }
        final draft = _draft(plan, definition, environment, exactCases[name]!);
        final result = await executor.execute(
          plan,
          draft,
          resolveSecret: resolveSecret,
          cancellation: cancellation,
          onRequestDispatched: () {
            dispatched = true;
            executed.add(operationIdentity);
          },
        );
        try {
          results.add(_assert(name, label, definition, result, clock.elapsed));
        } finally {
          await result.close();
        }
      } on CoreFailure catch (failure) {
        if (failure.code == 'cancelled') rethrow;
        results.add(
          _failedCase(
            name,
            label,
            plan?.snapshot.identity ?? captured.snapshot.identity,
            failure.code,
            failure.message,
            source: failure.source,
            elapsed: clock.elapsed,
            dispatched: dispatched,
            complete:
                !failure.code.startsWith('runtime.') &&
                !failure.code.contains('timeout') &&
                !failure.code.contains('transport') &&
                !failure.unsupported,
            operationalFailure: !failure.unsupported,
          ),
        );
      } finally {
        plan?.close();
      }
    }
    final all = operations
        .map(
          (value) =>
              value['occurrence']?.toString() ??
              '${httpOperationMethod(value)} ${value['path']}',
        )
        .toSet();
    return ContractTestReport(
      snapshot: captured.snapshot.identity,
      complete: results.isNotEmpty && results.every((value) => value.complete),
      passed: results.isNotEmpty && results.every((value) => value.passed),
      cases: List.unmodifiable(results),
      executedOperations: List.unmodifiable(executed),
      untestedOperations: List.unmodifiable(
        (all..removeAll(executed)).toList(),
      ),
      saved: saved,
    );
  }

  static void _validateDefinition(Map<String, Object?> value, int index) {
    Never invalid(String path, String explanation) => throw CoreFailure(
      'test.configuration',
      'busyapi.yaml /tests/$index/$path: $explanation',
    );
    void strings(Object? value, String path, {bool allowEmpty = false}) {
      if (value is! Map ||
          !allowEmpty && value.isEmpty ||
          value.length > 512 ||
          value.entries.any(
            (e) =>
                e.key is! String ||
                (e.key as String).isEmpty ||
                e.value is! String,
          ))
        invalid(
          path,
          'Expected a non-empty bounded mapping of literal strings.',
        );
    }

    final operation = value['operation'];
    if (operation is! Map ||
        !(operation['occurrence'] is String &&
                (operation['occurrence'] as String).isNotEmpty ||
            operation['method'] is String &&
                (operation['method'] as String).isNotEmpty &&
                operation['path'] is String &&
                (operation['path'] as String).startsWith('/')))
      invalid('operation', 'Choose an occurrence or method/path.');
    for (final field in ['occurrence', 'method', 'path']) {
      if (operation.containsKey(field) &&
          (operation[field] is! String ||
              (operation[field] as String).isEmpty ||
              field == 'path' &&
                  !(operation[field] as String).startsWith('/'))) {
        invalid(
          'operation/$field',
          'Expected a non-empty operation selector string.',
        );
      }
    }
    for (final key in ['environment']) {
      if (value.containsKey(key) &&
          (value[key] is! String || (value[key] as String).isEmpty))
        invalid(key, 'Expected a non-empty string.');
    }
    for (final key in ['server', 'securityAlternative']) {
      if (value.containsKey(key) &&
          (value[key] is! int ||
              (value[key] as int) < 0 ||
              (value[key] as int) >= 2048))
        invalid(key, 'Expected a selection index between 0 and 2047.');
    }
    for (final key in [
      'connectTimeoutMs',
      'overallTimeoutMs',
      'inactivityTimeoutMs',
    ]) {
      if (value.containsKey(key) &&
          (value[key] is! int ||
              (value[key] as int) <= 0 ||
              (value[key] as int) > 600000))
        invalid(key, 'Expected 1–600000 milliseconds.');
    }
    for (final key in ['headers', 'variables']) {
      if (value.containsKey(key)) strings(value[key], key, allowEmpty: true);
    }
    if (value.containsKey('parameters')) {
      final parameters = value['parameters'];
      if (parameters is! Map)
        invalid('parameters', 'Expected a location mapping.');
      for (final entry in parameters.entries) {
        if (!const [
              'path',
              'query',
              'querystring',
              'header',
              'cookie',
            ].contains(entry.key) ||
            entry.value is! Map ||
            (entry.value as Map).keys.any((k) => k is! String || k.isEmpty))
          invalid(
            'parameters/${entry.key}',
            'Expected a supported location with named typed values.',
          );
      }
    }
    if (value.containsKey('body')) {
      final body = value['body'];
      if (body is! Map ||
          body['mediaType'] is! String ||
          (body['mediaType'] as String).isEmpty ||
          !body.containsKey('value'))
        invalid('body', 'Expected mediaType and a typed value.');
      if (body.containsKey('partMediaTypes')) {
        strings(
          body['partMediaTypes'],
          'body/partMediaTypes',
          allowEmpty: true,
        );
        if (![
              'multipart/form-data',
              'application/x-www-form-urlencoded',
            ].contains(
              (body['mediaType'] as String)
                  .split(';')
                  .first
                  .trim()
                  .toLowerCase(),
            ) ||
            body['value'] is! Map)
          invalid(
            'body/partMediaTypes',
            'Part media choices require object-valued form data.',
          );
      }
    }
    if (!value.containsKey('expect')) return;
    final expect = value['expect'];
    if (expect is! Map ||
        expect.isEmpty ||
        expect.keys.any((k) => !['status', 'mediaType', 'headers'].contains(k)))
      invalid('expect', 'Expected status, mediaType or headers assertions.');
    if (expect.containsKey('status')) {
      final status = expect['status'];
      bool valid(Object? v) => v is int && v >= 100 && v <= 599;
      if (!(valid(status) ||
          status is List &&
              status.isNotEmpty &&
              status.length <= 128 &&
              status.every(valid)))
        invalid(
          'expect/status',
          'Expected an HTTP status integer or a non-empty list of HTTP status integers.',
        );
    }
    if (expect.containsKey('mediaType') &&
        (expect['mediaType'] is! String ||
            (expect['mediaType'] as String).isEmpty))
      invalid('expect/mediaType', 'Expected a media type string.');
    if (expect.containsKey('headers')) {
      strings(expect['headers'], 'expect/headers');
      for (final entry in (expect['headers'] as Map).entries) {
        if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
                .hasMatch(entry.key as String) ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value as String))
          invalid(
            'expect/headers',
            'Header assertions require valid field names and literal field values.',
          );
      }
    }
  }

  static OperationRequestDraft _draft(
    OperationRequestPlan plan,
    Map<String, Object?> definition,
    String? environmentOverride,
    Map<String, dynamic> exact,
  ) {
    final parameters = <String, RequestValue>{};
    final headers = <RequestHeaderValue>[];
    if (definition['headers'] is Map) {
      for (final entry in (definition['headers'] as Map).entries) {
        if (entry.key is String && entry.value is String) {
          headers.add(
            RequestHeaderValue(entry.key as String, entry.value as String),
          );
        }
      }
    }
    RequestBodyDraft body = const RequestBodyDraft.none();
    final rawBody = definition['body'];
    for (final entry in (exact['parameters'] as Map).entries) {
      final value = entry.value as Map;
      parameters[entry.key as String] = value['json'] == true
          ? RequestValue.json(value['text'] as String)
          : RequestValue.text(value['text'] as String);
    }
    if (rawBody is Map && exact['body'] is Map) {
      final media = rawBody['mediaType'] as String,
          text = exact['body']['text'] as String;
      final partMediaTypes = rawBody['partMediaTypes'] is Map
          ? (rawBody['partMediaTypes'] as Map).cast<String, String>()
          : const <String, String>{};
      body = exact['body']['json'] == true
          ? switch (plan.formBindingForMedia(media)) {
              RequestFormBinding.urlEncoded => RequestBodyDraft.formValue(
                json: text,
                mediaType: media,
                partMediaTypes: partMediaTypes,
              ),
              RequestFormBinding.namedMultipart =>
                RequestBodyDraft.multipartValue(
                  json: text,
                  mediaType: media,
                  partMediaTypes: partMediaTypes,
                ),
              null => RequestBodyDraft.raw(mediaType: media, text: text),
            }
          : RequestBodyDraft.raw(mediaType: media, text: text);
    }
    return OperationRequestDraft(
      planIdentity: plan.identity,
      environment: environmentOverride ?? definition['environment'] as String?,
      server: definition['server'] is int ? definition['server'] as int : 0,
      securityAlternative: definition['securityAlternative'] as int?,
      parameters: Map.unmodifiable(parameters),
      headers: List.unmodifiable(headers),
      variables: definition['variables'] is Map
          ? Map.unmodifiable({
              for (final entry in (definition['variables'] as Map).entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            })
          : const {},
      body: body,
      connectTimeout: Duration(
        milliseconds: definition['connectTimeoutMs'] is int
            ? definition['connectTimeoutMs'] as int
            : 15000,
      ),
      overallTimeout: Duration(
        milliseconds: definition['overallTimeoutMs'] is int
            ? definition['overallTimeoutMs'] as int
            : 60000,
      ),
      inactivityTimeout: Duration(
        milliseconds: definition['inactivityTimeoutMs'] is int
            ? definition['inactivityTimeoutMs'] as int
            : 15000,
      ),
    );
  }

  static ContractCaseResult _assert(
    String name,
    String operation,
    Map<String, Object?> definition,
    ContractRequestResult result,
    Duration elapsed,
  ) {
    final findings = <Map<String, Object?>>[
      ...result.outgoing.findings,
      ...result.received.findings,
    ];
    final expected = definition['expect'];
    if (expected is Map) {
      final statuses = expected['status'] is List
          ? (expected['status'] as List).whereType<int>().toSet()
          : expected['status'] is int
          ? {expected['status'] as int}
          : <int>{};
      if (statuses.isNotEmpty && !statuses.contains(result.response.status)) {
        findings.add({
          'code': 'test.response.status',
          'severity': 'error',
          'message':
              'Expected HTTP ${statuses.join(' or ')}, received ${result.response.status}.',
          'location': 'status',
        });
      }
      if (expected['mediaType'] is String) {
        final actual = _contentType(result.response.headers);
        if (actual != (expected['mediaType'] as String).toLowerCase()) {
          findings.add({
            'code': 'test.response.media-type',
            'severity': 'error',
            'message':
                'Expected ${expected['mediaType']}, received ${actual ?? 'no Content-Type'}.',
            'location': 'headers:content-type',
          });
        }
      }
      if (expected['headers'] is Map) {
        final actual = <String, List<String>>{};
        for (final header in result.response.headers) {
          actual.putIfAbsent(header.$1.toLowerCase(), () => []).add(header.$2);
        }
        for (final header in (expected['headers'] as Map).entries) {
          if (header.key is String &&
              header.value is String &&
              !(actual[(header.key as String).toLowerCase()] ?? const [])
                  .contains(header.value)) {
            findings.add({
              'code': 'test.response.header',
              'severity': 'error',
              'message': 'Expected response header ${header.key}.',
              'location': 'headers:${header.key}',
            });
          }
        }
      }
    }
    final complete =
        result.response.receiptComplete &&
        result.outgoing.complete &&
        result.received.complete;
    final passed =
        complete && findings.every((value) => value['severity'] != 'error');
    return ContractCaseResult(
      name: name,
      operation: operation,
      snapshot: result.request.plan.snapshot.identity,
      status: passed
          ? 'passed'
          : complete
          ? 'failed'
          : 'incomplete',
      complete: complete,
      passed: passed,
      dispatched: true,
      responseStatus: result.response.status,
      mediaType: _contentType(result.response.headers),
      bodyIdentity: result.response.bodyIdentity,
      bodyLength: result.response.bodyLength,
      findings: List.unmodifiable(findings),
      elapsed: elapsed,
    );
  }

  static ContractCaseResult _failedCase(
    String name,
    String operation,
    String snapshot,
    String code,
    String message, {
    bool complete = true,
    bool operationalFailure = true,
    bool dispatched = false,
    CoreFailureSource? source,
    Duration elapsed = Duration.zero,
  }) => ContractCaseResult(
    name: name,
    operation: operation,
    snapshot: snapshot,
    status: complete ? 'failed' : 'incomplete',
    complete: complete,
    passed: false,
    elapsed: elapsed,
    operationalFailure: operationalFailure,
    dispatched: dispatched,
    findings: [
      {
        'code': code,
        'severity': 'error',
        'message': message,
        if (source != null) ...{
          'resource': source.resource,
          'pointer': source.pointer,
          'range': [source.range.start, source.range.end],
        },
      },
    ],
  );

  static String? _contentType(List<(String, String)> headers) {
    final value = headers
        .where((header) => header.$1.toLowerCase() == 'content-type')
        .map((header) => header.$2)
        .firstOrNull;
    return value?.split(';').first.trim().toLowerCase();
  }
}
