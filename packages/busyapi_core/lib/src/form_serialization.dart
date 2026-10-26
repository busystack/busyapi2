import 'dart:convert';
import 'dart:isolate';

import 'model.dart';
import 'multipart_encoding.dart';
import 'request_form_values.dart';

class FormContentPart {
  const FormContentPart(this.name, this.text, this.contentType, this.transfer);
  final String name, text, contentType;
  final MultipartTransferEncoding? transfer;
}

class FormStyleValue {
  const FormStyleValue(this.name, this.value, this.rule);
  final String name;
  final Object? value;
  final Map<String, Object?> rule;
}

/// The engine owns field shapes and the applicable encoding rules. This value
/// retains exact instance JSON alongside the content that transport will send.
class PreparedFormValues {
  const PreparedFormValues(this.content, this.styled, this.instance);
  final List<FormContentPart> content;
  final List<FormStyleValue> styled;
  final String? instance;
}

Future<PreparedFormValues> prepareFormValues(
  List<(String, String)> fields,
  Map declaration,
  bool multipart,
  Future<Map<String, dynamic>> Function(Map<String, String>) parseJson, {
  RequestFormData? data,
  Map<String, String> mediaTypes = const {},
  Map<String, MultipartPartEncoding> transfers = const {},
}) async {
  final metadata = declaration['form'];
  if (metadata is! Map || metadata['shape'] is! Map) {
    throw CoreFailure(
      'request.form.protocol',
      'The captured operation has no native form interpretation.',
    );
  }
  final shape = metadata['shape'] as Map;
  final properties = shape['properties'];
  final encoding = declaration['encoding'];
  final groups = <String, List<String>>{};
  final fieldOrder = <String, List<int>>{};
  for (final (index, (name, text)) in fields.indexed) {
    (groups[name] ??= []).add(text);
    (fieldOrder[name] ??= []).add(index);
  }
  if (data != null)
    for (final entry in data.fields.entries) {
      groups[entry.key] = [
        for (final value
            in entry.value.kind == RequestDataKind.array
                ? entry.value.items
                : [entry.value])
          value.text,
      ];
    }
  final jsonInputs = <String, String>{};
  final definitions = <String, _FormValue>{};
  var complete = true;
  String? type(Map shape) {
    final type = shape['literalType'];
    return type is String ? type : null;
  }

  String contentType(Map item) {
    final media = item['defaultContentType'] ?? metadata['defaultContentType'];
    if (media is! String) {
      throw CoreFailure(
        'request.form.protocol',
        'Missing captured form content type.',
      );
    }
    return media;
  }

  for (final entry in groups.entries) {
    final supplied = data?.fields[entry.key];
    final suppliedValues = supplied == null
        ? null
        : supplied.kind == RequestDataKind.array
        ? supplied.items
        : [supplied];
    final property = properties is Map ? properties[entry.key] : null;
    final fieldShape = property is Map ? property : const <String, Object?>{};
    final rawRule = encoding is Map ? encoding[entry.key] : null;
    final rule = rawRule is Map
        ? Map<String, Object?>.from(rawRule)
        : const <String, Object?>{};
    if (rule['contentType'] != null && rule['contentType'] is! String ||
        rule['explode'] != null && rule['explode'] is! bool ||
        rule['allowReserved'] != null && rule['allowReserved'] is! bool) {
      throw CoreFailure(
        'request.form.encoding',
        'Form property ${entry.key} has an invalid encoding declaration.',
      );
    }
    final styled =
        (!multipart || metadata['multipartStyle'] == true) &&
        ['style', 'explode', 'allowReserved'].any(rule.containsKey);
    if (styled &&
        (metadata['styles'] is! List ||
            !(metadata['styles'] as List).contains(rule['style'] ?? 'form'))) {
      throw CoreFailure(
        'request.form.style',
        'The form style for ${entry.key} is invalid for this specification.',
      );
    }
    if (styled &&
        rule['style'] == 'deepObject' &&
        (rule['explode'] != true ||
            (supplied == null
                ? type(fieldShape) != 'object'
                : supplied.kind != RequestDataKind.object))) {
      throw CoreFailure(
        'request.form.style',
        'deepObject requires an object with explode enabled; other combinations are undefined.',
      );
    }
    final array = supplied == null
        ? type(fieldShape) == 'array'
        : supplied.kind == RequestDataKind.array;
    if (!array && type(fieldShape) != null && entry.value.length > 1) {
      throw CoreFailure(
        'request.form.scalar',
        'Form property ${entry.key} permits one scalar value.',
      );
    }
    final items = fieldShape['items'];
    final itemShape = array && items is Map ? items : fieldShape;
    final media = styled
        ? null
        : mediaTypes[entry.key] ??
              rule['contentType'] as String? ??
              contentType(itemShape);
    final jsonMedia =
        media?.split(';').first.trim().toLowerCase() == 'application/json' ||
        media?.split(';').first.trim().toLowerCase().endsWith('+json') == true;
    final values = <_FormScalar>[];
    for (var index = 0; index < entry.value.length; index++) {
      final text = entry.value[index], itemType = type(itemShape);
      final literalMedia = media?.split(';').first.trim().toLowerCase();
      final actual = suppliedValues?[index];
      final transfer = transfers[entry.key]?.forValue(
        actual == null
            ? itemType == null || itemType == 'string'
            : actual.kind == RequestDataKind.string,
      );
      final encodedInput = transfer?.schemaEncoded == true;
      if (actual != null) {
        if (!styled &&
            !jsonMedia &&
            ![
              'text/plain',
              'application/octet-stream',
            ].contains(literalMedia) &&
            [
              RequestDataKind.array,
              RequestDataKind.object,
            ].contains(actual.kind)) {
          throw CoreFailure(
            'request.form.media.unsupported',
            'This form media type has no structured data serializer. Use an explicitly serialized literal field.',
          );
        }
        values.add(
          _FormScalar(
            '${definitions.length}:$index',
            jsonMedia && !encodedInput ? actual.raw : actual.text,
            actual.raw,
            false,
            supplied: true,
            value: actual.value,
            transfer: transfer,
          ),
        );
        continue;
      }
      final undecoded =
          !styled &&
          !jsonMedia &&
          literalMedia != 'text/plain' &&
          [
            'object',
            'array',
            'number',
            'integer',
            'boolean',
            'null',
          ].contains(itemType);
      if (undecoded) complete = false;
      final parse =
          !undecoded &&
          !encodedInput &&
          (jsonMedia ||
              [
                'object',
                'array',
                'integer',
                'number',
                'boolean',
                'null',
              ].contains(itemType));
      final key = '${definitions.length}:$index';
      if (parse) jsonInputs[key] = text;
      values.add(
        _FormScalar(
          key,
          text,
          parse ? text : jsonEncode(text),
          parse,
          transfer: transfer,
        ),
      );
    }
    definitions[entry.key] = _FormValue(
      array ||
          supplied == null && type(fieldShape) == null && values.length > 1,
      styled,
      rule,
      media,
      values,
    );
  }
  final parsed = await parseJson(jsonInputs);
  final content = <FormContentPart>[], styled = <FormStyleValue>[];
  final contentOrder = <FormContentPart, int>{};
  final instance = <String>[];
  for (final entry in definitions.entries) {
    final definition = entry.value;
    final values = [
      for (final value in definition.values)
        value.supplied
            ? value.value
            : value.parse
            ? parsed[value.key]
            : value.text,
    ];
    // RFC6570 treats an empty collection as undefined. Named multipart arrays
    // likewise produce no parts. Check the emitted object's actual presence.
    if (values.isEmpty ||
        definition.styled &&
            !definition.array &&
            values.single is Map &&
            (values.single as Map).isEmpty)
      continue;
    final raw = definition.array
        ? '[${definition.values.map((value) => value.json).join(',')}]'
        : definition.values.single.json;
    instance.add('${jsonEncode(entry.key)}:$raw');
    if (definition.styled) {
      styled.add(
        FormStyleValue(
          entry.key,
          definition.array ? values : values.single,
          definition.rule,
        ),
      );
    } else {
      for (final (index, value) in definition.values.indexed) {
        final part = FormContentPart(
          entry.key,
          value.text,
          definition.mediaType!,
          value.transfer,
        );
        content.add(part);
        if (data == null) contentOrder[part] = fieldOrder[entry.key]![index];
      }
    }
  }
  // Grouping is needed for schema evaluation, but literal rows retain their
  // authored interleaving on the wire. Structured JSON has property/array order.
  if (data == null)
    content.sort((a, b) => contentOrder[a]!.compareTo(contentOrder[b]!));
  return PreparedFormValues(
    content,
    styled,
    complete ? '{${instance.join(',')}}' : null,
  );
}

