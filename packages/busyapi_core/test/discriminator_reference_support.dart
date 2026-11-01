import 'dart:convert';

String discriminatorApi(
  String version,
  String format,
  String kind, {
  int? port,
  String property = 'kind',
  bool schemaExamples = false,
}) {
  final anchor = kind == 'static-anchor' ? r'$anchor' : r'$dynamicAnchor';
  final schema = {r'$ref': '#/components/schemas/Subject'};
  final example = {'kind': 'Base', 'n': 'EXACT', 'flag': false, 'nil': null};
  final document = <String, Object?>{
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
        'Base': {
          if (kind != 'pointer') anchor: 'base',
          r'$ref': r'./model.yaml#/$defs/Actual',
        },
        'Subject': {
          'allOf': [
            {
              r'$dynamicRef': kind == 'pointer'
                  ? '#/components/schemas/Base'
                  : '#base',
            },
          ],
          'discriminator': {'propertyName': property},
          if (schemaExamples) 'examples': [example] else 'example': example,
        },
      },
    },
    'x-kept': {
      'number': 'EXACT',
      r'$dynamicRef': 'literal space',
      'false': false,
      'zero': 0,
    },
  };
  final text = format == 'json'
      ? jsonEncode(document)
      : '# Keep native discriminator source\r\n${document.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n';
  return text.replaceAll('"EXACT"', '9007199254740993.00');
}

String discriminatorModel() {
  final model = {
    'type': 'object',
    'required': ['kind'],
    'properties': {
      'kind': {'type': 'string'},
      'n': {
        'type': 'integer',
        'enum': ['EXACT'],
      },
      'flag': {'type': 'boolean'},
      'nil': {'type': 'null'},
    },
  };
  return '# Preserve model comments, aliases and exact numbers 雪\r\n'
      '\$schema: https://json-schema.org/draft/2020-12/schema\r\n'
      '\$id: model.yaml\r\ndescription: Original model\r\n'
      '\$defs:\r\n  Actual: &model ${jsonEncode(model).replaceAll('"EXACT"', '9007199254740993.00')}\r\n'
      'x-copy: *model\r\n';
}
