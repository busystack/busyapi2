import 'dart:convert';

import 'model.dart';

enum SchemaValueForm { object, boolean, objectArray }

/// Shape metadata from the captured engine field. This presentation check does
/// not evaluate a schema or choose an OpenAPI family or schema dialect.
class SchemaValueForms {
  const SchemaValueForms._(this.supported, this.forms);

  factory SchemaValueForms.fromJson(Object? value) {
    CoreFailure invalid() => CoreFailure(
      'engine.schema-value-forms',
      'The engine returned invalid schema field value forms',
    );
    if (value case {
      'version': 1,
      'supported': bool supported,
      'forms': List raw,
    }) {
      if (raw.length > 3 ||
          raw.toSet().length != raw.length ||
          supported != raw.isNotEmpty) {
        throw invalid();
      }
      final forms = <SchemaValueForm>[];
      for (final form in raw) {
        forms.add(switch (form) {
          'object' => SchemaValueForm.object,
          'boolean' => SchemaValueForm.boolean,
          'object-array' => SchemaValueForm.objectArray,
          _ => throw invalid(),
        });
      }
      return SchemaValueForms._(supported, List.unmodifiable(forms));
    }
    throw invalid();
  }

  final bool supported;
  final List<SchemaValueForm> forms;

  List<String> get jsonTypes => List.unmodifiable([
    for (final form in forms)
      switch (form) {
        SchemaValueForm.object => 'object',
        SchemaValueForm.boolean => 'boolean',
        SchemaValueForm.objectArray => 'array',
      },
  ]);

  /// Inspect only shape. The unchanged original lexeme remains the CST edit's
  /// input, including numbers outside Dart's machine-sized numeric range.
  bool accepts(String raw) {
    if (!supported) return false;
    final value = jsonDecode(raw);
    return forms.any(
      (form) => switch (form) {
        SchemaValueForm.object => value is Map,
        SchemaValueForm.boolean => value is bool,
        SchemaValueForm.objectArray =>
          value is List && value.every((item) => item is Map),
      },
    );
  }
}
