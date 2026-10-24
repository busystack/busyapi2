import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'F14/F15 canonical checks reach project and CLI $version ${json ? 'JSON' : 'YAML'}',
        () async {
          final dir = await Directory.systemTemp.createTemp(
            'busyapi-check-repair-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          BusyProject? project;
          try {
            final file = File('${dir.path}/openapi.${json ? 'json' : 'yaml'}');
            Future<Map> check(String text) async {
              project?.close();
              await file.writeAsString(text);
              project = await BusyProject.open(file.path, engine);
              final result = await project!.check(file.uri.toString());
              final cli = await Process.run(
                '$testBundle/busyapi',
                ['check', file.path, '--json'],
                environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
                includeParentEnvironment: false,
              );
              expect(
                cli.exitCode,
                result['status'] == 'invalid' ? 1 : 0,
                reason: '${cli.stderr}\n${cli.stdout}',
              );
              final machine = jsonDecode(cli.stdout as String) as Map;
              expect(machine['complete'], result['complete']);
              expect(
                (machine['findings'] as List).map((f) => f['code']),
                (result['findings'] as List).map((f) => f['code']),
              );
              return result;
            }

            final paths = json
                ? jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Checks', 'version': '1'},
                    'paths': {
                      for (final name in ['id', 'name'])
                        '/pets/{$name}': {
                          'get': {
                            'parameters': [
                              {
                                'in': 'path',
                                'name': name,
                                'required': true,
                                'schema': {'type': 'string'},
                              },
                            ],
                            'responses': {
                              '200': {'description': 'ok'},
                            },
                          },
                        },
                    },
                  })
                : '''openapi: $version
info: {title: Checks, version: "1"}
paths:
  /pets/{id}:
    get:
      parameters: [{in: path, name: id, required: true, schema: {type: string}}]
      responses: {"200": {description: ok}}
  /pets/{name}:
    get:
      parameters: [{in: path, name: name, required: true, schema: {type: string}}]
      responses: {"200": {description: ok}}
''';
            final equivalent = await check(paths);
            expect(equivalent['complete'], true);
            expect(equivalent['status'], 'invalid');
            final findings = (equivalent['findings'] as List)
                .where((f) => f['code'] == 'path.template.equivalent')
                .toList();
            expect(findings, hasLength(2));
            for (final finding in findings) {
              final range = finding['range'] as List;
              expect(
                paths.substring(range[0] as int, range[1] as int),
                contains('/pets/{'),
              );
            }
            final distinct = await check(
              paths.replaceAll('/pets/{name}', '/owners/{name}'),
            );
            expect(distinct['complete'], true);
            expect(distinct['status'], 'complete');
            final emptySegment = await check(
              paths
                  .replaceAll('/pets/{name}', '/owners/{name}')
                  .replaceAll('/pets/{id}', '/pets//{id}'),
            );
            expect(emptySegment['complete'], true);
            expect(
              emptySegment['status'],
              version.startsWith('3.2') ? 'invalid' : 'complete',
            );
            expect(
              (emptySegment['findings'] as List).any(
                (finding) => finding['code'] == 'path.template.syntax',
              ),
              version.startsWith('3.2'),
            );

            // R05: the public project/CLI checks keep literal-token boundaries
            // across template expressions, with 3.2-only grammar diagnostics.
            for (final malformed in [false, true]) {
              final names = malformed
                  ? ['/%{id}20', '/%2{id}0', '/%{id}2{other}0', '/%2G{id}']
                  : ['/%20{id}', '/{id}%20', '/%25{id}20', '/{id}2F'];
              final text = json
                  ? jsonEncode({
                      'openapi': version,
                      'info': {'title': 'Checks', 'version': '1'},
                      'paths': {for (final name in names) name: {}},
                    })
                  : 'openapi: $version\ninfo: {title: Checks, version: "1"}\npaths:\n'
                        '${names.map((name) => '  "$name": {}\n').join()}';
              final result = await check(text);
              expect(result['complete'], true);
              expect(
                result['status'],
                malformed && version.startsWith('3.2') ? 'invalid' : 'complete',
              );
              final syntax = (result['findings'] as List)
                  .where((f) => f['code'] == 'path.template.syntax')
                  .toList();
              expect(
                syntax,
                hasLength(malformed && version.startsWith('3.2') ? 4 : 0),
              );
              for (final finding in syntax) {
                final range = finding['range'] as List;
                expect(
                  text.substring(range[0] as int, range[1] as int),
                  contains(
                    (finding['pointer'] as String)
                        .substring('/paths/'.length)
                        .replaceAll('~1', '/'),
                  ),
                );
              }
            }

            String discriminator(bool required) => json
                ? jsonEncode({
                    'openapi': version,
                    'info': {'title': 'Checks', 'version': '1'},
                    'paths': {},
                    'components': {
                      'schemas': {
                        'Model': {
                          'type': 'object',
                          'properties': {
                            'kind': {'type': 'string'},
                          },
                          'oneOf': [
                            {
                              'required': ['a'],
                            },
                            {
                              'required': ['b'],
                            },
                          ],
                          'discriminator': {'propertyName': 'kind'},
                          if (required) 'required': ['kind'],
                          'examples': [
                            {'a': true, if (required) 'kind': 'a'},
                          ],
                        },
                      },
                    },
                  })
                : '''openapi: $version
info: {title: Checks, version: "1"}
paths: {}
components:
  schemas:
    Model:
      type: object
      properties: {kind: {type: string}}
      oneOf: [{required: [a]}, {required: [b]}]
      discriminator: {propertyName: kind}
${required ? '      required: [kind]\n' : ''}      examples: [${required ? '{a: true, kind: a}' : '{a: true}'}]
''';
            final optional = await check(discriminator(false));
            expect(optional['complete'], true);
            expect(
              optional['status'],
              version.startsWith('3.2') ? 'invalid' : 'complete',
            );
            expect(
              (optional['findings'] as List).any(
                (f) => f['code'] == 'discriminator.default-mapping.required',
              ),
              version.startsWith('3.2'),
            );
            expect(
              (optional['findings'] as List).any(
                (finding) => finding['code'] == 'example.schema.incompatible',
              ),
              false,
            );
            final required = await check(discriminator(true));
            expect(required['complete'], true);
            expect(required['status'], 'complete');
          } finally {
            project?.close();
            await engine.close();
            await dir.delete(recursive: true);
          }
        },
      );
    }
  }
}
