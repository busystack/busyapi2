// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
import 'dart:math' as math;
import 'dart:collection';

class SourceLine {
  const SourceLine({
    required this.number,
    required this.startOffset,
    required this.endOffset,
    required this.endOffsetIncludingLineBreak,
    required this.text,
    required this.lineBreak,
  });

  final int number;
  final int startOffset;
  final int endOffset;
  final int endOffsetIncludingLineBreak;
  final String text;
  final String lineBreak;

  bool get hasLineBreak => lineBreak.isNotEmpty;
}

class SourceLineIndex {
  SourceLineIndex(String source) : source = source {
    _lines = _ChunkedLines.from(_buildLines(source));
  }

  SourceLineIndex._({required this.source, required List<SourceLine> lines})
    : _lines = lines is _ChunkedLines ? lines : _ChunkedLines.from(lines);

  factory SourceLineIndex.updated({
    required SourceLineIndex previous,
    required String source,
    required int oldStart,
    required int oldEnd,
  }) {
    if (previous.source == source) {
      return previous;
    }
    final safeStart = oldStart.clamp(0, previous.source.length).toInt();
    final safeEnd = oldEnd.clamp(safeStart, previous.source.length).toInt();
    final line = previous.lineAtOffset(safeStart);
    final delta = source.length - previous.source.length;
    final changedEnd = safeEnd + delta;
    if (safeEnd <= line.endOffset &&
        changedEnd >= safeStart &&
        !previous.source
            .substring(safeStart, safeEnd)
            .contains(RegExp(r'[\r\n]')) &&
        !source.substring(safeStart, changedEnd).contains(RegExp(r'[\r\n]'))) {
      final table = previous._lines as _ChunkedLines;
      final result = table.replaceLine(
        line.number - 1,
        SourceLine(
          number: line.number,
          startOffset: line.startOffset,
          endOffset: line.endOffset + delta,
          endOffsetIncludingLineBreak: line.endOffsetIncludingLineBreak + delta,
          text: source.substring(line.startOffset, line.endOffset + delta),
          lineBreak: line.lineBreak,
        ),
        delta,
      );
      return SourceLineIndex._(source: source, lines: result);
    }

    // Include the neighboring code units so edits at a CRLF boundary cannot
    // leave one half of the pair in a reused prefix or suffix line.
    final firstChangedIndex =
        previous.lineNumberAtOffset(math.max(0, safeStart - 1)) - 1;
    final lastChangedIndex =
        previous.lineNumberAtOffset(
          math.min(previous.source.length, safeEnd + 1),
        ) -
        1;
    final suffixIndex = lastChangedIndex + 1;
    final segmentStart = previous._lines[firstChangedIndex].startOffset;
    final oldSuffixStart = suffixIndex < previous._lines.length
        ? previous._lines[suffixIndex].startOffset
        : previous.source.length;
    final newSuffixStart = (oldSuffixStart + delta)
        .clamp(segmentStart, source.length)
        .toInt();
    final localLines = _buildLines(
      source.substring(segmentStart, newSuffixStart),
    );
    if (suffixIndex < previous._lines.length &&
        localLines.isNotEmpty &&
        localLines.last.text.isEmpty &&
        !localLines.last.hasLineBreak) {
      localLines.removeLast();
    }

    final result = <SourceLine>[...previous._lines.take(firstChangedIndex)];
    for (final line in localLines) {
      result.add(
        SourceLine(
          number: result.length + 1,
          startOffset: segmentStart + line.startOffset,
          endOffset: segmentStart + line.endOffset,
          endOffsetIncludingLineBreak:
              segmentStart + line.endOffsetIncludingLineBreak,
          text: line.text,
          lineBreak: line.lineBreak,
        ),
      );
    }
    for (final line in previous._lines.skip(suffixIndex)) {
      result.add(
        SourceLine(
          number: result.length + 1,
          startOffset: line.startOffset + delta,
          endOffset: line.endOffset + delta,
          endOffsetIncludingLineBreak: line.endOffsetIncludingLineBreak + delta,
          text: line.text,
          lineBreak: line.lineBreak,
        ),
      );
    }
    if (result.isEmpty) {
      return SourceLineIndex(source);
    }
    return SourceLineIndex._(source: source, lines: result);
  }

  final String source;
  late final List<SourceLine> _lines;

  List<SourceLine> get lines => _lines;

  int get lineCount => _lines.length;

  SourceLine lineAt(int oneBasedLineNumber) {
    final index = (oneBasedLineNumber - 1).clamp(0, _lines.length - 1);
    return _lines[index];
  }

  SourceLine lineAtOffset(int offset) {
    return lineAt(lineNumberAtOffset(offset));
  }

