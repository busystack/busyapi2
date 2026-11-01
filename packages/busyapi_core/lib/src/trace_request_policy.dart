import 'model.dart';

/// RFC 9110 §9.3.8 forbids TRACE content and sensitive request fields. HTTP
/// method tokens are case-sensitive (§9.1); a custom `trace` has no such rule.
final class TraceRequestPolicy {
  TraceRequestPolicy._(this.source);
  final CoreFailureSource source;

  static TraceRequestPolicy? capture(String method, Object? location) {
    if (method != 'TRACE') return null;
    if (location
        case {
          'resource': String resource,
          'pointer': String pointer,
          'range': [int start, int end],
        }
        when start >= 0 && end >= start) {
      return TraceRequestPolicy._(
        CoreFailureSource(resource, pointer, SourceRange(start, end)),
      );
    }
    throw CoreFailure(
      'request.protocol',
      'TRACE has no captured source location',
    );
  }

  void content(int bytes) {
    if (bytes != 0) {
      throw CoreFailure(
        'request.trace.content',
        'Remove request content before sending TRACE (RFC 9110 §9.3.8).',
        source: source,
      );
    }
  }

  void headers(Iterable<String> names, Iterable<String> sensitive) {
    final blocked = {
      'authorization',
      'proxy-authorization',
      'cookie',
      ...sensitive.map((name) => name.toLowerCase()),
    };
    if (names.any((name) => blocked.contains(name.toLowerCase())))
      credentials();
  }

  void securityScheme(Object? type) {
    if (const {'apiKey', 'http', 'oauth2', 'openIdConnect'}.contains(type)) {
      credentials();
    }
  }

  Never credentials() => throw CoreFailure(
    'request.trace.credentials',
    'TRACE cannot send authorization, cookies or configured credentials (RFC 9110 §9.3.8). Select an operation that permits those credentials.',
    source: source,
  );
}
