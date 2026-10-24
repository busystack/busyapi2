// Coordinate mechanics adapted from BusyMark source_hidden_ranges.dart,
// Copyright 2026 BusyStack, Apache-2.0. Modified for immutable, bounded BusyAPI
// source windows and core-owned edits; no Markdown or Flutter dependencies.
import 'model.dart';

enum SourceFoldAffinity { before, after }

/// Read-only offset projection. Hidden ranges never own, delete or serialize
/// source. Only bounded windows are materialized; a folded megabyte is not
/// copied into another editable document or laid out by the input control.
class SourceFoldMap {
  SourceFoldMap(this.length, Iterable<SourceRange> hidden) {
    if (length < 0) throw ArgumentError.value(length, 'length');
    final sorted = hidden.toList();
    if (sorted.length > 20000) {
      throw CoreFailure('fold.limit', 'Too many collapsed source ranges');
    }
    if (sorted.any((r) => r.start < 0 || r.end < r.start || r.end > length)) {
      throw CoreFailure('fold.range', 'Invalid collapsed source range');
    }
    sorted.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : b.end.compareTo(a.end),
    );
    final normalized = <SourceRange>[];
    for (final range in sorted) {
      if (range.start == range.end) continue;
      if (normalized.isNotEmpty && range.start <= normalized.last.end) {
        final previous = normalized.removeLast();
        normalized.add(
          SourceRange(
            previous.start,
            previous.end > range.end ? previous.end : range.end,
          ),
        );
      } else {
        normalized.add(range);
      }
    }
    ranges = List.unmodifiable(normalized);
    final prefix = <int>[0];
    for (final r in ranges) prefix.add(prefix.last + r.end - r.start);
    _removed = List.unmodifiable(prefix);
    _seams = List.unmodifiable([
      for (var i = 0; i < ranges.length; i++) ranges[i].start - prefix[i],
    ]);
  }

  final int length;
  late final List<SourceRange> ranges;
  late final List<int> _removed, _seams;
  int get visibleLength => length - _removed.last;
  bool get folded => ranges.isNotEmpty;

  int _first(int count, bool Function(int index) before) {
    var low = 0, high = count;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (before(middle)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int visibleOffset(int full) {
    full = full.clamp(0, length);
    final index = _first(ranges.length, (i) => ranges[i].end < full);
    if (index == ranges.length) return full - _removed.last;
    return (full < ranges[index].start ? full : ranges[index].start) -
        _removed[index];
  }

  int fullOffset(
    int visible, {
    SourceFoldAffinity affinity = SourceFoldAffinity.after,
  }) {
    visible = visible.clamp(0, visibleLength);
    final index = _first(_seams.length, (i) => _seams[i] < visible);
    if (index < _seams.length && _seams[index] == visible) {
      return affinity == SourceFoldAffinity.before
          ? ranges[index].start
          : ranges[index].end;
    }
    return visible + _removed[index];
  }

  bool hides(int offset) {
    final index = _first(ranges.length, (i) => ranges[i].end <= offset);
    return index < ranges.length && ranges[index].start <= offset;
  }

  bool intersects(int start, int end) {
    final index = _first(ranges.length, (i) => ranges[i].end <= start);
    return index < ranges.length && ranges[index].start < end;
  }

  /// Shift only known accepted edit coordinates. A boundary-crossing edit
  /// expands the affected fold; an internal Design edit retains its view state.
  SourceFoldMap afterEdit(TextEdit edit) {
    if (edit.start < 0 || edit.end < edit.start || edit.end > length) {
      throw CoreFailure('fold.edit', 'Invalid source change for folding');
    }
    final delta = edit.replacement.length - (edit.end - edit.start);
    return SourceFoldMap(length + delta, [
      for (final range in ranges)
        if (edit.end <= range.start)
          SourceRange(range.start + delta, range.end + delta)
        else if (edit.start >= range.end)
          range
        else if (edit.start >= range.start &&
            edit.end <= range.end &&
            !(edit.start == range.start && edit.end == range.end))
          SourceRange(range.start, range.end + delta),
    ]);
  }

  SourceFoldWindow window(String source, int visibleStart, int visibleEnd) {
    if (source.length != length ||
        visibleStart < 0 ||
        visibleEnd < visibleStart ||
        visibleEnd > visibleLength ||
        visibleEnd - visibleStart > 65536) {
      throw CoreFailure('fold.window', 'Invalid or unbounded source window');
    }
    final start = fullOffset(visibleStart, affinity: SourceFoldAffinity.before),
        end = fullOffset(visibleEnd);
    final pieces = <SourceRange>[];
    var cursor = start;
    var index = _first(ranges.length, (i) => ranges[i].end <= start);
    while (index < ranges.length && ranges[index].start < end) {
      final range = ranges[index++];
      if (cursor < range.start) pieces.add(SourceRange(cursor, range.start));
      cursor = range.end;
    }
    if (cursor < end) pieces.add(SourceRange(cursor, end));
    // With no gaps this is the original transparent source windowing path.
    final text = pieces.length == 1
        ? source.substring(pieces.single.start, pieces.single.end)
        : pieces.map((r) => source.substring(r.start, r.end)).join();
    return SourceFoldWindow._(this, visibleStart, start, end, text, pieces);
  }
}

class SourceFoldWindow {
  SourceFoldWindow._(
    this.map,
    this.visibleStart,
    this.start,
    this.end,
    this.text,
    List<SourceRange> pieces,
  ) : pieces = List.unmodifiable(pieces);
  final SourceFoldMap map;
  final int visibleStart, start, end;
  final String text;
  final List<SourceRange> pieces;
  int visibleOffset(int full) =>
      (map.visibleOffset(full) - visibleStart).clamp(0, text.length);
  int fullOffset(
    int visible, {
    SourceFoldAffinity affinity = SourceFoldAffinity.after,
  }) => map.fullOffset(
    visibleStart + visible.clamp(0, text.length),
    affinity: affinity,
  );
}
