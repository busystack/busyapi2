import 'dart:convert';

String schemaRoleSource(
  String version,
  String format,
  String keyword,
  int port,
) {
  final value = {
    'openapi': version,
    'info': {'title': 'Shared schema roles 雪', 'version': '1'},
    'servers': [
      {'url': 'http://127.0.0.1:$port'},
    ],
    'paths': {
      '/echo': {
        'post': {
          'requestBody': {
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Use'},
              },
            },
          },
          'responses': {
            '200': {
              'description': 'Exact echo',
              'content': {
                'application/json': {
                  'schema': {r'$ref': '#/components/schemas/Use'},
                },
              },
            },
          },
        },
      },
    },
    'components': {
      'schemas': {
        'Envelope': {
          keyword: {
            'properties': {
              'Leaf': {
                'type': 'integer',
                'enum': ['EXACT'],
              },
            },
          },
        },
        'Use': {r'$ref': '#/components/schemas/Envelope/$keyword'},
      },
    },
    'x-literal': {r'$ref': 'unchanged', 'number': 'EXACT'},
  };
  return '${format == 'yaml' ? '# retained overlapping schema roles\r\n' : ''}'
      '${const JsonEncoder.withIndent('  ').convert(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
}
