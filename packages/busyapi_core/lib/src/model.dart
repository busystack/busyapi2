import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'source_line_index.dart';

String contentIdentity(List<int> bytes) => sha256.convert(bytes).toString();
String textIdentity(String text) => contentIdentity(utf8.encode(text));
Future<String> textIdentityAsync(String text) => text.length < 262144
    ? Future.value(textIdentity(text))
    : Isolate.run(() => textIdentity(text));

// Hashing large immutable inputs must not occupy the desktop's UI isolate.
// Small values avoid worker startup overhead; both paths use the same SHA-256.
Future<String> contentIdentityAsync(List<int> bytes) => bytes.length < 262144
    ? Future.value(contentIdentity(bytes))
    : Isolate.run(() => contentIdentity(bytes));

/// Canonical operation identity supplies the distinction between fixed fields
/// and case-sensitive additionalOperations keys. Display must retain it too.
String httpOperationMethod(Map operation) => operation['customMethod'] == true
    ? '${operation['method']}'
    : '${operation['method']}'.toUpperCase();

enum CoreFailureKind { operational, unsupported }

class CoreFailureSource {
  const CoreFailureSource(this.resource, this.pointer, this.range);
  final String resource, pointer;
  final SourceRange range;
}

class CoreFailure implements Exception {
  CoreFailure(this.code, this.message, {CoreFailureKind? kind, this.source})
    : kind =
          kind ??
          (code.endsWith('.unsupported')
              ? CoreFailureKind.unsupported
              : CoreFailureKind.operational);
  final String code, message;
  final CoreFailureKind kind;
  final CoreFailureSource? source;
  bool get unsupported => kind == CoreFailureKind.unsupported;
  @override
  String toString() => '$code: $message';
}

enum SpecificationFamily { swagger20, openapi30, openapi31, openapi32 }

/// Syntax and bounded authoring limits supplied by the containing engine scope.
class MemberNamePolicy {
  const MemberNamePolicy._(this.allowEmpty, this.maxLength, this._pattern);
  factory MemberNamePolicy.fromJson(Object? value) {
    CoreFailure invalid() => CoreFailure(
      'engine.name-policy',
      'The engine returned an incomplete member-name policy',
    );
    if (value case {'allowEmpty': bool empty, 'maxLength': int length}) {
      if (length < 1 || length > 65536) throw invalid();
      final pattern = value['pattern'];
      RegExp? expression;
      if (pattern != null) {
        if (pattern is! String || pattern.length > 1024) throw invalid();
        try {
          expression = RegExp(pattern);
        } on FormatException {
          throw invalid();
        }
      }
      return MemberNamePolicy._(empty, length, expression);
    }
    throw invalid();
  }
  final bool allowEmpty;
  final int maxLength;
  final RegExp? _pattern;
  bool allows(String value) =>
      value.length <= maxLength &&
      (value.isEmpty ? allowEmpty : _pattern?.hasMatch(value) ?? true);
}

enum SecurityRequirementValueKind { scopes, roles, empty, unresolved }

class SecurityBindingInspection {
  const SecurityBindingInspection._(this.name, this.kind);
  factory SecurityBindingInspection.fromJson(Object? value) {
    if (value case {'name': String name, 'kind': String kind}) {
      for (final candidate in SecurityRequirementValueKind.values) {
        if (candidate.name == kind)
          return SecurityBindingInspection._(name, candidate);
      }
    }
    throw CoreFailure(
      'engine.security-binding',
      'The engine returned an incomplete security binding context',
    );
  }
  final String name;
  final SecurityRequirementValueKind kind;
  bool get allowsValues =>
      kind == SecurityRequirementValueKind.scopes ||
      kind == SecurityRequirementValueKind.roles;
}

/// Feature choices belong to the engine's captured specification context.
class SpecificationCapabilities {
  const SpecificationCapabilities._(
    this.modernSchema,
    this.webhooks,
    this.reusablePathItems,
    this.additionalOperations,
    this.referenceAnnotations,
    this.securityRequirementUris,
  );

  factory SpecificationCapabilities.fromJson(Object? value) {
    if (value case {
      'modernSchema': bool modern,
      'webhooks': bool webhooks,
      'reusablePathItems': bool pathItems,
      'additionalOperations': bool additional,
      'referenceAnnotations': bool annotations,
      'securityRequirementUris': bool securityUris,
    }) {
      return SpecificationCapabilities._(
        modern,
        webhooks,
        pathItems,
        additional,
        annotations,
        securityUris,
      );
    }
    throw CoreFailure(
      'engine.specification',
      'The engine returned incomplete specification capabilities',
    );
  }

  final bool modernSchema,
      webhooks,
      reusablePathItems,
      additionalOperations,
      referenceAnnotations,
      securityRequirementUris;
}

/// Captured engine semantics. The API's info.version is deliberately absent.
/// Presentation consumes capabilities instead of interpreting version strings.
class SpecificationContext {
  const SpecificationContext._(
    this.family,
    this.declaredVersion,
    this.schemaDialect,
    this.capabilities,
  );

  factory SpecificationContext.fromJson(Object? value) {
    if (value case {
      'family': String family,
      'declaredVersion': String version,
      'schemaDialect': String dialect,
      'capabilities': final capabilities,
    }) {
      final selected = switch (family) {
        '2.0' => SpecificationFamily.swagger20,
        '3.0' => SpecificationFamily.openapi30,
        '3.1' => SpecificationFamily.openapi31,
        '3.2' => SpecificationFamily.openapi32,
        _ => throw CoreFailure(
          'engine.specification',
          'Unknown specification family in the engine response',
        ),
      };
      return SpecificationContext._(
        selected,
        version,
        dialect,
        SpecificationCapabilities.fromJson(capabilities),
      );
    }
    throw CoreFailure(
      'engine.specification',
      'The engine returned an incomplete specification context',
    );
  }

