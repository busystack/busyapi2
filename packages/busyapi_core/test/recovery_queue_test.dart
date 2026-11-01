import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'worker recovery freezes fields and retirement follows in-flight encoding',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-recovery-worker-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final store = RecoveryStore(temp.path);
      final b = DocumentBuffer.decode('/tmp/large.yaml', utf8.encode('saved'));
      b.update('😀\r\n' * 300000);
      final capturedText = b.text;
      final draft = PropertySession(
        root: b.id,
        buffer: b.id,
        generation: b.generation,
        pointer: '/info',
        range: [0, 0],
        expected: '',
      )..values['title'] = 'captured';
      final saving = store.persist(b, draft: draft);
      draft.values['title'] = 'later';
      b.update('later source');
      await saving;
      final file = Directory(temp.path).listSync().whereType<File>().single;
      final record = jsonDecode(await file.readAsString()) as Map;
      expect(record['text'], capturedText);
      expect(record['draft']['values']['title'], 'captured');
      b.update(capturedText);
      final encoding = store.persist(b);
      // Run the worker before queuing retirement; the final record must be gone
      // even when an already-captured older generation is being encoded.
      await Future<void>.delayed(Duration.zero);
      final retiring = store.retire(b.id);
      await Future.wait([encoding, retiring]);
      expect(Directory(temp.path).listSync(), isEmpty);
    },
  );
  test('rapid checkpoints and retirements coalesce without corrupting the latest draft', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-recovery-queue-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final store = RecoveryStore(temp.path);
    final b = DocumentBuffer.decode('/tmp/queue.yaml', utf8.encode('saved'));
    final work = <Future<void>>[];
    for (var i = 0; i < 30; i++) {
      b.update('draft $i');
      work.add(store.persist(b));
    }
    await Future.wait(work);
    final record = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.json'));
    expect(
      (jsonDecode(await record.readAsString()) as Map)['text'],
      'draft 29',
    );
    final retirement = store.retire(b.id);
    b.update('newer draft');
    final checkpoint = store.persist(b);
    await Future.wait([retirement, checkpoint]);
    final newer = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.json'));
    expect(
      (jsonDecode(await newer.readAsString()) as Map)['text'],
      'newer draft',
    );
    await store.retire(b.id);
    expect(
      Directory(temp.path)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json')),
      isEmpty,
    );
  });
  test('a checkpoint enqueued at drain completion is persisted before its returned future succeeds', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-recovery-queue-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/root.yaml');
    await source.writeAsString('saved\n');
    final buffer = DocumentBuffer.decode(
      source.path,
      await source.readAsBytes(),
    );
    final buffers = BufferStore()..buffers[buffer.id] = buffer;
    buffers.replace(buffer.id, 'first unsaved\n');
    Future<void>? later;
    var queued = false;
    late RecoveryStore recovery;
    recovery = RecoveryStore(
      '${temp.path}/private-recovery',
      onCheckpointPhase: (phase) {
        if (phase == 'drain:end' && !queued) {
          queued = true;
          scheduleMicrotask(() {
            buffers.replace(buffer.id, 'latest unsaved 雪😀\n');
            later = recovery.persist(buffer);
          });
        }
      },
    );
    await recovery.persist(buffer);
    await Future<void>.delayed(Duration.zero);
    expect(later, isNotNull);
    await later;
    final records = [
      for (final entry in Directory(
        recovery.directory,
      ).listSync().whereType<File>())
        if (entry.path.endsWith('.json'))
          jsonDecode(await entry.readAsString()) as Map,
    ];
    expect(records, hasLength(1));
    expect(records.single['text'], 'latest unsaved 雪😀\n');
    expect(records.single['generation'], buffer.generation);
    expect(await source.readAsString(), 'saved\n');
  });
  test('a superseded checkpoint waiting on inventory does not flush an already obsolete record', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-recovery-coalesced-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final b = DocumentBuffer.decode(
      '${temp.path}/root.yaml',
      utf8.encode('saved'),
    )..update('first');
    late RecoveryStore recovery;
    Future<void>? newer;
    var replaced = false, writes = 0;
    recovery = RecoveryStore(
      '${temp.path}/recovery',
      onCheckpointPhase: (phase) {
        if (phase == 'inventory:end' && !replaced) {
          replaced = true;
          b.update('newest captured 雪😀');
          newer = recovery.persist(b);
        }
        if (phase == 'write:start') writes++;
      },
    );
    await recovery.persist(b);
    await newer;
    expect(
      writes,
      1,
      reason: 'Only the already captured latest record needs a durable write',
    );
    final file = Directory(recovery.directory)
        .listSync()
        .whereType<File>()
        .single;
    expect(
      (jsonDecode(await file.readAsString()) as Map)['text'],
      'newest captured 雪😀',
    );
  });
  test(
    'continuous captured updates cannot starve recovery publication',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-recovery-fairness-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final b = DocumentBuffer.decode(
        '${temp.path}/root.yaml',
        utf8.encode('saved'),
      )..update('initial');
      late RecoveryStore recovery;
      final pending = <Future<void>>[];
      var replaced = 0, inventories = 0, maximum = 0, writes = 0;
      recovery = RecoveryStore(
        '${temp.path}/recovery',
        onCheckpointPhase: (phase) {
          if (phase == 'inventory:end') {
            inventories++;
            if (replaced < 6) {
              b.update('captured ${++replaced} 雪😀');
              pending.add(recovery.persist(b));
            }
          }
          if (phase == 'rename:end') {
            writes++;
            if (inventories > maximum) maximum = inventories;
            inventories = 0;
          }
        },
      );
      await recovery.persist(b);
      await Future.wait(pending);
      expect(maximum, lessThanOrEqualTo(2));
      expect(writes, greaterThanOrEqualTo(3));
      final file = Directory(recovery.directory)
          .listSync()
          .whereType<File>()
          .single;
      final record = jsonDecode(await file.readAsString()) as Map;
      expect(record['text'], 'captured 6 雪😀');
      expect(record['generation'], b.generation);
    },
  );
}
