// Development-only capture of real installed renderer assets. Never shipped.
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3 ||
      !RegExp(
        r'^/tmp/busyapi-documentation-native-[^/]+/renderer-assets/(redoc|swagger)-production-(20|30)$',
      ).hasMatch(arguments[2])) {
    throw ArgumentError(
      'Use the native test launcher and its owned fixture destination',
    );
  }
  final directory = Directory(arguments[2]);
  if (await directory.exists())
    throw StateError('Occupied fixture destination');
  final engine = EngineProcess.bundled(applicationExecutable: arguments[0]);
  BusyProject? project;
  try {
    project = await BusyProject.open(arguments[1], engine);
    final root = project.roots.single.id, buffer = await project.buffer(root);
    final original = await File(buffer.path).readAsBytes();
    final page = await project.inspectObject(root, root, '');
    final range = List<int>.from(page['range'] as List);
    final swagger = arguments[2].endsWith('-20');
    final example = swagger
        ? '/paths/~1things/get/responses/200/examples/application~1json'
        : '/paths/~1things/get/responses/200/content/application~1json/example';
    final schemas = swagger ? '/definitions' : '/components/schemas';
    await project.proposeAndApply(
      root,
      PropertySession(
        root: root,
        buffer: root,
        generation: buffer.generation,
        pointer: '',
        range: range,
        expected: buffer.text.substring(range[0], range[1]),
      ),
      [
        {
          'kind': 'set',
          'pointer': '/info/description',
          'value': 'Unsaved native legacy capture sentinel',
        },
        {
          'kind': 'setData',
          'pointer': example,
          'raw': r'{"name":"fixture","$ref":"payload data","precise":9007199254740993.00}',
        },
        {
          'kind': 'createData',
          'pointer': '$schemas/Precise',
          'raw': r'{"type":"integer","minimum":9007199254740993,"example":9007199254740993.0}',
        },
      ],
    );
    final result = await project.check(root);
    if (result['status'] != 'complete')
      throw StateError('Invalid native fixture: $result');
    final captured = await project.captureDocumentationPresentation(root);
    final runtime = await DocumentationRuntime.forEngine(
      engine,
      preset: arguments[2].split('/').last.split('-').first,
    );
    final files = await runtime.page(
      captured.toJson(),
      labels: defaultDocumentationLabels,
      native: true,
    );
    final exampleOwner = await project.inspectObject(
      root,
      root,
      swagger
          ? '/paths/~1things/get/responses/200'
          : '/paths/~1things/get/responses/200/content/application~1json',
    );
    final exampleField = (exampleOwner['fields'] as List)
        .cast<Map>()
        .firstWhere(
          (field) => field['name'] == (swagger ? 'examples' : 'example'),
        );
    final exactExample = await project.readDataValue(
      Map<String, dynamic>.from(exampleField['target'] as Map),
    );
    final source = captured.sourceActions.firstWhere(
      (action) =>
          action.role == 'node' && action.pointer == '/paths/~1things/get',
    );
    await directory.create(recursive: true);
    for (final entry in files.entries) {
      await File('${directory.path}/${entry.key}')
          .writeAsBytes(entry.value, flush: true);
    }
    await File('${directory.path}/presentation.ini').writeAsString(
      '[presentation]\nsnapshot=${captured.snapshot.identity}\nsource_count=${captured.sourceActions.length}\nsource_index=${source.index}\n',
      flush: true,
    );
    await File('${directory.path}/expected.json').writeAsString(
      jsonEncode({
        'example': swagger
            ? '/paths/~1things/get/responses/200/examples'
            : example,
        'exampleValue': exactExample,
        'minimum': '$schemas/Precise/minimum',
        'schemaExample': '$schemas/Precise/example',
      }),
      flush: true,
    );
    if (contentIdentity(await File(buffer.path).readAsBytes()) !=
            contentIdentity(original) ||
        !buffer.dirty) {
      throw StateError(
        'Native capture lost unsaved ownership or changed source',
      );
    }
  } finally {
    project?.close();
    await engine.close();
  }
}
