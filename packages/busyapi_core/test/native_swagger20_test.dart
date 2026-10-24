import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    test(
      'Swagger $format creation, native editing, history, save and documentation',
      () async {
        final temp = await Directory.systemTemp.createTemp('busyapi-native20-');
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final path = await Initializer.create(
          destination: '${temp.path}/api',
          title: '雪😀',
          apiVersion: 'api-version',
          openapi: '2.0',
          format: format,
        );
        final file = File(path), original = await file.readAsBytes();
        var project = await BusyProject.open(path, engine);
        addTearDown(() => project.close());
        final root = file.uri.toString();
        expect((await project.check(root))['status'], 'complete');
        expect(
          (await project.check(root))['projection']['specification']['family'],
          '2.0',
        );
        final buffer = await project.buffer(root);
        await project.save(buffer);
        expect(await file.readAsBytes(), original);
        final page = await project.inspectObject(root, root, '');
        final fields = (page['fields'] as List).cast<Map>();
        expect(fields.any((f) => f['name'] == 'swagger'), true);
        expect(fields.any((f) => f['name'] == 'host'), true);
        expect(
          fields.any(
            (f) => f['name'] == 'components' || f['name'] == 'servers',
          ),
          false,
        );
        await project.proposeAndApply(
          root,
          PropertySession(
            root: root,
            buffer: root,
            generation: buffer.generation,
            pointer: '',
            range: List<int>.from(page['range'] as List),
            expected: buffer.text.substring(
              (page['range'] as List)[0] as int,
              (page['range'] as List)[1] as int,
            ),
          ),
          [
            {'kind': 'set', 'pointer': '/host', 'value': 'api.invalid'},
          ],
        );
        final changed = buffer.text;
        expect(changed, contains('api.invalid'));
        expect(changed, contains('swagger'));
        expect(changed, isNot(contains('openapi:')));
        expect(await file.readAsBytes(), original);
        project.store.undo();
        expect(utf8.encode(buffer.text), original);
        project.store.redo();
        expect(buffer.text, changed);
        await project.save(buffer);
        expect(await file.readAsString(), changed);
        project.close();
        project = await BusyProject.open(path, engine);
        expect((await project.check(root))['status'], 'complete');
        final docs = await project.prepareDocumentation(
          root,
          '${temp.path}/docs',
        );
        addTearDown(docs.close);
        await docs.publish();
        expect(
          await File('${docs.destination}/index.html').readAsString(),
          contains('2.0'),
        );
      },
    );
  }
  test('Swagger contract cases send native URL, collection formats, headers and exact JSON bytes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-native20-wire-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <(String, String, String?, String?, String)>[];
    server.listen((request) async {
      final bytes = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.contentType?.mimeType,
        request.headers.value('X-Tags'),
        bytes,
      ));
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('X-Values', '1 2');
      request.response.write('{"id":9007199254740993,"name":"雪😀"}');
      await request.response.close();
    });
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final file = File('${temp.path}/api.yaml');
    await file.writeAsString('''
swagger: "2.0"
info: {title: Native wire, version: "1"}
host: 127.0.0.1:${server.port}
basePath: /v1
schemes: [http]
consumes: [application/json]
produces: [application/json]
paths:
  /pets/{id}:
    parameters: [{name: id, in: path, required: true, type: integer}]
    post:
      parameters:
        - {name: q, in: query, type: array, collectionFormat: multi, items: {type: string}}
        - {name: X-Tags, in: header, type: array, collectionFormat: pipes, items: {type: string}}
        - {name: body, in: body, required: true, schema: {\$ref: '#/definitions/Pet'}}
      responses:
        '200':
          description: Pet
          headers: {X-Values: {type: array, collectionFormat: ssv, items: {type: integer}}}
          schema: {\$ref: '#/definitions/Pet'}
definitions:
  Pet: {type: object, required: [id, name], properties: {id: {type: integer, minimum: 9007199254740993}, name: {type: string}}}
''');
    await File('${temp.path}/busyapi.yaml').writeAsString('''
version: 1
roots: [{name: api, path: api.yaml}]
tests:
  - name: native20
    operation: {method: post, path: '/pets/{id}'}
    parameters: {path: {id: 7}, query: {q: [a, b]}, header: {X-Tags: [a, b]}}
    body: {mediaType: application/json, value: {id: 9007199254740993, name: 雪😀}}
    expect: {status: 200, mediaType: application/json}
''');
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final report = await const ContractTestRunner().run(
      project,
      file.uri.toString(),
      selectedCases: const ['native20'],
      resolveSecret: (_) async => null,
    );
    expect(report.complete, true, reason: '${report.toJson()}');
    expect(report.passed, true, reason: '${report.toJson()}');
    expect(requests, [
      (
        'POST',
        '/v1/pets/7?q=a&q=b',
        'application/json',
        'a|b',
        '{"id":9007199254740993,"name":"雪😀"}',
      ),
    ]);
  });
  test(
    'Swagger packaged mock preserves response examples as exact data',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-native20-mock-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString('''
swagger: "2.0"
info: {title: Mock, version: "1"}
produces: [application/json]
paths:
  /pets:
    get:
      responses:
        '200': {description: Pet, examples: {application/json: {amount: 9007199254740993.00, \$ref: literal}}}
''');
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final mock = await project.prepareMock(file.uri.toString());
      final run = await mock.start(
        nodeExecutable: runtimeNode,
        helper: '$testBundle/libexec/busyapi/mock-server.cjs',
      );
      addTearDown(run.stop);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(run.baseUri.resolve('/pets')))
          .close();
      expect(response.statusCode, 200);
      expect(
        await utf8.decoder.bind(response).join(),
        '{"amount":9007199254740993.00,"\$ref":"literal"}',
      );
    },
  );
}