  final SpecificationFamily family;
  final String declaredVersion, schemaDialect;
  final SpecificationCapabilities capabilities;
  bool get modernSchema => capabilities.modernSchema;
  bool get webhooks => capabilities.webhooks;
  bool get reusablePathItems => capabilities.reusablePathItems;
  bool get additionalOperations => capabilities.additionalOperations;
  bool get referenceAnnotations => capabilities.referenceAnnotations;
  bool get securityRequirementUris => capabilities.securityRequirementUris;
}

/// UTF-16 code units, half-open ranges. BOM excluded, raw line endings retained.
class SourceRange {
  const SourceRange(this.start, this.end);
  final int start, end;
}

class SourceSelection {
  const SourceSelection(this.base, this.extent);
  final int base, extent;
}

class TextEdit {
  const TextEdit({
    required this.buffer,
    required this.generation,
    required this.start,
    required this.end,
    required this.expected,
    required this.replacement,
  });
  factory TextEdit.fromJson(Map<String, dynamic> m) => TextEdit(
    buffer: m['buffer'] as String,
    generation: m['generation'] as int,
    start: m['start'] as int,
    end: m['end'] as int,
    expected: m['expected'] as String,
    replacement: m['replacement'] as String,
  );
  final String buffer, expected, replacement;
  final int generation, start, end;
}

/// A captured virtual path change. Applying this value never touches disk.
/// The project/publication owner must separately approve and publish paths.
class BufferPathEdit {
  const BufferPathEdit({
    required this.buffer,
    required this.generation,
    required this.expectedPath,
    required this.expectedText,
    required this.expectedBom,
    required this.destination,
    required this.path,
  });
  final String buffer, expectedPath, expectedText, destination, path;
  final int generation;
  final bool expectedBom;
}

/// An unpublished physical resource. The project must prove destination
/// approval/absence before applying this plain in-memory transaction value.
class BufferCreation {
  const BufferCreation({
    required this.id,
    required this.path,
    required this.text,
    this.hasBom = false,
    this.mode = 420,
  });
  final String id, path, text;
  final bool hasBom;
  final int mode;
}

/// Captured virtual presence, not filesystem deletion. Hidden source remains
/// bound to its original buffer until history/publication can release it.
class BufferPresenceEdit {
  const BufferPresenceEdit({
    required this.buffer,
    required this.generation,
    required this.expectedPath,
    required this.expectedText,
    required this.expectedBom,
    required this.expectedPresent,
    required this.present,
  });
  final String buffer, expectedPath, expectedText;
  final int generation;
  final bool expectedBom, expectedPresent, present;
}

/// Narrow project-owned recovery capabilities keep storage/build tools
/// independent of the contract parser and the application's project graph.
class FileRecoveryOwner {
  FileRecoveryOwner({
    required this.boundary,
    required this.location,
    required this.store,
    required this.restore,
    required this.matches,
  });
  final String boundary, location;
  final BufferStore store;
  final Future<Map<String, DocumentBuffer>> Function(List<Map<String, dynamic>>)
  restore;
  final bool Function(List<Map<String, dynamic>>) matches;
}

class DocumentBuffer {
  DocumentBuffer({
    required String id,
    required String path,
    required this.text,
    required this.baseline,
    required this.diskIdentity,
    required this.hasBom,
    this.generation = 1,
    this.mode = 420,
    bool present = true,
    this.publishedPresent = true,
  }) : _id = id,
       _path = path,
       _present = present,
       publishedPath = path,
       lines = SourceLineIndex(text);
  factory DocumentBuffer.decode(
    String path,
    List<int> bytes, {
    int mode = 420,
  }) {
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 239 &&
        bytes[1] == 187 &&
        bytes[2] == 191;
    final text = utf8.decode(
      bom ? bytes.sublist(3) : bytes,
      allowMalformed: false,
    );
    return DocumentBuffer(
      id: Uri.file(path).toString(),
      path: path,
      text: text,
      baseline: text,
      diskIdentity: contentIdentity(bytes),
      hasBom: bom,
      mode: mode,
    );
  }
  String _id, _path;
  String get id => _id;
  String get path => _path;
  bool _present;
  bool get present => _present;
  // Like publishedPath, this is acknowledged disk ownership, not undo state.
  bool publishedPresent;
  // Disk ownership is not history. Undo after Save stages a reverse move;
  // it must not pretend that the old physical filename already exists again.
  String publishedPath;
  bool get hasPathIntent =>
      present && publishedPresent && path != publishedPath;
  bool get hasFileIntent => present != publishedPresent || hasPathIntent;
  String text, baseline, diskIdentity;
  bool hasBom;
  int generation, mode;
  SourceLineIndex lines;
  SourceSelection selection = const SourceSelection(0, 0);
  double scroll = 0;
  bool externalConflict = false;
  bool pendingFilePublication = false;
  bool get dirty =>
      hasFileIntent ||
      pendingFilePublication ||
      present && publishedPresent && text != baseline;
  List<int> bytes() {
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (i + 1 >= text.length ||
            text.codeUnitAt(i + 1) < 0xdc00 ||
            text.codeUnitAt(i + 1) > 0xdfff) {
          throw CoreFailure(
            'encoding.composing',
            'Finish Unicode composition before saving',
          );
        }
        i++;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw CoreFailure(
          'encoding.composing',
          'Source contains an incomplete Unicode character',
        );
      }
    }
    return [
      if (hasBom) ...[239, 187, 191],
      ...utf8.encode(text),
    ];
  }

  void update(String value, {int? start, int? end}) {
    if (value == text) return;
    lines = start != null && end != null
        ? SourceLineIndex.updated(
            previous: lines,
            source: value,
            oldStart: start,
            oldEnd: end,
          )
        : SourceLineIndex(value);
    text = value;
    int clamp(int offset) {
      var at = offset.clamp(0, text.length);
      if (at > 0 &&
          at < text.length &&
          text.codeUnitAt(at) >= 0xdc00 &&
          text.codeUnitAt(at) <= 0xdfff) {
        at--;
      }
      return at;
    }

    selection = SourceSelection(clamp(selection.base), clamp(selection.extent));
    generation++;
  }

  String? _sourceIdentity, _identityText;
  bool? _identityBom;
  String get sourceIdentity {
    if (_sourceIdentity == null ||
        !identical(_identityText, text) ||
        _identityBom != hasBom) {
      _identityText = text;
      _identityBom = hasBom;
      _sourceIdentity = textIdentity('${hasBom ? '\ufeff' : ''}$text');
    }
    return _sourceIdentity!;
  }

  Map<String, Object?> snapshot() {
    if (!present)
      throw CoreFailure(
        'buffer.missing',
        'A virtually absent file has no current source snapshot',
      );
    return {
      'id': id,
      'text': text,
      'generation': generation,
      'hasBom': hasBom,
      'identity': sourceIdentity,
    };
  }

  Future<Map<String, Object?>> snapshotAsync() async {
    if (!present)
      throw CoreFailure(
        'buffer.missing',
        'A virtually absent file has no current source snapshot',
      );
    final captured = text, bom = hasBom, revision = generation, resource = id;
    final cached = identical(_identityText, captured) && _identityBom == bom
        ? _sourceIdentity
        : null;
    final identity =
        cached ??
        (captured.length < 262144
            ? textIdentity('${bom ? '\ufeff' : ''}$captured')
            : await Isolate.run(
                () => textIdentity('${bom ? '\ufeff' : ''}$captured'),
              ));
    if (identical(text, captured) && hasBom == bom) {
      _identityText = captured;
      _identityBom = bom;
      _sourceIdentity = identity;
    }
    return {
      'id': resource,
      'text': captured,
      'generation': revision,
      'hasBom': bom,
      'identity': identity,
    };
  }
}

