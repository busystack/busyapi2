import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format documentation uses captured URI contexts and unsaved identities',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-markdown-context-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final source = File('${temp.path}/api.$format'),
              manifest = File('${temp.path}/busyapi.yaml');
          final modern = version.startsWith('3.1') || version.startsWith('3.2');
          final value = <String, Object?>{
            version == '2.0' ? 'swagger' : 'openapi': version,
            if (version.startsWith('3.2'))
              r'$self': 'https://identity.example.invalid/root/api.$format',
            'info': {
              'title': 'Context 雪',
              'version': '1',
              'description': '[Guide](guide?zero=0&empty=) [unsafe](file:///private) ![never loaded](https://must-not-load.invalid/image)',
            },
            'paths': {},
            version == '2.0' ? 'definitions' : 'components': version == '2.0'
                ? {
                    'Value': {
                      'type': 'string',
                      'description': '[Schema](guide)',
                    },
                  }
                : {
                    'schemas': {
                      'Value': {
                        if (modern)
                          r'$id': 'https://schema.example.invalid/models/',
                        'type': 'string',
                        'description': '[Schema](guide)',
                      },
                    },
                  },
            'x-data': {
              'description': '[Literal](../payload)',
              'n': 'EXACT',
              'false': false,
              'empty': '',
            },
          };
          final text =
              '${format == 'yaml' ? '# Keep 雪\r\n' : ''}${jsonEncode(value).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
          await source.writeAsString(text);
          await manifest.writeAsString(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'resourceMappings': {
                'https://retrieval.example.invalid/original/api.$format':
                    'api.$format',
              },
            }),
          );
          final original = await source.readAsBytes();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final root = source.uri.toString();
          final base = version.startsWith('3.2')
              ? 'https://identity.example.invalid/root/'
              : 'https://retrieval.example.invalid/original/';
          final plan = await project.prepareDocumentation(
            root,
            '${temp.path}/before',
          );
          addTearDown(plan.close);
          await plan.publish();
          final html = await File('${plan.destination}/index.html')
              .readAsString();
          expect(html, contains('href="${base}guide?zero=0&amp;empty="'));
          expect(
            html,
            contains(
              'href="${modern ? 'https://schema.example.invalid/models/' : base}guide"',
            ),
          );
          expect(html, isNot(contains('href="file:')));
          expect(html, isNot(contains('<img')));
          final buffer = await project.buffer(root);
          project.store.replace(
            root,
            buffer.text.replaceFirst(
              modern
                  ? 'https://schema.example.invalid/models/'
                  : '[Schema](guide)',
              modern
                  ? 'https://changed.example.invalid/new/'
                  : '[Schema](next)',
            ),
          );
          final next = await project.prepareDocumentation(
            root,
            '${temp.path}/after',
          );
          addTearDown(next.close);
          expect(next.unsaved, true);
          await next.publish();
          final changed = await File('${next.destination}/index.html')
              .readAsString();
          expect(
            changed,
            contains(
              'href="${modern ? 'https://changed.example.invalid/new/guide' : '${base}next'}"',
            ),
          );
          expect(await source.readAsBytes(), original);
          expect(buffer.text, contains('9007199254740993.00'));
          final cliOutput = '${temp.path}/cli';
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'build-docs',
              temp.path,
              '--output',
              cliOutput,
              '--preset',
              'native-reference',
              '--json',
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stderr}${cli.stdout}');
          expect(
            await File('$cliOutput/index.html').readAsString(),
            contains('href="${base}guide?zero=0&amp;empty="'),
          );
          expect(await source.readAsBytes(), original);
        },
      );
    }
  }
}
