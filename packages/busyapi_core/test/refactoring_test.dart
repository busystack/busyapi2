import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  late BusyProject project;
  late String root, part;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-refactor-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
    final file = File('${temp.path}/root.yaml');
    await file.writeAsBytes([
      239,
      187,
      191,
      ...'# retained\r\nopenapi: 3.2.1\r\ninfo: {title: Rename, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    \'Old\':\r\n      type: object\r\n      x-kept: 1.00\r\n      properties: {child: {\$ref: "#/components/schemas/Old"}}\r\n    External: {\$ref: "part.yaml#/Schema"}'
          .codeUnits,
    ]);
    await File('${temp.path}/part.yaml').writeAsString(
      '# fragment\nSchema: {\$ref: "root.yaml#/components/schemas/Old"}\n',
    );
    project = await BusyProject.open(file.path, engine);
    root = project.roots.single.id;
    part = Uri.file('${temp.path}/part.yaml').toString();
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });
  Future<RefactoringPlan> plan() async {
    final b = await project.buffer(root);
    return project.planComponentRename({
      'resource': root,
      'generation': b.generation,
      'pointer': '/components/schemas/Old',
    }, 'New');
  }

  test(
    'review, one-step undo/redo and save/reopen preserve every source style',
    () async {
      final original = await File(Uri.parse(root).toFilePath()).readAsBytes();
      final oldPart = await File(Uri.parse(part).toFilePath()).readAsBytes();
      final review = await plan();
      expect(review.edits, hasLength(2));
      expect(review.result['usages'], hasLength(2));
      expect(await File(Uri.parse(root).toFilePath()).readAsBytes(), original);
      await project.applyRefactoring(review);
      final b = project.store.get(root), fragment = project.store.get(part);
      expect(b.text, contains("'New':"));
      expect(b.text, contains('x-kept: 1.00'));
      expect(b.hasBom, true);
      expect(b.text, isNot(endsWith('\n')));
      expect(fragment.text, contains('root.yaml#/components/schemas/New'));
      final accepted = {
        for (final b in project.store.buffers.values) b.id: b.text,
      };
      project.store.undo();
      expect(b.bytes(), original);
      expect(fragment.bytes(), oldPart);
      project.store.redo();
      for (final e in accepted.entries)
        expect(project.store.get(e.key).text, e.value);
      final publication = PublicationStore('${temp.path}/private-publication');
      expect(
        (await publication.save(
          project,
          project.store.buffers.values,
        )).complete,
        true,
      );
      project.close();
      project = await BusyProject.open(Uri.parse(root).toFilePath(), engine);
      final check = await project.check(root);
      expect(check['status'], 'complete');
      expect(check['findings'], isEmpty);
      for (final e in accepted.entries)
        expect((await project.buffer(e.key)).text, e.value);
    },
  );
  test('a later unsaved consumer rejects the entire captured plan', () async {
    final review = await plan();
    final b = await project.buffer(part);
    project.store.replace(part, '${b.text}# later input\n');
    final before = {for (final b in project.store.buffers.values) b.id: b.text};
    await expectLater(
      project.applyRefactoring(review),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    for (final e in before.entries)
      expect(project.store.get(e.key).text, e.value);
  });
  test(
    'an unopened dependency changed on disk rejects all proposed edits',
    () async {
      final review = await plan();
      expect(project.store.buffers.containsKey(part), false);
      final b = project.store.get(root),
          before = b.text,
          generation = b.generation;
      await File(Uri.parse(part).toFilePath())
          .writeAsString('# external\nSchema: false\n');
      await expectLater(
        project.applyRefactoring(review),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
        ),
      );
      expect(b.text, before);
      expect(b.generation, generation);
      expect(
        await File(Uri.parse(part).toFilePath()).readAsString(),
        '# external\nSchema: false\n',
      );
    },
  );
  test(
    'approval changes and a different project cannot apply a reviewed plan',
    () async {
      final review = await plan();
      await project.approveResource('https://contracts.test/root', root);
      await expectLater(
        project.applyRefactoring(review),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
        ),
      );
      final other = await BusyProject.open(
        Uri.parse(root).toFilePath(),
        engine,
      );
      try {
        await expectLater(
          other.applyRefactoring(review),
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
          ),
        );
      } finally {
        other.close();
      }
    },
  );
}
