import 'dart:convert';

String staticDynamicRefApi(String version, String format, {int? port}) {
  final schema = {r'$ref': '#/components/schemas/Subject'};
  final document = {
    'openapi': version,
    'info': {'title': 'Original API 雪', 'version': 'unrelated-api-version'},
    if (port != null)
      'servers': [
        {'url': 'http://127.0.0.1:$port/v1'},
      ],
    'paths': {
      if (port != null)
        '/echo': {
          'post': {
            'requestBody': {
              'required': true,
              'content': {
                'application/json': {'schema': schema},
              },
            },
            'responses': {
              '200': {
                'description': 'Exact echo',
                'content': {
                  'application/json': {'schema': schema},
                },
              },
            },
          },
        },
    },
    'components': {
      'schemas': {
        'Subject': {
          r'$dynamicRef': './model.yaml#model',
          r'$ref': '#/components/schemas/Flags',
        },
        'Flags': {
          'type': 'object',
          'required': ['flag'],
          'properties': {
            'flag': {'type': 'boolean', 'const': true},
          },
        },
      },
    },
    'x-kept': {
      r'$dynamicRef': 'literal space',
      'number': 'EXACT',
      'false': false,
      'zero': 0,
      'nil': null,
    },
  };
  return (format == 'json'
          ? jsonEncode(document)
          : '# Keep static reference migration source\r\n${document.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n')
      .replaceAll('"EXACT"', '9007199254740993.00');
}

String staticDynamicRefModel({String definitionKeyword = r'$defs'}) {
  final schema = {
    r'$anchor': 'model',
    'type': 'object',
    'required': ['n', 'name'],
    'properties': {
      'n': {
        'type': 'integer',
        'enum': ['EXACT'],
      },
      'name': {
        'type': 'string',
        'enum': ['雪'],
      },
    },
  };
  return '# Preserve shared model comments and aliases\r\n'
      '\$schema: https://json-schema.org/draft/2020-12/schema\r\n'
      '\$id: model.yaml\r\ndescription: Original model\r\n'
      '$definitionKeyword:\r\n  Actual: ${jsonEncode(schema).replaceAll('"EXACT"', '9007199254740993.00')}\r\n'
      'x-kept: &literal {exact: 9007199254740993.00, flag: false, nil: null}\r\n'
      'x-alias: *literal\r\n';
}
