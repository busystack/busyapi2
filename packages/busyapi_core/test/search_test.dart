import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  late BusyProject project;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-search-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
    await File('${temp.path}/root.yaml').writeAsString(
      'openapi: 3.2.1\ninfo: {title: Old, version: "1"}\npaths: {}\n',
    );
    await File('${temp.path}/part.json')
        .writeAsString('\ufeff{ "old": "Old 😀", "number": 1.00 }\r\n');
    project = await BusyProject.open(temp.path, engine);
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });

  test('document search captures its source and leaves unrelated edits outside its transaction', () async {
    final root = await project.buffer(project.roots.single.id);
    final part = await project.buffer(
      Uri.file('${temp.path}/part.json').toString(),
    );
    final rootBefore = root.text, partBefore = part.text;
    final rootDisk = File(root.path).readAsBytesSync(),
        partDisk = File(part.path).readAsBytesSync();
    final search = ProjectSearch(project);
    addTearDown(search.cancel);
    final captured = await search.run(
      const SearchOptions('Old'),
      resource: root.id,
    );
    expect(captured.resources.single['id'], root.id);
    expect(captured.matches.single.resource, root.id);
    project.store.replace(part.id, partBefore.replaceFirst('Old', 'Unrelated'));
    expect(captured.current(project.store), true);
    captured.replace(project.store, 'New');
    expect(root.text, rootBefore.replaceFirst('Old', 'New'));
    expect(part.text, partBefore.replaceFirst('Old', 'Unrelated'));
    project.store.undo();
    expect(root.text, rootBefore);
    expect(part.text, partBefore.replaceFirst('Old', 'Unrelated'));
    final stale = await search.run(
      const SearchOptions('Old'),
      resource: root.id,
    );
    project.store.replace(root.id, '$rootBefore\n# changed');
    expect(
      () => stale.replace(project.store, 'New'),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'search.stale')),
    );
    expect(File(root.path).readAsBytesSync(), rootDisk);
    expect(File(part.path).readAsBytesSync(), partDisk);
    final plain = File('${temp.path}/plain.txt');
    await plain.writeAsString('A readable document\n');
    final document = await project.buffer(plain.uri.toString());
    final plainResult = await search.run(
      const SearchOptions('readable'),
      resource: document.id,
    );
    expect(plainResult.matches.single.resource, document.id);
    expect(plainResult.resources.single['id'], document.id);
  });

  test('whole project replacement includes overlays, preserves bytes and uses one undo step', () async {
    final part = await project.buffer(
      Uri.file('${temp.path}/part.json').toString(),
    );
    project.store.replace(
      part.id,
      part.text.replaceFirst('Old 😀', 'Old unsaved 😀'),
    );
    final before = {
      for (final file in project.files) file: File(file).readAsBytesSync(),
    };
    final search = ProjectSearch(project);
    addTearDown(search.cancel);
    final result = await search.run(const SearchOptions('Old'));
    expect(result.matches, hasLength(3));
    expect(result.matches.every((m) => m.line >= 1), true);
    final texts = {for (final b in project.store.buffers.values) b.id: b.text};
    result.replace(project.store, 'New');
    expect(project.store.get(part.id).text, contains('New unsaved 😀'));
    expect(project.store.get(part.id).text, contains('1.00'));
    expect(project.store.get(part.id).hasBom, true);
    expect(project.store.get(part.id).text, endsWith('\r\n'));
    for (final entry in before.entries)
      expect(File(entry.key).readAsBytesSync(), entry.value);
    project.store.undo();
    for (final entry in texts.entries)
      expect(project.store.get(entry.key).text, entry.value);
    project.store.redo();
    expect(project.store.get(part.id).text, contains('New unsaved 😀'));
    for (final b in project.store.buffers.values)
      if (b.dirty) await project.save(b);
    expect(File(part.path).readAsBytesSync(), part.bytes());
    expect(
      DocumentBuffer.decode(part.path, File(part.path).readAsBytesSync()).text,
      part.text,
    );
  });
  test('invalid regex, resource limits, zero-length matches and literal replacements are explicit', () async {
    final search = ProjectSearch(project);
    addTearDown(search.cancel);
    await expectLater(
      search.run(const SearchOptions('[', regex: true)),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'search.pattern'),
      ),
    );
    final result = await search.run(
      const SearchOptions('(?=Old)', regex: true, caseSensitive: true),
    );
    expect(result.matches, hasLength(2));
    expect(result.matches.every((m) => m.start == m.end), true);
    result.replace(project.store, r'$1');
    expect(
      project.store.buffers.values.where((b) => b.text.contains(r'$1Old')),
      hasLength(2),
    );
    final root = project.store.buffers.values.first;
    project.store.replace(root.id, 'x' * 20001);
    await expectLater(
      search.run(const SearchOptions('x')),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'limit.search.matches',
        ),
      ),
    );
  });
  test(
    'replacement expansion is bounded before constructing its output',
    () async {
      final root = await project.buffer(project.roots.single.id);
      project.store.replace(root.id, 'Old\n' * 19999);
      final search = ProjectSearch(project);
      addTearDown(search.cancel);
      final result = await search.run(
        const SearchOptions('Old', caseSensitive: true),
      );
      expect(result.matches, hasLength(20000));
      final before = {
        for (final b in project.store.buffers.values)
          b.id: (text: b.text, generation: b.generation),
      };
      expect(
        () => result.replace(project.store, 'x' * 4000),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'limit.transaction'),
        ),
      );
      for (final entry in before.entries) {
        expect(project.store.get(entry.key).text, entry.value.text);
        expect(project.store.get(entry.key).generation, entry.value.generation);
      }
      project.store.undo();
      expect(root.text, contains('openapi:'));
    },
  );
  test('stale results cannot change any resource, and cancellation remains reusable', () async {
    final search = ProjectSearch(project);
    addTearDown(search.cancel);
    final result = await search.run(const SearchOptions('Old'));
    final part = project.store.get(
      Uri.file('${temp.path}/part.json').toString(),
    );
    project.store.replace(part.id, '${part.text}\nnew input');
    final before = {for (final b in project.store.buffers.values) b.id: b.text};
    expect(
      () => result.replace(project.store, 'replacement'),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'search.stale')),
    );
    for (final entry in before.entries)
      expect(project.store.get(entry.key).text, entry.value);
    final running = search.run(const SearchOptions('Old'));
    search.cancel();
    await expectLater(
      running,
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'search.cancelled'),
      ),
    );
    expect((await search.run(const SearchOptions('Old'))).matches, isNotEmpty);
  });
  test('all 261 reviewed occurrences retain context, reject a late stale buffer and save/reopen exactly', () async {
    final partFile = File('${temp.path}/part.json');
    await partFile.writeAsString(
      '\ufeff{ "values": [\r\n${List.generate(80, (i) => '  "Old 😀 $i"').join(',\r\n')}\r\n], "number": 1.00 }',
    );
    final lastFile = File('${temp.path}/z-last.yaml');
    await lastFile.writeAsString(
      '# leading context\r\n${List.generate(180, (i) => 'item$i: "Old 😀 $i" # retained').join('\n')}\r\n# trailing context',
    );
    // Discovery is an explicit project-open boundary, just like the GUI.
    project.close();
    project = await BusyProject.open(temp.path, engine);
    final search = ProjectSearch(project);
    addTearDown(search.cancel);
    final result = await search.run(
      const SearchOptions('Old', caseSensitive: true),
    );
    expect(result.matches, hasLength(261));
    final last = result.matches.last;
    expect(last.resource, Uri.file(lastFile.path).toString());
    expect(last.line, 181);
    final preview = result.preview(last, r'New $1');
    expect(
      preview.page(false, 0),
      contains('item179: "Old 😀 179" # retained'),
    );
    expect(
      preview.page(true, 0),
      contains(r'item179: "New $1 😀 179" # retained'),
    );
    expect(preview.page(false, 0), contains('# trailing context'));
    final originals = {
      for (final b in project.store.buffers.values) b.id: b.text,
    };
    final lastBuffer = project.store.get(last.resource);
    project.store.replace(
      last.resource,
      '${lastBuffer.text}\n# external draft',
    );
    final stale = {for (final b in project.store.buffers.values) b.id: b.text};
    expect(
      () => result.replace(project.store, 'New'),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'search.stale')),
    );
    expect({for (final b in project.store.buffers.values) b.id: b.text}, stale);
    project.store.undo();
    final fresh = await search.run(
      const SearchOptions('Old', caseSensitive: true),
    );
    fresh.replace(project.store, r'New $1');
    final expected = {
      for (final entry in originals.entries)
        entry.key: entry.value.replaceAll('Old', r'New $1'),
    };
    expect({
      for (final b in project.store.buffers.values) b.id: b.text,
    }, expected);
    project.store.undo();
    expect({
      for (final b in project.store.buffers.values) b.id: b.text,
    }, originals);
    project.store.redo();
    for (final b in project.store.buffers.values) {
      if (b.dirty) await project.save(b);
    }
    expect((await partFile.readAsBytes()).take(3), [0xef, 0xbb, 0xbf]);
    project.close();
    project = await BusyProject.open(temp.path, engine);
    for (final entry in expected.entries) {
      expect((await project.buffer(entry.key)).text, entry.value);
    }
    expect(fresh.timings!.collectionMicros, greaterThan(0));
    expect(fresh.timings!.workerMicros, greaterThan(0));
    expect(fresh.timings!.resultMicros, greaterThan(0));
  });
  test('context pages preserve long multiline Unicode matches without truncation or splitting scalars', () {
    final before = '${'😀abc\r\n' * 600}END', after = '${'新😀\n' * 900}FINISH';
    final preview = SearchChangePreview(
      'preceding line\n',
      before,
      after,
      '\nfollowing line',
    );
    for (final replaced in [false, true]) {
      final chunks = List.generate(
        preview.pages(replaced),
        (i) => preview.page(replaced, i),
      );
      expect(
        chunks.join(),
        'preceding line\n${replaced ? after : before}\nfollowing line',
      );
      for (final chunk in chunks) {
        expect(chunk.runes, isNot(contains(0xfffd)));
      }
    }
  });
  test(
    'clean reloads performed during collection notify the resource owner',
    () async {
      final root = await project.buffer(project.roots.single.id);
      final changed = <String>[];
      final search = ProjectSearch(project, onResourceRefreshed: changed.add);
      addTearDown(search.cancel);
      await File(root.path)
          .writeAsString(root.text.replaceFirst('Old', 'Reloaded'));
      final result = await search.run(const SearchOptions('Reloaded'));
      expect(result.matches.single.resource, root.id);
      expect(changed, [root.id]);
      expect(root.text, contains('Reloaded'));
      search.cancel();
      expect(root.dirty, false);
    },
  );
  test(
    'a catastrophic regex is killed instead of occupying the UI isolate',
    () async {
      final root = await project.buffer(project.roots.single.id);
      project.store.replace(root.id, '${'a' * 50000}!');
      final search = ProjectSearch(
        project,
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(search.cancel);
      await expectLater(
        search.run(const SearchOptions(r'^(a+)+$', regex: true)),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'search.timeout'),
        ),
      );
      final next = ProjectSearch(project);
      addTearDown(next.cancel);
      expect((await next.run(const SearchOptions('!'))).matches, hasLength(1));
    },
  );
}
