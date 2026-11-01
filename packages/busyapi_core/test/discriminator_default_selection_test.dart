import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format fallback selection retains captured ownership', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-default-selection-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final file = File('${directory.path}/api.$format');
        final models = File('${directory.path}/models.json');
        const part = '{"Fallback":{"type":"object","properties":{"value":{"type":"string"}}}}';
        await models.writeAsString(part);
        final original =
            '${format == 'yaml' ? '# keep source\r\n' : ''}${jsonEncode({
              'openapi': version,
              'info': {'title': 'Fallback selection', 'version': 'business'},
              'paths': {},
              'components': {
                'schemas': {
                  'Parent': {
                    'type': 'object',
                    'oneOf': [
                      {r'$ref': 'models.json#/Fallback'},
                      {r'$ref': '#/components/schemas/Cat'},
                    ],
                    'discriminator': {
                      'propertyName': 'kind',
                      'defaultMapping': 'Unrelated',
                    },
                  },
                  'Cat': {'type': 'object', 'required': ['kind']},
                  'Unrelated': {'type': 'object'},
                },
              },
            })}\r\n';
        await file.writeAsString(original);
        var project = await BusyProject.open(file.path, engine);
        addTearDown(() => project.close());
        final root = project.roots.single.id;
        const pointer = '/components/schemas/Parent/discriminator';
        Future<ReferenceChoicePage> choices() => project.referenceChoices(
          root, root, pointer, keyword: 'defaultMapping', query: 'Fallback',
        );
        final page = await choices();
        expect(page.result['count'], 1);
        expect((page.result['entries'] as List).single['target']['resource'], models.uri.toString());
        final plan = await project.planReferenceSelection(page, 0);
        await expectLater(
          project.planReferenceSelection(page, 0, cancelled: () => true),
          throwsA(isA<CoreFailure>().having((failure) => failure.code, 'code', 'cancelled')),
        );
        await project.applyRefactoring(plan);
        final changed = (await project.buffer(root)).text;
        expect(changed, original.replaceFirst('Unrelated', 'models.json#/Fallback'));
        expect(await file.readAsString(), original);
        expect(await models.readAsString(), part);
        project.store.undo();
        expect((await project.buffer(root)).text, original);
        project.store.redo();
        expect((await project.buffer(root)).text, changed);

        final stale = await choices();
        project.store.replace(models.uri.toString(), part.replaceFirst('string', 'integer'));
        expect(stale.current, false);
        await expectLater(
          project.planReferenceSelection(stale, 0),
          throwsA(isA<CoreFailure>().having((failure) => failure.code, 'code', 'reference.choice.stale')),
        );
        project.store.undo();
        final review = await project.check(root);
        expect(review['complete'], true, reason: '${review['findings']}');
        expect((review['findings'] as List).where((finding) =>
            (finding['code'] as String).startsWith('discriminator.default-mapping.')), isEmpty);
        expect((await PublicationStore('${directory.path}/publication').save(
          project, project.store.buffers.values,
        )).complete, true);
        project.close();
        project = await BusyProject.open(file.path, engine);
        final reopened = await project.check(root);
        expect(reopened['complete'], true, reason: '${reopened['findings']}');
        final fallback = (reopened['references'] as List).singleWhere(
          (reference) => reference['keyword'] == 'defaultMapping',
        );
        expect(fallback['targetResource'], models.uri.toString());
        expect(fallback['targetPointer'], '/Fallback');
        expect(await models.readAsString(), part);
      });
    }
  }
}
