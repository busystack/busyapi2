import 'dart:convert';

import 'model.dart';
import 'request_form_values.dart';

String swaggerDelimiter(Object? format) => switch (format ?? 'csv') {
  'csv' => ',',
  'ssv' => ' ',
  'tsv' => '\t',
  'pipes' => '|',
  _ => throw CoreFailure(
    'request.collectionFormat',
    'Unsupported Swagger collectionFormat',
  ),
};

/// Serialize native Parameter/Items declarations, including nested arrays.
/// Exact numeric leaves arrive as source lexemes from the contract engine.
List<(String, String)> serializeSwaggerParameter(
  Map declaration,
  Object? value,
) {
  final name = declaration['name'] as String, location = declaration['in'];
  String scalar(Object? value) {
    if (value is List || value is Map)
      throw CoreFailure(
        'request.parameter.shape',
        'A Swagger primitive parameter cannot serialize this structured value',
      );
    final text = value == null ? 'null' : '$value';
    if (location == 'header' && RegExp(r'[\x00-\x1f\x7f]').hasMatch(text))
      throw CoreFailure(
        'request.header.injection',
        'A Swagger header item must not contain control characters',
      );
    return text;
  }

  String item(Map? rule, Object? value, int depth) {
    if (depth > 128)
      throw CoreFailure(
        'limit.request.items',
        'Swagger Items nesting exceeds 128',
      );
    if (value is! List) return scalar(value);
    if (rule?['type'] != 'array')
      throw CoreFailure(
        'request.parameter.shape',
        'The Swagger Items declaration does not describe a nested array',
      );
    return value
        .map((v) => item(rule?['items'] as Map?, v, depth + 1))
        .join(swaggerDelimiter(rule?['collectionFormat']));
  }

  final values = value is List
      ? value.map((v) => item(declaration['items'] as Map?, v, 0)).toList()
      : [scalar(value)];
  final multiple = value is List && declaration['collectionFormat'] == 'multi';
  final serialized = multiple
      ? values
      : [
          values.join(
            value is List
                ? swaggerDelimiter(declaration['collectionFormat'])
                : '',
          ),
        ];
  return [
    for (final text in serialized)
      (
        name,
        location == 'path' || location == 'query'
            ? Uri.encodeComponent(text)
            : text,
      ),
  ];
}

/// Form editors hold repeated literal fields. Native collectionFormat owns
/// their wire grouping; schema validation uses the original individual values.
List<(String, String)> swaggerFormFields(
  List<(String, String)> fields,
  List<Map> declarations,
  Iterable<String> files,
) {
  final grouped = <String, List<String>>{};
  for (final field in fields)
    grouped.putIfAbsent(field.$1, () => []).add(field.$2);
  final fileNames = files.toSet();
  for (final declaration in declarations) {
    final name = declaration['name'] as String, values = grouped[name];
    if (declaration['required'] == true &&
        values == null &&
        !fileNames.contains(name))
      throw CoreFailure(
        'request.form.required',
        'Enter required Swagger formData parameter $name',
      );
    if (values != null && declaration['type'] == 'file')
      throw CoreFailure(
        'request.form.file',
        'Select a file for Swagger formData parameter $name',
      );
    if (fileNames.contains(name) && declaration['type'] != 'file')
      throw CoreFailure(
        'request.form.file',
        'The Swagger formData parameter $name is not a file',
      );
    if (values != null && values.length > 1 && declaration['type'] != 'array')
      throw CoreFailure(
        'request.form.scalar',
        'Swagger scalar formData parameter $name has multiple values',
      );
  }
  return [
    for (final entry in grouped.entries)
      ...() {
        final rule = declarations
            .where((d) => d['name'] == entry.key)
            .firstOrNull;
        if (rule?['type'] == 'array' && rule?['collectionFormat'] != 'multi')
          return [
            (
              entry.key,
              entry.value.join(swaggerDelimiter(rule?['collectionFormat'])),
            ),
          ];
        return [for (final value in entry.value) (entry.key, value)];
      }(),
  ];
}

String swaggerFormInstance(Map declaration, List<String> values) {
  String primitive(Object? type, String text) {
    if (type == 'integer' || type == 'number') {
      if (!RegExp(r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$')
          .hasMatch(text))
        throw const FormatException('Expected a JSON decimal');
      return text;
    }
    if (type == 'boolean') {
      if (text != 'true' && text != 'false')
        throw const FormatException('Expected true or false');
      return text;
    }
    return jsonEncode(text);
  }

  if (declaration['type'] == 'array') {
    final items = declaration['items'];
    if (items is! Map || items['type'] == 'array')
      throw UnsupportedError('Nested form items require structured input');
    return '[${values.map((v) => primitive(items['type'], v)).join(',')}]';
  }
  return primitive(declaration['type'], values.single);
}

List<(String, String)> swaggerFormDataFields(
  RequestFormData data,
  List<Map> declarations,
  Iterable<String> files,
) {
  final fileNames = files.toSet();
  for (final declaration in declarations) {
    final name = declaration['name'] as String;
    final value = data.fields[name];
    final absent =
        value == null ||
        value.kind == RequestDataKind.array && value.items.isEmpty;
    if (declaration['required'] == true &&
        absent &&
        !fileNames.contains(name)) {
      throw CoreFailure(
        'request.form.required',
        'Enter required Swagger formData parameter $name',
      );
    }
    if (declaration['type'] == 'file' && data.fields.containsKey(name) ||
        declaration['type'] != 'file' && fileNames.contains(name)) {
      throw CoreFailure(
        'request.form.file',
        'Use the declared file input for Swagger formData parameter $name',
      );
    }
  }
  return [
    for (final entry in data.fields.entries)
      ...serializeSwaggerParameter({
        'collectionFormat': 'multi',
        ...?declarations
            .where((declaration) => declaration['name'] == entry.key)
            .firstOrNull,
        'name': entry.key,
        'in': 'formData',
      }, entry.value.value),
  ];
}