class SemanticTransition {
  const SemanticTransition(
    this.resource,
    this.from,
    this.to, {
    this.mode = 'relocation',
    this.destinationResource,
  });
  final String resource, from, to;
  final String mode;
  final String? destinationResource;
  String get toResource => destinationResource ?? resource;
  bool affects(String pointer) => mode == 'restoration'
      ? pointer == from
      : pointer == from || pointer.startsWith('$from/');
  String mapResource(String id, String pointer) =>
      id == resource && affects(pointer) ? toResource : id;
  SemanticTransition get reversed => SemanticTransition(
    toResource,
    to,
    from,
    destinationResource: destinationResource == null ? null : resource,
    mode: switch (mode) {
      'removal' => 'restoration',
      'restoration' => 'removal',
      _ => mode,
    },
  );
  String map(String pointer) {
    if (mode == 'restoration') return pointer == from ? to : pointer;
    if (pointer != from && !pointer.startsWith('$from/')) return pointer;
    return mode == 'removal' ? to : '$to${pointer.substring(from.length)}';
  }
}

class _BufferPathState {
  const _BufferPathState(this.id, this.path, this.present);
  final String id, path;
  final bool present;
}

List<List<String>> decodePublicationGroups(Object? value, Set<String> allowed) {
  if (value == null) return const [];
  if (value is! List || value.length > 256 || allowed.length > 512) {
    throw CoreFailure(
      'recovery.groups',
      'Invalid publication dependency groups',
    );
  }
  final groups = <List<String>>[], used = <String>{};
  for (final group in value) {
    if (group is! List ||
        group.length < 2 ||
        group.length > 512 ||
        group.any((id) => id is! String || !allowed.contains(id)) ||
        group.toSet().length != group.length ||
        group.any(used.contains)) {
      throw CoreFailure(
        'recovery.groups',
        'Publication dependencies require distinct captured source identities',
      );
    }
    final ids = List<String>.from(group);
    groups.add(ids);
    used.addAll(ids);
  }
  return groups;
}

class _History {
  _History(
    this.before,
    this.after,
    this.label,
    this.transitions,
    this.buffers,
    this.beforePaths,
    this.afterPaths,
    this.coupledPublication,
  );
  final Map<String, String> before, after;
  final String label;
  final List<SemanticTransition> transitions;
  final Map<String, DocumentBuffer> buffers;
  final Map<DocumentBuffer, _BufferPathState> beforePaths, afterPaths;
  final bool coupledPublication;
}

class BufferStore {
  final Map<String, DocumentBuffer> buffers = {};
  final Set<DocumentBuffer> _absent = {};
  final Map<String, int> _absentIdentities = {};

  /// Active source plus retained file/history owners. Ordinary source readers
  /// use [buffers], which never exposes a virtually deleted file as current.
  Iterable<DocumentBuffer> get fileBuffers sync* {
    yield* buffers.values;
    yield* _absent;
  }

  bool ownsFileBuffer(DocumentBuffer buffer) =>
      identical(buffers[buffer.id], buffer) || _absent.contains(buffer);

  final Map<DocumentBuffer, Set<DocumentBuffer>> _publicationGroups = {};

  void _prunePublicationGroups() {
    final groups = _publicationGroups.values.toSet();
    _publicationGroups.clear();
    for (final group in groups) {
      final members = group.where(ownsFileBuffer).toSet();
      if (members.length < 2 ||
          !members.any(
            (buffer) => buffer.dirty || buffer.pendingFilePublication,
          )) {
        continue;
      }
      for (final buffer in members) {
        _publicationGroups[buffer] = members;
      }
    }
  }

