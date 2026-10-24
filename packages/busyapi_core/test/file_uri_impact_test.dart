import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test('external example deletion remains passive $version json=$json', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-data-impact-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final ext = json ? 'json' : 'yaml',
            root = File('${temp.path}/root.$ext'),
            data = File('${temp.path}/payload 雪.$ext');
        const payload =
            '\ufeffopaque serialized data: [ invalid YAML\r\n900719925474099312345678901😀';
        await data.writeAsString(payload);
        final locator = '${data.uri}#opaque%7E%2Fdata';
        final source = json
            ? jsonEncode({
                'openapi': version,
                if (version.startsWith('3.2'))
                  r'$self': 'https://identity.example/entry',
                'info': {'title': 'Passive data 雪', 'version': '1'},
                'paths': <String, Object>{},
                'components': {
                  'examples': {
                    'Serialized': {'externalValue': locator},
                    'Literal': {
                      'value': {'externalValue': locator, r'$ref': locator},
                    },
                    'Ignored': {
                      r'$ref': '#/components/examples/Literal',
                      'externalValue': locator,
                    },
                  },
                },
              })
            : '\ufeff# Preserve passive resource ownership\r\nopenapi: $version\r\n'
                  '${version.startsWith('3.2') ? '\$self: https://identity.example/entry\r\n' : ''}'
                  'info: {title: "Passive data 雪", version: "1"}\r\npaths: {}\n'
                  'components:\n  examples:\n    Serialized:\n      externalValue: ${jsonEncode(locator)} # exact\n'
                  '    Literal: {value: {externalValue: ${jsonEncode(locator)}, \$ref: ${jsonEncode(locator)}}}\n'
                  '    Ignored: {\$ref: "#/components/examples/Literal", externalValue: ${jsonEncode(locator)}}';
        await root.writeAsString(source);
        final project = await BusyProject.open(root.path, engine);
        addTearDown(project.close);
        final checked = await project.check(root.uri.toString());
        expect(checked['complete'], true, reason: '${checked['findings']}');
        expect((checked['resources'] as List).map((r) => r['id']), [
          root.uri.toString(),
        ]);
        expect(
          project.store.buffers.containsKey(data.uri.toString()),
          false,
          reason: 'Opening/checking must not acquire an external serialized example',
        );
        final plan = await project.planFileDeletion(data.uri.toString());
        final usage = (plan.result['usages'] as List).single as Map;
        expect(usage['resource'], root.uri.toString());
        expect(
          usage['pointer'],
          '/components/examples/Serialized/externalValue',
        );
        expect(usage['connection'], 'externalValue');
        expect(
          (plan.result['blockers'] as List).single['code'],
          'file.delete.consumer',
        );
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(isA<CoreFailure>()),
        );
        expect(await root.readAsBytes(), utf8.encode(source));
        expect(await data.readAsBytes(), utf8.encode(payload));
        expect(project.store.get(data.uri.toString()).present, true);
      });

      test(
        'external example move is exact, reviewed and one undo step $version json=$json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-data-move-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final ext = json ? 'json' : 'yaml',
              root = File('${temp.path}/root.$ext'),
              model = File('${temp.path}/model.$ext'),
              destination = File('${temp.path}/moved 雪.$ext');
          final source = json
              ? '{"openapi":"$version","info":{"title":"Data move","version":"1"},"paths":{},"components":{"schemas":{"Value":{"\$ref":"model.$ext"}},"examples":{"Serialized":{"externalValue":"model.$ext#opaque%7E%2Fdata"},"Literal":{"value":{"externalValue":"model.$ext"}}}}}'
              : '\ufeff# retain source\r\nopenapi: $version\r\ninfo: {title: "Data move", version: "1"}\npaths: {}\n'
                    'components:\n  schemas:\n    Value: {\$ref: "model.$ext"}\n  examples:\n'
                    '    Serialized: {externalValue: "model.$ext#opaque%7E%2Fdata"} # locator\n'
                    '    Literal: {value: {externalValue: "model.$ext"}}';
          final modelText = json
              ? '\ufeff{"type":"integer","example":900719925474099312345678901}\r\n'
              : '\ufeff# precise bytes\r\ntype: integer\nexample: 900719925474099312345678901 # retain';
          await root.writeAsString(source);
          await model.writeAsString(modelText);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(model.uri.toString());
          final plan = await project.planFileMove(buffer.id, destination.path);
          expect(
            (plan.result['usages'] as List).any(
              (u) => u['connection'] == 'externalValue',
            ),
            true,
          );
          expect(await destination.exists(), false);
          final rootBuffer = await project.buffer(root.uri.toString()),
              before = rootBuffer.text;
          await project.applyRefactoring(plan);
          final after = rootBuffer.text;
          expect(after, contains('moved%20%E9%9B%AA.$ext#opaque%7E%2Fdata'));
          expect(
            after,
            contains('externalValue${json ? '":"' : ': "'}model.$ext'),
          );
          expect(buffer.text, modelText.substring(1));
          project.store.undo();
          expect(rootBuffer.text, before);
          expect(buffer.id, model.uri.toString());
          project.store.redo();
          expect(rootBuffer.text, after);
          expect(buffer.id, destination.uri.toString());
          final stale = await project.planFileMove(
            buffer.id,
            '${temp.path}/later.$ext',
            retainIdentity: false,
          );
          project.store.replace(
            rootBuffer.id,
            '$after${json ? ' ' : '\n# later 雪'}',
          );
          final later = rootBuffer.text;
          await expectLater(
            project.applyRefactoring(stale),
            throwsA(isA<CoreFailure>()),
          );
          expect(rootBuffer.text, later);
          expect(buffer.id, destination.uri.toString());
          final publication = PublicationStore('${temp.path}/state');
          expect((await publication.save(project, [buffer])).complete, true);
          expect(await model.exists(), false);
          expect(await destination.readAsBytes(), utf8.encode(modelText));
          expect(
            await root.readAsBytes(),
            utf8.encode('${rootBuffer.hasBom ? '\ufeff' : ''}$later'),
          );
          final reopened = await BusyProject.open(root.path, engine);
          addTearDown(reopened.close);
          final checked = await reopened.check(root.uri.toString());
          expect(checked['complete'], true, reason: '${checked['findings']}');
          expect(
            (await reopened.buffer(destination.uri.toString())).text,
            buffer.text,
          );
        },
      );
      test('cross-file response URI relocation uses shared history $version json=$json', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-copy-data-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final ext = json ? 'json' : 'yaml',
            root = File('${temp.path}/root.$ext'),
            destination = File('${temp.path}/models/shared.$ext');
        await destination.parent.create();
        final source = json
            ? '{"openapi":"$version","info":{"title":"Copy data","version":"1"},"paths":{"/items":{"get":{"responses":{"200":{"description":"Response 雪😀","content":{"application/json":{"schema":false,"examples":{"External":{"externalValue":"./payload.txt#opaque%7E%2Fdata"},"Literal":{"value":{"externalValue":"payload data","number":900719925474099312345678901}}}}}}}}}}}'
            : '\ufeff# original 雪😀\r\nopenapi: $version\r\ninfo: {title: "Copy data", version: "1"}\npaths:\n  /items:\n    get:\n      responses:\n        "200":\n          description: "Response 雪😀"\n          content:\n            application/json:\n              schema: false\n              examples:\n                External: {externalValue: "./payload.txt#opaque%7E%2Fdata"}\n                Literal:\n                  value: {externalValue: "payload data", number: 900719925474099312345678901} # exact';
        final targetSource = json
            ? '{"openapi":"$version","info":{"title":"Shared","version":"1"},"paths":{}}'
            : '# shared\r\nopenapi: $version\r\ninfo: {title: Shared, version: "1"}\npaths: {}';
        await root.writeAsString(source);
        await destination.writeAsString(targetSource);
        await File('${temp.path}/busyapi.yaml').writeAsString(
          'version: 1\nroots: [{name: Main, path: root.$ext}, {name: Shared, path: models/shared.$ext}]\n',
        );
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(root.uri.toString());
        const pointer = '/paths/~1items/get/responses/200';
        final plan = await project.planComponentExtraction(
          {
            'root': buffer.id,
            'resource': buffer.id,
            'generation': buffer.generation,
            'pointer': pointer,
          },
          'SharedResponse',
          destinationResource: destination.uri.toString(),
        );
        expect(await destination.readAsBytes(), utf8.encode(targetSource));
        await project.applyRefactoring(plan);
        final definition = project.store.get(destination.uri.toString()),
            extracted = definition.text;
        final expected = '${temp.uri}payload.txt#opaque%7E%2Fdata';
        expect(extracted, contains(expected));
        expect(extracted, contains('900719925474099312345678901'));
        expect(extracted, contains('payload data'));
        project.store.undo();
        expect(buffer.bytes(), utf8.encode(source));
        expect(definition.bytes(), utf8.encode(targetSource));
        project.store.redo();
        expect(definition.text, extracted);
        final referenced = buffer.text;
        await project.applyRefactoring(
          await project.planReferenceInlining({
            'root': buffer.id,
            'resource': buffer.id,
            'generation': buffer.generation,
            'pointer': pointer,
          }),
        );
        expect(buffer.text, contains(expected));
        expect(definition.text, extracted);
        final inlined = buffer.text;
        project.store.undo();
        expect(buffer.text, referenced);
        project.store.redo();
        expect(buffer.text, inlined);
        expect((await project.check(buffer.id))['complete'], true);
        expect(await File('${temp.path}/payload.txt').exists(), false);
        final publication = PublicationStore('${temp.path}/state');
        expect(
          (await publication.save(project, [buffer, definition])).complete,
          true,
        );
        expect(await root.readAsBytes(), buffer.bytes());
        expect(await destination.readAsBytes(), definition.bytes());
        final reopened = await BusyProject.open(temp.path, engine);
        addTearDown(reopened.close);
        expect((await reopened.buffer(root.uri.toString())).text, inlined);
        expect(
          (await reopened.buffer(destination.uri.toString())).text,
          extracted,
        );
      });
    }
  }
}
