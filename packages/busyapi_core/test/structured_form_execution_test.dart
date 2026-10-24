import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _large = '900719925474099312345678901234567890';

String _source(String version, int port, String format) {
  final swagger = version == '2.0';
  final properties = <String, Object?>{
    'big': {'type': 'integer', 'minimum': 111},
    'zero': {'type': 'integer'},
    'flag': {'type': 'boolean'},
    'tag': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'optional': {
      'type': 'array',
      'items': {'type': 'integer'},
    },
    'empty': {'type': 'string', 'maxLength': 0},
    'literal': {'type': 'string'},
    if (!swagger)
      'nil': version.startsWith('3.0.')
          ? {'type': 'string', 'nullable': true}
          : {'type': 'null'},
    if (!swagger) 'payload': {'type': 'object'},
  };
  final doc = <String, Object?>{
    swagger ? 'swagger' : 'openapi': version,
    'info': {'title': 'Structured forms', 'version': 'api-version'},
    if (swagger) ...{
      'host': '127.0.0.1:$port',
      'schemes': ['http'],
      'basePath': '/api',
      'consumes': ['application/x-www-form-urlencoded'],
    } else
      'servers': [
        {'url': 'http://127.0.0.1:$port/api'},
      ],
    'paths': {
      '/form': {
        'post': {
          if (swagger)
            'parameters': [
              for (final property in properties.entries)
                {
                  'name': property.key,
                  'in': 'formData',
                  if (property.key != 'optional') 'required': true,
                  ...property.value as Map<String, Object?>,
                  if (['tag', 'optional'].contains(property.key))
                    'collectionFormat': 'multi',
                },
            ]
          else
            'requestBody': {
              'content': {
                'application/x-www-form-urlencoded': {
                  'schema': {
                    'type': 'object',
                    'required': [
                      'big',
                      'zero',
                      'flag',
                      'tag',
                      'empty',
                      'literal',
                      'nil',
                      'payload',
                    ],
                    'properties': properties,
                  },
                  'encoding': {
                    'tag': {'style': 'form', 'explode': true},
                    'nil': {'contentType': 'application/json'},
                  },
                },
              },
            },
          'responses': {
            '204': {'description': 'ok'},
          },
        },
      },
    },
  };
  if (format == 'json')
    return jsonEncode(doc).replaceAll('"minimum":111', '"minimum":$_large');
  final header = swagger
      ? "swagger: '2.0'\ninfo: {title: Structured forms, version: api-version}\nhost: 127.0.0.1:$port\nschemes: [http]\nbasePath: /api\nconsumes: [application/x-www-form-urlencoded]\n"
      : "openapi: $version\ninfo: {title: Structured forms, version: api-version}\nservers: [{url: 'http://127.0.0.1:$port/api'}]\n";
  return '''# Retain native YAML and exact source
${header}paths:
  /form:
    post:
${swagger ? '''      parameters:
        - {name: big, in: formData, type: integer, minimum: $_large, required: true}
        - {name: zero, in: formData, type: integer, required: true}
        - {name: flag, in: formData, type: boolean, required: true}
        - {name: tag, in: formData, type: array, items: {type: string}, collectionFormat: multi, required: true}
        - {name: optional, in: formData, type: array, items: {type: integer}, collectionFormat: multi}
        - {name: empty, in: formData, type: string, maxLength: 0, required: true}
        - {name: literal, in: formData, type: string, required: true}
''' : '''      requestBody:
        content:
          application/x-www-form-urlencoded:
            schema:
              type: object
              required: [big, zero, flag, tag, empty, literal, nil, payload]
              properties:
                big: {type: integer, minimum: $_large}
                zero: {type: integer}
                flag: {type: boolean}
                tag: {type: array, items: {type: string}}
                optional: {type: array, items: {type: integer}}
                empty: {type: string, maxLength: 0}
                literal: {type: string}
                nil: ${version.startsWith('3.0.') ? '{type: string, nullable: true}' : "{type: 'null'}"}
                payload: {type: object}
            encoding: {tag: {style: form, explode: true}, nil: {contentType: application/json}}
'''}      responses: {'204': {description: ok}}
''';
}

String _data(String version, {bool invalid = false}) =>
    '{"big":$_large,"zero":0,"flag":${invalid ? 'null' : 'false'},"tag":["a,b","雪"],"optional":[],"empty":"","literal":"0"'
    '${version == '2.0' ? '' : ',"nil":null,"payload":{"\$ref":"ordinary data","n":$_large}'}'
    '}';

