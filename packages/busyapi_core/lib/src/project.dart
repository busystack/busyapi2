import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';
import 'content_selection.dart';
import 'storage.dart';
import 'publication_staging.dart';
import 'engine_process.dart';
import 'publication.dart';
import 'atomic_file_writer.dart';
import 'atomic_directory_writer.dart';
import 'reference_markdown.dart';
import 'documentation_runtime.dart';
import 'generator_runtime.dart';
import 'request_form_values.dart';
import 'form_media_types.dart';
import 'multipart_encoding.dart';

part 'governance.dart';
part 'policy_code_review.dart';
part 'documentation.dart';
part 'documentation_sources.dart';
part 'execution.dart';
part 'mock.dart';
part 'file_refactoring.dart';
part 'resource_configuration.dart';
part 'root_configuration.dart';
part 'resource_package.dart';
part 'generation.dart';
part 'migration.dart';

// Semantic revisions are part of captured evaluator ownership, alongside the
// wire protocol and snapshot identity.
const _schemaProducerVersion = '1.18.0+15';

// Keep native-isolate IO wakeups bounded without serializing every resource.
// Each batch finishes (including failures) before access can be released.
Future<void> _resourceBatch<T>(
  Iterable<T> resources,
  Future<void> Function(T) action,
) async {
  final values = resources.toList();
  for (var start = 0; start < values.length; start += 16) {
    await Future.wait([
      for (var i = start; i < start + 16 && i < values.length; i++)
        action(values[i]),
    ]);
  }
}

class ProjectRoot {
  const ProjectRoot(this.name, this.id);
  final String name, id;
}

Object? _freezeProjection(Object? value) {
  if (value is Map)
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeProjection(entry.value),
    });
  if (value is List)
    return List<Object?>.unmodifiable(value.map(_freezeProjection));
  return value;
}

Map<String, dynamic> _freezeResult(Map<String, dynamic> value) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key: _freezeProjection(entry.value),
    });

/// Resource changes include open nondependencies; affected roots alone cannot
/// describe which Source buffers or conflict indicators need presentation.
class ResourceRefresh {
  ResourceRefresh(Set<String> resources, Set<String> roots)
    : resources = Set.unmodifiable(resources),
      roots = Set.unmodifiable(roots);
  final Set<String> resources, roots;
}

class AnalysisSnapshot {
  AnalysisSnapshot({
    required this.root,
    required List<Map<String, Object?>> resources,
    List<String> boundaries = const [],
    String? engineIdentity,
    List<Map<String, Object?>> configuration = const [],
  }) : resources = List.unmodifiable(
         resources.map(
           (r) => Map<String, Object?>.unmodifiable({
             for (final entry in r.entries)
               entry.key: _freezeProjection(entry.value),
           }),
         ),
       ),
       configuration = List.unmodifiable(
         configuration.map((r) => Map<String, Object?>.unmodifiable(r)),
       ),
       identity = _snapshotIdentity(
         root,
         resources,
         boundaries,
         engineIdentity,
         true,
         configuration,
       ),
       sourceIdentity = _snapshotIdentity(
         root,
         resources,
         boundaries,
         engineIdentity,
         false,
         configuration,
       );
  final String root, identity, sourceIdentity;
  static String _snapshotIdentity(
    String root,
    List<Map<String, Object?>> resources,
    List<String> boundaries,
    String? engine,
    bool generations,
    List<Map<String, Object?>> configuration,
  ) {
    final entries =
        resources
            .map(
              (r) => <String, Object?>{
                'id': r['id'],
                'identity': r['identity'],
                if (r['aliases'] != null) 'aliases': r['aliases'],
                if (generations) 'generation': r['generation'],
              },
            )
            .toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return textIdentity(
      jsonEncode({
        'root': root,
        'resources': entries,
        if (configuration.isNotEmpty)
          'configurationResources': [
            for (final r in configuration)
              {
                'id': r['id'],
                'identity': r['identity'],
                if (generations) 'generation': r['generation'],
              },
          ],
        'engine': {'version': '0.1.0', 'assets': engine},
        'configuration': 1,
        'boundaries': boundaries.toList()..sort(),
      }),
    );
  }

  final List<Map<String, Object?>> resources, configuration;
  Iterable<Map<String, Object?>> get allInputs => [
    ...resources,
    ...configuration,
  ];
  Map<String, Object?> toJson() => {
    'root': root,
    'snapshot': identity,
    'resources': resources,
  };
  bool current(BufferStore store) => allInputs.every(
    (r) =>
        !store.isVirtuallyAbsent(r['id'] as String) &&
        (!store.buffers.containsKey(r['id']) ||
            (store.get(r['id'] as String).generation == r['generation'] &&
                store.get(r['id'] as String).sourceIdentity == r['identity'])),
  );
}

/// Preserve original-source results when a required export check cannot pass.
class OutputAnalysisFailure extends CoreFailure {
  OutputAnalysisFailure(
    super.code,
    super.message,
    Map<String, dynamic> analysis, {
    this.cause,
  }) : analysis = _freezeResult(analysis);
  final Map<String, dynamic> analysis;
  final CoreFailure? cause;
}

int outputFailureExitCode(Object error) {
  final code = error is CoreFailure ? error.code : 'io.failure';
  if (code == 'bundle.contract' ||
      code == 'documentation.contract' ||
      code == 'generate.contract')
    return 1;
  if ([
    'generate.incomplete',
    'generate.coverage',
    'generate.limit',
    'generate.timeout',
  ].contains(code))
    return 2;
  if (code == 'mock.bundle.incomplete' ||
      code.startsWith('diff.bundle.') ||
      code.startsWith('diff.reference.')) {
    return 2;
  }
  if (code.startsWith('limit.') ||
      code.startsWith('bundle.') &&
          ![
            'bundle.destination',
            'bundle.snapshot',
            'bundle.package.assets',
          ].contains(code) ||
      code.startsWith('documentation.') &&
          ![
            'documentation.destination',
            'documentation.snapshot',
            'documentation.preset',
            'documentation.assets',
          ].contains(code))
    return 2;
  return 3;
}

Future<(List<int>, List<int>)> _encodeBundleFiles(
  String text,
  Map<String, Object?> metadata,
) => Isolate.run(
  () => (utf8.encode(text), utf8.encode(jsonEncode(metadata) + '\n')),
);

// One result policy for ordinary project checks and immutable resource-package
// checks. Collection/coherence remain with their respective core IO owners.
Map<String, dynamic> _mergeSchemaEvaluation(
  AnalysisSnapshot snapshot,
  Map<String, dynamic> structural,
  Map<String, dynamic>? evaluated,
  String? executionFailure,
) {
  final findings = List<dynamic>.from(structural['findings'] as List);
  final findingKeys = {
    for (final finding in findings)
      (finding['resource'], finding['pointer'], finding['code']),
  };
  for (final value in evaluated?['findings'] as List? ?? const []) {
    final finding = Map<String, dynamic>.from(value as Map)
      ..['snapshot'] = snapshot.sourceIdentity;
    if (findingKeys.add((
      finding['resource'],
      finding['pointer'],
      finding['code'],
    )))
      findings.add(finding);
  }
  if (executionFailure != null)
    findings.add({
      'version': 1,
      'category': 'openapi',
      'code': 'schema.execution.incomplete',
      'severity': 'warning',
      'resource': snapshot.root,
      'root': snapshot.root,
      'pointer': '',
      'range': [0, 0],
      'message': 'Schema evaluation did not complete. No clean result is inferred from a failed or malformed worker response.',
      'producer': 'busyapi',
      'producerVersion': '0.1.0',
      'snapshot': snapshot.sourceIdentity,
      'failureCode': executionFailure,
    });
  final complete =
      structural['complete'] == true && evaluated?['complete'] == true;
  return {
    ...structural,
    'projection': structural,
    'projectionComplete': structural['complete'],
    'complete': complete,
    'status': structural['status'] == 'unsupported'
        ? 'unsupported'
        : structural['status'] == 'invalid' &&
              (structural['findings'] as List).any(
                (f) => f['category'] == 'syntax',
              ) &&
              executionFailure == null
        ? 'invalid'
        : !complete
        ? 'incomplete'
        : findings.any((f) => f['severity'] == 'error')
        ? 'invalid'
        : 'complete',
    'findings': findings,
    'categories': {
      ...Map<String, dynamic>.from(structural['categories'] as Map? ?? {}),
      'openapi': {
        'complete': complete,
        'producer': 'busyapi',
        'producerVersion': '0.1.0',
        'snapshot': snapshot.sourceIdentity,
        'coverage': structural['coverage']?['openapi'],
        'status': complete ? 'complete' : 'incomplete',
        'schema': {
          'complete': evaluated?['complete'] == true,
          'producer': evaluated?['producer'] ?? 'hyperjump+busyapi-exact',
          'producerVersion':
              evaluated?['producerVersion'] ?? _schemaProducerVersion,
          if (evaluated != null) ...{
            'configuration': evaluated['configuration'],
            'coverage': evaluated['coverage'],
            'schemas': evaluated['schemas'],
            'instances': evaluated['instances'],
            'skipped': (evaluated['skipped'] as List).length,
          },
          'snapshot': snapshot.sourceIdentity,
        },
      },
    },
    'coverage': {
      ...Map<String, dynamic>.from(structural['coverage'] as Map? ?? {}),
      'schemaEvaluation': evaluated?['coverage'] ?? 'incomplete',
    },
  };
}

class BundleOutput {
  BundleOutput._(
    this._owner,
    this._access,
    this.destination,
    this.snapshot,
    this.saved,
    this.unsaved,
    this._revision,
    Map<String, dynamic> result,
    Map<String, Object?> metadata, {
    bool resultAlreadyFrozen = false,
  }) : result = resultAlreadyFrozen ? result : _freezeResult(result),
       metadata = _freezeResult(Map<String, dynamic>.from(metadata));
  final BusyProject _owner;
  final ProjectAccess _access;
  final String destination;
  final AnalysisSnapshot snapshot;
  final bool saved, unsaved;
  final int _revision;
  final Map<String, dynamic> result;
  final Map<String, Object?> metadata;
  bool _closed = false;
  bool get outdated =>
      _owner._closed ||
      _revision != _owner._resourceRevision ||
      !snapshot.current(_owner.store);
  String get identity => result['output']['identity'] as String;
  Future<OutputDirectoryReceipt?> existing() async =>
      await _access.missing(destination)
      ? null
      : await _access.inspectOutput(destination);
  Future<OutputDirectoryResult> publish({
    String? replaceIdentity,
    bool Function()? cancelled,
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
  }) async {
    if (_closed)
      throw CoreFailure('output.closed', 'The frozen output owner is closed');
    final (document, provenance) = await _encodeBundleFiles(
      result['output']['text'] as String,
      metadata,
    );
    return _access.publishOutput(
      destination,
      {'openapi.json': document, 'provenance.json': provenance},
      metadata,
      replaceIdentity: replaceIdentity,
      cancelled: cancelled,
      beforePublish: beforePublish,
      afterPublish: afterPublish,
    );
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _access.close();
    }
  }
}

enum SecurityBindingForm { name, uri }

/// Typed choices from one immutable, approved graph. A pointer alone is never
/// a definition identity, and selecting a row does not edit its definition.
class ReferenceChoicePage {
  ReferenceChoicePage._(
    this._owner,
    this._snapshot,
    this._revision,
    Map<String, dynamic> data,
  ) : result = _freezeResult(data);
  final BusyProject _owner;
  final AnalysisSnapshot _snapshot;
  final int _revision;
  final Map<String, dynamic> result;
  bool get current =>
      !_owner._closed &&
      _revision == _owner._resourceRevision &&
      _snapshot.current(_owner.store);
  Map<String, Object?> _capture(Map location) {
    final resource = _snapshot.resources.firstWhere(
      (r) => r['id'] == location['resource'],
    );
    final range = List<int>.from(location['range'] as List);
    return {
      'root': _snapshot.root,
      'resource': location['resource'],
      'pointer': location['pointer'],
      'generation': resource['generation'],
      'range': range,
      'expected': (resource['text'] as String).substring(range[0], range[1]),
    };
  }
}

class RefactoringPlan {
  RefactoringPlan._(
    this._owner,
    this._revision,
    this._snapshots,
    Map<String, dynamic> data,
  ) : result = _freezeResult(data),
      edits = List.unmodifiable([
        for (final edit in data['edits'] as List)
          TextEdit.fromJson(Map<String, dynamic>.from(edit as Map)),
      ]);
  final BusyProject _owner;
  final int _revision;
  final List<AnalysisSnapshot> _snapshots;
  final Map<String, dynamic> result;
  final List<TextEdit> edits;
  bool get hasChanges => edits.isNotEmpty;
  String get identity =>
      result['identity'] as String? ?? result['snapshot'] as String;
  List<String> get checkedRoots =>
      List<String>.from(result['checkedRoots'] as List);
  SemanticTransition get transition {
    final from = result['from'] as Map, to = result['to'] as Map;
    return SemanticTransition(
      from['resource'] as String,
      from['pointer'] as String,
      to['pointer'] as String,
      destinationResource: to['resource'] as String?,
    );
  }

  List<SemanticTransition> get transitions => List.unmodifiable([
    if (result['transitions'] is List)
      for (final move in result['transitions'] as List)
        SemanticTransition(
          move['resource'] as String,
          move['from'] as String,
          move['to'] as String,
          mode: move['mode'] as String? ?? 'relocation',
          destinationResource: move['toResource'] as String?,
        )
    else
      transition,
  ]);
}