  /// Required repairs in one reviewed source transaction publish together.
  /// Buffer identities survive path changes and remain separate from labels.
  Set<DocumentBuffer> publicationBuffersFor(Iterable<DocumentBuffer> selected) {
    _prunePublicationGroups();
    final result = selected.toSet();
    var changed = true;
    while (changed) {
      changed = false;
      for (final buffer in result.toList()) {
        final before = result.length;
        result.addAll(_publicationGroups[buffer] ?? const {});
        changed |= before != result.length;
      }
    }
    return result;
  }

  void _couplePublicationBuffers(Iterable<DocumentBuffer> participants) {
    final members = publicationBuffersFor(participants)
        .where(
          (buffer) => buffer.id.startsWith('file:') && ownsFileBuffer(buffer),
        )
        .toSet();
    if (members.length < 2) return;
    for (final buffer in members) {
      _publicationGroups[buffer] = members;
    }
  }

  List<Set<DocumentBuffer>> get publicationGroups {
    _prunePublicationGroups();
    return List.unmodifiable(
      _publicationGroups.values.toSet().map(Set<DocumentBuffer>.unmodifiable),
    );
  }

  void restorePublicationGroups(List<List<String>> groups) {
    final members = [
      for (final group in groups) [for (final id in group) fileBuffer(id)],
    ];
    retainPublicationGroups(members);
  }

  /// Receipts retain live owners even if Undo made the group temporarily clean
  /// before a frozen save published. File identities may have moved meanwhile.
  void retainPublicationGroups(Iterable<Iterable<DocumentBuffer>> groups) {
    for (final group in groups) {
      _couplePublicationBuffers(group);
    }
  }

  bool isVirtuallyAbsent(String id) =>
      !buffers.containsKey(id) && _absentIdentities.containsKey(id);

  DocumentBuffer fileBuffer(String id) {
    final active = buffers[id];
    if (active != null) return active;
    final matching = _absent.where((buffer) => buffer.id == id).toList();
    final pending = matching.where((buffer) => buffer.dirty).toList();
    if (pending.length == 1) return pending.single;
    if (matching.length == 1) return matching.single;
    throw CoreFailure(
      'buffer.missing',
      'The retained file owner is absent or ambiguous',
    );
  }

  /// Install a verified recovery group, including hidden owners. Callers must
  /// inspect disk ownership first; this operation performs no filesystem work.
  void restoreFileOwners(
    Iterable<DocumentBuffer> recovered, {
    Set<DocumentBuffer> replacing = const {},
  }) {
    final values = recovered.toList(), ids = <String>{};
    for (final b in values) {
      if (!ids.add(b.id) ||
          buffers[b.id] != null && !replacing.contains(buffers[b.id]) ||
          _absent.any(
            (other) =>
                other.id == b.id && other.dirty && !replacing.contains(other),
          )) {
        throw CoreFailure(
          'recovery.stale',
          'A recovered identity belongs to another current file owner',
        );
      }
    }
    retireHistory({...ids, for (final b in replacing) b.id});
    for (final b in replacing) {
      if (identical(buffers[b.id], b)) buffers.remove(b.id);
      if (_absent.remove(b)) _releaseAbsentIdentity(b.id);
    }
    for (final b in values) {
      if (b.present) {
        buffers[b.id] = b;
      } else {
        _absent.add(b);
        _absentIdentities[b.id] = (_absentIdentities[b.id] ?? 0) + 1;
      }
    }
  }

  /// Installed by the project owner. Runs synchronously after a verified path
  /// transition so root, resource and monitor identities change with history.
  void Function(Map<String, String> paths, Set<DocumentBuffer> participants)?
  onPathsChanged;

