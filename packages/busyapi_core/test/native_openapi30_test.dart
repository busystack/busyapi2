import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test(
    '3.0 packaged mock keeps exact example bytes and stops on cancellation',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-native30-mock-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString(r'''
openapi: 3.0.4
info: {title: Native mock, version: "1"}
paths:
  /pets/{id}:
    get:
      parameters: [{name: id, in: path, required: true, schema: {type: integer}}]
      responses:
        '200':
          description: Exact example
          content:
            application/json:
              example: {$ref: literal payload, amount: 9007199254740993.00}
''');
      final source = await file.readAsBytes();
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final plan = await project.prepareMock(file.uri.toString());
      final run = await plan.start(
        nodeExecutable: runtimeNode,
        helper: '$testBundle/libexec/busyapi/mock-server.cjs',
      );
      addTearDown(run.stop);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        run.baseUri.resolve('/pets/1'),
      )).close();
      expect(response.statusCode, 200);
      expect(
        await utf8.decoder.bind(response).join(),
        r'{"$ref":"literal payload","amount":9007199254740993.00}',
      );
      expect(run.upstreamForwarding, false);
      await run.stop();
      await expectLater(
        client
            .getUrl(run.baseUri.resolve('/pets/1'))
            .then((request) => request.close()),
        throwsA(anything),
      );
      expect(await file.readAsBytes(), source);
    },
  );
  test(
    '3.0 contract cases send exact method, URL, headers and JSON body bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-native30-wire-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <(String, String, String?, String)>[];
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add((
          request.method,
          request.uri.toString(),
          request.headers.contentType?.mimeType,
          body,
        ));
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Result', 'checked');
        request.response.write(
          '{"id":7,"name":"雪😀","amount":9007199254740993}',
        );
        await request.response.close();
      });
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString('''
openapi: 3.0.4
info: {title: Native wire, version: "1"}
servers: [{url: http://127.0.0.1:${server.port}/v1}]
paths:
  /pets/{id}:
    post:
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
        - {name: tags, in: query, style: form, explode: false, schema: {type: array, items: {type: string}}}
      requestBody: {required: true, content: {application/json: {schema: {\$ref: '#/components/schemas/Pet'}}}}
      responses:
        '200':
          description: Pet
          headers: {X-Result: {required: true, schema: {type: string}}}
          content: {application/json: {schema: {\$ref: '#/components/schemas/Pet'}}}
components:
  schemas:
    Pet:
      type: object
      required: [id, name, secret, amount]
      properties:
        id: {type: integer, readOnly: true}
        name: {type: string}
        secret: {type: string, writeOnly: true}
        amount: {type: integer, minimum: 9007199254740993}
''');
      await File('${temp.path}/busyapi.yaml').writeAsString('''
version: 1
roots: [{name: api, path: api.yaml}]
tests:
  - name: native30
    operation: {method: post, path: '/pets/{id}'}
    parameters: {path: {id: 7}, query: {tags: [a, b]}}
    body: {mediaType: application/json, value: {name: 雪😀, amount: 9007199254740993, secret: synthetic}}
    expect: {status: 200, mediaType: application/json, headers: {X-Result: checked}}
''');
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      final report = await const ContractTestRunner().run(
        project,
        file.uri.toString(),
        selectedCases: const ['native30'],
        resolveSecret: (_) async => null,
      );
      expect(report.complete, true, reason: '${report.toJson()}');
      expect(report.passed, true, reason: '${report.toJson()}');
      expect(requests, [
        (
          'POST',
          '/v1/pets/7?tags=a,b',
          'application/json',
          '{"name":"雪😀","amount":9007199254740993,"secret":"synthetic"}',
        ),
      ]);
    },
  );
  for (final format in ['yaml', 'json']) {
    test('native 3.0 $format authoring, Source, history, save and documentation', () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-native30-');
      addTearDown(() => temp.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final path = await Initializer.create(
        destination: '${temp.path}/api',
        title: 'Native 雪😀',
        apiVersion: 'business-version',
        openapi: '3.0.0',
        format: format,
      );
      final file = File(path);
      final source = format == 'json'
          ? '{"openapi":"3.0.4","info":{"title":"Native 雪😀","version":"business-version"},"paths":{"/pets":{"get":{"summary":"Before","responses":{"204":{"description":"Empty"}}}}},"components":{"schemas":{"Pet":{"type":"string","nullable":true}}},"x-number":9007199254740993.00}'
          : '# Keep this\r\nopenapi: 3.0.4\r\ninfo: {title: "Native 雪😀", version: business-version}\r\npaths:\r\n  /pets:\r\n    get:\r\n      summary: Before # keep\r\n      responses: {204: {description: Empty}}\r\ncomponents:\r\n  schemas:\r\n    Pet: {type: string, nullable: true}\r\nx-number: 9007199254740993.00';
      final bytes = [239, 187, 191, ...utf8.encode(source)];
      await file.writeAsBytes(bytes);
      var project = await BusyProject.open(path, engine);
      addTearDown(() => project.close());
      final root = file.uri.toString();
      final checked = await project.check(root);
      expect(checked['status'], 'complete', reason: '${checked['findings']}');
      expect(checked['projection']['specification']['family'], '3.0');
      final buffer = await project.buffer(root);
      await project.save(buffer);
      expect(await file.readAsBytes(), bytes);
      final page = await project.inspectObject(
        root,
        root,
        '/components/schemas/Pet',
      );
      expect(page['family'], '3.0');
      final fields = (page['fields'] as List).cast<Map>();
      expect(
        fields.singleWhere((f) => f['name'] == 'nullable')['type'],
        'boolean',
      );
      expect(fields.any((f) => f['name'] == r'$id'), false);
      final caret = buffer.text.indexOf('nullable') + 2;
      final help = await project.assistSource(
        root,
        root,
        SourceSelection(caret, caret),
        action: 'help',
      );
      expect(
        help.result['help']['standard'],
        contains('/v3.0.4.html#schema-object'),
      );
      final operation = await project.inspectObject(
        root,
        root,
        '/paths/~1pets/get',
      );
      final range = List<int>.from(operation['range'] as List);
      await project.proposeAndApply(
        root,
        PropertySession(
          root: root,
          buffer: root,
          generation: buffer.generation,
          pointer: '/paths/~1pets/get',
          range: range,
          expected: buffer.text.substring(range[0], range[1]),
        ),
        [
          {
            'kind': 'set',
            'pointer': '/paths/~1pets/get/summary',
            'value': 'After 雪😀',
          },
        ],
      );
      final changed = source.replaceFirst('Before', 'After 雪😀');
      expect(buffer.text, changed);
      expect(await file.readAsBytes(), bytes);
      project.store.undo();
      expect(buffer.text, source);
      project.store.redo();
      expect(buffer.text, changed);
      final reference = await project.referencePage(
        root,
        root,
        '/paths/~1pets/get',
      );
      expect(reference['family'], '3.0');
      final docs = await project.prepareDocumentation(
        root,
        '${temp.path}/docs',
      );
      addTearDown(docs.close);
      expect(docs.unsaved, true);
      await docs.publish();
      final html = await File('${docs.destination}/index.html').readAsString();
      expect(html, contains('After 雪😀'));
      expect(html, contains('9007199254740993.00'));
      expect(await file.readAsBytes(), bytes);
      await project.save(buffer);
      expect(await file.readAsBytes(), [
        239,
        187,
        191,
        ...utf8.encode(changed),
      ]);
      project.close();
      project = await BusyProject.open(path, engine);
      expect((await project.buffer(root)).text, changed);
      expect((await project.check(root))['status'], 'complete');
    });
  }
  test('Source declaration changes invalidate old semantics and never migrate', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-version-switch-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final file = File('${temp.path}/api.json');
    final source =
        '{"openapi":"3.1.0","info":{"title":"Switch","version":"1"},"paths":{},"components":{"schemas":{"Pet":{"type":["string","null"]}}}}';
    await file.writeAsString(source);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final root = file.uri.toString(),
        buffer = await project.buffer(file.uri.toString());
    expect((await project.check(root))['status'], 'complete');
    project.store.replace(root, source.replaceFirst('3.1.0', '3.0.4'));
    final old = await project.check(root);
    expect(old['status'], 'invalid');
    expect(buffer.text, source.replaceFirst('3.1.0', '3.0.4'));
    expect(await file.readAsString(), source);
    project.store.replace(root, source.replaceFirst('3.1.0', '3.2.1'));
    expect((await project.check(root))['status'], 'complete');
    project.store.replace(root, source.replaceFirst('"3.1.0"', '3.0'));
    final malformed = await project.check(root);
    expect(malformed['complete'], false);
    expect(
      (malformed['findings'] as List).any(
        (f) => f['code'] == 'version.malformed',
      ),
      true,
    );
  });
}