/// Read-only assistance is captured at a full-document caret and snapshot. Its
/// accepted insertion uses the existing source transaction, not another buffer.
class SourceAssistance {
  SourceAssistance._(
    this._owner,
    this._snapshot,
    this._revision,
    this.resource,
    this.selection,
    Map<String, dynamic> data,
  ) : result = _freezeResult(data);
  final BusyProject _owner;
  final AnalysisSnapshot _snapshot;
  final int _revision;
  final String resource;
  final SourceSelection selection;
  final Map<String, dynamic> result;
  bool get current =>
      !_owner._closed &&
      _revision == _owner._resourceRevision &&
      _snapshot.current(_owner.store);
  List<Map<String, dynamic>> get completions => [
    for (final entry in result['completions'] as List)
      Map<String, dynamic>.from(entry as Map),
  ];
  TextEdit completion(int index, DocumentBuffer buffer) {
    if (!current ||
        buffer.id != resource ||
        buffer.selection.base != selection.base ||
        buffer.selection.extent != selection.extent) {
      throw CoreFailure(
        'assist.stale',
        'Source or caret changed after the suggestion was prepared',
      );
    }
    final choices = completions;
    if (index < 0 || index >= choices.length)
      throw CoreFailure(
        'assist.choice',
        'The captured suggestion is unavailable',
      );
    final edits = choices[index]['edits'] as List;
    if (edits.length != 1)
      throw CoreFailure(
        'assist.protocol',
        'A source suggestion must contain one local insertion plan',
      );
    final edit = TextEdit.fromJson(
      Map<String, dynamic>.from(edits.single as Map),
    );
    if (edit.buffer != resource || edit.generation != buffer.generation)
      throw CoreFailure(
        'assist.stale',
        'The suggestion belongs to another source generation',
      );
    return edit;
  }
}

class SourceAssistanceJob {
  SourceAssistanceJob._(
    this._project,
    this.root,
    this.resource,
    this.selection,
    this.onResourceRefreshed,
  ) : _id = 'source-assist-${++_serial}:';
  static int _serial = 0;
  final BusyProject _project;
  final String root, resource, _id;
  final SourceSelection selection;
  final void Function(String resource)? onResourceRefreshed;
  bool _cancelled = false, _started = false, _done = false;
  Future<SourceAssistance> run(
    String action, {
    SourceRange? viewport,
    List<String> foldedPointers = const [],
  }) async {
    if (_started)
      throw CoreFailure('assist.job', 'This source job was already started');
    _started = true;
    try {
      return await _project._assistSource(
        root,
        resource,
        selection,
        action: action,
        requestId: _id,
        cancelled: () => _cancelled,
        viewport: viewport,
        foldedPointers: foldedPointers,
        onResourceRefreshed: onResourceRefreshed,
      );
    } finally {
      _done = true;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    if (_done) return;
    await _project.engine.cancelPrefix(_id);
    await _project.engine.cancel(_id);
  }
}

/// A semantic index is a read-only projection, with each occurrence bound to
/// its entry root as well as the physical resource. It is never a text rename.
class SemanticSearchSnapshot {
  SemanticSearchSnapshot._(
    this._owner,
    this._revision,
    this._snapshots,
    List<Map<String, dynamic>> matches,
    this.complete,
  ) : matches = List.unmodifiable(matches.map(_freezeResult));
  final BusyProject _owner;
  final int _revision;
  final List<AnalysisSnapshot> _snapshots;
  final List<Map<String, dynamic>> matches;
  final bool complete;
  List<String> get checkedRoots =>
      List.unmodifiable(_snapshots.map((s) => s.root));
  bool get current =>
      !_owner._closed &&
      _owner._resourceRevision == _revision &&
      _snapshots.every((s) => s.current(_owner.store));
}

class SemanticSearchJob {
  SemanticSearchJob._(this._project, this.onResourceRefreshed)
    : _id = 'semantic-search-${++_serial}:';
  static int _serial = 0;
  final BusyProject _project;
  final void Function(String resource)? onResourceRefreshed;
  final String _id;
  bool _cancelled = false, _started = false, _done = false;
  Future<SemanticSearchSnapshot> run(
    String query, {
    String category = 'all',
  }) async {
    if (_started)
      throw CoreFailure(
        'search.job',
        'This semantic search was already started',
      );
    _started = true;
    try {
      return await _project._searchSemantic(
        query,
        category,
        _id,
        () => _cancelled,
        onResourceRefreshed,
      );
    } finally {
      _done = true;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    if (_done) return;
    await _project.engine.cancelPrefix(_id);
  }
}

enum BufferReloadStatus { applied, stale, failed, cancelled }

/// A discard decision owns all mutable source/publication state, not just text.
class BufferReloadCapture {
  BufferReloadCapture._(this.project, this.buffer)
    : generation = buffer.generation,
      id = buffer.id,
      path = buffer.path,
      baseline = buffer.baseline,
      diskIdentity = buffer.diskIdentity,
      publishedPath = buffer.publishedPath,
      present = buffer.present,
      publishedPresent = buffer.publishedPresent,
      hasBom = buffer.hasBom,
      mode = buffer.mode,
      pendingPublication = buffer.pendingFilePublication,
      _acceptsReload = project.acceptsBufferReload;
  final BusyProject project;
  final DocumentBuffer buffer;
  final int generation, mode;
  final String id, path, baseline, diskIdentity, publishedPath;
  final bool present, publishedPresent, hasBom, pendingPublication;
  final bool Function(DocumentBuffer)? _acceptsReload;
  bool get current => bufferCurrent && (_acceptsReload?.call(buffer) ?? true);
  bool get bufferCurrent =>
      publicationCurrent &&
      buffer.generation == generation &&
      buffer.hasBom == hasBom;
  bool get publicationCurrent =>
      !project._closed &&
      project.store.ownsFileBuffer(buffer) &&
      buffer.id == id &&
      buffer.path == path &&
      buffer.baseline == baseline &&
      buffer.diskIdentity == diskIdentity &&
      buffer.publishedPath == publishedPath &&
      buffer.present == present &&
      buffer.publishedPresent == publishedPresent &&
      buffer.mode == mode &&
      buffer.pendingFilePublication == pendingPublication;
}

class BufferReloadResult {
  const BufferReloadResult(this.status, {this.applied, this.failure});
  final BufferReloadStatus status;
  final BufferReloadCapture? applied;
  final Object? failure;
}

class BusyProject {
  BusyProject._(
    this.access,
    this.engine,
    this.store,
    this.roots,
    this.files,
    this.location, {
    bool standalone = false,
  }) : _standalone = standalone {
    store.onPathsChanged = _pathsChanged;
    store.onCommitted = _rootConfigurationCommitted;
  }

  /// Validate generated configuration with the same URI normalization and
  /// mapping parser used when a project opens. This borrows access and performs
  /// no resource reads, acquisitions or publication.
  static Future<void> validateGeneratedConfiguration(
    ProjectAccess access,
    EngineProcess engine, {
    required String text,
    required String id,
  }) async {
    if (utf8.encode(text).length > 65536) {
      throw CoreFailure('limit.manifest', 'Project manifest exceeds 64 KiB');
    }
    final validation = BusyProject._(
      access,
      engine,
      BufferStore(),
      [],
      [],
      access.boundary,
    );
    final source = <String, Object?>{'id': id, 'text': text};
    await validation._normalizeConfigurationKeys(source);
    validation._parseResourceMappings(source, const {});
  }

  final ProjectAccess access;
  final EngineProcess engine;
  final BufferStore store;

  /// The UI owns input that has not entered the source buffer. Recheck this
  /// authority at reload application and recovery retirement, not only capture.
  bool Function(DocumentBuffer)? acceptsBufferReload;
  final List<ProjectRoot> roots;
  final List<String> files;
  String location;
  final bool _standalone;
  late final String _manifestResource = Uri.file(
    p.join(access.boundary, 'busyapi.yaml'),
  ).toString();
  bool _closed = false;
  String? discoveryFailure;
  final Map<String, Set<String>> dependencies = {};
  final Map<String, Set<String>> _policyDependencies = {};
  final Map<String, Map<String, String>> _policyLookupKinds = {};
  Map<String, Object?> lastTimings = {};
  final Map<String, String?> resourceFingerprints = {};
  final Map<String, Map<String, Object?>> _standardResources = {};
  Future<Set<String>>? _standardCatalogue;
  Future<void>? _standardRead;
  Future<Map<String, Object?>?> _bundledStandard(String id) async {
    void active() {
      if (_closed)
        throw CoreFailure('access.closed', 'The resource owner is closed');
    }

    active();
    if (_standardResources.containsKey(id)) return _standardResources[id];
    final collecting = _standardCatalogue ??= () async {
      final result = await engine.request('standardResource', {'list': true});
      if (result['version'] != 1 ||
          result['identities'] is! List ||
          (result['identities'] as List).length > 128 ||
          !(result['identities'] as List).every((value) => value is String))
        throw CoreFailure(
          'resource.protocol',
          'Invalid bundled standard catalogue',
        );
      return Set<String>.from(result['identities'] as List);
    }();
    late Set<String> catalogue;
    try {
      catalogue = await collecting;
    } on Object {
      if (identical(_standardCatalogue, collecting)) _standardCatalogue = null;
      rethrow;
    }
    active();
    if (!catalogue.contains(id)) return null;
    final previous = _standardRead, finished = Completer<void>();
    _standardRead = finished.future;
    try {
      if (previous != null) await previous;
      active();
      if (_standardResources.containsKey(id)) return _standardResources[id];
      final result = await engine.request('standardResource', {'uri': id});
      active();
      if (result['version'] != 1 || result['found'] != true)
        throw CoreFailure(
          'resource.protocol',
          'Bundled standard is absent from its catalogue',
        );
      final value = result['source'];
      if (value is! Map ||
          value['id'] is! String ||
          !catalogue.contains(value['id']) ||
          value['text'] is! String ||
          (value['text'] as String).length > 1024 * 1024 ||
          value['identity'] != textIdentity(value['text'] as String) ||
          value['generation'] != 0 ||
          value['bundled'] != true ||
          value['producer'] != '@hyperjump/json-schema' ||
          value['producerVersion'] != '1.18.0' ||
          value['aliases'] is! List ||
          !(value['aliases'] as List).every(
            (alias) => alias is String && catalogue.contains(alias),
          ) ||
          (value['id'] != id && !(value['aliases'] as List).contains(id))) {
        throw CoreFailure(
          'resource.protocol',
          'Invalid bundled standard identity or contents',
        );
      }
      final source = Map<String, Object?>.from(value);
      _standardResources[id] = source;
      _standardResources.putIfAbsent(source['id'] as String, () => source);
      return source;
    } finally {
      finished.complete();
    }
  }

  final Map<String, ProjectAccess> _approvedContexts = {};
  final Map<String, (ProjectAccess, String)> _executionFiles = {};

  /// Explicit user/file-input capability. The held parent guard is never
  /// exposed as directory approval; only these exact, captured bytes may read.
  Future<void> approveExecutionFile(String selected) async {
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    final path = p.normalize(p.absolute(selected));
    if (_executionFiles.length >= 16 && !_executionFiles.containsKey(path))
      throw CoreFailure('access.limit', 'Selected TLS file limit reached');
    final guard = await ProjectAccess.open(p.dirname(path));
    try {
      final bytes = await guard.read(path);
      if (bytes.length > 4 * 1024 * 1024)
        throw CoreFailure('limit.tls.material', 'TLS material exceeds 4 MiB');
      if (_closed)
        throw CoreFailure(
          'access.closed',
          'Project closed during file approval',
        );
      // Other selections can finish while this guard/read is pending. Only a
      // distinct new path consumes capacity; a failed renewal keeps its guard.
      if (_executionFiles.length >= 16 && !_executionFiles.containsKey(path))
        throw CoreFailure('access.limit', 'Selected TLS file limit reached');
      _executionFiles.remove(path)?.$1.close();
      _executionFiles[path] = (guard, contentIdentity(bytes));
    } on Object {
      guard.close();
      rethrow;
    }
  }

  final Map<String, String> _approvedResources = {};
  final Map<String, String> _configuredResources = {};
  String? _resourceConfigurationText;
  bool _resourceConfigurationPresent = false;
  String? get configurationResource =>
      _resourceConfigurationPresent ? _manifestResource : null;
  final Map<String, String> _resourceIdentityCache = {};
  final Map<DocumentBuffer, Set<DocumentBuffer>> _fileParticipants = {};
  final Map<String, (DocumentBuffer, int, String, String)> _fileRecoveries = {};
  int _resourceRevision = 0;
  AnalysisSnapshot? _workingSnapshot;
  int _workingSnapshotRevision = -1;
  Map<String, String> get approvedResources =>
      Map.unmodifiable(_resourceMappings);
  Map<String, String> get _resourceMappings => {
    ..._configuredResources,
    ..._approvedResources,
  };