  /// Passive project-owned projections observe a completed logical mutation,
  /// including text-only Undo/Redo. Observers must not edit/reenter or throw.
  void Function(Set<DocumentBuffer> participants)? onCommitted;
  final List<_History> _undo = [], _redo = [];
  final Map<DocumentBuffer, int> _historyOwners = {};
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  DocumentBuffer get(String id) =>
      buffers[id] ??
      (throw CoreFailure('buffer.missing', 'Buffer is no longer open'));
  void apply(
    List<TextEdit> edits, {
    String label = 'Edit',
    List<SemanticTransition> transitions = const [],
    List<BufferPathEdit> paths = const [],
    List<BufferCreation> creations = const [],
    List<BufferPresenceEdit> presences = const [],
    bool coupledPublication = false,
  }) {
    if (edits.isEmpty &&
        paths.isEmpty &&
        creations.isEmpty &&
        presences.isEmpty)
      return;
    final created = <String, DocumentBuffer>{};
    for (final addition in creations) {
      final uri = Uri.tryParse(addition.id);
      if (uri == null ||
          uri.scheme != 'file' ||
          !uri.hasAbsolutePath ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.endsWith('/') ||
          uri.normalizePath() != uri ||
          uri.toFilePath() != addition.path ||
          Uri.file(addition.path).toString() != addition.id ||
          addition.mode < 0 ||
          addition.mode > 511) {
        throw CoreFailure(
          'file.path',
          'Choose an absolute physical file identity and ordinary permission bits',
        );
      }
      if (buffers.containsKey(addition.id) ||
          created.containsKey(addition.id) ||
          _absent.any((buffer) => buffer.id == addition.id && buffer.dirty)) {
        throw CoreFailure(
          'file.collision',
          'A file destination already belongs to a current or pending buffer',
        );
      }
      if (addition.text.length > 16 * 1024 * 1024) {
        throw CoreFailure(
          'limit.buffers',
          'A created source exceeds the per-resource buffer budget',
        );
      }
      created[addition.id] = DocumentBuffer(
        id: addition.id,
        path: addition.path,
        text: addition.text,
        baseline: addition.text,
        diskIdentity: '',
        hasBom: addition.hasBom,
        mode: addition.mode,
        present: false,
        publishedPresent: false,
      );
    }
    if (created.isNotEmpty &&
        (fileBuffers.length + created.length > 512 ||
            fileBuffers
                    .followedBy(created.values)
                    .fold<int>(0, (n, buffer) => n + buffer.text.length * 2) >
                256 * 1024 * 1024)) {
      throw CoreFailure(
        'limit.buffers',
        'Created resources exceed the project buffer budget',
      );
    }
    final presenceIds = presences.map((edit) => edit.buffer).toSet();
    final restoring = {
      for (final edit in presences)
        if (edit.present) edit.buffer,
    };
    DocumentBuffer input(String id) =>
        buffers[id] ??
        created[id] ??
        (presenceIds.contains(id) ? fileBuffer(id) : get(id));
    final pathChanges = <DocumentBuffer, _BufferPathState>{};
    final destinations = <String>{...created.keys};
    for (final edit in paths) {
      final b = input(edit.buffer);
      final uri = Uri.tryParse(edit.destination);
      if (!b.present && !restoring.contains(b.id) ||
          b.id != edit.buffer ||
          b.generation != edit.generation ||
          b.path != edit.expectedPath ||
          b.text != edit.expectedText ||
          b.hasBom != edit.expectedBom) {
        throw CoreFailure(
          'file.stale',
          'The captured buffer path or source changed',
        );
      }
      if (uri == null ||
          uri.scheme != 'file' ||
          !uri.hasAbsolutePath ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.endsWith('/') ||
          uri.normalizePath() != uri ||
          uri.toFilePath() != edit.path ||
          Uri.file(edit.path).toString() != edit.destination ||
          Uri.file(b.path).toString() != b.id) {
        throw CoreFailure(
          'file.path',
          'Choose an absolute physical file identity',
        );
      }
      if (edit.destination == b.id && edit.path == b.path) continue;
      if (pathChanges.containsKey(b) ||
          !destinations.add(edit.destination) ||
          buffers.containsKey(edit.destination) ||
          buffers.values.any(
            (other) => !identical(other, b) && other.path == edit.path,
          )) {
        throw CoreFailure(
          'file.collision',
          'A virtual file destination already belongs to another buffer',
        );
      }
      pathChanges[b] = _BufferPathState(edit.destination, edit.path, b.present);
    }
    final presenceOwners = <DocumentBuffer>{};
    for (final edit in presences) {
      final b = input(edit.buffer);
      if (!presenceOwners.add(b) ||
          created.containsKey(b.id) ||
          b.generation != edit.generation ||
          b.path != edit.expectedPath ||
          b.text != edit.expectedText ||
          b.hasBom != edit.expectedBom ||
          b.present != edit.expectedPresent) {
        throw CoreFailure(
          'file.stale',
          'The captured file presence or source changed',
        );
      }
      if (b.present == edit.present) continue;
      final next = pathChanges[b];
      pathChanges[b] = _BufferPathState(
        next?.id ?? b.id,
        next?.path ?? b.path,
        edit.present,
      );
    }
    for (final b in created.values) {
      pathChanges[b] = _BufferPathState(b.id, b.path, true);
    }
    final grouped = <String, List<TextEdit>>{};
    for (final edit in edits) {
      (grouped[edit.buffer] ??= []).add(edit);
    }
    final next = <String, String>{}, before = <String, String>{};
    var estimatedBytes = 0;
    for (final entry in grouped.entries) {
      final b = input(entry.key);
      if (!b.present &&
          !created.containsKey(b.id) &&
          !restoring.contains(b.id)) {
        throw CoreFailure(
          'file.stale',
          'A hidden file cannot receive source edits without an explicit restoration',
        );
      }
      final sorted = entry.value..sort((a, b) => a.start.compareTo(b.start));
      int end = -1;
      for (final e in sorted) {
        if (e.generation != b.generation) {
          throw CoreFailure(
            'edit.stale',
            'Buffer changed since the field was captured',
          );
        }
        if (e.start < 0 ||
            e.end < e.start ||
            e.end > b.text.length ||
            e.start < end) {
          throw CoreFailure('edit.range', 'Invalid or overlapping edits');
        }
        if (b.text.substring(e.start, e.end) != e.expected) {
          throw CoreFailure(
            'edit.expected',
            'Original source no longer matches',
          );
        }
        for (final offset in [e.start, e.end]) {
          if (offset > 0 &&
              offset < b.text.length &&
              b.text.codeUnitAt(offset) >= 0xdc00 &&
              b.text.codeUnitAt(offset) <= 0xdfff &&
              b.text.codeUnitAt(offset - 1) >= 0xd800 &&
              b.text.codeUnitAt(offset - 1) <= 0xdbff) {
            throw CoreFailure(
              'edit.unicode',
              'Range splits a Unicode surrogate pair',
            );
          }
        }
        end = e.end;
      }
      if (sorted.any((edit) => edit.expected != edit.replacement)) {
        final length =
            b.text.length +
            sorted.fold<int>(
              0,
              (n, edit) =>
                  n + edit.replacement.length - (edit.end - edit.start),
            );
        estimatedBytes += (b.text.length + length) * 2;
        if (estimatedBytes > 64 * 1024 * 1024) {
          throw CoreFailure(
            'limit.transaction',
            'Transaction exceeds the 64 MiB history budget; no buffers were changed',
          );
        }
      }
    }
    // Check every input and the output budget before allocating replacements.
    // A short search input can otherwise expand into gigabytes before the
    // existing post-construction history check gets a chance to reject it.
    for (final entry in grouped.entries) {
      final b = input(entry.key), sorted = entry.value;
      if (sorted.every((edit) => edit.expected == edit.replacement)) continue;
      var value = b.text;
      if (sorted.length > 1) {
        final output = StringBuffer();
        var cursor = 0;
        for (final edit in sorted) {
          output
            ..write(b.text.substring(cursor, edit.start))
            ..write(edit.replacement);
          cursor = edit.end;
        }
        output.write(b.text.substring(cursor));
        value = output.toString();
      } else {
        final e = sorted.single;
        // The pinned VM's one-byte replaceRange copies large ranges with a
        // Dart character loop. Public substring/concatenation uses native bulk
        // copies. Keep small edits on the ordinary path and construct only the
        // core-owned accepted value; the editor still reuses this exact value.
        value = value.length < 262144
            ? value.replaceRange(e.start, e.end, e.replacement)
            : '${value.substring(0, e.start)}${e.replacement}${value.substring(e.end)}';
      }
      if (value != b.text) {
        before[b.id] = b.text;
        next[b.id] = value;
      }
    }
    for (final buffer in pathChanges.keys) {
      before.putIfAbsent(buffer.id, () => buffer.text);
      next.putIfAbsent(buffer.id, () => buffer.text);
    }
    if (next.isEmpty) return;
    final bound = {for (final id in before.keys) id: input(id)};
    final beforePaths = {
      for (final b in bound.values)
        b: _BufferPathState(b.id, b.path, b.present),
    };
    final afterPaths = {
      for (final b in bound.values)
        b: pathChanges[b] ?? _BufferPathState(b.id, b.path, b.present),
    };
    final planBytes =
        before.values.fold<int>(0, (n, t) => n + t.length * 2) +
        next.values.fold<int>(0, (n, t) => n + t.length * 2);
    if (planBytes > 64 * 1024 * 1024) {
      throw CoreFailure(
        'limit.transaction',
        'Transaction exceeds the 64 MiB history budget; no buffers were changed',
      );
    }
    for (final e in next.entries) {
      final edits = grouped[e.key];
      bound[e.key]!.update(
        e.value,
        start: edits?.first.start,
        end: edits?.last.end,
      );
    }
    _setPaths(
      afterPaths,
      textChanged: {
        for (final id in next.keys)
          if (next[id] != before[id]) bound[id]!,
      },
    );
    final presenceTransitions = <SemanticTransition>[
      for (final entry in pathChanges.entries)
        if (beforePaths[entry.key]!.present != entry.value.present)
          if (!transitions.any(
            (transition) =>
                transition.resource == beforePaths[entry.key]!.id &&
                transition.from.isEmpty &&
                transition.to.isEmpty &&
                transition.toResource == entry.value.id &&
                transition.mode ==
                    (entry.value.present ? 'restoration' : 'removal'),
          ))
            SemanticTransition(
              beforePaths[entry.key]!.id,
              '',
              '',
              mode: entry.value.present ? 'restoration' : 'removal',
              destinationResource: entry.value.id == beforePaths[entry.key]!.id
                  ? null
                  : entry.value.id,
            ),
    ];
    // A destination must be restored before an object can follow a relocation
    // into it; reversing history must relocate that object out before hiding
    // the created file. Otherwise native removal fallback loses its owner.
    final historyTransitions = [
      ...presenceTransitions.where((t) => t.mode == 'restoration'),
      ...transitions,
      ...presenceTransitions.where((t) => t.mode == 'removal'),
      for (final entry in pathChanges.entries)
        if (beforePaths[entry.key]!.id != entry.value.id &&
            beforePaths[entry.key]!.present == entry.value.present)
          if (!transitions.any(
            (t) =>
                t.resource == beforePaths[entry.key]!.id &&
                t.from.isEmpty &&
                t.to.isEmpty &&
                t.toResource == entry.value.id,
          ))
            SemanticTransition(
              beforePaths[entry.key]!.id,
              '',
              '',
              destinationResource: entry.value.id,
            ),
    ];
    final history = _History(
      before,
      next,
      label,
      List.unmodifiable(historyTransitions),
      bound,
      beforePaths,
      afterPaths,
      coupledPublication,
    );
    _undo.add(history);
    for (final buffer in history.buffers.values) {
      _historyOwners[buffer] = (_historyOwners[buffer] ?? 0) + 1;
    }
    int historyBytes() => _undo.fold<int>(
      0,
      (sum, h) =>
          sum +
          h.before.values.fold<int>(0, (n, t) => n + t.length * 2) +
          h.after.values.fold<int>(0, (n, t) => n + t.length * 2),
    );
    while (_undo.length > 1 &&
        (_undo.length > 200 || historyBytes() > 64 * 1024 * 1024)) {
      _releaseHistory(_undo.removeAt(0));
    }
    for (final history in _redo) {
      _releaseHistory(history);
    }
    _redo.clear();
    _pruneAbsent();
    if (coupledPublication) _couplePublicationBuffers(bound.values);
    onCommitted?.call(Set.unmodifiable(bound.values));
  }

