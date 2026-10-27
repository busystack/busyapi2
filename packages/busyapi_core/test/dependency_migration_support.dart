import 'dart:convert';

import 'static_dynamicref_support.dart' as static_reference;

String dependencyMigrationApi(
  String version,
  String format, {
  int? port,
  bool sharedRole = false,
}) {
  final text = static_reference.staticDynamicRefApi(
    version,
    format,
    port: port,
  );
  return sharedRole
      ? text.replaceFirst(
          '"Flags":',
          '"Independent": {"\$ref":"./model.yaml#/\$defs/Actual/dependentRequired"},"Flags":',
        )
      : text;
}

String dependencyMigrationModel({bool requiredTrigger = false}) {
  final schema = {
    r'$anchor': 'model',
    'type': 'object',
    if (requiredTrigger)
      'allOf': [
        {
          'required': ['seed'],
        },
      ],
    'dependentRequired': {
      if (requiredTrigger) 'seed': ['name'],
      'name': ['n'],
    },
    'properties': {
      if (requiredTrigger) 'seed': <String, Object>{},
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
  return '# Preserve dependency model comments and aliases\r\n'
      '\$schema: https://json-schema.org/draft/2020-12/schema\r\n'
      '\$id: model.yaml\r\ndescription: Original model\r\n'
      '\$defs:\r\n  Actual: ${jsonEncode(schema).replaceAll('"EXACT"', '9007199254740993.00')}\r\n'
      'x-kept: &literal {exact: 9007199254740993.00, flag: false, nil: null}\r\n'
      'x-alias: *literal\r\n';
}
