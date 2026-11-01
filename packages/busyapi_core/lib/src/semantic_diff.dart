import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'engine_process.dart';
import 'model.dart';
import 'project.dart';

enum SemanticChangeSeverity { breaking, potentiallyBreaking, unclassified }

class SemanticChange {
  const SemanticChange({
    required this.rule,
    required this.severity,
    required this.message,
    this.path,
    this.method,
    this.operationId,
    this.before,
    this.after,
    this.source,
    this.details = const {},
  });
  final String rule, message;
  final SemanticChangeSeverity severity;
  final String? path, method, operationId;
  final Map<String, Object?>? before, after, source;
  final Map<String, Object?> details;
  Map<String, Object?> toJson() => {
    'rule': rule,
    'severity': severity.name,
    'message': message,
    if (path != null) 'path': path,
    if (method != null) 'method': method,
    if (operationId != null) 'operationId': operationId,
    if (before != null) 'before': before,
    if (after != null) 'after': after,
    if (source != null) 'source': source,
    if (details.isNotEmpty) 'details': details,
  };
}

class SemanticReview {
  const SemanticReview({
    required this.baseline,
    required this.current,
    required this.toolVersion,
    required this.complete,
    required this.changes,
    required this.rawDiff,
    required this.diff,
    required this.coverage,
    required this.baselineText,
    required this.currentText,
  });
  final AnalysisSnapshot baseline, current;
  final String toolVersion, rawDiff, baselineText, currentText;
  final bool complete;
  final List<SemanticChange> changes;
  final Map<String, dynamic> diff;
  final Map<String, Object?> coverage;
  bool get breaking => changes.any(
    (change) => change.severity == SemanticChangeSeverity.breaking,
  );
  bool get potentiallyBreaking => changes.any(
    (change) => change.severity == SemanticChangeSeverity.potentiallyBreaking,
  );
  Map<String, Object?> toJson() => {
    'version': 1,
    'status': !complete
        ? 'incomplete'
        : breaking
        ? 'breaking'
        : potentiallyBreaking
        ? 'potentially-breaking'
        : 'compatible',
    'complete': complete,
    'baseline': baseline.sourceIdentity,
    'current': current.sourceIdentity,
    'producer': 'oasdiff',
    'producerVersion': toolVersion,
    'coverage': coverage,
    'changes': changes.map((change) => change.toJson()).toList(),
    'rawDiff': rawDiff,
    'diff': diff,
  };
  String summary() {
    final lines = <String>[
      'BusyAPI semantic review',
      'Baseline: ${baseline.sourceIdentity}',
      'Current: ${current.sourceIdentity}',
      'oasdiff: $toolVersion',
      'Coverage: ${complete ? 'complete for qualified cases' : 'incomplete; see unclassified coverage'}',
      '',
    ];
    for (final change in changes) {
      lines.add(
        '${change.severity.name}: ${change.rule}${change.method == null ? '' : ' ${change.method}'}${change.path == null ? '' : ' ${change.path}'} — ${change.message}',
      );
    }
    if (changes.isEmpty) lines.add('No semantic changes reported.');
    return '${lines.join('\n')}\n';
  }
}

class OasdiffAdapter {
  OasdiffAdapter({String? executable})
    : executable = executable ?? bundledExecutable();
  final String executable;

  static String bundledExecutable({String? applicationExecutable}) {
    final app = applicationExecutable ?? Platform.resolvedExecutable;
    return p.join(p.dirname(app), 'libexec', 'busyapi', 'oasdiff');
  }

