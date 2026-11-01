// Development-only fixture producer for the real GTK/WebKit host. Not shipped.
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3 ||
      !RegExp(
        r'^/tmp/busyapi-documentation-native-[^/]+/renderer-assets/(redoc|swagger)-production-(31|32)$',
      ).hasMatch(arguments[2])) {
    throw ArgumentError(
      'Use the native test launcher and its dedicated temporary destination',
    );
  }
  final directory = Directory(arguments[2]);
  if (await directory.exists())
    throw StateError('The fixture destination is occupied');
  final engine = EngineProcess.bundled(applicationExecutable: arguments[0]);
  BusyProject? project;
  try {
    final modern = arguments[2].endsWith('-32');
    project = await BusyProject.open(arguments[1], engine);
    final root = project.roots.single.id,
        buffer = await project.buffer(root),
        original = await File(buffer.path).readAsBytes(),
        item = await project.inspectObject(root, root, ''),
        range = List<int>.from(item['range'] as List);
    // Two legal OAS schema-resource roots share one retrieval base but have
    // different dialects and no individual $id. Documentation must consume
    // their captured graph, not route through a lossy single-file bundle.
    final preset = arguments[2].split('/').last.split('-').first,
        dialects = File.fromUri(
          File(buffer.path).parent.uri.resolve('native-dialects-$preset.json'),
        ),
        dialectText =
            '{"openapi":"${modern ? '3.2.1' : '3.1.2'}",' +
            r'"info":{"title":"Native dialect resource","version":"1"},"paths":{},"components":{"schemas":{' +
            r'"A":{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","description":"Native 2020 dialect schema sentinel","properties":{"sibling":{"$ref":"#/components/schemas/B"}},"examples":[{"sibling":"okay"}]},' +
            r'"B":{"type":"string","description":"Native OAS dialect schema sentinel","minLength":2,"examples":["okay"]}}}}';
    if (await dialects.exists()) throw StateError('Occupied dialect fixture');
    await dialects.writeAsString(dialectText, flush: true);
    await project.proposeAndApply(
      root,
      PropertySession(
        root: root,
        buffer: buffer.id,
        generation: buffer.generation,
        pointer: '',
        range: range,
        expected: buffer.text.substring(range[0], range[1]),
      ),
      [
        {
          'kind': 'createData',
          'pointer': '/paths/~1things/get/callbacks',
          'raw':
              r'{"Inline":{"{$request.body#/callbackUrl}":{"post":{"summary":"Native callback POST sentinel","responses":{"204":{"description":"Bodyless callback sentinel"}}}' +
              (modern
                  ? r',"query":{"summary":"Native callback QUERY sentinel","responses":{"204":{"description":"Bodyless callback QUERY"}}},"additionalOperations":{"COPY":{"summary":"Native callback COPY sentinel","responses":{"200":{"description":"Callback content sentinel","content":{"application/json":{"schema":true,"examples":{"Captured":{"dataValue":{"$ref":"literal nested callback payload","number":900719925474099312345678901.00}}}}}}}}}'
                  : '') +
              '}}}',
        },
        {
          'kind': 'setData',
          'pointer': '/paths/~1things/get/responses/200/content/application~1json/example',
          'raw': r'{"name":"fixture","$ref":"payload data","precise":9007199254740993.00}',
        },
        {
          'kind': 'createData',
          'pointer': '/components/schemas/Precise',
          'raw': r'{"type":"integer","minimum":9007199254740993,"examples":[9007199254740993.0]}',
        },
        {
          'kind': 'createData',
          'pointer': '/paths/~1native-exact',
          'raw': r'{"post":{"summary":"Native exact content sentinel","requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Precise"},"example":9007199254740993.0},"text/plain":{"schema":{"type":"string"},"example":"serialized 雪😀"}}},"responses":{"204":{"description":"Bodyless native response"}}}}',
        },
        {
          'kind': 'createData',
          'pointer': '/components/pathItems',
          'raw':
              r'{"Alias":{"$ref":"#/components/pathItems/Shared"},"Shared":{' +
              (modern ? r'"additionalOperations":{"COPY":' : r'"get":') +
              r'{"operationId":"shared-native-context","summary":"Native shared Path Item sentinel","responses":{"204":{"description":"Native shared bodyless sentinel"}}}' +
              (modern ? '}' : '') +
              '}}',
        },
        {
          'kind': 'createData',
          'pointer': '/paths/~1native-shared',
          'raw': r'{"$ref":"#/components/pathItems/Alias","servers":[{"url":"https://one.invalid"}],"parameters":[{"in":"query","name":"owner","description":"Native one parameter owner","schema":{"type":"string"}}]}',
        },
        {
          'kind': 'createData',
          'pointer': '/paths/~1native-shared-two',
          'raw': r'{"$ref":"#/components/pathItems/Alias","servers":[{"url":"https://two.invalid"}],"parameters":[{"in":"query","name":"owner","description":"Native two parameter owner","schema":{"type":"string"}}]}',
        },
        for (final name in ['A', 'B'])
          {
            'kind': 'createData',
            'pointer': '/components/schemas/Mixed$name',
            'raw':
                '{"\$ref":"native-dialects-$preset.json#/components/schemas/$name"}',
          },
        {
          'kind': 'createData',
          'pointer': '/paths/~1native-mixed',
          'raw': r'{"get":{"summary":"Native mixed dialect operation sentinel","responses":{"200":{"description":"Native dialect response","content":{"application/json":{"schema":{"$ref":"#/components/schemas/MixedA"},"example":{"sibling":"okay","exact":9007199254740993.00}}}}}}}',
        },
      ],
    );
    final captured = await project.captureDocumentationPresentation(
          project.roots.single.id,
        ),
        runtime = await DocumentationRuntime.forEngine(
          engine,
          preset: arguments[2].split('/').last.split('-').first,
        ),
        files = await runtime.page(
          captured.toJson(),
          labels: defaultDocumentationLabels,
          native: true,
        ),
        source = captured.sourceActions.firstWhere(
          (action) =>
              action.role == 'node' && action.pointer == '/paths/~1things/get',
        );
    final callbackPointer =
        r'/paths/~1things/get/callbacks/Inline/{$request.body#~1callbackUrl}/' +
        (modern ? 'additionalOperations/COPY' : 'post');
    final callbackSource = captured.sourceActions.firstWhere(
      (action) => action.role == 'node' && action.pointer == callbackPointer,
    );
    final sharedContexts =
        (captured.originalProjection['sections'] as List).firstWhere(
              (section) =>
                  section['source']['resource'] == root &&
                  section['source']['pointer'] ==
                      '/components/pathItems/Shared/${modern ? 'additionalOperations/COPY' : 'get'}',
            )['contexts']
            as List;
    String contextRoute(String path) =>
        '/busyapi-operation/${sharedContexts.firstWhere((context) => context['path'] == path)['navigationId']}';
    await directory.create(recursive: true);
    for (final entry in files.entries) {
      await File('${directory.path}/${entry.key}')
          .writeAsBytes(entry.value, flush: true);
    }
    final media = await project.inspectObject(
      root,
      root,
      '/paths/~1things/get/responses/200/content/application~1json',
    );
    final field = (media['fields'] as List).cast<Map>().firstWhere(
      (value) => value['name'] == 'example',
    );
    final expected = await project.readDataValue(
      Map<String, dynamic>.from(field['target'] as Map),
    );
    await File('${directory.path}/example.txt')
        .writeAsString(expected, flush: true);
    if (modern) {
      final example = await project.inspectObject(
        root,
        root,
        '$callbackPointer/responses/200/content/application~1json/examples/Captured',
      );
      final field = (example['fields'] as List).cast<Map>().firstWhere(
        (value) => value['name'] == 'dataValue',
      );
      final exact = await project.readDataValue(
        Map<String, dynamic>.from(field['target'] as Map),
      );
      await File('${directory.path}/callback-example.txt')
          .writeAsString(exact, flush: true);
    }
    await File('${directory.path}/presentation.ini').writeAsString(
      '[presentation]\nsnapshot=${captured.snapshot.identity}\nsource_count=${captured.sourceActions.length}\nsource_index=${source.index}\ncallback_source_index=${callbackSource.index}\ncontext_route_one=${contextRoute('/native-shared')}\ncontext_route_two=${contextRoute('/native-shared-two')}\n',
      flush: true,
    );
    if (contentIdentity(await File(buffer.path).readAsBytes()) !=
            contentIdentity(original) ||
        await dialects.readAsString() != dialectText) {
      throw StateError('Fixture capture wrote canonical source');
    }
  } finally {
    project?.close();
    await engine.close();
  }
}
