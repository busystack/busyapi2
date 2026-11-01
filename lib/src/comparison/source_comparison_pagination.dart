// Pages BusyMark's already aligned comparison; page boundaries are never diff
// inputs. Chunks retain ranges into the complete captured source.
import 'source_comparison.dart';

enum SourceComparisonChunkKind { unchanged, removed, added }

class SourceComparisonChunk {
  const SourceComparisonChunk({
    required this.source,
    required this.start,
    required this.end,
    this.kind = SourceComparisonChunkKind.unchanged,
    this.intraline = const SourceComparisonRange(0, 0),
  });
  final String source;
  final int start, end;
  final SourceComparisonChunkKind kind;
  final SourceComparisonRange intraline;
  int get length => end - start;
  String get text => source.substring(start, end);
}

class SourceComparisonPages {
  SourceComparisonPages(this.comparison, {required this.pageSize})
    : assert(pageSize > 0) {
    final source = comparison.currentInput.source;
    var offset = 0;
    for (final change in comparison.changes) {
      if (change.currentRange.start > offset) {
        _add(
          SourceComparisonChunk(
            source: source,
            start: offset,
            end: change.currentRange.start,
          ),
        );
      }
      _add(
        SourceComparisonChunk(
          source: change.oldText,
          start: 0,
          end: change.oldText.length,
          kind: SourceComparisonChunkKind.removed,
          intraline: change.oldIntralineRange,
        ),
      );
      _add(
        SourceComparisonChunk(
          source: change.currentText,
          start: 0,
          end: change.currentText.length,
          kind: SourceComparisonChunkKind.added,
          intraline: change.currentIntralineRange,
        ),
      );
      offset = change.currentRange.end;
    }
    if (offset < source.length) {
      _add(
        SourceComparisonChunk(
          source: source,
          start: offset,
          end: source.length,
        ),
      );
    }
  }
  final SourceComparison comparison;
  final int pageSize;
  final _chunks = <SourceComparisonChunk>[];
  final _ends = <int>[];
  int get length => _ends.isEmpty ? 0 : _ends.last;
  int get pages => ((length + pageSize - 1) ~/ pageSize).clamp(1, 1 << 30);

  void _add(SourceComparisonChunk chunk) {
    if (chunk.length == 0) return;
    _ends.add(length + chunk.length);
    _chunks.add(chunk);
  }

  List<SourceComparisonChunk> page(int index) {
    RangeError.checkValueInInterval(index, 0, pages - 1, 'index');
    final start = index * pageSize, end = start + pageSize;
    // Locate the first intersecting chunk without walking earlier pages.
    var low = 0, high = _ends.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_ends[middle] <= start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final result = <SourceComparisonChunk>[];
    for (var i = low; i < _chunks.length; i++) {
      final chunk = _chunks[i], offset = i == 0 ? 0 : _ends[i - 1];
      if (offset >= end) break;
      final a = _boundary(
        chunk.source,
        chunk.start + (start - offset).clamp(0, chunk.length),
      );
      final b = _boundary(
        chunk.source,
        chunk.start + (end - offset).clamp(0, chunk.length),
      );
      if (a == b) continue;
      final from = a - chunk.start, size = b - a;
      result.add(
        SourceComparisonChunk(
          source: chunk.source,
          start: a,
          end: b,
          kind: chunk.kind,
          intraline: SourceComparisonRange(
            (chunk.intraline.start - from).clamp(0, size),
            (chunk.intraline.end - from).clamp(0, size),
          ),
        ),
      );
    }
    return result;
  }
}

int _boundary(String text, int offset) =>
    offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff
    ? offset - 1
    : offset;
