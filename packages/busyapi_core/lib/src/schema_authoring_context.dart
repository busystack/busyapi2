import 'model.dart';

/// An authoring capability belongs to this occurrence and specification context.
/// API info.version is deliberately absent: it does not select schema semantics.
typedef SchemaAuthoringContext = ({
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

SchemaAuthoringContext schemaAuthoringContextFromJson(
  Object? value, {
  required CoreFailure Function() invalid,
}) {
  if (value case {
    'root': String root,
    'rootVersion': String? rootVersion,
    'resource': String resource,
    'resourceVersion': String? resourceVersion,
    'pointer': String pointer,
    'family': String family,
    'dialect': String? dialect,
    'base': String base,
    'resourcePointer': String resourcePointer,
  }) {
    return (
      root: root,
      rootVersion: rootVersion,
      resource: resource,
      resourceVersion: resourceVersion,
      pointer: pointer,
      family: family,
      dialect: dialect,
      base: base,
      resourcePointer: resourcePointer,
    );
  }
  throw invalid();
}
