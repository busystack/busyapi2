part of 'project.dart';

/// An opaque native action, tied to one captured presentation. The renderer
/// receives only [index], [pointer], [role] and [authored]; physical resource
/// identities, UTF-16 ranges and alias occurrences stay with its native owner.
class DocumentationSourceAction {
  DocumentationSourceAction._(
    this.index,
    this.pointer,
    this.role,
    this.authored,
    Map source,
  ) : source = _freezeResult(Map<String, dynamic>.from(source));
  final int index;
  final String pointer, role;
  final bool authored;
  final Map<String, dynamic> source;

  Map<String, Object?> toJson() => Map.unmodifiable({
    'index': index,
    'pointer': pointer,
    'role': role,
    'authored': authored,
  });
}

class _DocumentationSourceIndex {
  _DocumentationSourceIndex(List<DocumentationSourceAction> actions)
    : actions = List.unmodifiable(actions),
      coordinates = Map.unmodifiable({
        for (final action in actions)
          jsonEncode([action.role, action.pointer]): action.index,
      });
  final List<DocumentationSourceAction> actions;
  final Map<String, int> coordinates;
}

// Join already-proved display coordinates, never URI resolution, parsing or
// generated bundle fields. Every displayed location has an exact original
// occurrence; effective defaults remain metadata without source actions.
_DocumentationSourceIndex _documentationSourceIndex(
  Map<String, dynamic> original,
  Map<String, dynamic> derived,
  List provenance,
) {
  Never invalid() => throw CoreFailure(
    'documentation.source',
    'Documentation source ownership is absent or ambiguous',
  );
  String key(String resource, String pointer) =>
      jsonEncode([resource, pointer]);
  String signature(Map source) => jsonEncode([
    source['resource'],
    source['pointer'],
    source['generation'],
    source['range'],
    source['physicalPointer'],
    source['occurrenceRange'],
  ]);
  final originals = <String, Map<String, Map>>{
    'node': {},
    'field': {},
    'reference': {},
  };
  Iterable<(String, Map)> locations(Map document) sync* {
    for (final section in document['sections'] as List) {
      yield ('node', section['source'] as Map);
      for (final field in section['entries'] as List) {
        yield ('field', field['source'] as Map);
      }
      for (final reference in section['references'] as List) {
        yield ('reference', reference['source'] as Map);
      }
    }
  }

  for (final (role, source) in locations(original)) {
    final coordinate = key(
      source['resource'] as String,
      source['pointer'] as String,
    );
    final previous = originals[role]![coordinate];
    if (previous != null && signature(previous) != signature(source)) invalid();
    originals[role]![coordinate] = source;
  }
  Map? known(String resource, String pointer, String role) {
    final coordinate = key(resource, pointer);
    return originals[role]![coordinate] ??
        originals['node']![coordinate] ??
        originals['field']![coordinate];
  }

  final nodes = <String, List<Map>>{}, references = <String, List<Map>>{};
  final kinds = {
    for (final section in original['sections'] as List)
      key(
        section['source']['resource'] as String,
        section['source']['pointer'] as String,
      ): section['kind'],
  };
  final displayLocations = {
    for (final (_, source) in locations(derived)) source['pointer'] as String,
  };
  for (final value in provenance) {
    final record = value as Map, source = record['source'] as Map;
    final coordinate = key(
      source['resource'] as String,
      source['pointer'] as String,
    );
    if (record['kind'] == 'reference'
        ? !originals['reference']!.containsKey(coordinate)
        : kinds[coordinate] != record['kind']) {
      invalid();
    }
    final pointer = record['derived']['pointer'] as String;
    if (!displayLocations.contains(pointer)) invalid();
    final table = record['kind'] == 'reference' ? references : nodes;
    (table[pointer] ??= []).add(record);
  }
  final actions = <DocumentationSourceAction>[];
  final coordinates = <String>{};
  var bytes = 0;
  for (final (role, display) in locations(derived)) {
    final pointer = display['pointer'] as String;
    if (!coordinates.add(jsonEncode([role, pointer]))) invalid();
    List<Map>? records;
    var ancestor = pointer;
    if (role != 'node') records = references[pointer];
    if (records == null) {
      while (true) {
        records = nodes[ancestor];
        if (records != null || ancestor.isEmpty) break;
        ancestor = ancestor.substring(0, ancestor.lastIndexOf('/'));
      }
    }
    if (records == null) invalid();
    Map? selected;
    bool? authored;
    for (final record in records) {
      final source = record['source'] as Map;
      final resource = source['resource'] as String;
      final originalPointer =
          (source['pointer'] as String) + pointer.substring(ancestor.length);
      final target = known(resource, originalPointer, role);
      if (target == null ||
          selected != null && signature(selected) != signature(target)) {
        invalid();
      }
      selected = target;
      authored = true;
    }
    if (selected == null) invalid();
    bytes += pointer.length * 2 + signature(selected).length * 2;
    if (actions.length >= 200000 || bytes > 64 * 1024 * 1024) {
      throw CoreFailure(
        'documentation.source.limit',
        'Documentation source actions exceed their bounded limit',
      );
    }
    actions.add(
      DocumentationSourceAction._(
        actions.length,
        pointer,
        role,
        authored!,
        selected,
      ),
    );
  }
  return _DocumentationSourceIndex(actions);
}