class _FormScalar {
  const _FormScalar(
    this.key,
    this.text,
    this.json,
    this.parse, {
    this.supplied = false,
    this.value,
    this.transfer,
  });
  final String key, text, json;
  final bool parse, supplied;
  final Object? value;
  final MultipartTransferEncoding? transfer;
}

class _FormValue {
  const _FormValue(
    this.array,
    this.styled,
    this.rule,
    this.mediaType,
    this.values,
  );
  final bool array, styled;
  final Map<String, Object?> rule;
  final String? mediaType;
  final List<_FormScalar> values;
}

/// The engine selected an unencoded octet string (OAS 3.0 §4.4.2). Count its
/// exact JSON transport size before allocating escaped control characters.
Future<({String json, int byteLength})?> multipartOctetInstance(
  List<int> bytes,
  int budget,
) async {
  if (bytes.length >= 262144)
    return Isolate.run(() => _multipartOctetInstance(bytes, budget));
  return _multipartOctetInstance(bytes, budget);
}

({String json, int byteLength})? _multipartOctetInstance(
  List<int> bytes,
  int budget,
) {
  var size = 2;
  for (final byte in bytes) {
    size += byte == 34 || byte == 92 || const [8, 9, 10, 12, 13].contains(byte)
        ? 2
        : byte < 32
        ? 6
        : byte < 128
        ? 1
        : 2;
    if (size > budget) return null;
  }
  if (size > budget) return null;
  return (json: jsonEncode(latin1.decode(bytes)), byteLength: size);
}

