import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _large = '900719925474099312345678901234567890';
const _jsonType = 'application/json; profile="a,b"';
const _literalType = 'application/*+json;; profile="a,b"';

String _source(String version, int port, String format) {
  final media = {
    'schema': {
      'type': 'object',
      'required': ['value', 'big'],
      'properties': {
        'value': {'type': 'string'},
        'big': {'type': 'integer'},
        'image': {
          'type': 'array',
          'items': version.startsWith('3.0.')
              ? {'type': 'string', 'format': 'binary'}
              : {},
        },
      },
    },
    'encoding': {
      'value': {'contentType': '$_jsonType, text/plain, $_literalType'},
      'image': {'contentType': 'image/*'},
    },
  };
  if (format == 'json') {
    return jsonEncode({
      'openapi': version,
      'info': {'title': 'Part media', 'version': 'api-version'},
      'servers': [
        {'url': 'http://127.0.0.1:$port/api'},
      ],
      'paths': {
        '/form': {
          'post': {
            'requestBody': {
              'content': {'multipart/form-data': media},
            },
            'responses': {
              '204': {'description': 'ok'},
            },
          },
        },
      },
    });
  }
  return '''# Native part choices, untouched by execution
openapi: $version
info: {title: Part media, version: api-version}
servers: [{url: 'http://127.0.0.1:$port/api'}]
paths:
  /form:
    post:
      requestBody:
        content:
          multipart/form-data:
            schema:
              type: object
              required: [value, big]
              properties:
                value: {type: string}
                big: {type: integer}
                image: {type: array, items: ${version.startsWith('3.0.') ? '{type: string, format: binary}' : '{}'}}
            encoding:
              value: {contentType: '$_jsonType, text/plain, $_literalType'}
              image: {contentType: 'image/*'}
      responses: {'204': {description: ok}}
''';
}

Future<OperationRequestPlan> _plan(BusyProject project, File file) async {
  final analysis = await project.check(file.uri.toString());
  final operation =
      (analysis['projection']['operations'] as List).single as Map;
  return project.prepareRequest(
    file.uri.toString(),
    resource: operation['resource'] as String,
    pointer: operation['pointer'] as String,
    occurrence: operation['occurrence'] as String,
  );
}

