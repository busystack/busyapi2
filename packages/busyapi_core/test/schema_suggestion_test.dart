import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    test(
      'reviewed schema suggestion $version preserves large example bytes through undo save and stale rejection',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-schema-suggestion-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final file = File('${temp.path}/root.json');
        const media =
            '/paths/~1items/post/requestBody/content/application~1json';
        final text =
            '{"openapi":"$version","info":{"title":"T","version":"1"},"paths":{"/items":{"post":{"requestBody":{"content":{"application/json":{"example":{"id":9007199254740993,"price":1.00,"message":"😀\\nkept","\$ref":"literal payload"}}}},"responses":{"204":{"description":"Bodyless"}}}}}}\r\n';
        await file.writeAsString('\ufeff$text');
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id,
            buffer = await project.buffer(project.roots.single.id);
        final page = await project.inspectObject(root, root, media);
        Future<RefactoringPlan> plan() =>
            project.planSchemaSuggestion(root, root, '$media/example', {
              'resource': root,
              'generation': buffer.generation,
              'pointer': media,
              'range': page['range'],
            });
        final proposal = await plan();
        expect(buffer.text, text);
        expect(proposal.result['kind'], 'schema-suggestion');
        expect(
          proposal.result['schema']['properties']['id']['type'],
          'integer',
        );
        expect(
          proposal.result['schema']['properties']['price']['type'],
          'integer',
        );
        expect(
          proposal.result['schema']['properties'].containsKey(r'$ref'),
          true,
        );
        await project.applyRefactoring(proposal);
        final accepted = buffer.bytes();
        expect(buffer.text, contains('"id":9007199254740993,"price":1.00'));
        expect(buffer.text, contains('"204":{"description":"Bodyless"}'));
        expect(buffer.text, endsWith('\r\n'));
        expect(buffer.hasBom, true);
        project.store.undo();
        expect(buffer.text, text);
        project.store.redo();
        expect(buffer.bytes(), accepted);
        await project.save(buffer);
        expect(await file.readAsBytes(), accepted);
        project.store.undo();
        final current = await project.inspectObject(root, root, media);
        final stale = await project.planSchemaSuggestion(
          root,
          root,
          '$media/example',
          {
            'resource': root,
            'generation': buffer.generation,
            'pointer': media,
            'range': current['range'],
          },
        );
        project.store.replace(
          root,
          buffer.text.replaceFirst('9007199254740993', '9007199254740995'),
        );
        final newer = buffer.text;
        await expectLater(
          project.applyRefactoring(stale),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
          ),
        );
        expect(buffer.text, newer);
      },
    );
}