  Future<SemanticReview> compare(
    AnalysisSnapshot baseline,
    AnalysisSnapshot current,
    EngineProcess engine, {
    RunCancellation? cancellation,
    Map<String, dynamic>? baselineAnalysis,
    Map<String, dynamic>? currentAnalysis,
  }) async {
    cancellation?.throwIfCancelled();
    final version = await _version(cancellation);
    final temp = await Directory.systemTemp.createTemp('busyapi-diff-');
    try {
      final base = await _derive(
        baseline,
        engine,
        Uri.file(p.join(temp.path, 'base.json')).toString(),
        'diff-base',
        cancellation,
      );
      final revision = await _derive(
        current,
        engine,
        Uri.file(p.join(temp.path, 'revision.json')).toString(),
        'diff-current',
        cancellation,
      );
      final baseFile = File(p.join(temp.path, 'base.json')),
          revisionFile = File(p.join(temp.path, 'revision.json')),
          config = File(p.join(temp.path, 'oasdiff.yaml'));
      await Future.wait([
        baseFile.writeAsString(base),
        revisionFile.writeAsString(revision),
        config.writeAsString('{}\n'),
      ]);
      final coverageResults = await Future.wait([
        engine.request('semanticDiffCoverage', baseline.toJson()),
        engine.request('semanticDiffCoverage', current.toJson()),
      ]);
      for (var index = 0; index < coverageResults.length; index++) {
        final expected = index == 0 ? baseline.identity : current.identity;
        if (coverageResults[index]['version'] != 1 ||
            coverageResults[index]['snapshot'] != expected ||
            coverageResults[index]['coverage'] is! Map) {
          throw CoreFailure(
            'diff.protocol',
            'Semantic coverage returned an unrelated snapshot',
          );
        }
      }
      final breakingResult = await _run(
        [
          'breaking',
          'base.json',
          'revision.json',
          '--format',
          'json',
          '--allow-external-refs=false',
          '--config',
          'oasdiff.yaml',
        ],
        temp.path,
        cancellation,
      );
      final diffResult = await _run(
        [
          'diff',
          'base.json',
          'revision.json',
          '--format',
          'json',
          '--allow-external-refs=false',
          '--config',
          'oasdiff.yaml',
        ],
        temp.path,
        cancellation,
      );
      Object? rawBreaking, rawDiff;
      try {
        rawBreaking = jsonDecode(breakingResult);
        rawDiff = jsonDecode(diffResult);
      } on FormatException {
        throw CoreFailure('diff.protocol', 'oasdiff returned malformed JSON');
      }
      if (rawBreaking is! List || rawDiff is! Map) {
        throw CoreFailure(
          'diff.protocol',
          'oasdiff returned an unexpected result shape',
        );
      }
      final changes = <SemanticChange>[];
      for (final value in rawBreaking) {
        if (value is! Map || value['id'] is! String) {
          throw CoreFailure(
            'diff.protocol',
            'oasdiff returned a malformed change',
          );
        }
        final level = value['level'];
        final severity = level is int && level >= 3
            ? SemanticChangeSeverity.breaking
            : level is int && level >= 2
            ? SemanticChangeSeverity.potentiallyBreaking
            : SemanticChangeSeverity.unclassified;
        final path = value['path'] as String?,
            method = value['operation'] is String
                ? (value['operation'] as String).toUpperCase()
                : null;
        changes.add(
          SemanticChange(
            rule: value['id'] as String,
            severity: severity,
            message: _explanation(
              value['id'] as String,
              value['text']?.toString() ?? 'Semantic compatibility changed.',
            ),
            path: path,
            method: method,
            operationId: value['operationId'] as String?,
            before: _operationSource(baselineAnalysis, path, method),
            after: _operationSource(currentAnalysis, path, method),
            source: _source(value['baseSource'] ?? value['revisionSource']),
            details: Map<String, Object?>.unmodifiable({
              for (final entry in value.entries)
                if (!const {
                  'id',
                  'text',
                  'path',
                  'operation',
                  'operationId',
                  'baseSource',
                  'revisionSource',
                }.contains(entry.key))
                  entry.key.toString(): entry.value,
            }),
          ),
        );
      }
      _appendStructuredChanges(
        changes,
        Map<String, dynamic>.from(rawDiff),
        baselineAnalysis,
        currentAnalysis,
      );
      final sections = rawDiff.entries
          .where((entry) => !_empty(entry.value))
          .map((entry) => entry.key.toString())
          .toList();
      if (sections.isNotEmpty && changes.isEmpty) {
        changes.add(
          SemanticChange(
            rule: 'oasdiff-change-unclassified',
            severity: SemanticChangeSeverity.unclassified,
            message: 'The API changed without a pinned breaking-rule classification; inspect the structured and raw diff.',
            details: {'sections': sections},
          ),
        );
      }
      final dynamicReferences = <Object?>[
        ...coverageResults[0]['dynamicReferences'] as List? ?? const [],
        ...coverageResults[1]['dynamicReferences'] as List? ?? const [],
      ];
      final pathItems = <Object?>[
        ...coverageResults[0]['reusablePathItems'] as List? ?? const [],
        ...coverageResults[1]['reusablePathItems'] as List? ?? const [],
      ];
      final complete = dynamicReferences.isEmpty && pathItems.isEmpty;
      if (dynamicReferences.isNotEmpty) {
        changes.add(
          const SemanticChange(
            rule: 'oasdiff-dynamic-reference-unclassified',
            severity: SemanticChangeSeverity.unclassified,
            message: 'oasdiff 1.33.0 does not establish complete dynamic-reference comparison; these source locations remain available in raw review.',
          ),
        );
      }
      if (pathItems.isNotEmpty) {
        changes.add(
          const SemanticChange(
            rule: 'oasdiff-reusable-path-item-unclassified',
            severity: SemanticChangeSeverity.unclassified,
            message: 'oasdiff 1.33.0 does not establish complete reusable Path Item comparison; these source locations remain available in raw review.',
          ),
        );
      }
      return SemanticReview(
        baseline: baseline,
        current: current,
        toolVersion: version,
        complete: complete,
        changes: List.unmodifiable(changes),
        rawDiff: _rawPatch(base, revision),
        diff: Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(rawDiff),
        ),
        coverage: Map.unmodifiable({
          'ordinaryOperations': 'oasdiff-1.33.0',
          'dynamicReferences': dynamicReferences.isEmpty
              ? 'not-present'
              : 'unclassified',
          'reusablePathItems': pathItems.isEmpty
              ? 'not-present'
              : 'unclassified',
          'input': 'busyapi-derived-single-file-revision-3',
          'externalRetrieval': false,
        }),
        baselineText: base,
        currentText: revision,
      );
    } finally {
      try {
        await temp.delete(recursive: true);
      } on Object {
        // Private temporary comparison material is removed best effort.
      }
    }
  }

  Future<String> _version(RunCancellation? cancellation) async {
    final output = (await _run(
      const ['--version'],
      Directory.systemTemp.path,
      cancellation,
    )).trim();
    if (output != 'oasdiff version 1.33.0') {
      throw CoreFailure('diff.version', 'Expected packaged oasdiff 1.33.0');
    }
    return '1.33.0';
  }

  static Future<String> _derive(
    AnalysisSnapshot snapshot,
    EngineProcess engine,
    String outputId,
    String requestId,
    RunCancellation? cancellation,
  ) async {
    cancellation?.throwIfCancelled();
    final result = await engine.request('deriveBundle', {
      ...snapshot.toJson(),
      'outputId': outputId,
      'consumer': 'oasdiff',
    }, requestId: requestId);
    cancellation?.throwIfCancelled();
    final output = result['output'];
    if (result['version'] != 1 ||
        result['snapshot'] != snapshot.identity ||
        result['complete'] != true ||
        result['producer'] != 'busyapi-graph-bundle' ||
        result['producerVersion'] != '4' ||
        output is! Map ||
        output['id'] != outputId ||
        output['text'] is! String ||
        output['identity'] != textIdentity(output['text'] as String)) {
      throw CoreFailure(
        'diff.bundle.incomplete',
        'Semantic comparison requires two complete coherent derived snapshots',
      );
    }
    return output['text'] as String;
  }

  Future<String> _run(
    List<String> arguments,
    String directory,
    RunCancellation? cancellation,
  ) async {
    cancellation?.throwIfCancelled();
    if (!await File(executable).exists()) {
      throw CoreFailure(
        'diff.assets',
        'Packaged oasdiff 1.33.0 is unavailable',
      );
    }
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: directory,
      environment: const {'PATH': '', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'},
      includeParentEnvironment: false,
      runInShell: false,
    );
    final stdoutBytes = BytesBuilder(copy: false),
        stderrBytes = BytesBuilder(copy: false);
    var total = 0, limited = false;
    Future<void> collect(Stream<List<int>> stream, BytesBuilder target) async {
      await for (final chunk in stream) {
        if (limited) continue;
        final remaining = 32 * 1024 * 1024 - total;
        if (chunk.length > remaining) {
          if (remaining > 0) target.add(chunk.sublist(0, remaining));
          limited = true;
          process.kill(ProcessSignal.sigkill);
        } else {
          target.add(chunk);
          total += chunk.length;
        }
      }
    }

    final out = collect(process.stdout, stdoutBytes),
        err = collect(process.stderr, stderrBytes);
    await process.stdin.close();
    final code =
        await Future.any<int>([
          process.exitCode,
          if (cancellation != null)
            cancellation.whenCancelled.then((_) {
              process.kill(ProcessSignal.sigterm);
              return -1;
            }),
        ]).timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -2;
          },
        );
    await Future.wait([out, err]);
    if (cancellation?.cancelled == true) {
      throw CoreFailure('cancelled', 'Semantic comparison was cancelled');
    }
    if (limited) {
      throw CoreFailure('limit.diff.output', 'oasdiff output exceeds 32 MiB');
    }
    if (code == -2) {
      throw CoreFailure('diff.timeout', 'oasdiff exceeded two minutes');
    }
    if (code != 0) {
      final detail = utf8
          .decode(stderrBytes.takeBytes(), allowMalformed: true)
          .replaceAll(directory, '[temporary comparison]')
          .trim();
      throw CoreFailure(
        'diff.execution',
        'oasdiff did not complete${detail.isEmpty ? '' : ': ${detail.length > 2000 ? detail.substring(0, 2000) : detail}'}',
      );
    }
    return utf8.decode(stdoutBytes.takeBytes(), allowMalformed: false);
  }

  static bool _empty(Object? value) =>
      value == null ||
      value is Map && value.isEmpty ||
      value is List && value.isEmpty ||
      value is String && value.isEmpty ||
      value == false ||
      value == 0;

  static Map<String, Object?>? _source(Object? value) {
    if (value is! Map) return null;
    return Map.unmodifiable({
      for (final entry in value.entries)
        if (entry.value is String || entry.value is num || entry.value is bool)
          entry.key.toString(): entry.value,
    });
  }

  static Map<String, Object?>? _operationSource(
    Map<String, dynamic>? analysis,
    String? path,
    String? method,
  ) {
    if (analysis == null || path == null || method == null) return null;
    final projection = analysis['projection'] is Map
        ? analysis['projection'] as Map
        : analysis;
    final operations = projection['operations'];
    if (operations is! List) return null;
    final operation = operations
        .whereType<Map>()
        .where(
          (value) =>
              value['path'] == path && httpOperationMethod(value) == method,
        )
        .firstOrNull;
    if (operation == null) return null;
    return Map.unmodifiable({
      for (final key in ['resource', 'pointer', 'range', 'occurrence'])
        if (operation[key] != null) key: operation[key],
    });
  }

  /// oasdiff deliberately separates confirmed breaking rules from its full
  /// structural diff. Surface the latter as conservative review entries so an
  /// added operation, response, or authentication requirement cannot vanish
  /// from the native tree merely because it is not classified as breaking.
  static void _appendStructuredChanges(
    List<SemanticChange> changes,
    Map<String, dynamic> diff,
    Map<String, dynamic>? baselineAnalysis,
    Map<String, dynamic>? currentAnalysis,
  ) {
    Map<String, dynamic>? mapping(Object? value) =>
        value is Map ? Map<String, dynamic>.from(value) : null;
    Iterable<String> names(Object? value) =>
        value is List ? value.whereType<String>() : const <String>[];
    bool already(String path, String? method, String category) => changes.any(
      (change) =>
          change.path == path &&
          (method == null || change.method == method) &&
          change.rule.contains(category),
    );
    void add({
      required String rule,
      required SemanticChangeSeverity severity,
      required String message,
      required String path,
      String? method,
      Object? detail,
    }) {
      changes.add(
        SemanticChange(
          rule: rule,
          severity: severity,
          message: message,
          path: path,
          method: method,
          before: _operationSource(baselineAnalysis, path, method),
          after: _operationSource(currentAnalysis, path, method),
          details: Map.unmodifiable({if (detail != null) 'oasdiff': detail}),
        ),
      );
    }

    final paths = mapping(diff['paths']);
    if (paths != null) {
      for (final path in names(paths['added'])) {
        add(
          rule: 'oasdiff-path-added',
          severity: SemanticChangeSeverity.unclassified,
          message: 'A new API path was added; existing consumers are unchanged, while new surface should be reviewed.',
          path: path,
        );
      }
      for (final path in names(paths['deleted'])) {
        if (!already(path, null, 'removed')) {
          add(
            rule: 'oasdiff-path-deleted',
            severity: SemanticChangeSeverity.potentiallyBreaking,
            message: 'An API path was removed and remains visible for consumer review.',
            path: path,
          );
        }
      }
      final modifiedPaths = mapping(paths['modified']);
      if (modifiedPaths != null) {
        for (final pathEntry in modifiedPaths.entries) {
          final path = pathEntry.key;
          final operations = mapping(mapping(pathEntry.value)?['operations']);
          if (operations == null) continue;
          for (final methodValue in names(operations['added'])) {
            final method = methodValue.toUpperCase();
            add(
              rule: 'oasdiff-operation-added',
              severity: SemanticChangeSeverity.unclassified,
              message: 'A new operation was added; it does not remove an existing consumer capability.',
              path: path,
              method: method,
            );
          }
          for (final methodValue in names(operations['deleted'])) {
            final method = methodValue.toUpperCase();
            if (!already(path, method, 'removed')) {
              add(
                rule: 'oasdiff-operation-deleted',
                severity: SemanticChangeSeverity.potentiallyBreaking,
                message: 'An operation was removed and may break existing consumers.',
                path: path,
                method: method,
              );
            }
          }
          final modifiedOperations = mapping(operations['modified']);
          if (modifiedOperations == null) continue;
          for (final operationEntry in modifiedOperations.entries) {
            final method = operationEntry.key.toUpperCase();
            final operation = mapping(operationEntry.value);
            if (operation == null) continue;
            final authentication =
                operation['securityRequirements'] ?? operation['security'];
            if (!_empty(authentication)) {
              add(
                rule: 'oasdiff-authentication-changed',
                severity: SemanticChangeSeverity.potentiallyBreaking,
                message: 'The operation authentication requirements changed; consumers may need a different credential combination.',
                path: path,
                method: method,
                detail: authentication,
              );
            }
            final parameters = operation['parameters'];
            if (!_empty(parameters) && !already(path, method, 'parameter')) {
              add(
                rule: 'oasdiff-input-changed',
                severity: SemanticChangeSeverity.potentiallyBreaking,
                message: 'The operation input contract changed; inspect parameter additions, removals, and constraints.',
                path: path,
                method: method,
                detail: parameters,
              );
            }
            final requestBody = operation['requestBody'];
            if (!_empty(requestBody)) {
              add(
                rule: 'oasdiff-request-body-changed',
                severity: SemanticChangeSeverity.potentiallyBreaking,
                message: 'The request-body contract changed and may reject a previously accepted request.',
                path: path,
                method: method,
                detail: requestBody,
              );
            }
            final responses = mapping(operation['responses']);
            if (responses != null) {
              for (final status in names(responses['added'])) {
                add(
                  rule: 'oasdiff-response-added',
                  severity: SemanticChangeSeverity.unclassified,
                  message:
                      'Response status $status was added; consumers should decide whether it needs explicit handling.',
                  path: path,
                  method: method,
                  detail: status,
                );
              }
              if (!_empty(responses['modified']) &&
                  !already(path, method, 'response')) {
                add(
                  rule: 'oasdiff-response-changed',
                  severity: SemanticChangeSeverity.potentiallyBreaking,
                  message: 'An existing response contract changed and may affect consumer parsing.',
                  path: path,
                  method: method,
                  detail: responses['modified'],
                );
              }
            }
          }
        }
      }
    }

    final schemas = mapping(mapping(diff['components'])?['schemas']);
    if (schemas != null && !_empty(schemas)) {
      changes.add(
        SemanticChange(
          rule: 'oasdiff-component-schema-changed',
          severity: SemanticChangeSeverity.potentiallyBreaking,
          message: 'Reusable schema definitions changed; inspect their oasdiff details and raw source review.',
          details: Map.unmodifiable({'oasdiff': schemas}),
        ),
      );
    }
  }

  static String _explanation(String rule, String fallback) {
    if (rule.contains('required') && rule.contains('parameter')) {
      return 'Clients must now supply an input that was previously optional or absent.';
    }
    if (rule.contains('enum') || rule.contains('narrow')) {
      return 'The revised contract accepts fewer values, so an existing client value may be rejected.';
    }
    if (rule.contains('response')) {
      return 'The response contract changed in a way that may break an existing consumer.';
    }
    if (rule.contains('security') || rule.contains('auth')) {
      return 'The authentication requirement changed for an existing consumer operation.';
    }
    if (rule.contains('removed')) {
      return 'An API surface used by existing consumers was removed.';
    }
    return fallback;
  }

  static String _rawPatch(String before, String after) {
    if (before == after) return '';
    final left = const LineSplitter().convert(before),
        right = const LineSplitter().convert(after);
    var prefix = 0;
    while (prefix < left.length &&
        prefix < right.length &&
        left[prefix] == right[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < left.length - prefix &&
        suffix < right.length - prefix &&
        left[left.length - 1 - suffix] == right[right.length - 1 - suffix]) {
      suffix++;
    }
    final oldLines = left.sublist(prefix, left.length - suffix),
        newLines = right.sublist(prefix, right.length - suffix);
    final buffer = StringBuffer()
      ..writeln('--- baseline/openapi.json')
      ..writeln('+++ current/openapi.json')
      ..writeln(
        '@@ -${prefix + 1},${oldLines.length} +${prefix + 1},${newLines.length} @@',
      );
    const maximum = 20000;
    var emitted = 0;
    for (final line in oldLines) {
      if (emitted++ >= maximum) break;
      buffer.writeln('-$line');
    }
    for (final line in newLines) {
      if (emitted++ >= maximum) break;
      buffer.writeln('+$line');
    }
    if (emitted >= maximum)
      buffer.writeln(
        '… raw diff truncated; side-by-side sources remain complete',
      );
    return buffer.toString();
  }
}