/// Merge captured file string representations without round-tripping exact
/// numeric field values through Dart's JSON number representation.
String multipartInstanceWithFiles(
  RequestFormData fields,
  Map<String, List<String>> files,
  Map declaration, {
  Set<String> replacedFields = const {},
  Map<String, bool> fileShapes = const {},
}) {
  final shape = (declaration['form'] as Map)['shape'] as Map;
  final properties = shape['properties'];
  final values = <String, String>{
    for (final entry in fields.fields.entries) entry.key: entry.value.raw,
  };
  for (final entry in files.entries) {
    final existing = fields.fields[entry.key];
    final items = <String>[
      if (existing != null && !replacedFields.contains(entry.key))
        ...existing.kind == RequestDataKind.array
            ? existing.items.map((item) => item.raw)
            : [existing.raw],
      ...entry.value,
    ];
    final property = properties is Map ? properties[entry.key] : null;
    final type = property is Map ? property['literalType'] : null;
    final array =
        fileShapes[entry.key] ??
        (type == 'array' || type == null && items.length > 1);
    if (!array && items.length != 1) {
      throw CoreFailure(
        'request.form.scalar',
        'This form property permits one scalar value.',
      );
    }
    values[entry.key] = array ? '[${items.join(',')}]' : items.single;
  }
  return '{${values.entries.map((entry) => '${jsonEncode(entry.key)}:${entry.value}').join(',')}}';
}
