import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _high = '9007199254740993.00';
const _working = '9007199254740995.00';
const _low = '9007199254740992.00';

String _render(Object value, String format) =>
    '${format == 'yaml' ? '# Preserve source and exact examples\r\n' : ''}'
    '${jsonEncode(value).replaceAll('"HIGH"', _high).replaceAll('"LOW"', _low)}\r\n';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format schema choices retain native mock ownership and exact working bytes',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-schema-mock-owner-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final legacy = version == '2.0';
          final modern = version.startsWith('3.1') || version.startsWith('3.2');
          final file = File('${directory.path}/api.$format');
          final shared = File('${directory.path}/shared.$format');
          final reference = {r'$ref': 'shared.$format#/Stored'};
          final paths = <String, Object?>{};
          for (final name in ['schema', 'override', 'named', 'empty-map']) {
            paths['/$name'] = {
              'get': {
                'responses': {
                  '200': {
                    'description': 'Exact values',
                    if (legacy) ...{
                      'schema': reference,
                      if (name == 'override' || name == 'named')
                        'examples': {'application/json': 'LOW'},
                    } else
                      'content': {
                        'application/json': {
                          'schema': reference,
                          if (name == 'override') 'example': 'LOW',
                          if (name == 'named')
                            'examples': {
                              'Native': {'value': 'LOW'},
                            },
                          if (name == 'empty-map')
                            'examples': <String, Object?>{},
                        },
                      },
                  },
                },
              },
            };
          }
          final original = _render({
            legacy ? 'swagger' : 'openapi': version,
            'info': {'title': 'Mock ownership', 'version': 'business'},
            if (legacy) 'produces': ['application/json'],
            'paths': paths,
          }, format);
          final originalShared = _render({
            'Stored': {
              'type': 'integer',
              'example': 'HIGH',
              if (modern) 'examples': ['HIGH'],
            },
          }, format);
          await file.writeAsString(original);
          await shared.writeAsString(originalShared);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(shared.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceAll(_high, _working),
          );
          final prepared = await project.prepareMock(file.uri.toString());
          final mock = await prepared.start(
            nodeExecutable: runtimeNode,
            helper: '$testBundle/libexec/busyapi/mock-server.cjs',
          );
          addTearDown(mock.stop);
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          for (final (name, expected) in [
            ('schema', _working),
            ('override', _low),
            ('named', _low),
            ('empty-map', _working),
          ]) {
            final response = await (await client.getUrl(
              mock.baseUri.resolve('/$name'),
            )).close();
            final bytes = await response.fold<List<int>>(
              [],
              (all, next) => all..addAll(next),
            );
            expect(
              response.statusCode,
              200,
              reason: '$name: ${utf8.decode(bytes)}',
            );
            expect(bytes, utf8.encode(expected), reason: name);
            expect(
              response.contentLength,
              utf8.encode(expected).length,
              reason: name,
            );
            expect(
              response.headers.value('busyapi-response-validation-complete'),
              'true',
              reason: name,
            );
            expect(
              jsonDecode(response.headers.value('sl-violations') ?? '[]'),
              isEmpty,
              reason: name,
            );
          }
          expect(buffer.text, contains(_working));
          expect(await file.readAsString(), original);
          expect(await shared.readAsString(), originalShared);
        },
      );
    }
  }
}
