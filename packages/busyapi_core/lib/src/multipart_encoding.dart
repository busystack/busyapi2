import 'model.dart';

enum MultipartInstanceEncoding { octets }

/// Serialization directives checked by the captured contract engine. Encoded
/// schema instances and raw selected files have different input representations.
class MultipartTransferEncoding {
  const MultipartTransferEncoding({
    required this.schemaEncoded,
    this.encoding,
    this.resource,
    this.pointer,
    this.range,
    this.instanceEncoding,
    this.instanceSource,
  });
  final String? encoding, resource, pointer;
  final SourceRange? range;
  final bool schemaEncoded;
  final MultipartInstanceEncoding? instanceEncoding;
  final CoreFailureSource? instanceSource;

  factory MultipartTransferEncoding.fromJson(Object? raw) {
    if (raw is! Map || raw['schemaEncoded'] is! bool) _invalid();
    final encoding = raw['encoding'], instance = raw['instanceEncoding'];
    final source = _multipartSource(raw['source']),
        instanceSource = _multipartSource(raw['instanceSource']);
    if (encoding != null && (encoding is! String || encoding.isEmpty))
      _invalid();
    if (instance != null && instance != 'octets' ||
        (instance != null) != (instanceSource != null) ||
        instance != null && raw['schemaEncoded'] == true)
      _invalid();
    if (raw['schemaEncoded'] == true && encoding == null) _invalid();
    return MultipartTransferEncoding(
      schemaEncoded: raw['schemaEncoded'] as bool,
      encoding: encoding as String?,
      resource: source?.resource,
      pointer: source?.pointer,
      range: source?.range,
      instanceEncoding: instance == 'octets'
          ? MultipartInstanceEncoding.octets
          : null,
      instanceSource: instanceSource,
    );
  }
}

CoreFailureSource? _multipartSource(Object? source) {
  if (source == null) return null;
  if (source
      case {
        'resource': String resource,
        'pointer': String pointer,
        'range': [int start, int end],
      }
      when start >= 0 && end >= start) {
    return CoreFailureSource(resource, pointer, SourceRange(start, end));
  }
  _invalid();
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
