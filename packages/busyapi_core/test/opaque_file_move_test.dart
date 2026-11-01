import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _ObservedEngine extends EngineProcess {
  _ObservedEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final methods = <String>[];
  final graphInputs = <String>{};
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) {
    methods.add(method);
    for (final value in params['resources'] as List? ?? const []) {
      if (value is Map && value['id'] is String)
        graphInputs.add(value['id'] as String);
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      for (final retained in [false, true]) {
        test(
          'opaque example source $version json=$json retained=$retained preserves working bytes through history and publication',
          () async {
            final temp = await Directory.systemTemp.createTemp(
              'busyapi-opaque-move-',
            );
            addTearDown(() => temp.delete(recursive: true));
            final engine = _ObservedEngine();
            addTearDown(engine.close);
            final ext = json ? 'json' : 'yaml',
                root = File('${temp.path}/root.$ext'),
                data = File('${temp.path}/payload.$ext'),
                destination = File('${temp.path}/moved 雪.$ext');
            final original = json
                ? '{"openapi":"$version","info":{"title":"Opaque","version":"1"},"paths":{},"components":{"examples":{"External":{"externalValue":"payload.$ext#opaque%7E%2Fdata"},"Literal":{"value":{"externalValue":"payload.$ext","\$ref":"payload data"}}}}}'
                : '\ufeff# original root\r\nopenapi: $version\ninfo: {title: Opaque, version: "1"}\npaths: {}\ncomponents:\n  examples:\n    External: {externalValue: "payload.$ext#opaque%7E%2Fdata"} # exact\n    Literal: {value: {externalValue: "payload.$ext", \$ref: "payload data"}}';
            const payload =
                '\ufeff{"openapi":"3.2.1","\$self":"not a URI","paths": { deliberately invalid data\r\n900719925474099312345678901 雪😀';
            await root.writeAsString(original);
            await data.writeAsString(payload);
            await File('${temp.path}/busyapi.yaml').writeAsString(
              'version: 1\nroots: [{name: Main, path: root.$ext}]\nunknown: {number: 900719925474099312345}\n',
            );
            final project = await BusyProject.open(temp.path, engine);
            addTearDown(project.close);
            final rootBuffer = await project.buffer(root.uri.toString()),
                buffer = await project.buffer(data.uri.toString());
            project.store.replace(
              buffer.id,
              '${buffer.text}\nunsaved exact example',
            );
            final working = buffer.bytes(), beforeRoot = rootBuffer.text;
            final plan = await project.planFileMove(
              buffer.id,
              destination.path,
              retainIdentity: retained,
            );
            expect(plan.result['file']['opaque'], true);
            expect(plan.result['blockers'], isEmpty);
            expect(
              engine.graphInputs,
              isNot(contains(data.uri.toString())),
              reason: 'The explicit opaque source is not admitted as an API/schema graph input',
            );
            expect(await destination.exists(), false);
            expect(await data.readAsBytes(), utf8.encode(payload));
            await project.applyRefactoring(plan);
            final afterRoot = rootBuffer.text;
            expect(
              rootBuffer.text,
              contains(
                retained
                    ? 'payload.$ext#opaque%7E%2Fdata'
                    : 'moved%20%E9%9B%AA.$ext#opaque%7E%2Fdata',
              ),
            );
            expect(buffer.bytes(), working);
            expect(buffer.id, destination.uri.toString());
            project.store.undo();
            expect(rootBuffer.text, beforeRoot);
            expect(buffer.id, data.uri.toString());
            expect(buffer.bytes(), working);
            project.store.redo();
            expect(rootBuffer.text, afterRoot);
            expect(buffer.id, destination.uri.toString());
            expect(buffer.bytes(), working);
            final publication = PublicationStore('${temp.path}/state');
            expect((await publication.save(project, [buffer])).complete, true);
            expect(await destination.readAsBytes(), working);
            expect(await data.exists(), false);
            expect(await root.readAsBytes(), rootBuffer.bytes());
            expect(engine.methods, isNot(contains('govern')));
            final reopened = await BusyProject.open(temp.path, engine);
            addTearDown(reopened.close);
            expect(
              (await reopened.check(root.uri.toString()))['complete'],
              true,
            );
            expect(
              (await reopened.buffer(destination.uri.toString())).bytes(),
              working,
            );
            if (retained)
              expect(
                reopened.approvedResources[data.uri.toString()],
                destination.uri.toString(),
              );
          },
        );
      }
    }
  }
  for (final changed in ['source', 'consumer', 'policy'])
    test('later $changed rejects an opaque move before any proposed mutation', () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-opaque-stale-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final engine = _ObservedEngine();
      addTearDown(engine.close);
      final root = File('${temp.path}/root.json'),
          data = File('${temp.path}/payload.json');
      const source =
          '{"openapi":"3.2.1","info":{"title":"Stale","version":"1"},"paths":{},"components":{"examples":{"External":{"externalValue":"payload.json"}}}}';
      await root.writeAsString(source);
      await data.writeAsString('opaque invalid data: [');
      final project = await BusyProject.open(root.path, engine);
      addTearDown(project.close);
      final a = await project.buffer(root.uri.toString()),
          b = await project.buffer(data.uri.toString());
      final plan = await project.planFileMove(b.id, '${temp.path}/new.json');
      if (changed == 'source') await data.writeAsString('new external bytes');
      if (changed == 'consumer') project.store.replace(a.id, '${a.text} ');
      if (changed == 'policy')
        await File('${temp.path}/.spectral.yaml').writeAsString('rules: {}\n');
      final beforeA = a.text, beforeB = b.text;
      await expectLater(
        project.applyRefactoring(plan),
        throwsA(isA<CoreFailure>()),
      );
      expect(a.text, beforeA);
      expect(b.id, data.uri.toString());
      expect(b.text, changed == 'source' ? 'new external bytes' : beforeB);
      expect(await File('${temp.path}/new.json').exists(), false);
      expect(await root.readAsString(), source);
    });
  for (final content in [
    'rules: {}\n',
    'rules: [\n',
    'functionsDir: ./unapproved\nrules: {}\n',
  ])
    test(
      'governance inputs or incomplete footprint block a move without executing rules: $content',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-opaque-policy-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = _ObservedEngine();
        addTearDown(engine.close);
        await File('${temp.path}/root.yaml').writeAsString(
          'openapi: 3.2.1\ninfo: {title: Policy, version: "1"}\npaths: {}\n',
        );
        final policy = File('${temp.path}/.spectral.yaml');
        await policy.writeAsString(content);
        final project = await BusyProject.open(
          '${temp.path}/root.yaml',
          engine,
        );
        addTearDown(project.close);
        final plan = await project.planFileMove(
          policy.uri.toString(),
          '${temp.path}/moved.yaml',
        );
        expect(
          (plan.result['blockers'] as List).any(
            (entry) =>
                entry['code'] == 'file.move.policy-consumer' ||
                entry['code'] == 'file.move.policy-analysis',
          ),
          true,
        );
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(isA<CoreFailure>()),
        );
        expect(await policy.readAsString(), content);
        expect(await File('${temp.path}/moved.yaml').exists(), false);
        expect(engine.methods, isNot(contains('govern')));
      },
    );
  test('the manifest cannot become an opaque contract move target', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-manifest-move-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = _ObservedEngine();
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Reserved',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    await expectLater(
      project.planFileMove(
        File('${temp.path}/busyapi.yaml').uri.toString(),
        '${temp.path}/new.yaml',
      ),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'file.move.configuration',
        ),
      ),
    );
  });
}
