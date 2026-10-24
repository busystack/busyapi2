import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  DocumentBuffer buffer(String path, [String text = 'title: "雪😀"\r\n']) =>
      DocumentBuffer.decode(path, [239, 187, 191, ...utf8.encode(text)]);
  BufferPathEdit move(DocumentBuffer b, String path) => BufferPathEdit(
    buffer: b.id,
    generation: b.generation,
    expectedPath: b.path,
    expectedText: b.text,
    expectedBom: b.hasBom,
    destination: Uri.file(path).toString(),
    path: path,
  );
  test('virtual paths retain the same physical buffer, bytes, line index and view state', () {
    final b = buffer('/tmp/project/old.yaml'), store = BufferStore();
    store.buffers[b.id] = b;
    final old = b.id, bytes = b.bytes(), lines = b.lines;
    b.selection = const SourceSelection(0, 4);
    b.scroll = 120;
    final generation = b.generation;
    store.apply(const [], paths: [move(b, '/tmp/project/new.yaml')]);
    expect(store.get(b.id), same(b));
    expect(store.buffers.containsKey(old), false);
    expect(b.bytes(), bytes);
    expect(b.lines, same(lines));
    expect(b.selection.base, 0);
    expect(b.selection.extent, 4);
    expect(b.scroll, 120);
    expect(b.generation, generation + 1);
    expect(b.dirty, true);
    expect(b.publishedPath, '/tmp/project/old.yaml');
    final destination = b.id;
    final reverse = store.undo().single;
    expect(reverse.mapResource(destination, '/info'), old);
    expect(b.id, old);
    expect(b.dirty, false);
    expect(b.bytes(), bytes);
    final forward = store.redo().single;
    expect(forward.mapResource(old, '/info'), destination);
    expect(b.id, destination);
    expect(b.bytes(), bytes);
  });
  test('earlier text history remains attached to its physical owner across path undo and redo', () {
    final b = buffer('/tmp/project/old.yaml'), store = BufferStore();
    store.buffers[b.id] = b;
    final original = b.text;
    store.replace(b.id, '$original# changed\n');
    final edited = b.text;
    store.apply(const [], paths: [move(b, '/tmp/project/new.yaml')]);
    store.undo();
    expect(b.text, edited);
    expect(b.path, '/tmp/project/old.yaml');
    store.undo();
    expect(b.text, original);
    store.redo();
    expect(b.text, edited);
    store.redo();
    expect(b.path, '/tmp/project/new.yaml');
    expect(b.text, edited);
  });
  test('a path and cross-buffer source repair are one all-input-verified history step', () {
    final a = buffer('/tmp/project/a.yaml'),
        b = buffer('/tmp/project/b.yaml', 'ref: a.yaml\n');
    final store = BufferStore()..buffers.addAll({a.id: a, b.id: b});
    final original = {a.id: a.bytes(), b.id: b.bytes()};
    final path = move(a, '/tmp/project/moved.yaml');
    final edit = TextEdit(
      buffer: b.id,
      generation: b.generation,
      start: 5,
      end: 11,
      expected: 'a.yaml',
      replacement: 'moved.yaml',
    );
    store.apply([edit], paths: [path]);
    expect(b.text, 'ref: moved.yaml\n');
    expect(a.path, '/tmp/project/moved.yaml');
    store.undo();
    for (final entry in original.entries) {
      expect(store.get(entry.key).bytes(), entry.value);
    }
    store.redo();
    expect(b.text, 'ref: moved.yaml\n');
    expect(a.path, '/tmp/project/moved.yaml');
  });
  test(
    'no-op, collisions and stale source cannot partially rename a buffer',
    () {
      final a = buffer('/tmp/project/a.yaml'),
          b = buffer('/tmp/project/b.yaml');
      final store = BufferStore()..buffers.addAll({a.id: a, b.id: b});
      store.apply(const [], paths: [move(a, a.path)]);
      expect(store.canUndo, false);
      expect(
        () => store.apply(const [], paths: [move(a, b.path)]),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'file.collision'),
        ),
      );
      final stale = move(a, '/tmp/project/new.yaml');
      store.replace(a.id, 'changed');
      expect(
        () => store.apply(const [], paths: [stale]),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'file.stale')),
      );
      expect(a.path, '/tmp/project/a.yaml');
      expect(b.text, contains('雪😀'));
      final valid = move(a, '/tmp/project/new.yaml');
      expect(
        () => store.apply(
          [
            TextEdit(
              buffer: b.id,
              generation: b.generation,
              start: 0,
              end: 1,
              expected: 'wrong',
              replacement: 'x',
            ),
          ],
          paths: [valid],
        ),
        throwsA(isA<CoreFailure>()),
      );
      expect(a.path, '/tmp/project/a.yaml');
    },
  );
  test(
    'undo refuses a foreign occupant and does not consume its history entry',
    () {
      final b = buffer('/tmp/project/old.yaml'), store = BufferStore();
      store.buffers[b.id] = b;
      final old = b.id;
      store.apply(const [], paths: [move(b, '/tmp/project/new.yaml')]);
      final foreign = buffer('/tmp/project/old.yaml', 'foreign\n');
      store.buffers[old] = foreign;
      expect(
        store.undo,
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'history.stale'),
        ),
      );
      expect(store.canUndo, true);
      expect(store.get(old), same(foreign));
      expect(b.path, '/tmp/project/new.yaml');
      expect(foreign.text, 'foreign\n');
    },
  );
  test('undo after publication stages the reverse path without rewriting disk ownership', () {
    final b = buffer('/tmp/project/old.yaml'), store = BufferStore();
    store.buffers[b.id] = b;
    store.apply(const [], paths: [move(b, '/tmp/project/new.yaml')]);
    // Simulate only the publication boundary's acknowledged ownership update.
    // Actual anchored file publication is tested separately by the project.
    b.publishedPath = b.path;
    b.baseline = b.text;
    expect(b.dirty, false);
    store.undo();
    expect(b.path, '/tmp/project/old.yaml');
    expect(b.publishedPath, '/tmp/project/new.yaml');
    expect(b.hasPathIntent, true);
    expect(b.dirty, true);
    store.redo();
    expect(b.hasPathIntent, false);
    expect(b.dirty, false);
  });
  test(
    'async snapshots cannot combine a new resource URI with an old generation',
    () async {
      final b = buffer('/tmp/project/old.yaml', 'x: "${'a' * 300000}"\n'),
          store = BufferStore();
      store.buffers[b.id] = b;
      final old = b.id, generation = b.generation;
      final snapshot = b.snapshotAsync();
      store.apply(const [], paths: [move(b, '/tmp/project/new.yaml')]);
      final captured = await snapshot;
      expect(captured['id'], old);
      expect(captured['generation'], generation);
      expect(b.id, isNot(old));
      expect(b.generation, generation + 1);
    },
  );
}