class _DelayedFormEngine extends EngineProcess {
  _DelayedFormEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'requestFormDataValues') {
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  test('exact form protocol rejects missing nulls and rounded numeric projections and freezes data', () async {
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    const input = '{"n":$_large,"nil":null,"nested":{"n":$_large}}';
    final result = await engine.request('requestFormDataValues', {
      'text': input,
    });
    final data = RequestFormData.fromJson(result, input);
    expect(data.fields['n']!.kind, RequestDataKind.number);
    expect(data.fields['n']!.value, _large);
    expect(data.fields['nil']!.kind, RequestDataKind.nullValue);
    expect(
      () => (data.fields['nested']!.value as Map)['n'] = 'changed',
      throwsUnsupportedError,
    );
    for (final fault in [
      'missing-null',
      'rounded-number',
      'wrong-number-kind',
    ]) {
      final changed = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
      final fields = changed['fields'] as List;
      if (fault == 'missing-null') (fields[1] as Map).remove('value');
      if (fault == 'rounded-number')
        fields[0]['value'] = '900719925474099300000000000000000000';
      if (fault == 'wrong-number-kind') fields[0]['value'] = 1;
      expect(
        () => RequestFormData.fromJson(changed, input),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'request.form.protocol',
          ),
        ),
      );
    }
  });
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format saved form cases use native serialization in core and installed CLI',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-typed-form-',
          );
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
          final file = File('${temp.path}/api.$format'),
              source = _source(version, server.port, format);
          await file.writeAsString(source);
          final manifest = File('${temp.path}/busyapi.yaml');
          final configuration =
              '{"version":1,"roots":[{"name":"api","path":"api.$format"}],"tests":['
              '{"name":"valid","operation":{"method":"post","path":"/form"},"body":{"mediaType":"application/x-www-form-urlencoded","value":${_data(version)}},"expect":{"status":204}},'
              '{"name":"invalid","operation":{"method":"post","path":"/form"},"body":{"mediaType":"application/x-www-form-urlencoded","value":${_data(version, invalid: true)}},"expect":{"status":204}}]}\n';
          await manifest.writeAsString(configuration);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final report = await const ContractTestRunner().run(
            project,
            file.uri.toString(),
            selectedCases: ['valid'],
            resolveSecret: (_) async => null,
          );
          expect(report.complete, isTrue, reason: '${report.toJson()}');
          expect(report.passed, isTrue, reason: '${report.toJson()}');
          expect(seen.single.$1, 'POST');
          expect(seen.single.$2, '/api/form');
          expect(seen.single.$3, 'application/x-www-form-urlencoded');
          final pairs = [
            for (final pair in seen.single.$4.split('&'))
              (
                Uri.decodeQueryComponent(pair.substring(0, pair.indexOf('='))),
                Uri.decodeQueryComponent(pair.substring(pair.indexOf('=') + 1)),
              ),
          ];
          expect(
            pairs,
            containsAll([
              ('big', _large),
              ('zero', '0'),
              ('flag', 'false'),
              ('tag', 'a,b'),
              ('tag', '雪'),
              ('empty', ''),
              ('literal', '0'),
            ]),
          );
          expect(pairs.where((pair) => pair.$1 == 'optional'), isEmpty);
          if (version != '2.0') {
            expect(pairs, contains(('nil', 'null')));
            expect(
              pairs,
              contains(('payload', '{"\$ref":"ordinary data","n":$_large}')),
            );
          }
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'valid', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], isTrue);
          expect(seen, hasLength(2));
          expect(seen[1], seen[0]);
          final invalid = await const ContractTestRunner().run(
            project,
            file.uri.toString(),
            selectedCases: ['invalid'],
            resolveSecret: (_) async => null,
          );
          expect(invalid.complete, isTrue, reason: '${invalid.toJson()}');
          expect(invalid.passed, isFalse);
          expect(seen, hasLength(3));
          expect(seen.last.$4, contains('flag=null'));
          expect(await file.readAsString(), source);
          expect(await manifest.readAsString(), configuration);
        },
      );
    }

  for (final outcome in ['cancelled', 'closed', 'version-changed']) {
    test('structured form preparation cannot send after $outcome', () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-form-owner-');
      addTearDown(() => temp.delete(recursive: true));
      final engine = _DelayedFormEngine();
      addTearDown(engine.close);
      final file = File('${temp.path}/api.yaml');
      final original = _source('3.0.4', 1, 'yaml');
      await file.writeAsString(original);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final analysis = await project.check(file.uri.toString());
      final operation =
          (analysis['projection']['operations'] as List).single as Map;
      final plan = await project.prepareRequest(
        file.uri.toString(),
        resource: operation['resource'] as String,
        pointer: operation['pointer'] as String,
        occurrence: operation['occurrence'] as String,
      );
      addTearDown(plan.close);
      final token = RunCancellation(), data = _data('3.0.4');
      final draft = OperationRequestDraft(
        planIdentity: plan.identity,
        body: RequestBodyDraft.formValue(json: data),
      );
      final pending = const ContractRequestBuilder().build(
        plan,
        draft,
        resolveSecret: (_) async => null,
        cancellation: token,
      );
      final checked = expectLater(
        pending,
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            outcome == 'cancelled'
                ? 'cancelled'
                : outcome == 'closed'
                ? 'request.closed'
                : 'request.draft.stale',
          ),
        ),
      );
      await engine.entered.future;
      if (outcome == 'cancelled') token.cancel();
      if (outcome == 'closed') project.close();
      if (outcome == 'version-changed') {
        final buffer = await project.buffer(file.uri.toString());
        project.store.replace(
          buffer.id,
          buffer.text.replaceFirst('3.0.4', '3.1.2'),
        );
      }
      engine.release.complete();
      await checked;
      expect(draft.body.text, data);
      expect(await file.readAsString(), original);
    });
  }
}