  void replace(String id, String value, {String label = 'Source'}) {
    final b = get(id);
    var a = 0;
    while (a < b.text.length &&
        a < value.length &&
        b.text.codeUnitAt(a) == value.codeUnitAt(a)) {
      a++;
    }
    if (a > 0 &&
        a < b.text.length &&
        b.text.codeUnitAt(a) >= 0xdc00 &&
        b.text.codeUnitAt(a) <= 0xdfff) {
      a--;
    }
    var oldEnd = b.text.length, newEnd = value.length;
    while (oldEnd > a &&
        newEnd > a &&
        b.text.codeUnitAt(oldEnd - 1) == value.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    if (oldEnd < b.text.length &&
        oldEnd > 0 &&
        b.text.codeUnitAt(oldEnd) >= 0xdc00 &&
        b.text.codeUnitAt(oldEnd) <= 0xdfff) {
      oldEnd++;
      newEnd++;
    }
    apply([
      TextEdit(
        buffer: id,
        generation: b.generation,
        start: a,
        end: oldEnd,
        expected: b.text.substring(a, oldEnd),
        replacement: value.substring(a, newEnd),
      ),
    ], label: label);
  }

  List<SemanticTransition> undo() {
    if (_undo.isEmpty) return const [];
    final h = _undo.last;
    _verifyHistory(h.after, h.buffers, h.afterPaths);
    _verifyPathDestinations(h.beforePaths);
    _undo.removeLast();
    _restoreHistory(h.before, h.buffers, h.beforePaths);
    _redo.add(h);
    if (h.coupledPublication) _couplePublicationBuffers(h.buffers.values);
    onCommitted?.call(Set.unmodifiable(h.buffers.values));
    return [
      for (final transition in h.transitions.reversed) transition.reversed,
    ];
  }

  List<SemanticTransition> redo() {
    if (_redo.isEmpty) return const [];
    final h = _redo.last;
    _verifyHistory(h.before, h.buffers, h.beforePaths);
    _verifyPathDestinations(h.afterPaths);
    _redo.removeLast();
    _restoreHistory(h.after, h.buffers, h.afterPaths);
    _undo.add(h);
    if (h.coupledPublication) _couplePublicationBuffers(h.buffers.values);
    onCommitted?.call(Set.unmodifiable(h.buffers.values));
    return h.transitions;
  }

  void _verifyHistory(
    Map<String, String> expected,
    Map<String, DocumentBuffer> bound,
    Map<DocumentBuffer, _BufferPathState> paths,
  ) {
    for (final entry in expected.entries) {
      final b = bound[entry.key], path = paths[b];
      if (b == null ||
          !(b.present ? identical(buffers[b.id], b) : _absent.contains(b)) ||
          buffers[b.id] != null && !identical(buffers[b.id], b) ||
          b.text != entry.value ||
          path == null ||
          b.id != path.id ||
          b.path != path.path ||
          b.present != path.present) {
        throw CoreFailure(
          'history.stale',
          'Source changed outside this transaction; no history was replayed',
        );
      }
    }
  }

  void _verifyPathDestinations(Map<DocumentBuffer, _BufferPathState> paths) {
    for (final entry in paths.entries) {
      final occupant = buffers[entry.value.id];
      if (occupant != null && !identical(occupant, entry.key)) {
        throw CoreFailure(
          'history.stale',
          'A historical file destination belongs to another buffer',
        );
      }
    }
  }

  void _restoreHistory(
    Map<String, String> text,
    Map<String, DocumentBuffer> bound,
    Map<DocumentBuffer, _BufferPathState> paths,
  ) {
    final changed = <DocumentBuffer>{};
    for (final entry in text.entries) {
      final b = bound[entry.key]!;
      if (b.text != entry.value) changed.add(b);
      b.update(entry.value);
    }
    _setPaths(paths, textChanged: changed);
  }

  void _setPaths(
    Map<DocumentBuffer, _BufferPathState> paths, {
    required Set<DocumentBuffer> textChanged,
  }) {
    final changed = paths.entries
        .where(
          (e) =>
              e.key.id != e.value.id ||
              e.key.path != e.value.path ||
              e.key.present != e.value.present,
        )
        .toList();
    final identities = {
      for (final entry in changed) entry.key.id: entry.value.id,
    };
    for (final entry in changed) {
      if (identical(buffers[entry.key.id], entry.key))
        buffers.remove(entry.key.id);
      if (_absent.remove(entry.key)) _releaseAbsentIdentity(entry.key.id);
    }
    for (final entry in changed) {
      final b = entry.key, path = entry.value;
      if (b.id != path.id || b.path != path.path || b.present != path.present) {
        b._id = path.id;
        b._path = path.path;
        b._present = path.present;
        if (!textChanged.contains(b)) b.generation++;
      }
      if (b.present) {
        buffers[b.id] = b;
      } else {
        _absent.add(b);
        _absentIdentities[b.id] = (_absentIdentities[b.id] ?? 0) + 1;
      }
    }
    if (identities.isNotEmpty)
      onPathsChanged?.call(
        Map.unmodifiable(identities),
        Set.unmodifiable(paths.keys),
      );
  }

  void clearHistory() {
    _undo.clear();
    _redo.clear();
    _historyOwners.clear();
    _pruneAbsent();
  }

  void _releaseHistory(_History history) {
    for (final buffer in history.buffers.values) {
      final count = _historyOwners[buffer]!;
      if (count == 1) {
        _historyOwners.remove(buffer);
      } else {
        _historyOwners[buffer] = count - 1;
      }
    }
  }

  void _pruneAbsent() {
    if (_absent.isEmpty) return;
    _absent.removeWhere((buffer) {
      if (buffer.dirty || _historyOwners.containsKey(buffer)) return false;
      _releaseAbsentIdentity(buffer.id);
      return true;
    });
  }

  void _releaseAbsentIdentity(String id) {
    final count = _absentIdentities[id]!;
    if (count == 1) {
      _absentIdentities.remove(id);
    } else {
      _absentIdentities[id] = count - 1;
    }
  }

  void retireHistory(Set<String> buffers) {
    bool touches(_History h) => h.buffers.entries.any(
      (e) => buffers.contains(e.key) || buffers.contains(e.value.id),
    );
    bool retire(_History history) {
      if (!touches(history)) return false;
      _releaseHistory(history);
      return true;
    }

    _undo.removeWhere(retire);
    _redo.removeWhere(retire);
    _pruneAbsent();
  }
}

/// Field ownership survives widget rebuilds and navigation. A flush is one plan.
class _PropertyInput {
  final Map<String, Object?> values = {};
  final Map<String, String> errors = {};
  bool composing = false;
}

class PropertySession {
  factory PropertySession.restore(Map<String, dynamic> record) {
    final session = PropertySession(
      root: record['root'] as String,
      buffer: record['buffer'] as String,
      generation: record['generation'] as int,
      pointer: record['pointer'] as String,
      range: List<int>.from(record['range'] as List),
      expected: record['expected'] as String,
    );
    session.committed.addAll(
      Map<String, Object?>.from(record['committed'] as Map? ?? const {}),
    );
    session.values.addAll(
      Map<String, Object?>.from(record['values'] as Map? ?? const {}),
    );
    return session;
  }
  PropertySession({
    required this.root,
    required this.buffer,
    required this.generation,
    required this.pointer,
    required List<int> range,
    required this.expected,
    PropertySession? shareInputFrom,
  }) : range = List.unmodifiable(range),
       _input = shareInputFrom?._input ?? _PropertyInput() {
    if (shareInputFrom != null &&
        (shareInputFrom.root != root ||
            shareInputFrom.buffer != buffer ||
            shareInputFrom.pointer != pointer)) {
      throw CoreFailure(
        'draft.owner',
        'Input cannot be shared with a different source occurrence',
      );
    }
  }
  final String root, buffer, pointer, expected;
  final int generation;
  final List<int> range;
  final _PropertyInput _input;
  final Map<String, Object?> committed = {};
  Map<String, Object?> get values => _input.values;
  Map<String, String> get errors => _input.errors;
  bool get composing => _input.composing;
  set composing(bool value) => _input.composing = value;
  bool get pending => jsonEncode(values) != jsonEncode(committed);
  void bind(String field, Object? value) {
    if (!values.containsKey(field)) {
      values[field] = value;
      committed[field] = value;
    }
  }

