// Headless allocation/index diagnosis. These CPU times do not measure UI paint.
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';

Map<String, Object> statistics(List<int> times) {
  times.sort();
  return {
    'count': times.length,
    'p50Us': times[times.length ~/ 2],
    'p95Us': times[(times.length * .95).ceil() - 1],
    'maxUs': times.last,
  };
}

void main(List<String> args) {
  final retained = args.length == 3 && args[1] == '--retained-files'
      ? int.tryParse(args[2])
      : 0;
  if ((args.length != 1 && args.length != 3) ||
      retained == null ||
      retained < 0 ||
      retained > 400 ||
      args.length == 3 && args[1] != '--retained-files') {
    stderr.writeln(
      'Usage: dart tools/benchmark_source.dart FIXTURE [--retained-files 0..400]',
    );
    exitCode = 64;
    return;
  }
  final file = File(args.first);
  final bytes = file.readAsBytesSync();
  final original = DocumentBuffer.decode(file.absolute.path, bytes).text;
  final results = <Map<String, Object>>[];
  for (final fraction in [0.0, .5, .99]) {
    var source = original;
    var lines = SourceLineIndex(source);
    var offset = (source.length * fraction).floor();
    if (offset > 0 &&
        offset < source.length &&
        source.codeUnitAt(offset) >= 0xdc00 &&
        source.codeUnitAt(offset) <= 0xdfff) {
      offset--;
    }
    final copying = <int>[], indexing = <int>[];
    final store = BufferStore();
    final buffer = DocumentBuffer.decode(file.absolute.path, bytes);
    store.buffers[buffer.id] = buffer;
    final hidden = <DocumentBuffer>[];
    for (var i = 0; i < retained; i++) {
      final other = DocumentBuffer.decode(
        '${file.absolute.parent.path}/.busyapi-headless-retained-$i.yaml',
        utf8.encode('# exact 雪😀\r\ntype: string'),
      );
      store.buffers[other.id] = other;
      hidden.add(other);
    }
    // Model-only pending deletions: no filesystem operation or publication.
    store.apply(
      [],
      presences: [
        for (final other in hidden)
          BufferPresenceEdit(
            buffer: other.id,
            generation: other.generation,
            expectedPath: other.path,
            expectedText: other.text,
            expectedBom: other.hasBom,
            expectedPresent: true,
            present: false,
          ),
      ],
    );
    final transactions = <int>[];
    // Twenty warmups, then 200 reversible insert/delete edits. This isolates
    // document-string and incremental-index work, without persistence or IPC.
    for (var i = 0; i < 220; i++) {
      final watch = Stopwatch()..start();
      final next = source.replaceRange(
        offset,
        offset + i % 2,
        i % 2 == 0 ? 'x' : '',
      );
      final copied = watch.elapsedMicroseconds;
      final updated = SourceLineIndex.updated(
        previous: lines,
        source: next,
        oldStart: offset,
        oldEnd: offset + i % 2,
      );
      final indexed = watch.elapsedMicroseconds - copied;
      watch.stop();
      source = next;
      lines = updated;
      watch.reset();
      watch.start();
      store.apply([
        TextEdit(
          buffer: buffer.id,
          generation: buffer.generation,
          start: offset,
          end: offset + i % 2,
          expected: i % 2 == 0 ? '' : 'x',
          replacement: i % 2 == 0 ? 'x' : '',
        ),
      ]);
      watch.stop();
      if (i >= 20) {
        copying.add(copied);
        indexing.add(indexed);
        transactions.add(watch.elapsedMicroseconds);
      }
    }
    if (source != original)
      throw StateError('Benchmark did not restore source');
    if (buffer.text != original) {
      throw StateError('Transactions did not restore source');
    }
    store.undo();
    if (buffer.text != original.replaceRange(offset, offset, 'x')) {
      throw StateError('Transaction undo differs');
    }
    store.redo();
    if (buffer.text != original) throw StateError('Transaction redo differs');
    if (hidden.any(
      (b) =>
          b.present ||
          !b.hasFileIntent ||
          !store.ownsFileBuffer(b) ||
          b.text != '# exact 雪😀\r\ntype: string',
    )) {
      throw StateError('Retained file ownership or source changed');
    }
    results.add({
      'fraction': fraction,
      'replacement': statistics(copying),
      'lineIndex': statistics(indexing),
      'coreTransaction': statistics(transactions),
    });
  }
  stdout.writeln(
    jsonEncode({
      'version': 1,
      'kind': 'headless-cpu-only',
      'fixtureBytes': bytes.length,
      'fixtureSha256': contentIdentity(bytes),
      'dart': Platform.version,
      'executable': Platform.resolvedExecutable,
      'warmup': 20,
      'retainedFiles': retained,
      'results': results,
    }),
  );
}