  int lineNumberAtOffset(int offset) {
    if (_lines.isEmpty) {
      return 1;
    }
    final safeOffset = offset.clamp(0, source.length).toInt();
    var low = 0;
    var high = _lines.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final line = _lines[mid];
      if (safeOffset < line.startOffset) {
        high = mid - 1;
      } else if (safeOffset >= line.endOffsetIncludingLineBreak &&
          mid < _lines.length - 1) {
        low = mid + 1;
      } else {
        return line.number;
      }
    }
    return math.max(1, math.min(_lines.length, low + 1));
  }

  int offsetForLine(int oneBasedLineNumber) {
    if (oneBasedLineNumber <= 1) {
      return 0;
    }
    if (oneBasedLineNumber > _lines.length) {
      return source.length;
    }
    return _lines[oneBasedLineNumber - 1].startOffset;
  }

  static List<SourceLine> _buildLines(String source) {
    if (source.isEmpty) {
      return const [
        SourceLine(
          number: 1,
          startOffset: 0,
          endOffset: 0,
          endOffsetIncludingLineBreak: 0,
          text: '',
          lineBreak: '',
        ),
      ];
    }

    final lines = <SourceLine>[];
    var lineStart = 0;
    var lineNumber = 1;
    var index = 0;
    while (index < source.length) {
      final unit = source.codeUnitAt(index);
      if (unit != 10 && unit != 13) {
        index++;
        continue;
      }
      final breakStart = index;
      var breakEnd = index + 1;
      if (unit == 13 &&
          breakEnd < source.length &&
          source.codeUnitAt(breakEnd) == 10) {
        breakEnd++;
      }
      lines.add(
        SourceLine(
          number: lineNumber,
          startOffset: lineStart,
          endOffset: breakStart,
          endOffsetIncludingLineBreak: breakEnd,
          text: source.substring(lineStart, breakStart),
          lineBreak: source.substring(breakStart, breakEnd),
        ),
      );
      lineStart = breakEnd;
      lineNumber++;
      index = breakEnd;
    }

    lines.add(
      SourceLine(
        number: lineNumber,
        startOffset: lineStart,
        endOffset: source.length,
        endOffsetIncludingLineBreak: source.length,
        text: source.substring(lineStart),
        lineBreak: '',
      ),
    );
    return lines;
  }
}

// Fixed-size immutable chunks share untouched line records. Offsets following
// a single-line edit shift at the chunk boundary, rather than allocating one
// new record per remaining document line. Lookups apply the shift once; there
// are no chained edit overlays, and previous indexes remain immutable snapshots.
class _LineChunk {
  const _LineChunk(this.lines, this.shift);
  final List<SourceLine> lines;
  final int shift;
}

SourceLine _shiftLine(SourceLine line, int shift) => shift == 0
    ? line
    : SourceLine(
        number: line.number,
        startOffset: line.startOffset + shift,
        endOffset: line.endOffset + shift,
        endOffsetIncludingLineBreak: line.endOffsetIncludingLineBreak + shift,
        text: line.text,
        lineBreak: line.lineBreak,
      );

class _ChunkedLines extends ListBase<SourceLine> {
  _ChunkedLines(this.chunks, this.length);
  factory _ChunkedLines.from(List<SourceLine> lines) => _ChunkedLines([
    for (var i = 0; i < lines.length; i += chunkSize)
      _LineChunk(
        List.unmodifiable(
          lines.sublist(i, math.min(i + chunkSize, lines.length)),
        ),
        0,
      ),
  ], lines.length);
  static const chunkSize = 128;
  final List<_LineChunk> chunks;
  @override
  final int length;
  @override
  set length(int value) => throw UnsupportedError('Immutable line index');
  @override
  SourceLine operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final chunk = chunks[index ~/ chunkSize];
    return _shiftLine(chunk.lines[index % chunkSize], chunk.shift);
  }

  @override
  void operator []=(int index, SourceLine value) =>
      throw UnsupportedError('Immutable line index');

  _ChunkedLines replaceLine(int index, SourceLine changed, int delta) {
    final at = index ~/ chunkSize, local = index % chunkSize, old = chunks[at];
    final records = <SourceLine>[
      for (var i = 0; i < old.lines.length; i++)
        if (i < local)
          old.lines[i]
        else if (i == local)
          _shiftLine(changed, -old.shift)
        else
          _shiftLine(old.lines[i], delta),
    ];
    return _ChunkedLines([
      ...chunks.take(at),
      _LineChunk(List.unmodifiable(records), old.shift),
      for (final chunk in chunks.skip(at + 1))
        delta == 0 ? chunk : _LineChunk(chunk.lines, chunk.shift + delta),
    ], length);
  }
}