  void edit(String field, Object? value) {
    values[field] = value;
    errors.remove(field);
  }

  List<Map<String, Object?>> actions() => [
    for (final e in values.entries)
      if (e.value != committed[e.key])
        {'kind': 'set', 'pointer': '$pointer/${e.key}', 'value': e.value},
  ];
  Map<String, Object?> target() => {
    'resource': buffer,
    'generation': generation,
    'pointer': pointer,
    'range': range,
    'expected': expected,
  };
  Map<String, Object?> recovery() => {
    'root': root,
    'buffer': buffer,
    'generation': generation,
    'pointer': pointer,
    'range': range,
    'expected': expected,
    'committed': committed,
    'values': values,
  };
  void discard() {
    values
      ..clear()
      ..addAll(committed);
    errors.clear();
  }
}

/// A dialog's fields belong to an exact source occurrence, never its next page.
/// Values are draft input, not a separately serialized contract model.
class FormSession {
  FormSession({
    required this.kind,
    required this.target,
    required this.contentIdentity,
    required Map<String, Object?> arguments,
    required Map<String, Object?> initial,
  }) : arguments = Map.unmodifiable(arguments),
       initial = Map.unmodifiable(initial),
       values = Map.of(initial);

  final String kind, contentIdentity;
  final PropertySession target;
  final Map<String, Object?> arguments, initial, values;
  final Set<String> composing = {};
  String? error;
  bool get pending => jsonEncode(values) != jsonEncode(initial);
  void edit(String field, Object? value, {bool isComposing = false}) {
    values[field] = value;
    if (isComposing) {
      composing.add(field);
    } else {
      composing.remove(field);
    }
    error = null;
  }

