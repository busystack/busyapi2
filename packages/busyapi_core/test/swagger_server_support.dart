import 'dart:convert';

String swaggerServerSource(String format, String host) {
  const body = 'Native IPv6 雪';
  if (format == 'yaml') {
    return '''# Keep native Swagger server ownership\r
swagger: '2.0'\r
info: {title: 'Native Swagger IPv6 雪', version: 'API-1'}\r
host: "$host" # Keep host comment\r
basePath: /v1\r
schemes: [https]\r
produces: [text/plain]\r
paths:\r
  /items:\r
    get:\r
      schemes: [http]\r
      responses:\r
        '200':\r
          description: Exact native text\r
          schema: {type: string, enum: ["$body"]}\r
x-exact: 9007199254740993.00\r
x-held: &held [false, 0, null, '雪']\r
x-copy: *held\r
''';
  }
  return '${const JsonEncoder.withIndent('  ').convert({
    'swagger': '2.0',
    'info': {'title': 'Native Swagger IPv6 雪', 'version': 'API-1'},
    'host': host,
    'basePath': '/v1',
    'schemes': ['https'],
    'produces': ['text/plain'],
    'paths': {
      '/items': {
        'get': {
          'schemes': ['http'],
          'responses': {
            '200': {
              'description': 'Exact native text',
              'schema': {
                'type': 'string',
                'enum': [body],
              },
            },
          },
        },
      },
    },
    'x-exact': 'EXACT',
    'x-literal': {'host': 'user@invalid.example', 'basePath': '/{ignored}?q=1'},
  }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
}