void main() {
  test('captured part media options reject malformed protocol values and freeze choices', () {
    for (final raw in [
      {'name': 'other', 'styled': true},
      {
        'name': 'part',
        'styled': true,
        'contentTypes': [0],
      },
      {'name': 'part', 'styled': false, 'contentTypes': []},
      {'name': 'part', 'styled': true, 'allowsCustom': 'yes'},
      {'name': 'part', 'styled': true, 'requiresChoice': 1},
      {'name': 'part', 'styled': true, 'error': false},
    ]) {
      expect(
        () => FormPartMediaOptions.fromJson({'part': raw}),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'request.form.protocol',
          ),
        ),
      );
    }
    final contentTypes = ['application/json', 'text/plain'];
    final values = FormPartMediaOptions.fromJson({
      'part': {
        'name': 'part',
        'styled': false,
        'contentTypes': contentTypes,
        'concreteTypes': contentTypes,
        'allowsCustom': false,
        'requiresChoice': true,
      },
    });
    contentTypes.clear();
    expect(values.single.contentTypes, ['application/json', 'text/plain']);
    expect(() => values.clear(), throwsUnsupportedError);
    expect(() => values.single.contentTypes.clear(), throwsUnsupportedError);
    expect(() => values.single.concreteTypes.clear(), throwsUnsupportedError);
  });
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['json', 'yaml']) {
      test(
        '$version $format explicit part choices send exact native core and installed CLI bodies',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-part-media-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final seen = <(String, String, String, String)>[];
          server.listen((request) async {
            final text = await utf8.decoder.bind(request).join();
            expect(request.contentLength, utf8.encode(text).length);
            seen.add((
              request.method,
              request.uri.toString(),
              request.headers.contentType.toString(),
              text,
            ));
            request.response.statusCode = 204;
            await request.response.close();
          });
          final file = File('${temp.path}/api.$format'),
              original = _source(version, server.port, format);
          await file.writeAsString(original);
          final manifest = File('${temp.path}/busyapi.yaml');
          final configuration = jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'tests': [
              for (final name in [
                'json',
                'literal',
                'text',
                'invalid',
                'missing',
                'empty',
                'ambiguous',
              ])
                {
                  'name': name,
                  'operation': {'method': 'post', 'path': '/form'},
                  'body': {
                    'mediaType': 'multipart/form-data',
                    'value': {'value': '雪+&', 'big': 111},
                    if (name != 'missing')
                      'partMediaTypes': name == 'empty'
                          ? <String, String>{}
                          : {
                              'value': name == 'json'
                                  ? _jsonType
                                  : name == 'literal'
                                  ? _literalType
                                  : name == 'text'
                                  ? 'text/plain'
                                  : name == 'ambiguous'
                                  ? 'text/plain; charset=utf-8; charset=utf-8'
                                  : 'image/png',
                            },
                  },
                  'expect': {'status': 204},
                },
            ],
          }).replaceAll('"big":111', '"big":$_large');
          await manifest.writeAsString(configuration);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final plan = await _plan(project, file);
          addTearDown(plan.close);
          final options = plan.formMediaOptions('multipart/form-data');
          expect(
            options
                .singleWhere((option) => option.name == 'value')
                .contentTypes,
            [_jsonType, 'text/plain', _literalType],
          );
          expect(
            options
                .singleWhere((option) => option.name == 'image')
                .allowsCustom,
            isTrue,
          );
          for (final name in ['json', 'literal', 'text']) {
            final report = await const ContractTestRunner().run(
              project,
              file.uri.toString(),
              selectedCases: [name],
              resolveSecret: (_) async => null,
            );
            expect(report.complete, isTrue, reason: '${report.toJson()}');
            expect(report.passed, isTrue, reason: '${report.toJson()}');
            expect(report.cases.single.dispatched, isTrue);
            final first = seen.last,
                type = name == 'json'
                    ? _jsonType
                    : name == 'literal'
                    ? _literalType
                    : 'text/plain';
            final boundary = ContentType.parse(first.$3)
                .parameters['boundary']!;
            expect(first.$1, 'POST');
            expect(first.$2, '/api/form');
            expect(
              first.$4,
              '--$boundary\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: $type\r\n\r\n${name != 'text' ? '"雪+&"' : '雪+&'}\r\n'
              '--$boundary\r\nContent-Disposition: form-data; name="big"\r\nContent-Type: text/plain\r\n\r\n$_large\r\n--$boundary--\r\n',
            );
            final cli = await Process.run(
              '$testBundle/busyapi',
              ['test', temp.path, '--case', name, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
            expect(
              (jsonDecode(cli.stdout as String) as Map)['complete'],
              isTrue,
            );
            final second = seen.last,
                secondBoundary = ContentType.parse(seen.last.$3)
                    .parameters['boundary']!;
            expect(second.$4.replaceAll(secondBoundary, boundary), first.$4);
          }
          final interleaved = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: const RequestBodyDraft.multipart(
                [
                  RequestFormField('note', 'first'),
                  RequestFormField('empty', ''),
                  RequestFormField('note', 'second'),
                  RequestFormField('value', 'literal'),
                  RequestFormField('big', _large),
                ],
                [],
                partMediaTypes: {'value': 'text/plain'},
              ),
            ),
            resolveSecret: (_) async => null,
          );
          expect(interleaved.outgoing.complete, isTrue);
          expect(interleaved.outgoing.valid, isTrue);
          expect(
            RegExp('Content-Disposition: form-data; name="([^"]*)"')
                .allMatches(seen.last.$4)
                .map((match) => match[1])
                .toList(),
            ['note', 'empty', 'note', 'value', 'big'],
          );
          await interleaved.close();
          final count = seen.length;
          for (final name in ['invalid', 'missing', 'empty']) {
            final report = await const ContractTestRunner().run(
              project,
              file.uri.toString(),
              selectedCases: [name],
              resolveSecret: (_) async => null,
            );
            expect(report.passed, isFalse);
            expect(report.complete, isTrue);
            expect(report.cases.single.status, 'failed');
            expect(report.cases.single.operationalFailure, isTrue);
            expect(report.cases.single.responseStatus, isNull);
            expect(report.cases.single.dispatched, isFalse);
            expect(report.executedOperations, isEmpty);
            expect(report.untestedOperations, hasLength(1));
            expect(
              jsonEncode(report.toJson()),
              contains('request.form.content-type'),
            );
            expect(seen.length, count);
          }
          final unsupported = await const ContractTestRunner().run(
            project,
            file.uri.toString(),
            selectedCases: ['ambiguous'],
            resolveSecret: (_) async => null,
          );
          expect(unsupported.complete, isFalse);
          expect(unsupported.passed, isFalse);
          expect(unsupported.cases.single.status, 'incomplete');
          expect(unsupported.cases.single.operationalFailure, isFalse);
          expect(unsupported.cases.single.dispatched, isFalse);
          expect(unsupported.executedOperations, isEmpty);
          expect(
            jsonEncode(unsupported.toJson()),
            contains('request.form.media-parameters.unsupported'),
          );
          final unsupportedCli = await Process.run(
            '$testBundle/busyapi',
            ['test', temp.path, '--case', 'ambiguous', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(
            unsupportedCli.exitCode,
            2,
            reason: '${unsupportedCli.stdout}\n${unsupportedCli.stderr}',
          );
          expect(
            (jsonDecode(unsupportedCli.stdout as String) as Map)['status'],
            'incomplete',
          );
          final unsupportedJson =
              jsonDecode(unsupportedCli.stdout as String) as Map;
          expect(unsupportedJson['executedOperations'], isEmpty);
          expect(unsupportedJson['cases'][0]['dispatched'], isFalse);
          expect(unsupportedJson['cases'][0]['operationalFailure'], isFalse);
          expect(seen.length, count);
          final buffer = await project.buffer(file.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst(', text/plain', ''),
          );
          final changed = await _plan(project, file);
          addTearDown(changed.close);
          await expectLater(
            const ContractRequestBuilder().build(
              changed,
              OperationRequestDraft(
                planIdentity: changed.identity,
                body: const RequestBodyDraft.multipart(
                  [
                    RequestFormField('value', '"雪+&"'),
                    RequestFormField('big', _large),
                  ],
                  [],
                  partMediaTypes: {'value': 'text/plain'},
                ),
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'code',
                'request.form.content-type',
              ),
            ),
          );
          expect(seen.length, count);
          expect(await file.readAsString(), original);
          expect(await manifest.readAsString(), configuration);
        },
      );
    }
    test(
      '$version per-file wildcard choices retain captured binary bytes and require explicit intent',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-file-media-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final seen = <(String, List<int>)>[];
        server.listen((request) async {
          seen.add((
            request.headers.contentType.toString(),
            await request.fold<List<int>>(
              [],
              (bytes, chunk) => bytes..addAll(chunk),
            ),
          ));
          request.response.statusCode = 204;
          await request.response.close();
        });
        final file = File('${temp.path}/api.json'),
            original = _source(version, server.port, 'json');
        await file.writeAsString(original);
        final image = File('${temp.path}/image.bin');
        const raw = [0, 255, 128, 13, 10, 42];
        await image.writeAsBytes(raw);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final plan = await _plan(project, file);
        addTearDown(plan.close);
        OperationRequestDraft draft(List<MultipartFileValue> files) =>
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: RequestBodyDraft.multipart(const [], files),
            );
        await expectLater(
          const ContractRequestBuilder().build(
            plan,
            draft([
              MultipartFileValue(
                name: 'image',
                path: image.path,
                mediaType: 'image/png',
              ),
            ]),
            resolveSecret: (_) async => null,
          ),
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'code',
              'request.form.content-type',
            ),
          ),
        );
        expect(seen, isEmpty);
        final prepared = await const ContractRequestBuilder().build(
          plan,
          draft([
            MultipartFileValue(
              name: 'image',
              path: image.path,
              filename: 'one.png',
              selectedMediaType: 'image/png',
            ),
            MultipartFileValue(
              name: 'image',
              path: image.path,
              filename: 'two.jpg',
              selectedMediaType: 'image/jpeg',
            ),
          ]),
          resolveSecret: (_) async => null,
        );
        await image.writeAsBytes([1, 2]);
        final response = await const ContractHttpTransport().send(prepared);
        await response.close();
        await prepared.body!.close();
        final boundary = ContentType.parse(seen.single.$1)
            .parameters['boundary']!;
        expect(seen.single.$2, [
          ...utf8.encode(
            '--$boundary\r\nContent-Disposition: form-data; name="image"; filename="one.png"\r\nContent-Type: image/png\r\n\r\n',
          ),
          ...raw,
          ...utf8.encode(
            '\r\n--$boundary\r\nContent-Disposition: form-data; name="image"; filename="two.jpg"\r\nContent-Type: image/jpeg\r\n\r\n',
          ),
          ...raw,
          ...utf8.encode('\r\n--$boundary--\r\n'),
        ]);
        expect(await file.readAsString(), original);
      },
    );
  }
}
