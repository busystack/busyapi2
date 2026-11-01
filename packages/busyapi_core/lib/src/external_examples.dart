part of 'project.dart';

enum ExternalExampleCondition { invalid, unsupported, unavailable }

/// Opaque payload ownership is separate from parsed contract resources. These
/// bytes never enter a DocumentBuffer merely because an Example references them.
class CapturedExternalExample {
  CapturedExternalExample._({
    required this.id,
    required this.identity,
    required this.generation,
    required List<String> aliases,
    Uint8List? bytes,
    this.problemCode,
    this.problemMessage,
    this.problemCondition,
    this.workingIdentity,
  }) : aliases = List.unmodifiable(aliases),
       bytes = bytes?.asUnmodifiableView() {
    if (bytes == null && (problemCode == null || problemMessage == null ||
            problemCondition == null) ||
        bytes != null && (problemCode != null || problemMessage != null || problemCondition != null)) {
      throw CoreFailure('example.capture.protocol',
          'An external example capture must contain bytes or one explicit failure');
    }
  }

  final String id, identity;
  final int generation;
  final List<String> aliases;
  final Uint8List? bytes;
  final String? problemCode, problemMessage, workingIdentity;
  final ExternalExampleCondition? problemCondition;
  bool get available => bytes != null;
  CapturedExternalExample _withAliases(Iterable<String> values) {
    final merged = {...aliases, ...values}.toList()..sort();
    if (merged.length > 2048) {
      throw CoreFailure('limit.examples.external.aliases',
          'An external example exceeds 2048 captured URI aliases');
    }
    return CapturedExternalExample._(id: id, identity: identity,
        generation: generation, aliases: merged, bytes: bytes,
        problemCode: problemCode, problemMessage: problemMessage,
        problemCondition: problemCondition, workingIdentity: workingIdentity);
  }

  Map<String, Object?> get ownership => {
    'id': id,
    'identity': identity,
    'generation': generation,
    'kind': 'external-example',
    'state': available ? 'available' : 'unavailable',
    if (!available) 'workingIdentity': workingIdentity,
  };
  Map<String, Object?> toJson() => {
    ...ownership,
    'version': 1,
    'aliases': aliases,
    if (bytes case final content?) ...{
      'base64': base64Encode(content),
      'byteLength': content.length,
    } else
      'problem': {'code': problemCode, 'message': problemMessage, 'condition': problemCondition?.name},
  };
}

extension _ExternalExampleCapture on BusyProject {
  Future<CapturedExternalExample> _captureExternalExample(
    String target,
    Map<String, String> mappings, {
    required bool saved,
    required void Function() active,
  }) async {
    var id = mappings[target] ?? target;
    final aliases = mappings.entries
        .where((entry) => entry.value == id)
        .map((entry) => entry.key).toSet().toList()..sort();
    CapturedExternalExample unavailable(String code, String message,
        [ExternalExampleCondition condition = ExternalExampleCondition.unavailable]) =>
        CapturedExternalExample._(
          id: id,
          identity: textIdentity(jsonEncode([id, code, condition.name])),
          generation: store.buffers[id]?.generation ?? 0,
          workingIdentity: store.buffers[id]?.sourceIdentity,
          aliases: aliases,
          problemCode: code,
          problemMessage: message,
          problemCondition: condition,
        );
    active();
    final uri = Uri.parse(id);
    if (uri.scheme != 'file') {
      return unavailable('example.external-value.unapproved',
          'The external example needs an approved local resource mapping');
    }
    try {
      final access = accessFor(uri.toFilePath());
      final path = access.pathFor(uri.toFilePath());
      final physical = Uri.file(path).toString();
      if (physical != id) {
        if (!aliases.contains(id)) aliases.add(id);
        aliases.sort();
        id = physical;
      }
      if (!saved) _verifyVirtualResource(id);
      final buffer = saved ? null : store.buffers[id];
      if (buffer != null && !buffer.dirty && !buffer.externalConflict) {
        await refreshDisk(buffer);
        active();
      }
      if (buffer != null && !buffer.dirty && buffer.externalConflict) {
        // Distinguish a missing file from an open buffer whose external bytes
        // cannot be reconciled. Neither observation substitutes stale text.
        await access.read(path);
        active();
        return unavailable('example.external-value.conflict',
            'The open external example conflicts with its current file; reconcile it before evaluation');
      }
      if (buffer != null && !_externalExampleUnicodeComplete(buffer.text)) {
        return unavailable('example.external-value.encoding',
            'The working external example contains an unpaired Unicode surrogate; no replacement bytes were captured', ExternalExampleCondition.invalid);
      }
      final generation = buffer?.generation ?? 0;
      final bytes = buffer == null
          ? await access.read(path)
          : buffer.bytes();
      active();
      if (bytes.length > 16 * 1024 * 1024) {
        return unavailable('limit.examples.external.resource',
            'An external example exceeds the 16 MiB resource limit', ExternalExampleCondition.unsupported);
      }
      final identity = await contentIdentityAsync(bytes);
      active();
      return CapturedExternalExample._(
        id: id, identity: identity, generation: generation, aliases: aliases,
        bytes: Uint8List.fromList(bytes),
      );
    } on CoreFailure catch (error) {
      active();
      if (error.code == 'cancelled' || error.code == 'access.closed') rethrow;
      return unavailable(error.code, error.message,
          error.code.startsWith('limit.') ? ExternalExampleCondition.unsupported : ExternalExampleCondition.unavailable);
    } on FileSystemException catch (error) {
      active();
      return unavailable(
          error.osError?.errorCode == 2
              ? 'example.external-value.missing' : 'example.external-value.denied',
          error.osError?.errorCode == 2
              ? 'The external example resource is missing'
              : 'The external example resource could not be read through its approved context');
    }
  }

  Future<bool> _externalExampleInputsCurrent(
    AnalysisSnapshot snapshot, {
    bool saved = false,
    bool rejectConflicts = true,
    bool Function()? cancelled,
  }) async {
    void active() {
      if (_closed) throw CoreFailure('access.closed', 'The workspace is closed');
      if (cancelled?.call() ?? false) {
        throw CoreFailure('cancelled', 'External example verification was cancelled');
      }
    }
    var current = true;
    await _resourceBatch(snapshot.exampleResources, (captured) async {
      active();
      final buffer = store.buffers[captured.id];
      if (!saved && buffer != null) {
        await refreshDisk(buffer);
        active();
        if (rejectConflicts && buffer.externalConflict) current = false;
      }
      final actual = await _captureExternalExample(captured.id, const {},
          saved: saved, active: active);
      if (actual.identity != captured.identity ||
          !saved && actual.generation != captured.generation) current = false;
    });
    active();
    return current && (saved || snapshot._examplesCurrent(store));
  }
}

// UTF-8 encoding must not silently replace transient/invalid editor code units.
// Opaque disk bytes never enter this Unicode check.
bool _externalExampleUnicodeComplete(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= units.length || units[index] < 0xdc00 || units[index] > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
