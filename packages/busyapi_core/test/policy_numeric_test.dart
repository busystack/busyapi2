import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'bundled governance numeric semantics retain source and CLI parity $version $json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-policy-numbers 雪 ',
          );
          addTearDown(() => temp.delete(recursive: true));
          final root = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
          final source = json
              ? '{\r\n"openapi":"$version","info":{"title":"Exact 😀","version":"1"},"paths":{},"x-number":1e-9999}'
              : '# retained 😀\r\nopenapi: $version\ninfo: {title: "Exact 😀", version: "1"}\r\npaths: {}\nx-number: 1e-9999';
          await root.writeAsBytes([239, 187, 191, ...utf8.encode(source)]);
          final policy = File(
            '${temp.path}/.spectral.${json ? 'json' : 'yaml'}',
          );
          String rules(String function, {String? options}) => json
              ? '{"rules":{"exact":{"given":"\$.x-number","then":{"function":"$function"${options == null ? '' : ',"functionOptions":$options'}}}}}'
              : 'rules:\n  exact:\n    given: \$.x-number\n    then:\n      function: $function\n${options == null ? '' : '      functionOptions: $options\n'}';
          await policy.writeAsString(rules('truthy'));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final before = await root.readAsBytes();
          final good = await project.lint(root.uri.toString());
          expect(good['complete'], true, reason: jsonEncode(good));
          expect(lintExitCode(good), 0);
          expect(
            (good['findings'] as List).where((f) => f['category'] == 'policy'),
            isEmpty,
          );
          Future<Map<String, dynamic>> cli(int exit) async {
            final result = await Process.run(
              '$testBundle/busyapi',
              ['lint', root.path, '--json'],
              environment: {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              result.exitCode,
              exit,
              reason: '${result.stdout}\n${result.stderr}',
            );
            return jsonDecode(result.stdout as String) as Map<String, dynamic>;
          }

          expect((await cli(0))['findings'], good['findings']);
          final buffer = await project.buffer(policy.uri.toString());
          project.store.replace(buffer.id, rules('falsy'));
          final changed = await project.lint(root.uri.toString());
          expect(changed['complete'], true, reason: jsonEncode(changed));
          expect(lintExitCode(changed), 1);
          expect(
            (changed['findings'] as List)
                .where((f) => f['code'] == 'policy.rule.exact')
                .single['pointer'],
            '/x-number',
          );
          expect(await policy.readAsString(), rules('truthy'));
          project.store.undo();
          expect(lintExitCode(await project.lint(root.uri.toString())), 0);
          project.store.redo();
          final publication = PublicationStore(
            '${temp.path}/state/publications',
          );
          expect((await publication.save(project, [buffer])).complete, true);
          expect((await cli(1))['findings'], changed['findings']);
          project.store.replace(
            buffer.id,
            rules('length', options: '{"max":1}'),
          );
          final incomplete = await project.lint(root.uri.toString());
          expect(incomplete['categories']['policy']['complete'], false);
          expect(lintExitCode(incomplete), 2);
          expect(
            (incomplete['findings'] as List).any(
              (f) =>
                  f['code'] == 'policy.numeric.incomplete' &&
                  f['pointer'] == '/x-number',
            ),
            true,
          );
          expect((await publication.save(project, [buffer])).complete, true);
          expect((await cli(2))['findings'], incomplete['findings']);
          expect(await root.readAsBytes(), before);
          final reopened = await BusyProject.open(root.path, engine);
          addTearDown(reopened.close);
          expect((await reopened.buffer(root.uri.toString())).bytes(), before);
        },
      );
    }
  }
}
