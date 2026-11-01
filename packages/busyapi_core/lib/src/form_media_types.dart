import 'model.dart';
import 'multipart_encoding.dart';

enum RequestFormBinding {
  urlEncoded,
  namedMultipart;

  static RequestFormBinding? fromJson(Object? value) => switch (value) {
    null => null,
    'urlencoded' => urlEncoded,
    'multipart-named' => namedMultipart,
    _ => throw CoreFailure(
      'request.form.protocol',
      'The captured form binding is not recognized.',
    ),
  };
}

class ResolvedFormMediaTypes {
  const ResolvedFormMediaTypes(this.fields, this.files);
  final Map<String, String> fields;
  final List<String> files;
}

/// Display choices supplied by the captured contract engine. Selection is
/// evaluated by that same engine before transport is prepared.
class FormPartMediaOptions {
  const FormPartMediaOptions({
    required this.name,
    required this.contentTypes,
    required this.concreteTypes,
    required this.styled,
    required this.allowsCustom,
    required this.requiresChoice,
    this.error,
    this.fileShapes = const [],
  });
  final String name;
  final List<String> contentTypes;
  final List<String> concreteTypes;
  final bool styled, allowsCustom, requiresChoice;
  final String? error;
  final List<MultipartFileShape> fileShapes;

  static List<FormPartMediaOptions> fromJson(Object? value) {
    if (value == null) return const [];
    if (value is! Map || value.length > 2048) _invalid();
    return List.unmodifiable([
      for (final entry in value.entries) _part(entry.key, entry.value),
    ]);
  }

  static FormPartMediaOptions _part(Object? name, Object? raw) {
    if (name is! String || raw is! Map || raw['name'] != name) _invalid();
    final shapes = raw['fileShapes'];
    if (raw.containsKey('fileShapes') &&
        (shapes is! List ||
            shapes.isEmpty ||
            shapes.length > 2 ||
            shapes.toSet().length != shapes.length ||
            shapes.any((shape) => shape != 'single' && shape != 'array')))
      _invalid();
    final styled = raw['styled'], error = raw['error'];
    if (styled is! bool || error != null && error is! String) _invalid();
    final types = raw['contentTypes'], concrete = raw['concreteTypes'];
    if (concrete != null &&
        (concrete is! List ||
            concrete.length > 2048 ||
            concrete.any((type) => type is! String)))
      _invalid();
    if (types != null &&
            (types is! List ||
                types.length > 2048 ||
                types.any((type) => type is! String)) ||
        raw.containsKey('allowsCustom') && raw['allowsCustom'] is! bool ||
        raw.containsKey('requiresChoice') && raw['requiresChoice'] is! bool) {
      _invalid();
    }
    if (!styled &&
        error == null &&
        (types is! List ||
            types.isEmpty ||
            types.length > 2048 ||
            types.any((type) => type is! String) ||
            raw['allowsCustom'] is! bool ||
            raw['requiresChoice'] is! bool)) {
      _invalid();
    }
    if (!styled &&
        error == null &&
        (concrete is! List ||
            concrete.length > 2048 ||
            concrete.any(
              (type) => type is! String || !(types as List).contains(type),
            )))
      _invalid();
    return FormPartMediaOptions(
      fileShapes: List.unmodifiable([
        for (final shape in shapes as List? ?? const [])
          MultipartFileShape.fromJson(shape),
      ]),
      name: name,
      contentTypes: List.unmodifiable(
        types is List ? types.cast<String>() : <String>[],
      ),
      concreteTypes: List.unmodifiable(
        concrete is List ? concrete.cast<String>() : <String>[],
      ),
      styled: styled,
      allowsCustom: raw['allowsCustom'] == true,
      requiresChoice: raw['requiresChoice'] == true,
      error: error as String?,
    );
  }

  static Never _invalid() => throw CoreFailure(
    'request.form.protocol',
    'Invalid captured part media choices.',
  );
}