  /// Bind an external URI identity to an explicitly approved local resource.
  /// A URI is never interpreted as a filesystem permission or fetched here.
  Future<void> approveResource(String identity, String resource) async {
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    identity = (await _normalizedResourceUris([identity])).single;
    final uri = Uri.tryParse(identity);
    if (uri == null ||
        !uri.hasScheme ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        RegExp(r'[\s\\]').hasMatch(identity)) {
      throw CoreFailure(
        'resource.identity',
        'Use an absolute resource URI without a fragment or credentials',
      );
    }
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    if (_resourceMappings.length >= 256 &&
        !_resourceMappings.containsKey(uri.toString())) {
      throw CoreFailure(
        'resource.limit',
        'Approved resource mapping limit reached',
      );
    }
    final file = Uri.tryParse(resource);
    if (file == null || file.scheme != 'file') {
      throw CoreFailure(
        'resource.local',
        'An approved mapping must identify a local file',
      );
    }
    final path = accessFor(file.toFilePath()).pathFor(file.toFilePath());
    await buffer(Uri.file(path).toString());
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    if (_resourceMappings.length >= 256 &&
        !_resourceMappings.containsKey(uri.toString())) {
      throw CoreFailure(
        'resource.limit',
        'Approved resource mapping limit reached',
      );
    }
    final existingIdentity = _resourceMappings.entries.where(
      (entry) =>
          entry.value == Uri.file(path).toString() &&
          entry.key != uri.toString(),
    );
    if (existingIdentity.isNotEmpty) {
      throw CoreFailure(
        'resource.base.ambiguous',
        'This local resource already has a different approved retrieval identity',
      );
    }
    final previous = _resourceMappings[uri.toString()];
    if (previous != null && previous != Uri.file(path).toString()) {
      throw CoreFailure(
        'resource.collision',
        'This identity already has a different approved resource',
      );
    }
    if (previous != Uri.file(path).toString()) {
      _approvedResources[uri.toString()] = Uri.file(path).toString();
      _resourceRevision++;
    }
  }

  List<String> get approvedContexts =>
      [access.boundary, ..._approvedContexts.keys]..sort();
  Future<void> approveContext(String directory) async {
    if (_approvedContexts.length >= 16) {
      throw CoreFailure('access.limit', 'Approved local context limit reached');
    }
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    final next = await ProjectAccess.open(directory);
    if (_closed || _approvedContexts.length >= 16) {
      next.close();
      throw CoreFailure(
        'access.closed',
        'Project context changed before approval',
      );
    }
    if (next.boundary == access.boundary ||
        _approvedContexts.containsKey(next.boundary)) {
      next.close();
      return;
    }
    _approvedContexts[next.boundary] = next;
    _resourceRevision++;
  }

  ProjectAccess accessFor(String path) {
    path = p.normalize(p.absolute(path));
    for (final candidate in [access, ..._approvedContexts.values]) {
      if (p.isWithin(candidate.boundary, path)) return candidate;
    }
    throw CoreFailure(
      'access.outside',
      'Resource needs explicit local context approval',
    );
  }

  static Future<BusyProject> open(
    String location,
    EngineProcess engine, {
    bool Function()? cancelled,
  }) async {
    final absolute = p.normalize(p.absolute(location));
    final isFile =
        await FileSystemEntity.type(absolute) == FileSystemEntityType.file;
    final boundary = isFile ? p.dirname(absolute) : absolute;
    final access = await ProjectAccess.open(boundary);
    final store = BufferStore();
    final files = <String>[];
    final roots = <ProjectRoot>[];
    String? discoveryFailure;
    try {
      if (isFile) {
        files.add(absolute);
      } else {
        // Limit traversal to the explicitly selected directory. Skip dependency/cache trees.
        final pending = [access.boundary];
        int visited = 0;
        while (pending.isNotEmpty) {
          if (cancelled?.call() ?? false) {
            throw CoreFailure('open.cancelled', 'Project discovery cancelled');
          }
          final dir = pending.removeLast();
          await for (final entry in Directory(dir).list(followLinks: false)) {
            if (++visited > 20000) {
              throw CoreFailure(
                'discovery.limit',
                'Project discovery exceeds 20000 entries; open a narrower directory',
              );
            }
            if (entry is Directory) {
              // Generated outputs are not new canonical project roots. This
              // classification grants no overwrite trust: replacement still
              // verifies the complete owned receipt and every actual file.
              var derived = isOutputStagingDirectoryName(
                p.basename(entry.path),
              );
              if (!derived) {
                try {
                  final bytes = await access.read(
                    p.join(entry.path, AtomicDirectoryWriter.receiptName),
                  );
                  if (bytes.length <= 4 * 1024 * 1024) {
                    final marker = jsonDecode(utf8.decode(bytes));
                    derived =
                        marker is Map &&
                        marker['version'] == 1 &&
                        marker['owner'] == 'io.busystack.busyapi' &&
                        marker['files'] is Map &&
                        marker['metadata'] is Map &&
                        [
                          'bundle',
                          'generate',
                        ].contains(marker['metadata']['operation']);
                  }
                } on Object {
                  /* Ordinary source directories have no output marker. */
                }
              }
              if (![
                    '.git',
                    'node_modules',
                    '.dart_tool',
                    'build',
                    '.cache',
                  ].contains(p.basename(entry.path)) &&
                  !isFileArchiveDirectoryName(p.basename(entry.path)) &&
                  !derived) {
                pending.add(entry.path);
              }
            } else if (entry is File &&
                [
                  '.yaml',
                  '.yml',
                  '.json',
                ].contains(p.extension(entry.path).toLowerCase()) &&
                p.basename(entry.path) != 'busyapi.yaml') {
              files.add(entry.path);
              if (files.length > 2048) {
                throw CoreFailure(
                  'discovery.limit',
                  'Project exceeds 2048 candidate documents',
                );
              }
            }
          }
        }
      }
      final manifest = File(p.join(access.boundary, 'busyapi.yaml'));
      if (!isFile && await manifest.exists()) {
        final manifestBytes = await access.read(manifest.path);
        if (manifestBytes.length > 65536) {
          throw CoreFailure(
            'limit.manifest',
            'Project manifest exceeds 64 KiB',
          );
        }
        final data = loadYaml(utf8.decode(manifestBytes));
        if (data is! YamlMap ||
            data['version'] != 1 ||
            data['roots'] is! YamlList) {
          throw CoreFailure(
            'manifest.version',
            'Expected BusyAPI manifest version 1 with named roots',
          );
        }
        if ((data['roots'] as YamlList).length > 128) {
          throw CoreFailure(
            'limit.roots',
            'Project manifest exceeds 128 named roots',
          );
        }
        for (final r in data['roots'] as YamlList) {
          if (r is! YamlMap || r['name'] is! String || r['path'] is! String) {
            throw CoreFailure('manifest.root', 'Invalid named root entry');
          }
          final file = access.pathFor(
            p.join(access.boundary, r['path'] as String),
          );
          if (roots.any((x) => x.name == r['name'])) {
            throw CoreFailure(
              'manifest.duplicate',
              'Root names must be unique',
            );
          }
          roots.add(
            ProjectRoot(r['name'] as String, Uri.file(file).toString()),
          );
          if (!files.contains(file)) files.add(file);
        }
      } else {
        // Batch content inspection, never infer roots from filename alone.
        for (var offset = 0; offset < files.length; offset += 64) {
          if (cancelled?.call() ?? false) {
            throw CoreFailure('open.cancelled', 'Project discovery cancelled');
          }
          final resources = <Map<String, Object?>>[];
          for (final file in files.skip(offset).take(64)) {
            try {
              final bytes = await access.read(file);
              final b = DocumentBuffer.decode(
                file,
                bytes,
                mode: await access.mode(file),
              );
              resources.add(b.snapshot());
              if (resources.fold<int>(
                    0,
                    (n, r) => n + (r['text'] as String).length * 6,
                  ) >
                  48 * 1024 * 1024) {
                throw CoreFailure(
                  'discovery.bytes',
                  'Discovery batch exceeds the memory budget; select a contract file or configured project',
                );
              }
            } on FormatException {
              /* Leave undecodable bytes intact; explicit opening reports it. */
            } on CoreFailure catch (e) {
              if (e.code == 'discovery.bytes') {
                if (!isFile) rethrow;
                discoveryFailure = e.toString();
                resources.clear();
                break;
              }
              /* Inaccessible candidates are not promoted to roots. */
            }
          }
          if (resources.isEmpty && discoveryFailure != null) break;
          final Map<String, dynamic> result;
          try {
            result = await engine.request('discover', {'resources': resources});
          } on CoreFailure catch (e) {
            if (e.code == 'cancelled') rethrow;
            discoveryFailure = e.toString();
            break; // Source remains available when structural discovery cannot run.
          }
          for (final r in result['roots'] as List) {
            roots.add(
              ProjectRoot(
                p.relative(
                  Uri.parse(r['id'] as String).toFilePath(),
                  from: access.boundary,
                ),
                r['id'] as String,
              ),
            );
          }
        }
      }
      if (roots.length > 128) {
        throw CoreFailure(
          'limit.roots',
          'Project exceeds 128 root candidates; choose a narrower directory or a standalone contract',
        );
      }
      final project = BusyProject._(
        access,
        engine,
        store,
        roots,
        files..sort(),
        absolute,
        standalone: isFile,
      )..discoveryFailure = discoveryFailure;
      try {
        await project._refreshResourceConfiguration();
      } on CoreFailure catch (error) {
        project.discoveryFailure = error.toString();
      }
      return project;
    } on Object {
      access.close();
      rethrow;
    }
  }

  final Map<String, Future<DocumentBuffer>> _loadingBuffers = {};
  Future<DocumentBuffer> buffer(
    String id, {
    Map<String, dynamic>? recovery,
  }) async {
    if (Uri.parse(id).scheme != 'file')
      throw CoreFailure(
        'resource.readonly',
        'Bundled standard resources are read-only; no editable physical file is associated with this identity',
      );
    final path = accessFor(Uri.parse(id).toFilePath())
        .pathFor(Uri.parse(id).toFilePath());
    id = Uri.file(path).toString();
    final existing = store.buffers[id];
    if (existing != null) return Future.value(existing);
    _verifyVirtualResource(id);
    final loading = _loadingBuffers[id];
    if (loading != null) return loading;
    final future = _loadBuffer(id, recovery: recovery);
    _loadingBuffers[id] = future;
    return future.whenComplete(() {
      if (identical(_loadingBuffers[id], future)) _loadingBuffers.remove(id);
    });
  }

  Future<DocumentBuffer> _loadBuffer(
    String id, {
    Map<String, dynamic>? recovery,
  }) async {
    if (store.buffers.containsKey(id)) return store.get(id);
    final fileAccess = accessFor(Uri.parse(id).toFilePath());
    final path = fileAccess.pathFor(Uri.parse(id).toFilePath());
    final DocumentBuffer b;
    if (recovery != null && await fileAccess.missing(path)) {
      if (recovery['id'] != id ||
          recovery['path'] != path ||
          (recovery['text'] as String).length > 16 * 1024 * 1024) {
        throw CoreFailure(
          'recovery.identity',
          'Recovery identity or size is unsafe',
        );
      }
      b = DocumentBuffer.decode(
        path,
        utf8.encode(recovery['baseline'] as String),
      );
      b.externalConflict = true;
    } else {
      b = DocumentBuffer.decode(
        path,
        await fileAccess.read(path),
        mode: await fileAccess.mode(path),
      );
    }
    if (store.buffers.length >= 512 ||
        store.buffers.values.fold<int>(
              b.text.length * 2,
              (n, b) => n + b.text.length * 2,
            ) >
            256 * 1024 * 1024) {
      throw CoreFailure(
        'limit.buffers',
        'Open buffers exceed the memory budget; close a project before opening more resources',
      );
    }
    store.buffers[id] = b;
    return b;
  }

  Future<Map<String, dynamic>> check(
    String root, {
    bool saved = false,
    String? requestId,
    bool measure = false,
    bool schemaEvaluation = true,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
    void Function(Map<String, dynamic> result)? onProgress,
    void Function(AnalysisSnapshot snapshot)? onSnapshot,
  }) async {
    void ensureActive() {
      if (_closed)
        throw CoreFailure('access.closed', 'The analysis owner is closed');
      if (cancelled?.call() ?? false)
        throw CoreFailure('cancelled', 'Snapshot analysis was cancelled');
    }

    ensureActive();
    var configurationScope = await _refreshResourceConfiguration(
      saved: saved,
      onResourceRefreshed: onResourceRefreshed,
    );
    ensureActive();
    await engine.start();
    ensureActive();
    final clock = Stopwatch()..start();
    var collection = 0, ipc = 0, coherence = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0)
        configurationScope = await _refreshResourceConfiguration(
          saved: saved,
          onResourceRefreshed: onResourceRefreshed,
        );
      final resourceRevision = _resourceRevision;
      final resources = <String, Map<String, Object?>>{},
          disk = <String, String>{};
      final configuration = configurationScope.source,
          resourceMappings = configurationScope.mappings;
      if (configuration != null &&
          (saved || store.buffers[configuration['id']]?.dirty != true))
        disk[configuration['id'] as String] =
            configuration['identity'] as String;
      Future<void> collect(String id) async {
        ensureActive();
        if (Uri.parse(id).scheme != 'file') {
          final source = await _bundledStandard(id);
          ensureActive();
          if (source != null) {
            final canonical = source['id'] as String,
                previous = resources[canonical];
            resources[canonical] = {
              ...source,
              'aliases': {
                ...(source['aliases'] as List),
                ...(previous?['aliases'] as List? ?? []),
              }.toList()..sort(),
            };
            if (resources.length > 2048 ||
                resources.values.fold<int>(
                      0,
                      (n, r) => n + (r['text'] as String).length * 6,
                    ) >
                    48 * 1024 * 1024)
              throw CoreFailure(
                'limit.snapshot',
                'Bundled resources exceed the snapshot budget',
              );
            return;
          }
          throw CoreFailure(
            'resource.unavailable',
            'External resource needs an approved local mapping',
          );
        }
        if (resources.length >= 2048) {
          throw CoreFailure('limit.resources', 'Dependency count exceeds 2048');
        }
        final fileAccess = accessFor(Uri.parse(id).toFilePath());
        final path = fileAccess.pathFor(Uri.parse(id).toFilePath());
        final b = store.buffers[id];
        if (!saved) _verifyVirtualResource(id);
        if (!saved && b != null) {
          if (!b.dirty && !b.externalConflict) {
            final before = (b.generation, b.externalConflict);
            await refreshDisk(b);
            if (before != (b.generation, b.externalConflict))
              onResourceRefreshed?.call(id);
          }
          resources[id] = await b.snapshotAsync();
          if (!b.dirty && !b.externalConflict) disk[id] = b.diskIdentity;
        } else {
          final bytes = await fileAccess.read(path);
          final b = DocumentBuffer.decode(path, bytes);
          resources[id] = b.snapshot();
          disk[id] = contentIdentity(bytes);
        }
        final aliases =
            resourceMappings.entries
                .where((entry) => entry.value == id)
                .map((entry) => entry.key)
                .toList()
              ..sort();
        if (aliases.isNotEmpty)
          resources[id] = {...resources[id]!, 'aliases': aliases};
        if (resources.values.fold<int>(
              0,
              (n, r) => n + (r['text'] as String).length * 6,
            ) >
            48 * 1024 * 1024) {
          throw CoreFailure(
            'limit.snapshot',
            'Snapshot exceeds the bounded text budget; analysis did not complete',
          );
        }
      }