void _documentationDisplayWorker(List<Object?> input) {
  final port = input[0] as SendPort;
  try {
    final packet = input[1] as Map<String, dynamic>;
    if (packet['version'] != 1 ||
        packet['producer'] != 'busyapi-reference-display-packet' ||
        packet['producerVersion'] != '2' ||
        packet['encoding'] != 'json' ||
        packet['content'] is! String ||
        (packet['content'] as String).length > 48 * 1024 * 1024) {
      throw CoreFailure(
        'documentation.protocol',
        'The worker returned an invalid display packet',
      );
    }
    Map<String, dynamic> result;
    try {
      result = jsonDecode(packet['content'] as String) as Map<String, dynamic>;
    } on Object {
      throw CoreFailure(
        'documentation.protocol',
        'The display packet is not a complete JSON record',
      );
    }
    final snapshot = input[2] as AnalysisSnapshot,
        outputId = input[3] as String,
        output = result['output'],
        original = result['original'],
        rawProjection = result['projection'];
    if (result['version'] != 1 ||
        result['complete'] != true ||
        result['producer'] != 'busyapi-reference-display' ||
        result['producerVersion'] != '2' ||
        result['representation'] != 'graph-addressed-display-only' ||
        result['root'] != snapshot.root ||
        result['snapshot'] != snapshot.identity ||
        output is! Map ||
        output['id'] != outputId ||
        output['text'] is! String ||
        (output['text'] as String).length > 16 * 1024 * 1024 ||
        output['identity'] != textIdentity(output['text'] as String) ||
        original is! Map<String, dynamic> ||
        rawProjection is! Map<String, dynamic> ||
        rawProjection['root'] != outputId ||
        rawProjection['snapshot'] != output['identity'] ||
        rawProjection['displayOnly'] != true ||
        rawProjection['coordinateSpace'] != 'display-document' ||
        result['provenance'] is! List ||
        (result['provenance'] as List).length > 200000) {
      throw CoreFailure(
        'documentation.protocol',
        'The worker did not return complete captured display coordinates',
      );
    }
    final coordinates = AnalysisSnapshot(
      root: outputId,
      resources: [
        {
          'id': outputId,
          'text': output['text'],
          'identity': output['identity'],
          'generation': 0,
        },
      ],
      engineIdentity: input[4] as String,
    );
    _verifyReferenceDocument(original, snapshot);
    final projection = <String, dynamic>{
      ...rawProjection,
      'snapshot': coordinates.identity,
    };
    _verifyReferenceDocument(projection, coordinates);
    final resources = {
      for (final resource in snapshot.resources) resource['id'],
    };
    for (final entry in result['provenance'] as List) {
      if (entry is! Map ||
          entry['kind'] is! String ||
          entry['source'] is! Map ||
          entry['derived'] is! Map ||
          !resources.contains(entry['source']['resource']) ||
          entry['source']['pointer'] is! String ||
          entry['derived']['resource'] != outputId ||
          entry['derived']['pointer'] is! String) {
        throw CoreFailure(
          'documentation.protocol',
          'The renderer source provenance is malformed',
        );
      }
    }
    final frozen = _freezeResult({...result, 'projection': projection});
    final originalFrozen = frozen['original'] as Map<String, dynamic>,
        projectionFrozen = frozen['projection'] as Map<String, dynamic>;
    Isolate.exit(
      port,
      _PreparedReferenceDisplay(
        coordinates,
        frozen,
        _documentationSourceIndex(
          originalFrozen,
          projectionFrozen,
          frozen['provenance'] as List,
        ),
      ),
    );
  } on Object catch (error) {
    port.send({
      'code': error is CoreFailure ? error.code : 'documentation.worker',
    });
  }
}
