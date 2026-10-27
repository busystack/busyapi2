import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format dynamic annotation ambiguity refuses HTTP and reports incomplete cases',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-multipart-binding-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          var requests = 0;
          server.listen((request) async {
            requests++;
            await request.drain<void>();
            await request.response.close();
          });
          final document = {
            'openapi': version,
            'info': {'title': 'Keep 雪', 'version': 'api-version'},
            'servers': [
              {'url': 'http://127.0.0.1:${server.port}'},
            ],
            'paths': {
              '/upload': {
                'post': {
                  'requestBody': {
                    'content': {
                      'multipart/form-data': {
                        'schema': {
                          'type': 'object',
                          'properties': {
                            'payload': {r'$dynamicRef': '#part'},
                          },
                        },
                        'encoding': {
                          'payload': {
                            'contentType': 'application/octet-stream',
                          },
                        },
                      },
                    },
                  },
                  'responses': {
                    '204': {'description': 'Empty'},
                  },
                },
              },
            },
            'components': {
              'schemas': {
                'Part': {
                  r'$dynamicAnchor': 'part',
                  'type': 'string',
                  'contentEncoding': 'base64',
                },
                'Peer': {
                  r'$id': 'other',
                  r'$dynamicAnchor': 'part',
                  'type': 'string',
                  'contentEncoding': 'base16',
                },
              },
            },
            'x-payload': {
              r'$dynamicRef': 'literal',
              'number': 'EXACT',
              'false': false,
              'zero': 0,
            },
          };
          final text =
              (format == 'json'
                      ? jsonEncode(document)
                      : '# Keep CRLF\r\n${document.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n')
                  .replaceFirst('"EXACT"', '9007199254740993.00');
          final source = [0xef, 0xbb, 0xbf, ...utf8.encode(text)];
          final file = File('${directory.path}/api.$format');
          await file.writeAsBytes(source);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final checked = await project.check(file.uri.toString());
          expect(checked['complete'], isTrue, reason: '$checked');
          final plan = await project.prepareRequest(
            file.uri.toString(),
            resource: file.uri.toString(),
            pointer: '/paths/~1upload/post',
          );
          addTearDown(plan.close);
          await expectLater(
            const ContractRequestExecutor().execute(
              plan,
              OperationRequestDraft(
                planIdentity: plan.identity,
                body: const RequestBodyDraft.multipartValue(
                  json: '{"payload":"Zg=="}',
                ),
              ),
              resolveSecret: (_) async => null,
            ),
            throwsA(
              isA<CoreFailure>()
                  .having(
                    (failure) => failure.code,
                    'code',
                    'request.multipart.encoding.unsupported',
                  )
                  .having(
                    (failure) => failure.kind,
                    'kind',
                    CoreFailureKind.unsupported,
                  )
                  .having(
                    (failure) => failure.source?.resource,
                    'resource',
                    file.uri.toString(),
                  )
                  .having(
                    (failure) => failure.source?.pointer,
                    'pointer',
                    endsWith('/properties/payload'),
                  ),
            ),
          );
          expect(requests, 0);
          final configuration = jsonEncode({
            'version': 1,
            'roots': [
              {'name': 'api', 'path': 'api.$format'},
            ],
            'tests': [
              {
                'name': 'ambiguous',
                'operation': {'method': 'post', 'path': '/upload'},
                'body': {
                  'mediaType': 'multipart/form-data',
                  'value': {'payload': 'Zg=='},
                },
              },
            ],
          });
          final manifest = File('${directory.path}/busyapi.yaml');
          await manifest.writeAsString(configuration);
          final configured = await BusyProject.open(directory.path, engine);
          addTearDown(configured.close);
          final report = await const ContractTestRunner().run(
            configured,
            file.uri.toString(),
            selectedCases: ['ambiguous'],
            resolveSecret: (_) async => null,
          );
          expect(report.complete, isFalse);
          expect(report.cases.single.status, 'incomplete');
          expect(report.cases.single.operationalFailure, isFalse);
          expect(report.cases.single.dispatched, isFalse);
          expect(report.executedOperations, isEmpty);
          final finding = report.cases.single.findings.single;
          expect(finding['code'], 'request.multipart.encoding.unsupported');
          expect(finding['resource'], file.uri.toString());
          expect(finding['pointer'], endsWith('/properties/payload'));
          final range = (finding['range'] as List).cast<int>();
          final buffer = await configured.buffer(file.uri.toString());
          expect(
            buffer.text.substring(range[0], range[1]),
            contains(r'$dynamicRef'),
          );
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['test', directory.path, '--case', 'ambiguous', '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 2, reason: '${cli.stdout}\n${cli.stderr}');
          final json = jsonDecode(cli.stdout as String) as Map;
          expect(json['complete'], isFalse);
          expect(json['status'], 'incomplete');
          expect(json['cases'][0]['operationalFailure'], isFalse);
          expect(json['cases'][0]['dispatched'], isFalse);
          expect(
            json['cases'][0]['findings'][0]['resource'],
            file.uri.toString(),
          );
          expect(requests, 0);
          expect(await file.readAsBytes(), source);
          expect(await manifest.readAsString(), configuration);
        },
      );
    }
  }
}
