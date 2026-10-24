import 'dart:convert';

import 'swagger_serialization.dart';

/// Reconstruct the declared representation for canonical JSON/schema checks.
/// Numbers remain JSON lexemes; ambiguous representations stay unchecked.
(Map?, String)? decodeDeclaredHeader(Map declaration, List<String> values) {
  final content = (declaration['content'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  if (content.isNotEmpty) {
    if (content.length != 1) throw UnsupportedError('Ambiguous header content');
    final media = content.single, schema = media['schema'];
    final type = '${media['mediaType']}'.split(';').first.trim().toLowerCase();
    if (!(type == 'application/json' || type.endsWith('+json'))) {
      if (schema is! Map || schema['unconstrained'] == true) return null;
      throw UnsupportedError('Unsupported header content representation');
    }
    if (values.length != 1) {
      throw UnsupportedError('Unsupported header content representation');
    }
    // JSON media still requires valid JSON when no schema was declared. Keep
    // the wire representation for the canonical exact-value syntax evaluator.
    return (schema is Map ? schema : null, values.single);
  }
  final schema = declaration['schema'];
  if (schema is! Map || schema['unconstrained'] == true) return null;
  final shape = declaration['shape'];
  if (shape is! Map ||
      declaration['family'] != '2.0' && declaration['style'] != 'simple') {
    throw UnsupportedError('Header representation cannot be established');
  }
  final cookie = '${declaration['name']}'.toLowerCase() == 'set-cookie';
  final type = shape['type'];
  if (cookie &&
      declaration['family'] != '3.2' &&
      (values.length > 1 || type == 'array' || type == 'object')) {
    throw UnsupportedError(
      'This Set-Cookie representation is not modeled by the selected OpenAPI version',
    );
  }
  String scalar(String text, Object? shape) {
    if (shape is! Map) throw UnsupportedError('Ambiguous header scalar');
    switch (shape['type']) {
      case 'string':
        return jsonEncode(text);
      case 'integer':
      case 'number':
        if (RegExp(r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$')
            .hasMatch(text.trim())) {
          return text.trim();
        }
        throw const FormatException('Header is not a JSON decimal');
      case 'boolean':
        if (text.trim() == 'true' || text.trim() == 'false') return text.trim();
        throw const FormatException('Header is not a JSON boolean');
      default:
        throw UnsupportedError('Nested header serialization is undefined');
    }
  }

  if (type != 'array' && type != 'object') {
    if (values.length != 1) throw UnsupportedError('Repeated scalar header');
    return (schema, scalar(values.single, shape));
  }
  final parts =
      declaration['family'] == '2.0' && declaration['collectionFormat'] != 'csv'
      ? values
            .join(',')
            .split(swaggerDelimiter(declaration['collectionFormat']))
      : cookie
      ? values
      : _listParts(values.join(','));
  if (type == 'array') {
    if (parts.length == 1 && parts.single.isEmpty)
      throw UnsupportedError('Ambiguous empty array representation');
    if (cookie)
      throw UnsupportedError('Set-Cookie is not a comma-separated array');
    return (
      schema,
      '[${parts.map((part) => scalar(part, shape['items'])).join(',')}]',
    );
  }
  final fields = <String, String>{};
  void add(String key, String value) {
    if (fields.containsKey(key))
      throw UnsupportedError('Repeated object member');
    final properties = shape['properties'];
    fields[key] = scalar(
      value,
      properties is Map
          ? properties[key] ?? shape['additionalProperties']
          : shape['additionalProperties'],
    );
  }

  if (declaration['explode'] == true) {
    for (final part in parts) {
      final equals = part.indexOf('=');
      if (equals < 0)
        throw const FormatException('Missing header object delimiter');
      add(part.substring(0, equals), part.substring(equals + 1));
    }
  } else {
    if (cookie)
      throw UnsupportedError('Set-Cookie requires an exploded object');
    if (parts.length.isOdd)
      throw const FormatException('Incomplete header object');
    for (var i = 0; i < parts.length; i += 2) {
      add(parts[i], parts[i + 1]);
    }
  }
  return (
    schema,
    '{${fields.entries.map((entry) => '${jsonEncode(entry.key)}:${entry.value}').join(',')}}',
  );
}

// HTTP quoting protects commas; quotes/escapes remain part of the OAS value.
List<String> _listParts(String text) {
  final result = <String>[];
  var quoted = false, escaped = false, start = 0;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quoted && char == r'\') {
      escaped = true;
      continue;
    }
    if (char == '"') quoted = !quoted;
    if (!quoted && char == ',') {
      result.add(text.substring(start, i).trim());
      start = i + 1;
    }
  }
  if (quoted || escaped)
    throw const FormatException('Unclosed header quoted value');
  result.add(text.substring(start).trim());
  return result;
}
