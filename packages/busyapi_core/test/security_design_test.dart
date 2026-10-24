import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true]) {
      test(
        'security advice $version $json preserves bytes, masks reports and agrees with headless check',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-security-core-',
          );
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          BusyProject? project;
          try {
            final token =
                'ghp_${List.generate(36, (i) => 'aB3cD5eF7gH9kL2mN4pQ6rS8tU0vW1xY'[i % 32]).join()}';
            final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
            final text = json
                ? '{"openapi":"$version","info":{"title":"Advice 😀","version":"1"},"paths":{"/p":{"get":{"responses":{"200":{"description":"OK","content":{"application/json":{"example":{"\$ref":"$token","n":9007199254740993,"z":1.00}}}}}}}}}'
                : '# exact retained\r\nopenapi: $version\r\ninfo: {title: "Advice 😀", version: "1"}\r\npaths:\r\n  /p:\r\n    get:\r\n      responses:\r\n        200:\r\n          description: OK\r\n          content:\r\n            application/json:\r\n              example: {\$ref: "$token", n: 9007199254740993, z: 1.00}';
            final original = [239, 187, 191, ...utf8.encode(text)];
            await file.writeAsBytes(original);
            project = await BusyProject.open(temp.path, engine);
            final root = project.roots.single.id;
            final saved = await project.check(root, saved: true);
            expect(saved['status'], 'complete');
            final advice = (saved['findings'] as List)
                .where((finding) => finding['category'] == 'security')
                .single;
            expect(advice['masked'], isTrue);
            expect(advice['confidence'], 'advisory');
            expect(advice['snapshot'], saved['snapshot']);
            expect(
              saved['categories']['security']['snapshot'],
              saved['snapshot'],
            );
            expect(saved['categories']['security']['complete'], isTrue);
            expect(
              text.substring(
                advice['range'][0] as int,
                advice['range'][1] as int,
              ),
              contains(token),
            );
            expect(jsonEncode(saved['findings']), isNot(contains(token)));
            expect(saved['references'], isEmpty);
            final command = await Process.run(
              '$testBundle/busyapi',
              ['check', file.path, '--json'],
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              command.exitCode,
              0,
              reason: '${command.stdout}\n${command.stderr}',
            );
            expect(command.stderr, isEmpty);
            final output = jsonDecode(command.stdout as String);
            expect(output['findings'], saved['findings']);
            expect(output['snapshots'], [saved['snapshot']]);
            expect(output['categories'].single['results'], saved['categories']);
            expect(command.stdout, isNot(contains(token)));
            final buffer = await project.buffer(root);
            project.store.replace(
              root,
              buffer.text.replaceFirst(
                token,
                'placeholder-for-an-illustrative-value',
              ),
            );
            final working = await project.check(root);
            expect(working['unsaved'], isTrue);
            expect(working['snapshot'], isNot(saved['snapshot']));
            expect(
              (working['findings'] as List).where(
                (finding) => finding['category'] == 'security',
              ),
              isEmpty,
            );
            expect(await file.readAsBytes(), original);
            project.store.undo();
            final restored = await project.check(root);
            expect(restored['snapshot'], saved['snapshot']);
            expect(restored['findings'], saved['findings']);
            expect(buffer.bytes(), original);
            expect(await file.readAsBytes(), original);
            expect(File('${temp.path}/busyapi.yaml').existsSync(), isFalse);
          } finally {
            project?.close();
            await engine.close();
            await temp.delete(recursive: true);
          }
        },
      );
    }
}
