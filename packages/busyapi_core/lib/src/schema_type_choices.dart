import 'model.dart';

typedef SchemaTypeContext = ({
  String root,
  String? rootVersion,
  String resource,
  String? resourceVersion,
  String pointer,
  String family,
  String? dialect,
  String base,
  String resourcePointer,
});

/// Captured authoring capabilities; the engine owns normative type selection.
class SchemaTypeChoices {
  const SchemaTypeChoices._(
    this.supported,
    this.context,
    this.scalarTypes,
    this.unionTypes,
  );

  factory SchemaTypeChoices.fromJson(Object? value) {
    CoreFailure invalid() => CoreFailure(
      'engine.schema-type-choices',
      'The engine returned incomplete schema type choices',
    );
    if (value case {
      'revision': '1',
      'supported': bool supported,
      'context': {
        'root': String root,
        'rootVersion': String? rootVersion,
        'resource': String resource,
        'resourceVersion': String? resourceVersion,
        'pointer': String pointer,
        'family': String family,
        'dialect': String? dialect,
        'base': String base,
        'resourcePointer': String resourcePointer,
      },
      'scalarTypes': List scalars,
      'unionTypes': List unions,
    }) {
      const names = {
        'object',
        'array',
        'string',
        'number',
        'integer',
        'boolean',
        'null',
      };
      List<String> read(List values, {required bool scalar}) {
        if (values.any(
              (v) =>
                  v is! String ||
                  !names.contains(v) && !(scalar && v == 'file'),
            ) ||
            values.toSet().length != values.length) {
          throw invalid();
        }
        return List<String>.unmodifiable(values.cast<String>());
      }

      final scalarTypes = read(scalars, scalar: true),
          unionTypes = read(unions, scalar: false);
      if (supported && scalarTypes.isEmpty ||
          !supported && (scalarTypes.isNotEmpty || unionTypes.isNotEmpty) ||
          unionTypes.any((v) => !scalarTypes.contains(v))) {
        throw invalid();
      }
      return SchemaTypeChoices._(
        supported,
        (
          root: root,
          rootVersion: rootVersion,
          resource: resource,
          resourceVersion: resourceVersion,
          pointer: pointer,
          family: family,
          dialect: dialect,
          base: base,
          resourcePointer: resourcePointer,
        ),
        scalarTypes,
        unionTypes,
      );
    }
    throw invalid();
  }

  final bool supported;
  final SchemaTypeContext context;
  final List<String> scalarTypes, unionTypes;

  bool equivalentTo(SchemaTypeChoices other) =>
      supported == other.supported &&
      context == other.context &&
      scalarTypes.join(',') == other.scalarTypes.join(',') &&
      unionTypes.join(',') == other.unionTypes.join(',');

  /// Shape validation consumes capabilities rather than reproducing OAS rules.
  bool allows(Object? value) =>
      supported &&
      (value == null ||
          value is String && scalarTypes.contains(value) ||
          value is List &&
              value.isNotEmpty &&
              value.toSet().length == value.length &&
              value.every((v) => v is String && unionTypes.contains(v)));
}
