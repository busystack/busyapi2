import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    test('$version form encodings send exact bytes and evaluate captured values', () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-form-wire-');
      addTearDown(() => temp.delete(recursive: true));
      final seen = <(String, String, String, String)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        seen.add((
          request.method,
          request.uri.toString(),
          request.headers.contentType.toString(),
          await utf8.decoder.bind(request).join(),
        ));
        request.response.statusCode = 204;
        await request.response.close();
      });
      final file = File('${temp.path}/api.yaml');
      final original =
          '''# Untouched native form source
openapi: $version
info: {title: Form wire, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}/v1'}]
paths:
  /form:
    post:
      requestBody:
        content:
          application/x-www-form-urlencoded:
            schema: {\$ref: '#/components/schemas/Form'}
            encoding:
              ids: {style: form, explode: false}
              options: {style: deepObject, explode: true}
              reserved: {style: form, allowReserved: true}
              jsonText: {contentType: application/json}
              nil: {contentType: application/json}
      responses: {'204': {description: ok}}
  /multipart:
    post:
      requestBody:
        content:
          multipart/form-data:
            schema:
              type: object
              required: [metadata, ids]
              properties:
                metadata: {\$ref: '#/components/schemas/Metadata'}
                ids: {type: array, items: {type: integer}}
            encoding:
              metadata: {style: form, explode: false, contentType: application/json}
              ids: {style: form, explode: false, contentType: application/json}
      responses: {'204': {description: ok}}
  /custom:
    post:
      requestBody:
        content:
          multipart/form-data:
            schema: {type: object, properties: {metadata: {type: object}}}
            encoding: {metadata: {contentType: application/xml}}
      responses: {'204': {description: ok}}
components:
  schemas:
    Form:
      allOf:
        - type: object
          required: [note, count, zero, enabled, ids, options, jsonText, empty, reserved, nil]
          properties:
            note: {type: string}
            count: {type: integer, minimum: 9007199254740993}
            zero: {type: integer, maximum: 0}
            enabled: {type: boolean}
            empty: {type: string, maxLength: 0}
            ids: {type: array, items: {type: integer}}
            options:
              type: object
              properties:
                zero: {type: integer}
                no: {type: boolean}
                empty: {type: string}
                unicode: {type: string}
            jsonText: {type: string}
            reserved: {type: string}
            nil: ${version == '3.0.4' ? '{type: string, nullable: true, enum: [null]}' : "{type: 'null'}"}
    Metadata:
      type: object
      required: [id, name]
      properties:
        id: {type: integer, minimum: 9007199254740993}
        name: {type: string}
''';
      await file.writeAsString(original);
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      Future<OperationRequestPlan> planFor(String path) async {
        final result = await project.check(file.uri.toString());
        expect(result['complete'], isTrue, reason: '$result');
        final operation = (result['projection']['operations'] as List)
            .whereType<Map>()
            .singleWhere((operation) => operation['path'] == path);
        return project.prepareRequest(
          file.uri.toString(),
          resource: operation['resource'] as String,
          pointer: operation['pointer'] as String,
          occurrence: operation['occurrence'] as String,
        );
      }

      final plan = await planFor('/form');
      addTearDown(plan.close);
      const fields = [
        RequestFormField('note', '雪 + &'),
        RequestFormField('count', '9007199254740993'),
        RequestFormField('zero', '0'),
        RequestFormField('enabled', 'false'),
        RequestFormField('empty', ''),
        RequestFormField('ids', '9007199254740993'),
        RequestFormField('ids', '0'),
        RequestFormField(
          'options',
          '{"zero":0,"no":false,"empty":"","unicode":"雪"}',
        ),
        RequestFormField('reserved', 'a+b&x=y#[]/%2B%zz'),
        RequestFormField('jsonText', '"a+b &雪"'),
        RequestFormField('nil', 'null'),
      ];
      Future<ContractRequestResult> send(List<RequestFormField> fields) =>
          const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.form(fields),
            ),
            resolveSecret: (_) async => null,
          );
      final result = await send(fields);
      expect(
        result.outgoing.complete,
        isTrue,
        reason: '${result.outgoing.findings}',
      );
      expect(
        result.outgoing.valid,
        isTrue,
        reason: '${result.outgoing.findings}',
      );
      expect(result.received.complete, isTrue);
      expect(result.received.valid, isTrue);
      expect(seen.single, (
        'POST',
        '/v1/form',
        'application/x-www-form-urlencoded',
        'note=%E9%9B%AA+%2B+%26&count=9007199254740993&zero=0&enabled=false&empty=&jsonText=%22a%2Bb+%26%E9%9B%AA%22&nil=null'
            '&ids=9007199254740993,0&options%5Bzero%5D=0&options%5Bno%5D=false&options%5Bempty%5D=&options%5Bunicode%5D=%E9%9B%AA'
            '&reserved=a%2Bb%26x%3Dy%23%5B%5D/%2B%25zz',
      ));
      await result.close();
      final invalid = await send(
        fields.where((field) => field.name != 'note').toList(),
      );
      expect(invalid.outgoing.complete, isTrue);
      expect(invalid.outgoing.valid, isFalse);
      expect(invalid.outgoing.findings, isNotEmpty);
      await invalid.close();

      final multipart = await planFor('/multipart');
      addTearDown(multipart.close);
      final uploaded = await const ContractRequestExecutor().execute(
        multipart,
        OperationRequestDraft(
          planIdentity: multipart.identity,
          body: const RequestBodyDraft.multipart([
            RequestFormField('metadata', '{"id":9007199254740993,"name":"雪"}'),
            RequestFormField('ids', '1'),
            RequestFormField('ids', '2'),
          ], []),
        ),
        resolveSecret: (_) async => null,
      );
      expect(
        uploaded.outgoing.complete,
        isTrue,
        reason: '${uploaded.outgoing.findings}',
      );
      expect(
        uploaded.outgoing.valid,
        isTrue,
        reason: '${uploaded.outgoing.findings}',
      );
      final wire = seen.last;
      expect(wire.$1, 'POST');
      expect(wire.$2, '/v1/multipart');
      final boundary = ContentType.parse(wire.$3).parameters['boundary']!;
      final prefix = '--$boundary\r\nContent-Disposition: form-data; name=';
      if (version == '3.0.4') {
        expect(
          wire.$4,
          '${prefix}"metadata"\r\nContent-Type: application/json\r\n\r\n{"id":9007199254740993,"name":"雪"}\r\n'
          '${prefix}"ids"\r\nContent-Type: application/json\r\n\r\n1\r\n'
          '${prefix}"ids"\r\nContent-Type: application/json\r\n\r\n2\r\n--$boundary--\r\n',
        );
      } else {
        expect(
          wire.$4,
          '${prefix}"metadata"\r\nContent-Type: text/plain\r\n\r\nid,9007199254740993,name,雪\r\n'
          '${prefix}"ids"\r\nContent-Type: text/plain\r\n\r\n1,2\r\n--$boundary--\r\n',
        );
      }
      await uploaded.close();
      final custom = await planFor('/custom');
      addTearDown(custom.close);
      final literal = await const ContractRequestExecutor().execute(
        custom,
        OperationRequestDraft(
          planIdentity: custom.identity,
          body: const RequestBodyDraft.multipart([
            RequestFormField('metadata', '<item id="7">雪</item>'),
          ], []),
        ),
        resolveSecret: (_) async => null,
      );
      expect(literal.outgoing.complete, isFalse);
      expect(
        literal.outgoing.findings.any(
          (finding) => finding['code'] == 'runtime.request.body.unchecked',
        ),
        isTrue,
      );
      expect(
        seen.last.$4,
        contains(
          'Content-Type: application/xml\r\n\r\n<item id="7">雪</item>\r\n',
        ),
      );
      await literal.close();
      expect(await file.readAsString(), original);
    });
  }

  test('Swagger formData collection formats and file bytes reach the server unchanged', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-swagger-form-');
    addTearDown(() => temp.delete(recursive: true));
    final seen = <(String, String, String, List<int>)>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      seen.add((
        request.method,
        request.uri.toString(),
        request.headers.contentType.toString(),
        await request.fold(<int>[], (bytes, chunk) => bytes..addAll(chunk)),
      ));
      request.response.statusCode = 204;
      await request.response.close();
    });
    final file = File('${temp.path}/api.yaml');
    final original =
        '''swagger: '2.0'
info: {title: Native forms, version: '1'}
host: 127.0.0.1:${server.port}
schemes: [http]
basePath: /v2
paths:
  /form:
    post:
      consumes: [application/x-www-form-urlencoded]
      parameters:
        - {in: formData, name: csv, type: array, items: {type: string}}
        - {in: formData, name: multi, type: array, collectionFormat: multi, items: {type: integer}}
        - {in: formData, name: zero, type: integer}
        - {in: formData, name: no, type: boolean}
        - {in: formData, name: empty, type: string, allowEmptyValue: true}
      responses: {'204': {description: ok}}
  /upload:
    post:
      consumes: [multipart/form-data]
      parameters:
        - {in: formData, name: note, type: string, required: true}
        - {in: formData, name: file, type: file, required: true}
      responses: {'204': {description: ok}}
''';
    await file.writeAsString(original);
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final analysis = await project.check(file.uri.toString());
    expect(analysis['complete'], isTrue, reason: '$analysis');
    Future<OperationRequestPlan> planFor(String path) {
      final operation = (analysis['projection']['operations'] as List)
          .whereType<Map>()
          .singleWhere((operation) => operation['path'] == path);
      return project.prepareRequest(
        file.uri.toString(),
        resource: operation['resource'] as String,
        pointer: operation['pointer'] as String,
        occurrence: operation['occurrence'] as String,
      );
    }

    final plan = await planFor('/form');
    addTearDown(plan.close);
    final result = await const ContractRequestExecutor().execute(
      plan,
      OperationRequestDraft(
        planIdentity: plan.identity,
        body: const RequestBodyDraft.form([
          RequestFormField('csv', 'a&b'),
          RequestFormField('csv', '雪'),
          RequestFormField('multi', '9007199254740993'),
          RequestFormField('multi', '0'),
          RequestFormField('zero', '0'),
          RequestFormField('no', 'false'),
          RequestFormField('empty', ''),
        ]),
      ),
      resolveSecret: (_) async => null,
    );
    expect(
      result.outgoing.complete,
      isTrue,
      reason: '${result.outgoing.findings}',
    );
    expect(
      result.outgoing.valid,
      isTrue,
      reason: '${result.outgoing.findings}',
    );
    expect(
      (seen.single.$1, seen.single.$2, seen.single.$3),
      ('POST', '/v2/form', 'application/x-www-form-urlencoded'),
    );
    expect(
      seen.single.$4,
      utf8.encode(
        'csv=a%26b%2C%E9%9B%AA&multi=9007199254740993&multi=0&zero=0&no=false&empty=',
      ),
    );
    await result.close();
    final binary = File('${temp.path}/payload.bin');
    const bytes = [0, 255, 128, 13, 10, 1, 42];
    await binary.writeAsBytes(bytes);
    final upload = await planFor('/upload');
    addTearDown(upload.close);
    final prepared = await const ContractRequestBuilder().build(
      upload,
      OperationRequestDraft(
        planIdentity: upload.identity,
        body: RequestBodyDraft.multipart(
          const [RequestFormField('note', '雪+&')],
          [MultipartFileValue(name: 'file', path: binary.path)],
        ),
      ),
      resolveSecret: (_) async => null,
    );
    await binary.writeAsBytes([1, 2]);
    final response = await const ContractHttpTransport().send(prepared);
    await response.close();
    await prepared.body!.close();
    final wire = seen.last,
        boundary = ContentType.parse(seen.last.$3).parameters['boundary']!;
    expect(wire.$1, 'POST');
    expect(wire.$2, '/v2/upload');
    expect(wire.$4, [
      ...utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="note"\r\n\r\n雪+&\r\n--$boundary\r\nContent-Disposition: form-data; name="file"; filename="payload.bin"\r\nContent-Type: application/octet-stream\r\n\r\n',
      ),
      ...bytes,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ]);
    expect(await file.readAsString(), original);
    final buffer = await project.buffer(file.uri.toString());
    project.store.replace(
      buffer.id,
      original.replaceFirst('allowEmptyValue: true', 'allowEmptyValue: false'),
    );
    final invalidPlan = await project.prepareRequest(
      buffer.id,
      resource: buffer.id,
      pointer: '/paths/~1form/post',
    );
    addTearDown(invalidPlan.close);
    final invalid = await const ContractRequestExecutor().execute(
      invalidPlan,
      OperationRequestDraft(
        planIdentity: invalidPlan.identity,
        body: const RequestBodyDraft.form([
          RequestFormField('csv', 'a&b'),
          RequestFormField('csv', '雪'),
          RequestFormField('multi', '9007199254740993'),
          RequestFormField('multi', '0'),
          RequestFormField('zero', '0'),
          RequestFormField('no', 'false'),
          RequestFormField('empty', ''),
        ]),
      ),
      resolveSecret: (_) async => null,
    );
    try {
      expect(invalid.outgoing.complete, isTrue);
      expect(invalid.outgoing.valid, isFalse);
      expect(
        invalid.outgoing.findings.any(
          (finding) => finding['code'] == 'runtime.request.form.empty',
        ),
        isTrue,
      );
      expect(seen.last.$4, seen.first.$4);
      expect(await file.readAsString(), original);
    } finally {
      await invalid.close();
    }
  });
}
