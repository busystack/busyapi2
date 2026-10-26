import 'model.dart';

/// One explicit MIME field line attached to a logical multipart field.
/// Repeated body parts retain their order and receive the same supplied lines.
class RequestPartHeaderValue {
  const RequestPartHeaderValue(this.part, this.name, this.value);
  final String part, name, value;

  factory RequestPartHeaderValue.fromJson(Object? raw) {
    if (raw
        case {'part': String part, 'name': String name, 'value': String value}
        when part.length <= 1024 &&
            name.length <= 1024 &&
            value.length <= 8192) {
      return RequestPartHeaderValue(part, name, value);
    }
    throw CoreFailure(
      'request.multipart.headers',
      'Invalid bounded multipart header input.',
    );
  }

  Map<String, String> toJson() => {'part': part, 'name': name, 'value': value};
}

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

class MultipartHeaderLine {
  const MultipartHeaderLine(this.name, this.value, this.source);
  final String name, value;
  final CoreFailureSource? source;

  factory MultipartHeaderLine.fromJson(Object? raw) {
    if (raw is! Map || raw['name'] is! String || raw['value'] is! String)
      _invalid();
    final name = raw['name'] as String, value = raw['value'] as String;
    if (name.length > 1024 ||
        value.length > 8192 ||
        !RegExp(r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name) ||
        RegExp(r'[^\x20-\x7e]').hasMatch(value) ||
        const [
          'content-type',
          'content-disposition',
          'content-transfer-encoding',
        ].contains(name.toLowerCase()))
      _invalid();
    return MultipartHeaderLine(name, value, _multipartSource(raw['source']));
  }
}

class MultipartPartEncoding {
  const MultipartPartEncoding({
    this.strings,
    this.other,
    this.headers = const [],
  });
  final MultipartTransferEncoding? strings, other;
  final List<MultipartHeaderLine> headers;

  factory MultipartPartEncoding.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.isEmpty ||
        raw.keys.any(
          (key) => key != 'string' && key != 'other' && key != 'headers',
        ) ||
        raw.containsKey('headers') &&
            (raw['headers'] is! List || (raw['headers'] as List).length > 61))
      _invalid();
    return MultipartPartEncoding(
      headers: List.unmodifiable([
        for (final value in raw['headers'] as List? ?? const [])
          MultipartHeaderLine.fromJson(value),
      ]),
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