      final collectionStart = clock.elapsedMicroseconds;
      await collect(root);
      final known = (dependencies[root] ?? <String>{})
          .where((id) => id != root && id != _manifestResource)
          .toList();
      if (known.length + 1 > 2048) {
        throw CoreFailure('limit.resources', 'Dependency count exceeds 2048');
      }
      await _resourceBatch(known, (id) async {
        try {
          await collect(resourceMappings[id] ?? id);
        } on CoreFailure catch (e) {
          if (e.code.startsWith('limit.')) rethrow;
        }
      });
      collection += clock.elapsedMicroseconds - collectionStart;
      Map<String, dynamic>? result;
      AnalysisSnapshot? snapshot;
      final unavailable = <String>{};
      for (var depth = 0; depth < 129; depth++) {
        ensureActive();
        snapshot = AnalysisSnapshot(
          root: root,
          resources: resources.values.toList()
            ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String)),
          boundaries: approvedContexts,
          engineIdentity: engine.assetIdentity,
          configuration: [if (configuration != null) configuration],
        );
        final ipcStart = clock.elapsedMicroseconds;
        result = await engine.request('analyse', {
          ...snapshot.toJson(),
          if (measure) 'measure': true,
        }, requestId: requestId == null ? null : '$requestId-$depth-$attempt');
        ensureActive();
        ipc += clock.elapsedMicroseconds - ipcStart;
        if (result['snapshot'] != snapshot.identity) {
          throw CoreFailure(
            'engine.snapshot',
            'Analysis returned an unrelated snapshot identity',
          );
        }
        if (result['info'] != null) {
          final reached = <String>{root};
          for (final ref in result['references'] as List? ?? []) {
            if (ref['resource'] is String) {
              reached.add(ref['resource'] as String);
            }
            if (ref['targetResource'] is String) {
              reached.add(ref['targetResource'] as String);
            }
            reached.addAll(
              List<String>.from(ref['candidateResources'] as List? ?? const []),
            );
          }
          final obsolete = resources.keys
              .where((id) => !reached.contains(id))
              .toList();
          if (obsolete.isNotEmpty) {
            for (final id in obsolete) {
              resources.remove(id);
              disk.remove(id);
            }
            continue; // Recheck after a dependency was removed; no stale resource can poison a clean graph.
          }
        }
        final missing = <String>{};
        for (final ref in result['references'] as List? ?? []) {
          final target = ref['targetResource'];
          if (target is! String) continue;
          final id = target;
          if (!resources.containsKey(id) && !unavailable.contains(id)) {
            missing.add(id);
          }
        }
        if (missing.isEmpty) break;
        if (resources.length + missing.length > 2048) {
          throw CoreFailure('limit.resources', 'Dependency count exceeds 2048');
        }
        final missingStart = clock.elapsedMicroseconds;
        await _resourceBatch(missing, (id) async {
          try {
            final mapped = resourceMappings[id];
            await collect(mapped ?? id);
          } on Object catch (e) {
            if (e is CoreFailure && e.code.startsWith('limit.')) rethrow;
            unavailable.add(id);
          }
        });
        collection += clock.elapsedMicroseconds - missingStart;
        if (depth == 128) {
          throw CoreFailure(
            'limit.graph',
            'Reference graph collection exceeds depth limit',
          );
        }
      }
      final coherenceStart = clock.elapsedMicroseconds;
      var coherent =
          (saved || snapshot!.current(store)) &&
          resourceRevision == _resourceRevision;
      await _resourceBatch(disk.entries, (e) async {
        try {
          if (await contentIdentityAsync(
                await accessFor(Uri.parse(e.key).toFilePath())
                    .read(Uri.parse(e.key).toFilePath()),
              ) !=
              e.value) {
            coherent = false;
          }
        } on Object {
          coherent = false;
        }
      });
      coherence += clock.elapsedMicroseconds - coherenceStart;
      coherent =
          coherent &&
          (saved || snapshot!.current(store)) &&
          resourceRevision == _resourceRevision;
      if (coherent) {
        ensureActive();
        onSnapshot?.call(snapshot!);
        if (!saved) {
          _workingSnapshot = snapshot;
          _workingSnapshotRevision = resourceRevision;
        }
        lastTimings = {
          'collectionUs': collection,
          'ipcAndEngineUs': ipc,
          'coherenceUs': coherence,
          'totalUs': clock.elapsedMicroseconds,
          if (measure) 'engine': result?['timings'],
        };
        final reachable = <String>{root, ...resources.keys, ...unavailable};
        dependencies[root] = {
          ...reachable,
          if (configuration != null) configuration['id'] as String,
        };
        final monitored = {
          ...store.buffers.keys,
          for (final graph in dependencies.values) ...graph,
          for (final policy in _policyDependencies.values) ...policy,
        };
        resourceFingerprints.removeWhere((id, _) => !monitored.contains(id));
        for (final id in {
          ...reachable,
          if (configuration != null) configuration['id'] as String,
        }) {
          final b = store.buffers[id];
          if (!saved && b != null && (b.dirty || b.externalConflict)) {
            // The overlay's baseline is not the latest observed disk version.
            // Keep deletion/replacement/conflict observations across analysis.
            resourceFingerprints.putIfAbsent(id, () => b.diskIdentity);
          } else {
            resourceFingerprints[id] = disk[id] ?? b?.diskIdentity;
          }
        }
        for (final finding in result!['findings'] as List) {
          finding['snapshot'] = snapshot!.sourceIdentity;
        }
        for (final category in (result['categories'] as Map? ?? {}).values) {
          if (category is Map) category['snapshot'] = snapshot!.sourceIdentity;
        }
        result
          ..['contextSnapshot'] = snapshot!.identity
          ..['snapshot'] = snapshot.sourceIdentity
          ..['checkedRoots'] = [root]
          ..['unsaved'] =
              !saved &&
              snapshot.allInputs.any(
                (input) => store.buffers[input['id']]?.dirty ?? false,
              );
        if (!schemaEvaluation) return result;
        final structural = result;
        final structuralCategory = {
          'complete': structural['complete'] == true,
          'producer': 'busyapi',
          'producerVersion': '0.1.0',
          'snapshot': snapshot.sourceIdentity,
          'coverage': structural['coverage']?['openapi'],
        };
        if (structural['specification'] is! Map) {
          return {
            ...structural,
            'categories': {
              ...Map<String, dynamic>.from(
                structural['categories'] as Map? ?? {},
              ),
              'openapi': {
                ...structuralCategory,
                'complete': false,
                'status': 'not-run',
              },
            },
          };
        }
        final progress = <String, dynamic>{
          ...structural,
          'projection': structural,
          'projectionComplete': structural['complete'],
          'complete': false,
          'status': 'checking',
          'categories': {
            ...Map<String, dynamic>.from(
              structural['categories'] as Map? ?? {},
            ),
            'openapi': {
              ...structuralCategory,
              'complete': false,
              'status': 'checking',
            },
          },
        };
        ensureActive();
        onProgress?.call(progress);
        Map<String, dynamic>? evaluated;
        String? executionFailure;
        final schemaStart = clock.elapsedMicroseconds;
        try {
          evaluated = await engine.request(
            'evaluateSchemas',
            snapshot.toJson(),
            requestId: requestId == null ? null : '$requestId-schema-$attempt',
          );
          ensureActive();
          _verifySchemaEvaluation(evaluated, snapshot);
        } on Object catch (e) {
          ensureActive();
          executionFailure = e is CoreFailure ? e.code : 'schema.execution';
          evaluated = null;
        }
        // Evaluation is derived from the frozen input. Its completion cannot
        // accept a changed buffer, new approval, or changed on-disk fragment.
        coherent =
            (saved || snapshot.current(store)) &&
            resourceRevision == _resourceRevision &&
            !_closed;
        await _resourceBatch(disk.entries, (entry) async {
          try {
            final access = accessFor(Uri.parse(entry.key).toFilePath());
            if (await contentIdentityAsync(
                  await access.read(Uri.parse(entry.key).toFilePath()),
                ) !=
                entry.value)
              coherent = false;
          } on Object {
            coherent = false;
          }
        });
        ensureActive();
        if (!coherent ||
            (!saved && !snapshot.current(store)) ||
            resourceRevision != _resourceRevision)
          continue;
        lastTimings['schemaUs'] = clock.elapsedMicroseconds - schemaStart;
        lastTimings['totalUs'] = clock.elapsedMicroseconds;
        return _mergeSchemaEvaluation(
          snapshot,
          structural,
          evaluated,
          executionFailure,
        );
      }
    }
    throw CoreFailure(
      'snapshot.changed',
      'Could not collect a coherent snapshot; resources kept changing',
    );
  }

  static void _verifySchemaEvaluation(
    Map<String, dynamic> result,
    AnalysisSnapshot snapshot,
  ) {
    final resources = {
      for (final resource in snapshot.resources) resource['id']: resource,
    };
    bool located(dynamic value) =>
        value is Map &&
        resources.containsKey(value['resource']) &&
        value['pointer'] is String &&
        (value['pointer'] as String).length <= 16384;
    final valid =
        result['version'] == 1 &&
        result['snapshot'] == snapshot.identity &&
        result['root'] == snapshot.root &&
        result['producer'] == 'hyperjump+busyapi-exact' &&
        result['producerVersion'] == _schemaProducerVersion &&
        result['complete'] is bool &&
        result['configuration'] is String &&
        result['coverage'] is Map &&
        result['schemas'] is int &&
        result['instances'] is int &&
        result['evaluations'] is List &&
        (result['evaluations'] as List).length <= 20000 &&
        (result['evaluations'] as List).every(
          (value) =>
              located(value) &&
              value['valid'] is bool &&
              located(value['schema']),
        ) &&
        result['skipped'] is List &&
        (result['skipped'] as List).length <= 20000 &&
        (result['skipped'] as List).every(located) &&
        result['findings'] is List &&
        (result['findings'] as List).length <= 201 &&
        (result['findings'] as List).every((value) {
          if (!located(value) ||
              value['code'] is! String ||
              value['message'] is! String ||
              !const [
                'error',
                'warning',
                'information',
                'hint',
              ].contains(value['severity']) ||
              value['category'] != 'openapi' ||
              value['snapshot'] != snapshot.identity)
            return false;
          final range = value['range'];
          return range is List &&
              range.length == 2 &&
              range[0] is int &&
              range[1] is int &&
              (range[0] as int) >= 0 &&
              (range[1] as int) >= (range[0] as int) &&
              (range[1] as int) <=
                  (resources[value['resource']]!['text'] as String).length;
        });
    if (!valid)
      throw CoreFailure(
        'schema.protocol',
        'The schema worker returned an invalid or unrelated evaluation',
      );
  }

  SemanticSearchJob semanticSearch({
    void Function(String resource)? onResourceRefreshed,
  }) => SemanticSearchJob._(this, onResourceRefreshed);

  Future<SemanticSearchSnapshot> _searchSemantic(
    String query,
    String category,
    String requestId,
    bool Function() cancelled,
    void Function(String resource)? refreshed,
  ) async {
    if (query.length > 4096)
      throw CoreFailure(
        'limit.search.query',
        'Choose a bounded semantic query',
      );
    if (roots.isEmpty)
      throw CoreFailure(
        'search.roots',
        'No API root is configured or discovered',
      );
    final revision = _resourceRevision,
        snapshots = <AnalysisSnapshot>[],
        matches = <Map<String, dynamic>>[];
    var complete = true, bytes = 0;
    void active() {
      if (cancelled())
        throw CoreFailure('search.cancelled', 'Semantic search was cancelled');
      if (_closed ||
          revision != _resourceRevision ||
          snapshots.any((s) => !s.current(store)))
        throw CoreFailure(
          'search.stale',
          'The project changed during semantic search',
        );
    }

    for (final entry in List<ProjectRoot>.of(roots)) {
      active();
      final checked = await check(
        entry.id,
        schemaEvaluation: false,
        requestId: '$requestId${snapshots.length}:collect',
        cancelled: cancelled,
        onResourceRefreshed: refreshed,
      );
      active();
      final snapshot = _workingSnapshot;
      if (snapshot == null ||
          snapshot.root != entry.id ||
          snapshot.identity != checked['contextSnapshot'])
        throw CoreFailure(
          'search.stale',
          'The root context changed during semantic search',
        );
      bytes += snapshot.resources.fold<int>(
        0,
        (n, r) => n + (r['text'] as String).length * 2,
      );
      if (bytes > 64 * 1024 * 1024)
        throw CoreFailure(
          'limit.search',
          'Semantic search input exceeds its 64 MiB captured-root budget',
        );
      snapshots.add(snapshot);
      final found = await engine.request('semanticSearch', {
        ...snapshot.toJson(),
        'query': query,
        'category': category,
      }, requestId: '$requestId${snapshots.length}:index');
      active();
      if (found['snapshot'] != snapshot.identity ||
          found['root'] != entry.id ||
          found['version'] != 1 ||
          found['complete'] is! bool ||
          found['matches'] is! List)
        throw CoreFailure(
          'search.protocol',
          'Semantic search returned an unrelated result',
        );
      complete = complete && found['complete'] == true;
      for (final match in found['matches'] as List) {
        if (match is! Map ||
            match['root'] != entry.id ||
            match['resource'] is! String ||
            match['pointer'] is! String ||
            match['semanticId'] is! String ||
            match['range'] is! List ||
            (match['range'] as List).length != 2)
          throw CoreFailure(
            'search.protocol',
            'Semantic search returned an invalid source occurrence',
          );
        final resource = snapshot.resources
            .where((r) => r['id'] == match['resource'])
            .firstOrNull;
        final range = match['range'] as List;
        if (range.any((v) => v is! int))
          throw CoreFailure(
            'search.protocol',
            'Semantic search returned an invalid source range',
          );
        final start = range[0] as int, end = range[1] as int;
        if (resource == null ||
            match['identity'] != resource['identity'] ||
            match['generation'] != resource['generation'] ||
            start < 0 ||
            end < start ||
            end > (resource['text'] as String).length)
          throw CoreFailure(
            'search.protocol',
            'Semantic search returned an invalid source range',
          );
        matches.add(Map<String, dynamic>.from(match));
        if (matches.length > 20000)
          throw CoreFailure(
            'limit.search.matches',
            'Refine the semantic query',
          );
      }
    }
    active();
    return SemanticSearchSnapshot._(
      this,
      revision,
      List.unmodifiable(snapshots),
      matches,
      complete,
    );
  }

  /// Lazy object pages consume the same approved coherent graph as checks.
  /// No renderer or field owns a resource loader or a second mutable document.
  Future<Map<String, dynamic>> inspectObject(
    String root,
    String resource,
    String pointer, {
    int offset = 0,
  }) async {
    final (snapshot, revision) = await _objectSnapshot(root, resource);
    final result = await engine.request('inspect', {
      ...snapshot.toJson(),
      'resource': resource,
      'pointer': pointer,
      'offset': offset,
    });
    if (_closed ||
        !snapshot.current(store) ||
        result['snapshot'] != snapshot.identity ||
        revision != _resourceRevision) {
      throw CoreFailure(
        'inspect.stale',
        'The object changed while its page was loading',
      );
    }
    return result;
  }

  /// Fetch a complete, explicitly selected form value, never a second source
  /// document. Large values stay out of ordinary object-page projections.
  Future<String> readDataValue(
    Map<String, dynamic> target, {
    bool text = false,
    String? requestId,
    bool Function()? cancelled,
  }) async {
    final root = target['root'] as String,
        resource = target['resource'] as String,
        pointer = target['pointer'] as String,
        generation = target['generation'] as int,
        range = List<int>.unmodifiable(target['range'] as List);
    if (range.length != 2 || range[0] < 0 || range[1] < range[0]) {
      throw CoreFailure('data.value.target', 'Choose a captured source range');
    }
    final (snapshot, revision) = await _objectSnapshot(
      root,
      resource,
      requestId: requestId,
      cancelled: cancelled,
    );
    final captured = snapshot.resources.singleWhere((r) => r['id'] == resource);
    if (captured['generation'] != generation) {
      throw CoreFailure(
        'data.value.stale',
        'The captured value changed before editing',
      );
    }
    final representation = text ? 'text' : 'json';
    final result = await engine.request('readDataValue', {
      ...snapshot.toJson(),
      'target': {
        'resource': resource,
        'pointer': pointer,
        'generation': generation,
        'range': range,
      },
      'representation': representation,
    }, requestId: requestId);
    if (cancelled?.call() == true)
      throw CoreFailure('cancelled', 'Data editing closed');
    if (_closed || revision != _resourceRevision || !snapshot.current(store)) {
      throw CoreFailure(
        'data.value.stale',
        'The source changed while the form value was being read',
      );
    }
    if (result['version'] != 1 ||
        result['snapshot'] != snapshot.identity ||
        result['root'] != root ||
        result['resource'] != resource ||
        result['generation'] != captured['generation'] ||
        result['pointer'] != pointer ||
        jsonEncode(result['range']) != jsonEncode(range) ||
        result['representation'] != representation ||
        result['value'] is! String ||
        (result['value'] as String).length > 16 * 1024 * 1024) {
      throw CoreFailure(
        'data.value.protocol',
        'The worker returned an invalid or unrelated data value',
      );
    }
    return result['value'] as String;
  }

  Future<ReferenceChoicePage> referenceChoices(
    String root,
    String resource,
    String pointer, {
    String keyword = r'$ref',
    SecurityBindingForm? bindingForm,
    String query = '',
    int offset = 0,
    String? requestId,
    bool Function()? cancelled,
  }) async {
    void active() {
      if (cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Reference selector closed');
    }

    active();
    final (snapshot, revision) = await _objectSnapshot(
      root,
      resource,
      requestId: requestId == null ? null : '$requestId:snapshot',
      cancelled: cancelled,
    );
    active();
    final result = await engine.request('referenceChoices', {
      ...snapshot.toJson(),
      'resource': resource,
      'pointer': pointer,
      'keyword': keyword,
      if (bindingForm != null) 'bindingForm': bindingForm.name,
      'query': query,
      'offset': offset,
    }, requestId: requestId);
    active();
    if (_closed ||
        !snapshot.current(store) ||
        revision != _resourceRevision ||
        result['snapshot'] != snapshot.identity) {
      throw CoreFailure(
        'reference.choice.stale',
        'The source changed while loading reference targets',
      );
    }
    bool validLocation(Object? location) {
      if (location is! Map ||
          location['root'] != root ||
          location['pointer'] is! String)
        return false;
      final input = snapshot.resources
          .where((r) => r['id'] == location['resource'])
          .firstOrNull;
      final range = location['range'];
      return input != null &&
          location['generation'] == input['generation'] &&
          range is List &&
          range.length == 2 &&
          range.every((v) => v is int) &&
          (range[0] as int) >= 0 &&
          (range[1] as int) >= (range[0] as int) &&
          (range[1] as int) <= (input['text'] as String).length;
    }

    final count = result['count'],
        start = result['offset'],
        entries = result['entries'];
    if (result['version'] != 1 ||
        result['resource'] != resource ||
        result['pointer'] != pointer ||
        result['keyword'] != keyword ||
        result['bindingForm'] != bindingForm?.name ||
        result['kind'] is! String ||
        result['targetKind'] is! String ||
        (result['targetKind'] as String).isEmpty ||
        (result['targetKind'] as String).length > 64 ||
        result['complete'] is! bool ||
        !validLocation(result) ||
        count is! int ||
        count < 0 ||
        count > 20000 ||
        start is! int ||
        start < 0 ||
        start % 50 != 0 ||
        entries is! List ||
        entries.length > 50 ||
        start + entries.length > count ||
        !entries.every(
          (entry) =>
              entry is Map &&
              validLocation(entry['target']) &&
              entry['semanticId'] is String &&
              entry['label'] is String &&
              (entry['label'] as String).length <= 512 &&
              entry['value'] is String &&
              (entry['value'] as String).length <= 65536 &&
              entry['kind'] == result['targetKind'] &&
              (keyword == 'security'
                  ? SecurityBindingForm.values.any(
                          (form) => form.name == entry['bindingForm'],
                        ) &&
                        (bindingForm == null ||
                            entry['bindingForm'] == bindingForm.name)
                  : entry['bindingForm'] == null) &&
              const [
                'component',
                'schema-resource',
                'inline',
              ].contains(entry['role']) &&
              entry['selected'] is bool &&
              entry['reference'] is bool &&
              entry['sharedSource'] is bool,
        )) {
      throw CoreFailure(
        'reference.choice.response',
        'Invalid typed reference response',
      );
    }
    return ReferenceChoicePage._(this, snapshot, revision, result);
  }

  Future<RefactoringPlan> planReferenceSelection(
    ReferenceChoicePage page,
    int index, {
    String? requestId,
    bool Function()? cancelled,
  }) async {
    if (cancelled?.call() == true)
      throw CoreFailure('cancelled', 'Reference selection closed');
    if (!identical(page._owner, this) || !page.current) {
      throw CoreFailure(
        'reference.choice.stale',
        'The captured reference targets changed',
      );
    }
    final entries = page.result['entries'] as List;
    if (index < 0 || index >= entries.length)
      throw CoreFailure(
        'reference.choice.index',
        'The captured reference target is unavailable',
      );
    final choice = entries[index] as Map;
    final plan = await _planSemantic(
      'planReference',
      page._capture(page.result),
      {
        'keyword': page.result['keyword'],
        'choice': {
          ...page._capture(choice['target'] as Map),
          if (page.result['keyword'] == 'security') ...{
            'bindingForm': choice['bindingForm'],
            'value': choice['value'],
          },
        },
      },
      expectedSnapshot: page._snapshot,
      requestId: requestId,
      cancelled: cancelled,
    );
    if (!page.current)
      throw CoreFailure(
        'reference.choice.stale',
        'The captured reference targets changed',
      );
    return plan;
  }

  /// Read one authored schema-tree level. A reference remains a navigation
  /// edge; it does not ask this service to recursively materialize definitions.
  Future<Map<String, dynamic>> schemaTree(
    String root,
    String resource,
    String pointer, {
    int offset = 0,
    String? requestId,
    bool Function()? cancelled,
    String? reveal,
  }) async {
    if (cancelled?.call() == true) {
      throw CoreFailure('cancelled', 'Tree closed');
    }
    final (snapshot, revision) = await _objectSnapshot(
      root,
      resource,
      requestId: requestId == null ? null : '$requestId:snapshot',
      cancelled: cancelled,
    );
    if (cancelled?.call() == true) {
      throw CoreFailure('cancelled', 'Tree closed');
    }
    final result = await engine.request('schemaTree', {
      ...snapshot.toJson(),
      'resource': resource,
      'pointer': pointer,
      'offset': offset,
      if (reveal != null) 'reveal': reveal,
    }, requestId: requestId);
    if (_closed ||
        !snapshot.current(store) ||
        result['snapshot'] != snapshot.identity ||
        revision != _resourceRevision) {
      throw CoreFailure(
        'schema.tree.stale',
        'The schema changed while loading',
      );
    }
    const kinds = ['schema', 'schema-map', 'schema-array'];
    bool validNode(Object? value) {
      if (value is! Map ||
          value['root'] != root ||
          value['resource'] != resource ||
          value['generation'] !=
              snapshot.resources.firstWhere(
                (r) => r['id'] == resource,
              )['generation'] ||
          value['pointer'] is! String ||
          !kinds.contains(value['kind']) ||
          value['name'] is! String ||
          value['childCount'] is! int ||
          (value['childCount'] as int) < 0 ||
          value['references'] is! List ||
          (value['references'] as List).length > 2 ||
          (value['childCount'] as int) > 400000 ||
          (value['name'] as String).length > 512 ||
          !(value['pointer'] as String).startsWith('/') &&
              value['pointer'] != '' ||
          value.containsKey('boolean') && value['boolean'] is! bool ||
          value.containsKey('required') && value['required'] is! bool ||
          value.containsKey('types') &&
              (value['types'] is! List ||
                  (value['types'] as List).length > 16 ||
                  !(value['types'] as List).every(
                    (v) => v is String && v.length <= 512,
                  ))) {
        return false;
      }
      final range = value['range'];
      return range is List &&
          range.length == 2 &&
          range.every((v) => v is int) &&
          (range[0] as int) >= 0 &&
          (range[1] as int) >= (range[0] as int) &&
          (range[1] as int) <=
              (snapshot.resources.firstWhere((r) => r['id'] == resource)['text']
                      as String)
                  .length;
    }

    if (result['version'] != 1 ||
        !validNode(result['node']) ||
        result['node']['pointer'] != pointer ||
        result['entries'] is! List ||
        (result['entries'] as List).length > 50 ||
        result['node']['childCount'] != result['count'] ||
        !(result['entries'] as List).every(
          (value) =>
              validNode(value) &&
              ((value as Map)['pointer'] as String).startsWith('$pointer/') &&
              !((value)['pointer'] as String)
                  .substring(pointer.length + 1)
                  .contains('/'),
        ) ||
        result['count'] is! int ||
        (result['count'] as int) < 0 ||
        result['offset'] is! int ||
        (result['offset'] as int) < 0 ||
        result.containsKey('revealOffset') &&
            (result['revealOffset'] is! int ||
                (result['revealOffset'] as int) < 0 ||
                (result['revealOffset'] as int) >= (result['count'] as int)) ||
        (result['offset'] as int) + (result['entries'] as List).length >
            (result['count'] as int)) {
      throw CoreFailure('schema.tree.response', 'Invalid schema tree response');
    }
    return result;
  }

  /// Read-only documentation uses canonical context and exact source data.
  /// Locations are physical occurrences, not a renderer's flattened bundle.
  Future<Map<String, dynamic>> referencePage(
    String root,
    String resource,
    String pointer, {
    int offset = 0,
    int textOffset = 0,
    int parameterOffset = 0,
    int contextOffset = 0,
    String? occurrence,
    bool definitionOnly = false,
    bool data = false,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    final (snapshot, revision) = await _objectSnapshot(
      root,
      resource,
      onResourceRefreshed: onResourceRefreshed,
    );
    final result = await engine.request('referencePage', {
      ...snapshot.toJson(),
      'resource': resource,
      'pointer': pointer,
      'offset': offset,
      'textOffset': textOffset,
      'parameterOffset': parameterOffset,
      'contextOffset': contextOffset,
      if (occurrence != null) 'occurrence': occurrence,
      'definitionOnly': definitionOnly,
      'data': data,
    });
    if (_closed ||
        !snapshot.current(store) ||
        result['snapshot'] != snapshot.identity ||
        revision != _resourceRevision) {
      throw CoreFailure(
        'reference.stale',
        'The documentation source changed while its page was loading',
      );
    }
    if (result['version'] != 1 ||
        result['root'] != root ||
        result['resource'] != resource ||
        result['pointer'] != pointer ||
        result['entries'] is! List ||
        result['references'] is! List ||
        result['count'] is! int ||
        result['offset'] is! int ||
        result['effective'] is! List ||
        result['defaults'] is! List ||
        result['issues'] is! List ||
        result['complete'] is! bool ||
        result['previews'] is! List ||
        result['previewsLimited'] is! bool ||
        occurrence != null &&
            !definitionOnly &&
            result['occurrence'] != occurrence ||
        definitionOnly && result['occurrence'] != null) {
      throw CoreFailure(
        'reference.response',
        'The documentation worker returned an invalid page',
      );
    }
    final resources = {
      for (final resource in snapshot.resources) resource['id']: resource,
    };
    bool located(Object? value) {
      if (value is! Map ||
          value['root'] != root ||
          value['resource'] is! String ||
          value['pointer'] is! String)
        return false;
      final source = resources[value['resource']];
      final range = value['range'];
      return source != null &&
          value['generation'] == source['generation'] &&
          range is List &&
          range.length == 2 &&
          range.every((offset) => offset is int) &&
          (range[0] as int) >= 0 &&
          (range[1] as int) >= (range[0] as int) &&
          (range[1] as int) <= (source['text'] as String).length;
    }

    bool excerpt(Map value, int maximum) =>
        value['text'] == null ||
        value['text'] is String &&
            (value['text'] as String).length <= maximum &&
            value['textOffset'] is int &&
            value['textEnd'] is int &&
            value['textLength'] is int &&
            (value['textOffset'] as int) >= 0 &&
            (value['textEnd'] as int) - (value['textOffset'] as int) ==
                (value['text'] as String).length &&
            (value['textEnd'] as int) <= (value['textLength'] as int);
    bool valid =
        located(result) &&
        excerpt(result, 16384) &&
        (result['count'] as int) >= 0 &&
        (result['offset'] as int) >= 0 &&
        (result['entries'] as List).length <= 50 &&
        (result['issues'] as List).length <= 50 &&
        (result['entries'] as List).every(
          (entry) =>
              entry is Map &&
              located(entry) &&
              entry['name'] is String &&
              entry['count'] is int &&
              (entry['count'] as int) >= 0 &&
              excerpt(entry, 240),
        ) &&
        (result['references'] as List).every(
          (ref) =>
              ref is Map &&
              ref['value'] is String &&
              ref['resolution'] is String &&
              located(ref['source']) &&
              (ref['target'] == null || located(ref['target'])) &&
              (ref['dynamic'] == null ||
                  ref['dynamic'] is Map &&
                      ref['dynamic']['candidates'] is List &&
                      (ref['dynamic']['candidates'] as List).every(located)),
        ) &&
        (result['effective'] as List).every(
          (field) =>
              field is Map &&
              field['name'] is String &&
              (field['source'] == null || located(field['source'])) &&
              (field['entries'] == null ||
                  field['entries'] is List &&
                      (field['entries'] as List).length <= 50 &&
                      field['count'] is int &&
                      field['offset'] is int &&
                      (field['entries'] as List).every(
                        (entry) =>
                            entry is Map &&
                            located(entry['source']) &&
                            (entry['definition'] == null ||
                                located(entry['definition'])),
                      )),
        ) &&
        (result['previews'] as List).length <= 50 &&
        (result['previews'] as List).every(
          (preview) =>
              preview is Map &&
              located(preview['source']) &&
              preview['name'] is String &&
              preview['label'] is String &&
              preview['depth'] is int &&
              (preview['text'] == null ||
                  preview['text'] is String &&
                      (preview['text'] as String).length <= 4096),
        ) &&
        (result['defaults'] as List).every(
          (field) => field is Map && field['name'] is String,
        ) &&
        (result['issues'] as List).every(
          (issue) =>
              issue is Map &&
              issue['code'] is String &&
              located(issue['source']),
        );
    if (result['kind'] == 'operation') {
      final contexts = result['contexts'];
      bool validContext(Object? context) =>
          context is Map &&
          context['occurrence'] is String &&
          (context['occurrence'] as String).startsWith('$root#/') &&
          (context['occurrence'] as String).length <= root.length + 16385 &&
          context['navigationId'] is String &&
          RegExp(r'^[a-f0-9]{64}$')
              .hasMatch(context['navigationId'] as String) &&
          context['path'] is String &&
          (context['path'] as String).length <= 16384 &&
          context['method'] is String &&
          (context['method'] as String).length <= 256 &&
          const [
            'operation',
            'webhook',
            'callback',
          ].contains(context['role']) &&
          located(context['pathItem']) &&
          context['pathItem']['kind'] == 'path-item';
      valid =
          valid &&
          contexts is List &&
          contexts.length <= 50 &&
          result['contextCount'] is int &&
          (result['contextCount'] as int) >= 0 &&
          (result['contextCount'] as int) <= 40000 &&
          result['contextOffset'] is int &&
          (result['contextOffset'] as int) >= 0 &&
          (result['contextOffset'] as int) <= (result['contextCount'] as int) &&
          (result['contextOffset'] as int) % 50 == 0 &&
          contexts.length ==
              ((result['contextCount'] as int) -
                      (result['contextOffset'] as int))
                  .clamp(0, 50) &&
          result['contextSelectionRequired'] is bool &&
          result['contextSelectionRequired'] ==
              ((result['contextCount'] as int) > 0 &&
                  result['occurrence'] == null) &&
          (result['occurrence'] == null
              ? result['selectedContext'] == null
              : validContext(result['selectedContext']) &&
                    result['selectedContext']['occurrence'] ==
                        result['occurrence']) &&
          contexts.every(validContext) &&
          contexts.map((context) => context['occurrence']).toSet().length ==
              contexts.length &&
          contexts.map((context) => context['navigationId']).toSet().length ==
              contexts.length;
    }
    if (!valid)
      throw CoreFailure(
        'reference.response',
        'The documentation worker returned invalid source locations or bounded content',
      );
    return _freezeResult(result);
  }

  Future<(AnalysisSnapshot, int)> _objectSnapshot(
    String root,
    String resource, {
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    if (_closed)
      throw CoreFailure('access.closed', 'The source workspace is closed');
    if (cancelled?.call() ?? false)
      throw CoreFailure('cancelled', 'Source assistance was cancelled');
    var snapshot = _workingSnapshot;
    if (snapshot == null ||
        snapshot.root != root ||
        !snapshot.current(store) ||
        _workingSnapshotRevision != _resourceRevision) {
      await check(
        root,
        requestId: requestId,
        cancelled: cancelled,
        schemaEvaluation: false,
        onResourceRefreshed: onResourceRefreshed,
      );
      snapshot = _workingSnapshot;
    }
    if (snapshot == null ||
        !snapshot.resources.any((r) => r['id'] == resource)) {
      throw CoreFailure(
        'inspect.resource',
        'The object is not in this root’s approved snapshot',
      );
    }
    final revision = _workingSnapshotRevision;
    if (cancelled?.call() ?? false)
      throw CoreFailure('cancelled', 'Source assistance was cancelled');
    if (snapshot.root != root ||
        revision != _resourceRevision ||
        !snapshot.current(store)) {
      throw CoreFailure(
        'inspect.stale',
        'The resource context changed while its snapshot was being collected',
      );
    }
    return (snapshot, revision);
  }

  Future<SourceAssistance> assistSource(
    String root,
    String resource,
    SourceSelection selection, {
    String action = 'completion',
  }) => sourceAssistance(root, resource, selection).run(action);

  SourceAssistanceJob sourceAssistance(
    String root,
    String resource,
    SourceSelection selection, {
    void Function(String resource)? onResourceRefreshed,
  }) => SourceAssistanceJob._(
    this,
    root,
    resource,
    selection,
    onResourceRefreshed,
  );

  Future<SourceAssistance> _assistSource(
    String root,
    String resource,
    SourceSelection selection, {
    required String action,
    required String requestId,
    required bool Function() cancelled,
    SourceRange? viewport,
    List<String> foldedPointers = const [],
    void Function(String resource)? onResourceRefreshed,
  }) async {
    final (snapshot, revision) = await _objectSnapshot(
      root,
      resource,
      requestId: '$requestId-collect',
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
    );
    if (cancelled())
      throw CoreFailure('cancelled', 'Source assistance was cancelled');
    final result = await engine.request(
      action == 'folds' ? 'sourceFolds' : 'assistSource',
      {
        ...snapshot.toJson(),
        'resource': resource,
        'caret': selection.extent,
        'action': action,
        if (viewport != null) ...{'from': viewport.start, 'to': viewport.end},
        if (action == 'folds') 'folded': foldedPointers,
      },
      requestId: requestId,
    );
    if (cancelled())
      throw CoreFailure('cancelled', 'Source assistance was cancelled');
    if (_closed ||
        !snapshot.current(store) ||
        result['snapshot'] != snapshot.identity ||
        revision != _resourceRevision) {
      throw CoreFailure(
        'assist.stale',
        'The source changed while assistance was being prepared',
      );
    }
    if (result['root'] != root ||
        result['resource'] != resource ||
        result['caret'] != selection.extent ||
        result['completions'] is! List) {
      throw CoreFailure(
        'assist.protocol',
        'Source assistance returned an unrelated or malformed location',
      );
    }
    if (action == 'folds') {
      final source = snapshot.resources.firstWhere((r) => r['id'] == resource);
      final length = (source['text'] as String).length;
      final folds = result['folds'];
      if (result['version'] != 1 ||
          result['generation'] != source['generation'] ||
          result['from'] != (viewport?.start ?? 0) ||
          result['to'] != (viewport?.end ?? length) ||
          result['complete'] is! bool ||
          folds is! List ||
          folds.length > 20000 ||
          !folds.every(
            (f) =>
                f is Map &&
                f['pointer'] is String &&
                (f['pointer'] as String).length <= 16384 &&
                f['header'] is int &&
                f['start'] is int &&
                f['end'] is int &&
                f['flow'] is bool &&
                ['object', 'array', 'scalar'].contains(f['kind']) &&
                (f['header'] as int) >= 0 &&
                (f['header'] as int) <= (f['start'] as int) &&
                (f['start'] as int) < (f['end'] as int) &&
                (f['end'] as int) <= length,
          )) {
        throw CoreFailure(
          'assist.protocol',
          'Source folding returned invalid physical ranges',
        );
      }
    }
    return SourceAssistance._(
      this,
      snapshot,
      revision,
      resource,
      selection,
      Map.unmodifiable(result),
    );
  }

  Future<RefactoringPlan> planSchemaSuggestion(
    String root,
    String resource,
    String pointer,
    Map<String, Object?> target, {
    bool nullable = false,
  }) async {
    final (snapshot, revision) = await _objectSnapshot(root, resource);
    final result = await engine.request('planSchemaSuggestion', {
      ...snapshot.toJson(),
      'resource': resource,
      'pointer': pointer,
      'target': target,
      'nullable': nullable,
    });
    if (_closed ||
        revision != _resourceRevision ||
        !snapshot.current(store) ||
        result['snapshot'] != snapshot.identity)
      throw CoreFailure(
        'refactor.stale',
        'The example or destination changed while preparing the suggestion',
      );
    return RefactoringPlan._(this, revision, [snapshot], result);
  }

  /// Freeze all configured entry descriptions separately: implicit component
  /// names in a shared fragment can mean different things in different roots.
  /// Freeze one selected root and its approved dependencies. GUI and CLI use
  /// this same derived transformation; later edits label this result outdated
  /// but never retarget its source, output location or published provenance.
  Future<BundleOutput> prepareBundle(
    String root,
    String destination, {
    bool saved = false,
    String? requestId,
    bool Function()? cancelled,
    BundleFormat format = BundleFormat.singleFile,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    if (format == BundleFormat.resourcePackage) {
      return _prepareResourcePackage(
        root,
        destination,
        saved: saved,
        requestId: requestId,
        cancelled: cancelled,
        onResourceRefreshed: onResourceRefreshed,
      );
    }
    final captured = await _captureOutputInput(
      root,
      destination,
      operation: 'bundle',
      saved: saved,
      requestId: requestId,
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
    );
    final outputAccess = captured.access;
    try {
      final target = captured.target,
          snapshot = captured.snapshot,
          checked = captured.checked;
      final outputId = Uri.file(p.join(target, 'openapi.json')).toString();
      final contract = await _deriveContract(
        captured,
        outputId,
        requestId: requestId,
        cancelled: cancelled,
      );
      final result = contract.result;
      final output = result['output'];
      String portable(String id) {
        final uri = Uri.parse(id);
        if (uri.scheme == 'file' &&
            p.isWithin(access.boundary, uri.toFilePath()))
          return './${p.relative(uri.toFilePath(), from: access.boundary)}';
        // Approved external mappings and URL user-info/query need not expose
        // private paths or credentials in routine portable provenance.
        return 'resource:${textIdentity(id)}';
      }

      final provenance = _portableDerivedProvenance(
        contract.provenance,
        portable,
        'openapi.json',
      );
      final metadata = <String, Object?>{
        'version': 1,
        'operation': 'bundle',
        'format': 'single-file',
        'root': portable(root),
        'snapshot': snapshot.sourceIdentity,
        'input': checked['unsaved'] == true ? 'working-copy' : 'saved-source',
        'unsaved': checked['unsaved'] == true,
        'producer': result['producer'],
        'producerVersion': result['producerVersion'],
        'engine': engine.assetIdentity,
        'entry': 'openapi.json',
        'outputIdentity': output['identity'],
        'sources': [
          for (final resource
              in snapshot.resources.toList()..sort(
                (a, b) => (a['id'] as String).compareTo(b['id'] as String),
              ))
            {
              'resource': portable(resource['id'] as String),
              'identity': resource['identity'],
            },
        ],
        'provenance': provenance,
      };
      return BundleOutput._(
        this,
        outputAccess,
        target,
        snapshot,
        saved,
        checked['unsaved'] == true,
        captured.revision,
        result,
        metadata,
        resultAlreadyFrozen: true,
      );
    } on CoreFailure catch (failure) {
      outputAccess.close();
      if (failure is OutputAnalysisFailure) rethrow;
      throw OutputAnalysisFailure(
        failure.code,
        failure.message,
        captured.checked,
        cause: failure,
      );
    } on Object {
      outputAccess.close();
      throw OutputAnalysisFailure(
        'io.failure',
        'Output generation did not complete; source files were not changed',
        captured.checked,
      );
    }
  }

  Future<RefactoringPlan> planComponentRename(
    Map<String, Object?> target,
    String name,
  ) => _planSemantic('planRename', target, {'name': name});

  Future<RefactoringPlan> planOperationMove(
    Map<String, Object?> target, {
    required String method,
    required bool additional,
    required String context,
    String? path,
    String? destinationPointer,
  }) => _planSemantic('planOperationMove', target, {
    'method': method,
    'additional': additional,
    'context': context,
    if (path != null) 'path': path,
    if (destinationPointer != null) 'destinationPointer': destinationPointer,
  });

  Future<RefactoringPlan> planPropertyRename(
    Map<String, Object?> target,
    String name, {
    List<Map<String, Object?>> actions = const [],
  }) => _planSemantic('planPropertyRename', target, {
    'name': name,
    'actions': actions,
  });

  Future<RefactoringPlan> planResponseRename(
    Map<String, Object?> target,
    String status, {
    List<Map<String, Object?>> actions = const [],
  }) => _planSemantic('planResponseRename', target, {
    'name': status,
    'actions': actions,
  });

  Future<RefactoringPlan> planObjectDeletion(Map<String, Object?> target) =>
      _planSemantic('planDelete', target, const {});

  Future<RefactoringPlan> planComponentExtraction(
    Map<String, Object?> target,
    String name, {
    String? destinationResource,
  }) => _planSemantic('planExtract', target, {
    'name': name,
    if (destinationResource != null) 'destinationResource': destinationResource,
  });

  Future<RefactoringPlan> planReferenceInlining(Map<String, Object?> target) =>
      _planSemantic('planInline', target, const {});

  /// Relocate an authored definition into an existing approved destination.
  /// The graph retains a public reference binding only where its family and
  /// position permit it; otherwise the review removes it and repairs consumers.
  Future<RefactoringPlan> planComponentDefinitionMove(
    Map<String, Object?> target,
    String name, {
    required String destinationResource,
  }) => _planSemantic('planMoveDefinition', target, {
    'name': name,
    'destinationResource': destinationResource,
  });

  /// A repair is tied to the originating complete input identity, not merely
  /// to a still-matching diagnostic code at some newer source location.
  Future<RefactoringPlan> planDiagnosticFix(
    Map<String, dynamic> finding, {
    required String contextSnapshot,
    required String fix,
    String? requestId,
    bool Function()? cancelled,
  }) async {
    final diagnostic = _freezeResult(finding);
    final root = diagnostic['root'], resource = diagnostic['resource'];
    if (root is! String ||
        resource is! String ||
        diagnostic['pointer'] is! String ||
        diagnostic['code'] != 'parameter.path.required' ||
        diagnostic['category'] != 'openapi' ||
        diagnostic['producer'] != 'busyapi' ||
        diagnostic['producerVersion'] != '0.1.0' ||
        diagnostic['pointerRedacted'] == true ||
        fix != 'path-parameter-required') {
      throw CoreFailure(
        'fix.unsupported',
        'No deterministic repair is available',
      );
    }
    final (snapshot, _) = await _objectSnapshot(
      root,
      resource,
      requestId: requestId == null ? null : '$requestId:origin',
      cancelled: cancelled,
    );
    if (snapshot.identity != contextSnapshot ||
        diagnostic['snapshot'] != snapshot.sourceIdentity) {
      throw CoreFailure('fix.stale', 'The diagnostic snapshot changed');
    }
    final source = snapshot.resources.firstWhere(
      (entry) => entry['id'] == resource,
    );
    final text = source['text'] as String, range = diagnostic['range'];
    if (range is! List ||
        range.length != 2 ||
        range.any((offset) => offset is! int)) {
      throw CoreFailure(
        'fix.location',
        'The diagnostic has no valid source range',
      );
    }
    final start = range[0] as int, end = range[1] as int;
    if (start < 0 || end < start || end > text.length) {
      throw CoreFailure(
        'fix.location',
        'The diagnostic has no valid source range',
      );
    }
    final plan = await _planSemantic(
      'planDiagnosticFix',
      {
        'root': root,
        'resource': resource,
        'pointer': diagnostic['pointer'],
        'generation': source['generation'],
        'range': range,
        'expected': text.substring(start, end),
      },
      {'diagnostic': diagnostic, 'fix': fix},
      expectedSnapshot: snapshot,
      requestId: requestId,
      cancelled: cancelled,
    );
    if (plan.result['kind'] != 'diagnostic-fix' ||
        plan.result['fix'] != fix ||
        plan.edits.length != 1 ||
        plan.edits.single.buffer != resource ||
        plan.result['changes'] is! List ||
        (plan.result['changes'] as List).length != 1 ||
        plan.result['changes'][0]['resource'] != resource ||
        plan.result['changes'][0]['before'] != text) {
      throw CoreFailure(
        'fix.response',
        'The worker returned an unrelated repair',
      );
    }
    return plan;
  }

  Future<RefactoringPlan> _planSemantic(
    String method,
    Map<String, Object?> target,
    Map<String, Object?> arguments, {
    AnalysisSnapshot? expectedSnapshot,
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    void active() {
      if (cancelled?.call() == true) {
        throw CoreFailure('cancelled', 'Semantic plan was cancelled');
      }
    }

    active();
    await _refreshResourceConfiguration(
      onResourceRefreshed: onResourceRefreshed,
    );
    active();
    final revision = _resourceRevision;
    final snapshots = <AnalysisSnapshot>[];
    for (final entry in List<ProjectRoot>.of(roots)) {
      active();
      await check(
        entry.id,
        schemaEvaluation: false,
        onResourceRefreshed: onResourceRefreshed,
        requestId: requestId == null
            ? null
            : '$requestId:snapshot:${snapshots.length}',
        cancelled: cancelled,
      );
      active();
      final snapshot = _workingSnapshot;
      if (snapshot == null || snapshot.root != entry.id) {
        throw CoreFailure(
          'refactor.snapshot',
          'The selected root has no current snapshot',
        );
      }
      snapshots.add(snapshot);
    }
    bool current() =>
        !_closed &&
        revision == _resourceRevision &&
        snapshots.every((s) => s.current(store));
    if (!current())
      throw CoreFailure(
        'refactor.stale',
        'The project changed while collecting semantic usages',
      );
    // Recollection inspects unopened dependencies too. Buffer-only freshness
    // cannot detect a changed base/dialect or the source behind an alias token.
    // Never reinterpret a captured target choice against a newer graph.
    if (expectedSnapshot != null &&
        !snapshots.any(
          (snapshot) =>
              snapshot.root == expectedSnapshot.root &&
              snapshot.identity == expectedSnapshot.identity,
        )) {
      throw CoreFailure(
        'reference.choice.stale',
        'The captured reference graph changed',
      );
    }
    final resources = <String, Map<String, Object?>>{};
    for (final snapshot in snapshots) {
      for (final resource in snapshot.resources) {
        final id = resource['id'] as String, previous = resources[id];
        if (previous != null &&
            (previous['identity'] != resource['identity'] ||
                previous['generation'] != resource['generation'])) {
          throw CoreFailure(
            'refactor.stale',
            'Root snapshots disagree about a shared resource',
          );
        }
        resources[id] = resource;
      }
    }
    final identity = textIdentity(
      jsonEncode({
        'contexts': [for (final s in snapshots) s.identity],
        'revision': revision,
      }),
    );
    active();
    final result = await engine.request(method, {
      'snapshot': identity,
      'resources': resources.values.toList(),
      'contexts': [
        for (final s in snapshots)
          {
            'root': s.root,
            'resources': [for (final r in s.resources) r['id']],
          },
      ],
      'target': target,
      if (method == 'planRename' &&
          snapshots.isNotEmpty &&
          snapshots.first.configuration.isNotEmpty)
        'configuration': snapshots.first.configuration.single,
      ...arguments,
    }, requestId: requestId);
    active();
    if (!current() || result['snapshot'] != identity) {
      throw CoreFailure(
        'refactor.stale',
        'The project changed while preparing the semantic plan',
      );
    }
    return RefactoringPlan._(
      this,
      revision,
      List.unmodifiable(snapshots),
      Map.unmodifiable(result),
    );
  }

  Future<Set<String>> applyRefactoring(
    RefactoringPlan plan, {
    bool Function()? current,
  }) async {
    if ((plan.result['blockers'] as List? ?? []).isNotEmpty) {
      throw CoreFailure(
        'refactor.blocked',
        'The reviewed deletion has unresolved consumers; no changes were applied',
      );
    }
    bool valid() =>
        !_closed &&
        identical(plan._owner, this) &&
        plan._revision == _resourceRevision &&
        plan._snapshots.every((s) => s.current(store)) &&
        (current == null || current());
    if (!valid())
      throw CoreFailure(
        'refactor.stale',
        'The reviewed project snapshot changed; no edits were applied',
      );
    final resources = {
      for (final s in plan._snapshots)
        for (final r in s.allInputs)
          if (r['bundled'] != true) r['id'] as String,
    };
    if (plan.edits.any((edit) => _standardResources.containsKey(edit.buffer)))
      throw CoreFailure(
        'refactor.readonly',
        'A refactoring cannot edit a bundled standard resource',
      );
    // Unopened inputs participate in freshness too. Refresh can update a clean
    // buffer, but no proposed edit is applied unless *all* inputs still match.
    await _resourceBatch(resources, (id) async {
      final b = await buffer(id);
      await refreshDisk(b);
    });
    if (!valid() || resources.any((id) => store.get(id).externalConflict)) {
      throw CoreFailure(
        'refactor.stale',
        'A source file changed after review; no proposed edits were applied',
      );
    }
    if (plan is FileMovePlan) await _verifyFileMove(plan);
    if (plan is FileCreationPlan) await _verifyFileCreation(plan);
    if (plan is FileDeletionPlan) await _verifyFileDeletion(plan);
    if (!valid())
      throw CoreFailure(
        'refactor.stale',
        'The reviewed project changed before applying the move',
      );
    store.apply(
      plan.edits,
      coupledPublication: true,
      paths: plan is FileMovePlan ? [plan.pathEdit] : const [],
      creations: plan is FileCreationPlan ? [plan.creation] : const [],
      presences: plan is FileDeletionPlan ? [plan.presence] : const [],
      label: switch (plan.result['kind']) {
        'schema-suggestion' => 'Insert schema suggestion',
        'property-rename' => 'Rename schema property',
        'object-delete' => 'Delete authored object',
        'reference-selection' => 'Change reference',
        'diagnostic-fix' => 'Apply diagnostic repair',
        'component-extract' => 'Extract reusable component',
        'component-extract-file' => 'Extract component to source file',
        'component-move' => 'Move component definition',
        'operation-move' => 'Relocate operation',
        'reference-inline' => 'Inline reference occurrence',
        'file-move' => 'Move source file',
        'file-create' => 'Create source file',
        'file-delete' => 'Delete source file',
        'root-remove' => 'Remove contract root',
        'execution-environment' ||
        'execution-environment-create' => 'Set up request environment',
        _ => 'Rename component',
      },
      transitions: plan.transitions,
    );
    if (plan is RootRemovalPlan) _adoptRootConfiguration(plan._configured);
    return {
      for (final edit in plan.edits) edit.buffer,
      if (plan is FileCreationPlan) plan.creation.id,
      if (plan is FileDeletionPlan) plan.presence.buffer,
      if (plan is FileMovePlan &&
          plan.pathEdit.buffer != plan.pathEdit.destination) ...[
        plan.pathEdit.buffer,
        plan.pathEdit.destination,
      ],
    };
  }

  /// Monitor reachable resources even when they have no editor tab.
  Future<ResourceRefresh> refreshResources() async {
    final changed = <String>{};
    final reachable = {...resourceFingerprints.keys, ...store.buffers.keys};
    await _resourceBatch(reachable, (id) async {
      if (_standardResources.containsKey(id)) return;
      final b = store.buffers[id];
      final conflict = b?.externalConflict;
      final before = resourceFingerprints.containsKey(id)
          ? resourceFingerprints[id]
          : b?.diskIdentity;
      String? actual;
      try {
        actual = b != null
            ? await refreshDisk(b)
            : await contentIdentityAsync(
                await accessFor(Uri.parse(id).toFilePath())
                    .read(Uri.parse(id).toFilePath()),
              );
      } on Object {
        /* Deletion/inaccessibility has an identity too. */
      }
      // Source typing can advance a generation while the disk read is in
      // flight. It is already notified by the source owner, not a disk reload.
      // Content changes (including format-only changes) and conflict changes
      // identify this monitor's actual work without replaying that notification.
      if (before != actual || b != null && b.externalConflict != conflict) {
        changed.add(id);
      }
      resourceFingerprints[id] = actual;
    });
    // Node lookup observations are not all text resources: a missing directory
    // becoming a directory must invalidate a captured package choice too.
    // Monitor presence/type, not unrelated directory mtimes, through anchored
    // metadata capabilities. Deduplicate shared observations across roots.
    final lookups = <String, Set<String>>{};
    for (final values in _policyLookupKinds.values) {
      for (final entry in values.entries) {
        (lookups[entry.key] ??= <String>{}).add(entry.value);
      }
    }
    await _resourceBatch(lookups.entries, (entry) async {
      var kind = 'denied';
      try {
        final uri = Uri.parse(entry.key);
        if (uri.scheme == 'file') {
          final path = uri.toFilePath();
          kind = (await _policyCodeAccess(path).describe(path)).kind;
        }
      } on Object {
        /* A revoked capability is not absence. */
      }
      if (entry.value.any((expected) => expected != kind))
        changed.add(entry.key);
      for (final values in _policyLookupKinds.values) {
        if (values.containsKey(entry.key)) values[entry.key] = kind;
      }
    });
    return ResourceRefresh(changed, {
      for (final entry in dependencies.entries)
        if (entry.value.any(changed.contains)) entry.key,
      for (final entry in _policyDependencies.entries)
        if (entry.value.any(changed.contains)) entry.key,
      for (final entry in _policyLookupKinds.entries)
        if (entry.value.keys.any(changed.contains)) entry.key,
    });
  }

  Future<PropertySession?> proposeAndApply(
    String root,
    PropertySession session,
    List<Map<String, Object?>> actions, {
    Map<String, Object?>? acceptedValues,
    bool Function()? current,
  }) async {
    if (session.composing) {
      throw CoreFailure(
        'draft.composing',
        'Finish text composition before applying fields',
      );
    }
    if (session.root != root) {
      throw CoreFailure('draft.root', 'Draft belongs to another root');
    }
    final b = store.get(session.buffer);
    if (b.generation != session.generation) {
      throw CoreFailure(
        'draft.stale',
        'Source changed while these fields were pending. Correct or discard the captured draft.',
      );
    }
    await engine.start();
    final snap = AnalysisSnapshot(
      root: root,
      resources: [b.snapshot()],
      boundaries: approvedContexts,
      engineIdentity: engine.assetIdentity,
    );
    final result = await engine.request('propose', {
      ...snap.toJson(),
      'target': session.target(),
      'actions': actions,
    });
    if ((current != null && !current()) ||
        result['snapshot'] != snap.identity ||
        !snap.current(store)) {
      throw CoreFailure(
        'proposal.stale',
        'Source changed while preparing the edit',
      );
    }
    store.apply([
      for (final e in result['edits'] as List)
        TextEdit.fromJson(Map<String, dynamic>.from(e as Map)),
    ], label: 'Design');
    final range = result['nextRange'];
    if (range is! List || range.length != 2) return null;
    final next = List<int>.from(range);
    if (next[0] < 0 || next[1] < next[0] || next[1] > b.text.length) {
      throw CoreFailure(
        'proposal.range',
        'Accepted edit returned an invalid source target',
      );
    }
    return PropertySession(
      root: session.root,
      buffer: session.buffer,
      generation: b.generation,
      pointer: session.pointer,
      range: next,
      expected: b.text.substring(next[0], next[1]),
      shareInputFrom: session,
    )..committed.addAll({...session.committed, ...?acceptedValues});
  }

  Future<void> save(DocumentBuffer b) async {
    if (b.hasFileIntent || b.pendingFilePublication) {
      throw CoreFailure(
        'file.intent.publication',
        'Staged paths require their grouped file-operation publication plan',
      );
    }
    if (!b.dirty) {
      await refreshDisk(b);
      if (b.externalConflict) {
        throw CoreFailure(
          'save.conflict',
          'Saved source changed or became unavailable; the buffer is preserved',
        );
      }
      return;
    }
    if (b.externalConflict) {
      throw CoreFailure(
        'save.conflict',
        'Resolve the external conflict explicitly before publishing',
      );
    }
    final generation = b.generation;
    final bytes = b.bytes();
    try {
      await accessFor(b.path)
          .publish(b.path, bytes, expected: b.diskIdentity, mode: b.mode);
    } on Object {
      b.externalConflict = true;
      rethrow;
    }
    b.diskIdentity = contentIdentity(bytes);
    resourceFingerprints[b.id] = b.diskIdentity;
    b.baseline = utf8.decode(b.hasBom ? bytes.sublist(3) : bytes);
    b.externalConflict = false;
    if (b.generation != generation) {
      /* Later input remains dirty relative to the published generation. */
    }
  }

  Future<String?> refreshDisk(
    DocumentBuffer b, {
    Future<void> Function()? beforeReload,
  }) async {
    final capture = BufferReloadCapture._(this, b);
    final diskPath = b.publishedPath;
    if (!b.publishedPresent) {
      final path = b.path;
      bool current() => capture.current && !b.publishedPresent;
      try {
        final missing = await accessFor(path).missing(path);
        final identity = missing
            ? null
            : await contentIdentityAsync(await accessFor(path).read(path));
        // The same deterministic observation boundary as a clean reload.
        // Publication, Undo or a move can retire an expected-absence read.
        await beforeReload?.call();
        if (current()) b.externalConflict = !missing;
        return identity;
      } on Object {
        if (current()) b.externalConflict = true;
        return null;
      }
    }
    try {
      final bytes = await accessFor(diskPath).read(diskPath);
      final identity = await contentIdentityAsync(bytes);
      if (!capture.publicationCurrent) return identity;
      if (identity == b.diskIdentity) {
        if (!b.dirty) {
          final mode = await accessFor(diskPath).mode(diskPath);
          if (capture.current) {
            b.externalConflict = false;
            b.mode = mode;
          }
        }
        return identity;
      }
      if (b.dirty) {
        b.externalConflict = true;
        return identity;
      }
      final read = DocumentBuffer.decode(
        b.path,
        bytes,
        mode: await accessFor(diskPath).mode(diskPath),
      );
      await beforeReload?.call();
      if (!capture.publicationCurrent) return identity;
      if (!capture.current || b.dirty) {
        b.externalConflict = true;
        return identity;
      }
      store.retireHistory({b.id});
      final previousGeneration = b.generation;
      b.update(read.text);
      if (b.generation == previousGeneration) b.generation++;
      b.baseline = read.text;
      b.diskIdentity = read.diskIdentity;
      b.hasBom = read.hasBom;
      b.mode = read.mode;
      b.externalConflict = false;
      return identity;
    } on Object {
      if (capture.publicationCurrent) b.externalConflict = true;
      return null;
    }
  }

  BufferReloadCapture captureReload(DocumentBuffer b) {
    if (b.hasFileIntent || b.pendingFilePublication)
      throw CoreFailure(
        'file.group.reload',
        'Discard or recover the complete file operation before reloading one of its members',
      );
    return BufferReloadCapture._(this, b);
  }

  Future<BufferReloadResult> reload(
    DocumentBuffer b, {
    BufferReloadCapture? accepted,
    Future<void> Function()? beforeReload,
    RunCancellation? cancellation,
  }) async {
    final capture = accepted ?? captureReload(b);
    bool current() =>
        identical(capture.project, this) &&
        identical(capture.buffer, b) &&
        capture.current;
    if (!current()) return const BufferReloadResult(BufferReloadStatus.stale);
    late DocumentBuffer read;
    try {
      cancellation?.throwIfCancelled();
      final bytes = await accessFor(capture.path).read(capture.path);
      await beforeReload?.call();
      cancellation?.throwIfCancelled();
      if (!current()) return const BufferReloadResult(BufferReloadStatus.stale);
      read = DocumentBuffer.decode(
        capture.path,
        bytes,
        mode: await accessFor(capture.path).mode(capture.path),
      );
      cancellation?.throwIfCancelled();
    } on Object catch (failure) {
      return BufferReloadResult(
        cancellation?.cancelled == true
            ? BufferReloadStatus.cancelled
            : BufferReloadStatus.failed,
        failure: failure,
      );
    }
    if (!current()) return const BufferReloadResult(BufferReloadStatus.stale);
    store.retireHistory({b.id});
    final previousGeneration = b.generation;
    b.update(read.text);
    if (b.generation == previousGeneration) b.generation++;
    b.baseline = read.text;
    b.diskIdentity = read.diskIdentity;
    b.hasBom = read.hasBom;
    b.mode = read.mode;
    b.externalConflict = false;
    resourceFingerprints[b.id] = b.diskIdentity;
    return BufferReloadResult(
      BufferReloadStatus.applied,
      applied: captureReload(b),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    access.close();
    for (final context in _approvedContexts.values) {
      context.close();
    }
    _approvedContexts.clear();
    for (final file in _executionFiles.values) {
      file.$1.close();
    }
    _executionFiles.clear();
  }
}

class Initializer {
  static Future<String> create({
    required String destination,
    required String title,
    required String apiVersion,
    String openapi = '3.1.2',
    String format = 'yaml',
    PublicationBoundary? beforePublish,
  }) async {
    if (title.trim().isEmpty || apiVersion.trim().isEmpty) {
      throw CoreFailure('init.input', 'API title and API version are required');
    }
    if (openapi != '2.0' && !RegExp(r'^3\.(0|1|2)\.\d+$').hasMatch(openapi)) {
      throw CoreFailure(
        'init.version',
        'Select Swagger 2.0 or OpenAPI 3.0.x, 3.1.x or 3.2.x',
      );
    }
    if (!['yaml', 'json'].contains(format)) {
      throw CoreFailure('init.format', 'Format must be yaml or json');
    }
    final directory = Directory(p.absolute(destination));
    final existed = await directory.exists();
    if (!existed) await directory.create(recursive: true);
    final access = await ProjectAccess.open(directory.path);
    final name = 'openapi.$format';
    final path = p.join(directory.path, name),
        manifest = p.join(directory.path, 'busyapi.yaml');
    final data = {
      (openapi == '2.0' ? 'swagger' : 'openapi'): openapi,
      'info': {'title': title, 'version': apiVersion},
      'paths': <String, Object?>{},
    };
    final text = format == 'json'
        ? '${const JsonEncoder.withIndent('  ').convert(data)}\n'
        : '${openapi == '2.0' ? 'swagger' : 'openapi'}: ${jsonEncode(openapi)}\ninfo:\n  title: ${jsonEncode(title)}\n  version: ${jsonEncode(apiVersion)}\npaths: {}\n';
    bool published = false;
    try {
      for (final f in [path, manifest]) {
        if (await FileSystemEntity.type(f, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw CoreFailure(
            'init.collision',
            'Project files already exist; nothing was overwritten',
          );
        }
      }
      await beforePublish?.call(path);
      await access.publish(path, utf8.encode(text));
      published = true;
      await beforePublish?.call(manifest);
      await access.publish(
        manifest,
        utf8.encode('version: 1\nroots:\n  - name: main\n    path: $name\n'),
      );
      return path;
    } on Object catch (error) {
      if (published) {
        throw CoreFailure(
          'init.partial',
          'Contract creation completed at $path, but manifest publication failed. Existing and concurrent files were retained: $error',
        );
      }
      if (error is AtomicFileAlreadyExistsException) {
        throw CoreFailure(
          'init.collision',
          'Project files already exist; nothing was overwritten',
        );
      }
      rethrow;
    } finally {
      access.close();
    }
  }
}
