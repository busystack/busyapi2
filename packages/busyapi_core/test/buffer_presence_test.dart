import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  DocumentBuffer buffer(
    String path, [
    String text = '# 雪😀\r\nvalue: 9007199254740993',
  ]) => DocumentBuffer.decode(path, [239, 187, 191, ...utf8.encode(text)]);
  BufferCreation create(String path, [String text = '# new 雪😀\r\n{}']) =>
      BufferCreation(
        id: Uri.file(path).toString(),
        path: path,
        text: text,
        hasBom: true,
      );
  BufferPresenceEdit presence(DocumentBuffer b, bool present) =>
      BufferPresenceEdit(
        buffer: b.id,
        generation: b.generation,
        expectedPath: b.path,
        expectedText: b.text,
        expectedBom: b.hasBom,
        expectedPresent: b.present,
        present: present,
      );

  test(
    'staged creation has no published owner and is one reversible history step',
    () {
      final store = BufferStore(), addition = create('/tmp/project/new.yaml');
      final changes = <Map<String, String>>[];
      store.onPathsChanged = (paths, _) => changes.add(paths);
      store.apply(const [], creations: [addition], label: 'Create fragment');
      final b = store.get(addition.id), bytes = b.bytes(), lines = b.lines;
      expect(b.present, true);
      expect(b.publishedPresent, false);
      expect(b.hasFileIntent, true);
      expect(b.hasPathIntent, false);
      expect(b.dirty, true);
      expect(store.fileBuffers, contains(same(b)));
      b.selection = const SourceSelection(2, 4);
      b.scroll = 120;
      final generation = b.generation;
      final inverse = store.undo().single;
      expect(inverse.mode, 'removal');
      expect(inverse.resource, addition.id);
      expect(store.buffers.containsKey(addition.id), false);
      expect(() => store.get(addition.id), throwsA(isA<CoreFailure>()));
      expect(b.present, false);
      expect(b.hasFileIntent, false);
      expect(b.dirty, false);
      expect(b.bytes(), bytes);
      expect(b.lines, same(lines));
      expect(b.generation, greaterThan(generation));
      final forward = store.redo().single;
      expect(forward.mode, 'restoration');
      expect(store.get(addition.id), same(b));
      expect(b.bytes(), bytes);
      expect(b.selection.base, 2);
      expect(b.selection.extent, 4);
      expect(b.scroll, 120);
      expect(changes, hasLength(3));
      expect(changes.every((paths) => paths[addition.id] == addition.id), true);
    },
  );

  test('staged deletion retains its exact physical owner and text for undo and redo', () {
    final store = BufferStore(), b = buffer('/tmp/project/model.yaml');
    store.buffers[b.id] = b;
    final bytes = b.bytes(), identity = b.diskIdentity;
    store.apply(const [], presences: [presence(b, false)]);
    expect(store.buffers.containsKey(b.id), false);
    expect(store.fileBuffers, contains(same(b)));
    expect(b.present, false);
    expect(b.publishedPresent, true);
    expect(b.dirty, true);
    expect(b.diskIdentity, identity);
    store.undo();
    expect(store.get(b.id), same(b));
    expect(b.bytes(), bytes);
    expect(b.dirty, false);
    store.redo();
    expect(b.present, false);
    expect(b.bytes(), bytes);
    expect(b.dirty, true);
  });

  test(
    'coupled creation restores before relocation and reverses before removal',
    () {
      final store = BufferStore(),
          source = buffer('/tmp/project/root.yaml'),
          addition = create('/tmp/project/new.yaml');
      store.buffers[source.id] = source;
      final move = SemanticTransition(
        source.id,
        '/inline',
        '',
        destinationResource: addition.id,
      );
      store.apply(const [], creations: [addition], transitions: [move]);
      final inverse = store.undo();
      expect(inverse.map((t) => t.mode), ['relocation', 'removal']);
      expect(inverse.first.resource, addition.id);
      expect(inverse.first.map(''), '/inline');
      expect(store.buffers.containsKey(addition.id), false);
      final forward = store.redo();
      expect(forward.map((t) => t.mode), ['restoration', 'relocation']);
      expect(forward.last.toResource, addition.id);
      expect(forward.last.map('/inline'), '');
      expect(store.buffers.containsKey(addition.id), true);
    },
  );

  test('creation and deletion join source repairs in one all-input-verified transaction', () {
    final store = BufferStore(),
        old = buffer('/tmp/project/old.yaml'),
        entry = buffer('/tmp/project/root.yaml', 'ref: old.yaml\r\n');
    store.buffers.addAll({old.id: old, entry.id: entry});
    final original = entry.bytes(),
        addition = create('/tmp/project/new.yaml', old.text);
    store.apply(
      [
        TextEdit(
          buffer: entry.id,
          generation: entry.generation,
          start: 5,
          end: 13,
          expected: 'old.yaml',
          replacement: 'new.yaml',
        ),
      ],
      creations: [addition],
      presences: [presence(old, false)],
    );
    final created = store.get(addition.id);
    expect(entry.text, 'ref: new.yaml\r\n');
    expect(store.buffers.containsKey(old.id), false);
    store.undo();
    expect(store.get(old.id), same(old));
    expect(entry.bytes(), original);
    expect(store.buffers.containsKey(created.id), false);
    expect(store.canUndo, false);
    store.redo();
    expect(store.get(created.id), same(created));
    expect(entry.text, 'ref: new.yaml\r\n');
    expect(store.buffers.containsKey(old.id), false);
  });

  test('stale or malformed inputs cannot create a buffer or partially delete another', () {
    final store = BufferStore(),
        b = buffer('/tmp/project/old.yaml'),
        entry = buffer('/tmp/project/root.yaml', 'ref: old.yaml');
    store.buffers.addAll({b.id: b, entry.id: entry});
    final captured = presence(b, false),
        addition = create('/tmp/project/new.yaml');
    store.replace(b.id, '${b.text}\n# later');
    final original = entry.bytes();
    expect(
      () => store.apply(
        [
          TextEdit(
            buffer: entry.id,
            generation: entry.generation,
            start: 5,
            end: 13,
            expected: 'old.yaml',
            replacement: 'new.yaml',
          ),
        ],
        creations: [addition],
        presences: [captured],
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(entry.bytes(), original);
    expect(store.buffers.containsKey(addition.id), false);
    expect(b.present, true);
    for (final invalid in [
      BufferCreation(id: addition.id, path: '/tmp/other.yaml', text: '{}'),
      BufferCreation(
        id: 'https://unapproved.invalid/new.yaml',
        path: '/tmp/project/new.yaml',
        text: '{}',
      ),
      BufferCreation(
        id: addition.id,
        path: addition.path,
        text: '{}',
        mode: 4095,
      ),
    ]) {
      expect(
        () => store.apply(
          const [],
          creations: [invalid],
          presences: [presence(b, false)],
        ),
        throwsA(isA<CoreFailure>()),
      );
      expect(b.present, true);
      expect(store.buffers.containsKey(addition.id), false);
    }
  });

  test('no-op presence edits do not create history or change generation', () {
    final store = BufferStore(), b = buffer('/tmp/project/old.yaml');
    store.buffers[b.id] = b;
    final generation = b.generation;
    store.apply(const [], presences: [presence(b, true)]);
    expect(store.canUndo, false);
    expect(b.generation, generation);
    expect(b.dirty, false);
  });

  test('a foreign occupant blocks redo without consuming history or changing either version', () {
    final store = BufferStore(), addition = create('/tmp/project/new.yaml');
    store.apply(const [], creations: [addition]);
    final created = store.get(addition.id);
    store.undo();
    final foreign = buffer(addition.path, '# foreign\n{}');
    store.buffers[foreign.id] = foreign;
    expect(
      store.redo,
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'history.stale',
        ),
      ),
    );
    expect(store.canRedo, true);
    expect(store.get(foreign.id), same(foreign));
    expect(created.present, false);
    expect(created.text, addition.text);
    expect(foreign.text, '# foreign\n{}');
  });

  test('undo after acknowledged publication stages the inverse intent, not imaginary disk ownership', () {
    final store = BufferStore(), addition = create('/tmp/project/new.yaml');
    store.apply(const [], creations: [addition]);
    final b = store.get(addition.id);
    // Only acknowledge ownership here; production publication/restart tests
    // must exercise the real anchored writer and archive boundary separately.
    b.publishedPresent = true;
    expect(b.dirty, false);
    store.undo();
    expect(b.present, false);
    expect(b.publishedPresent, true);
    expect(b.hasFileIntent, true);
    expect(b.dirty, true);
    store.redo();
    expect(b.dirty, false);
    store.apply(const [], presences: [presence(b, false)]);
    b.publishedPresent = false;
    expect(b.dirty, false);
    store.undo();
    expect(b.present, true);
    expect(b.publishedPresent, false);
    expect(b.hasFileIntent, true);
    expect(b.dirty, true);
  });

  test(
    'source history stays with a created buffer across hiding and restoration',
    () {
      final store = BufferStore(), addition = create('/tmp/project/new.yaml');
      store.apply(const [], creations: [addition]);
      final b = store.get(addition.id);
      store.replace(b.id, '${b.text}\n# edited');
      store.undo();
      expect(b.text, addition.text);
      store.undo();
      expect(b.present, false);
      store.redo();
      expect(store.get(b.id), same(b));
      expect(b.text, addition.text);
      store.redo();
      expect(b.text, '${addition.text}\n# edited');
      expect(b.hasBom, true);
    },
  );
  test('a virtual deletion invalidates captured analysis instead of masquerading as an unopened resource', () async {
    final store = BufferStore(), b = buffer('/tmp/project/model.yaml');
    store.buffers[b.id] = b;
    final snapshot = AnalysisSnapshot(root: b.id, resources: [b.snapshot()]);
    expect(snapshot.current(store), true);
    store.apply(const [], presences: [presence(b, false)]);
    expect(snapshot.current(store), false);
    expect(b.snapshot, throwsA(isA<CoreFailure>()));
    await expectLater(b.snapshotAsync(), throwsA(isA<CoreFailure>()));
    store.undo();
    expect(
      snapshot.current(store),
      false,
      reason: 'Restoration advances ownership generation',
    );
    expect(
      AnalysisSnapshot(root: b.id, resources: [b.snapshot()]).current(store),
      true,
    );
  });
  test('a create cannot collide with a move in the same transaction', () {
    final store = BufferStore(),
        b = buffer('/tmp/project/old.yaml'),
        addition = create('/tmp/project/new.yaml');
    store.buffers[b.id] = b;
    final before = b.bytes();
    expect(
      () => store.apply(
        const [],
        creations: [addition],
        paths: [
          BufferPathEdit(
            buffer: b.id,
            generation: b.generation,
            expectedPath: b.path,
            expectedText: b.text,
            expectedBom: b.hasBom,
            destination: addition.id,
            path: addition.path,
          ),
        ],
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(store.get(b.id), same(b));
    expect(b.bytes(), before);
    expect(store.buffers.containsKey(addition.id), false);
    expect(store.canUndo, false);
  });
  test('clean absent owners are released with their last history reference, pending disk intents are retained', () {
    final store = BufferStore(), addition = create('/tmp/project/new.yaml');
    store.apply(const [], creations: [addition]);
    final b = store.get(addition.id);
    store.undo();
    expect(store.fileBuffers, contains(same(b)));
    store.clearHistory();
    expect(store.fileBuffers, isEmpty);
    final existing = buffer('/tmp/project/old.yaml');
    store.buffers[existing.id] = existing;
    store.apply(const [], presences: [presence(existing, false)]);
    store.clearHistory();
    expect(store.fileBuffers, contains(same(existing)));
    existing.publishedPresent = false;
    store.clearHistory();
    expect(store.fileBuffers, isEmpty);
  });
}
