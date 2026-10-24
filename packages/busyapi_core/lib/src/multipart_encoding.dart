import 'model.dart';

/// Serialization directives checked by the captured contract engine. Encoded
/// schema instances and raw selected files have different input representations.
class MultipartTransferEncoding {
  const MultipartTransferEncoding({
    required this.schemaEncoded,
    this.encoding,
    this.resource,
    this.pointer,
    this.range,
  });
  final String? encoding, resource, pointer;
  final SourceRange? range;
  final bool schemaEncoded;

  factory MultipartTransferEncoding.fromJson(Object? raw) {
    if (raw is! Map || raw['schemaEncoded'] is! bool) _invalid();
    final encoding = raw['encoding'], source = raw['source'];
    if (encoding != null && (encoding is! String || encoding.isEmpty))
      _invalid();
    if (source != null &&
        (source is! Map ||
            source['resource'] is! String ||
            source['pointer'] is! String ||
            source['range'] is! List ||
            (source['range'] as List).length != 2 ||
            (source['range'] as List).any((value) => value is! int) ||
            (source['range'][0] as int) < 0 ||
            (source['range'][1] as int) < (source['range'][0] as int)))
      _invalid();
    if (raw['schemaEncoded'] == true && encoding == null) _invalid();
    return MultipartTransferEncoding(
      schemaEncoded: raw['schemaEncoded'] as bool,
      encoding: encoding as String?,
      resource: source?['resource'] as String?,
      pointer: source?['pointer'] as String?,
      range: source == null
          ? null
          : SourceRange(source['range'][0] as int, source['range'][1] as int),
    );
  }
}

class MultipartPartEncoding {
  const MultipartPartEncoding({this.strings, this.other});
  final MultipartTransferEncoding? strings, other;

  factory MultipartPartEncoding.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.isEmpty ||
        raw.keys.any((key) => key != 'string' && key != 'other'))
      _invalid();
    return MultipartPartEncoding(
      strings: raw.containsKey('string')
          ? MultipartTransferEncoding.fromJson(raw['string'])
          : null,
      other: raw.containsKey('other')
          ? MultipartTransferEncoding.fromJson(raw['other'])
          : null,
    );
  }

  MultipartTransferEncoding forValue(bool string) =>
      (string ? strings : other) ??
      (throw CoreFailure(
        'request.multipart.protocol',
        'The captured part kind changed during serialization.',
      ));
}

Never _invalid() => throw CoreFailure(
  'request.multipart.protocol',
  'Invalid captured multipart transfer directives.',
);
