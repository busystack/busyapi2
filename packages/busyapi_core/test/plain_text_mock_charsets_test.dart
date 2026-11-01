import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      for (final (media, text, charset, bytes) in [
        ('text/plain', 'café', 'utf-8', utf8.encode('café')),
        (
          'text/plain; charset=iso-8859-1',
          'café',
          'iso-8859-1',
          latin1.encode('café'),
        ),
        ('text/plain; charset=utf-8', 'café', 'utf-8', utf8.encode('café')),
        (
          'text/plain; charset=us-ascii',
          'false',
          'us-ascii',
          ascii.encode('false'),
        ),
      ]) {
        test('$version $format native mock encodes $media ${jsonEncode(text)}', () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-plain-mock-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final legacy = version == '2.0';
          final schema = {
            'type': 'string',
            'enum': [text],
          };
          final document = {
            legacy ? 'swagger' : 'openapi': version,
            'info': {'title': 'Original mock', 'version': 'business'},
            if (legacy) 'produces': [media],
            'paths': {
              '/data': {
                'get': {
                  'responses': {
                    '200': {
                      'description': 'Text',
                      if (legacy) ...{
                        'schema': schema,
                        'examples': {media: text},
                      } else
                        'content': {
                          media: {'schema': schema, 'example': text},
                        },
                    },
                  },
                },
              },
            },
            'x-number': 'EXACT',
          };
          final source =
              '${format == 'yaml' ? '# Keep mock\r\n' : ''}'
              '${jsonEncode(document).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
          final file = File('${temp.path}/api.$format');
          await file.writeAsString(source);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final checked = await project.check(file.uri.toString());
          expect(checked['complete'], true, reason: '$checked');
          expect(
            (checked['findings'] as List).whereType<Map>().where(
              (finding) => finding['severity'] == 'error',
            ),
            isEmpty,
            reason: '$checked',
          );
          final prepared = await project.prepareMock(file.uri.toString());
          final mock = await prepared.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(mock.stop);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final request = await client.getUrl(mock.baseUri.resolve('/data'));
          request.headers.set('accept', media);
          final response = await request.close();
          final actual = await response.fold<List<int>>(
            [],
            (all, next) => all..addAll(next),
          );
          expect(
            response.statusCode,
            200,
            reason:
                '${response.headers}\n${utf8.decode(actual, allowMalformed: true)}',
          );
          expect(response.headers.contentType!.mimeType, 'text/plain');
          expect(response.headers.contentType!.charset, charset);
          expect(actual, bytes);
          expect(await file.readAsString(), source);
        });
      }
    }
  }
}
