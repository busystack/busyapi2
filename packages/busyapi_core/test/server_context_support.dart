import 'dart:convert';

const serverContextBody = 'Native server context 雪';
String serverContextSource(String version, String format, String server) {
  final swagger = version == '2.0';
  final response = {
    'description': 'Native text',
    if (swagger)
      'schema': {
        'type': 'string',
        'enum': [serverContextBody],
      },
    if (!swagger)
      'content': {
        'text/plain': {
          'schema': {
            'type': 'string',
            'enum': [serverContextBody],
          },
        },
      },
  };
  if (format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert({
      swagger ? 'swagger' : 'openapi': version,
      'info': {'title': 'Native server context 雪', 'version': 'API-1'},
      if (swagger) ...{
        'host': server,
        'basePath': '/v1',
        'schemes': ['http'],
        'produces': ['text/plain'],
      },
      if (!swagger) 'servers': [
          {'url': server},
        ],
      'paths': {
        '/items': {
          'get': {
            'responses': {'200': response},
          },
        },
      },
      'x-exact': 'EXACT',
      'x-data': {
        'servers': [
          {'url': 'literal %zz'},
        ],
      },
    }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
  }
  return '# Keep native server ownership\r\n'
      '${swagger ? 'swagger' : 'openapi'}: "$version"\r\n'
      'info: {title: "Native server context 雪", version: "API-1"}\r\n'
      '${swagger ? 'host: ${jsonEncode(server)}\r\nbasePath: /v1\r\nschemes: [http]\r\nproduces: [text/plain]' : 'servers:\r\n  - url: ${jsonEncode(server)}'} # Keep URL comment\r\n'
      'paths:\r\n  /items:\r\n    get:\r\n      responses:\r\n        "200": ${jsonEncode(response)}\r\n'
      'x-exact: 9007199254740993.00\r\n'
      'x-held: &held [false, 0, null, "雪"]\r\nx-copy: *held\r\n';
}