  void verify(DocumentBuffer buffer, String root, {bool restoring = false}) {
    final range = target.range;
    if (root != target.root ||
        buffer.id != target.buffer ||
        (!restoring && buffer.generation != target.generation) ||
        textIdentity(buffer.text) != contentIdentity ||
        range.length != 2 ||
        range[0] < 0 ||
        range[1] > buffer.text.length ||
        range[1] < range[0] ||
        buffer.text.substring(range[0], range[1]) != target.expected) {
      throw CoreFailure(
        'draft.stale',
        'The captured form source changed. Its fields remain with the original occurrence; review or discard them.',
      );
    }
    if (composing.isNotEmpty) {
      throw CoreFailure(
        'draft.composing',
        'Complete composing text before applying this form',
      );
    }
  }

  Map<String, Object?> recovery() => {
    'version': 1,
    'kind': kind,
    'target': target.recovery(),
    'contentIdentity': contentIdentity,
    'arguments': arguments,
    'initial': initial,
    'values': values,
  };

  factory FormSession.restore(Map<String, dynamic> record) {
    if (record['version'] != 1) {
      throw CoreFailure('draft.version', 'Unsupported captured form version');
    }
    final t = record['target'] as Map;
    final session = FormSession(
      kind: record['kind'] as String,
      contentIdentity: record['contentIdentity'] as String,
      arguments: Map<String, Object?>.from(record['arguments'] as Map),
      initial: Map<String, Object?>.from(record['initial'] as Map),
      target: PropertySession(
        root: t['root'] as String,
        buffer: t['buffer'] as String,
        generation: t['generation'] as int,
        pointer: t['pointer'] as String,
        range: List<int>.from(t['range'] as List),
        expected: t['expected'] as String,
      ),
    );
    session.values
      ..clear()
      ..addAll(Map<String, Object?>.from(record['values'] as Map));
    return session;
  }
}
