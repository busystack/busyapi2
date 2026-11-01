import 'dart:convert';

String serverVariableDefaultsSource(
  String version,
  String format,
  int port,
  String fallback,
  List<String> options, {
  String? serverUrl,
}) {
  final url = serverUrl ?? 'http://[::1]:$port/v{suffix}';
  if (format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert({
      'openapi': version,
      'info': {'title': 'Server defaults 雪', 'version': 'API-1'},
      'servers': [
        {
          'url': url,
          'variables': {
            'suffix': {'default': fallback, 'enum': options},
          },
        },
      ],
      'paths': {
        '/items': {
          'get': {
            'responses': {
              '204': {'description': 'No body'},
            },
          },
        },
      },
      'x-exact': 'EXACT',
    }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
  }
  return '# Keep native default ownership\r\n'
      'openapi: "$version"\r\ninfo: {title: "Server defaults 雪", version: "API-1"}\r\n'
      'servers:\r\n  - url: "$url"\r\n    variables:\r\n      suffix:\r\n'
      '        default: ${jsonEncode(fallback)} # Keep default comment\r\n'
      '        enum: ${jsonEncode(options)}\r\n'
      'paths: {/items: {get: {responses: {"204": {description: "No body"}}}}}\r\n'
      'x-exact: 9007199254740993.00\r\n';
}
