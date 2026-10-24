import 'package:test/test.dart';
import 'package:busyapi_core/busyapi_core.dart';

void equalIndex(SourceLineIndex actual, SourceLineIndex expected) {
  expect(actual.lineCount, expected.lineCount);
  for (var n = 1; n <= actual.lineCount; n++) {
    final a = actual.lineAt(n), b = expected.lineAt(n);
    expect(
      [
        a.number,
        a.startOffset,
        a.endOffset,
        a.endOffsetIncludingLineBreak,
        a.text,
        a.lineBreak,
      ],
      [
        b.number,
        b.startOffset,
        b.endOffset,
        b.endOffsetIncludingLineBreak,
        b.text,
        b.lineBreak,
      ],
    );
  }
  for (final at in [0, 1, actual.source.length ~/ 2, actual.source.length]) {
    expect(actual.lineNumberAtOffset(at), expected.lineNumberAtOffset(at));
  }
}

void main() {
  test(
    'chunked line shifts preserve earlier snapshots and UTF16 locations',
    () {
      final original = List.generate(
        1500,
        (n) => 'field$n: "😀 value"${['\n', '\r\n', '\r'][n % 3]}',
      ).join();
      final baseline = SourceLineIndex(original);
      var index = baseline;
      for (var i = 0; i < 320; i++) {
        final number = [1, 127, 128, 129, 255, 256, 257, 750, 1499][i % 9];
        final line = index.lineAt(number),
            at = line.startOffset + line.text.indexOf(':') + 3;
        final replacement = i % 2 == 0 ? 'longer value' : 'v';
        final previous = index;
        final text = index.source.replaceRange(at, at + 2, replacement);
        index = SourceLineIndex.updated(
          previous: index,
          source: text,
          oldStart: at,
          oldEnd: at + 2,
        );
        expect(previous.lineAt(number).text, line.text);
        equalIndex(index, SourceLineIndex(text));
      }
      equalIndex(baseline, SourceLineIndex(original));
      expect(index.lines.length, 1501);
      expect(() => index.lines[0] = baseline.lineAt(1), throwsUnsupportedError);
    },
  );

  test(
    'newline and CRLF boundary edits remain correct after many shifted chunks',
    () {
      var index = SourceLineIndex(
        List.generate(400, (n) => 'line$n: 😀\r\n').join(),
      );
      for (var i = 0; i < 90; i++) {
        final line = index.lineAt([2, 128, 129, 256][i % 4]);
        final start = i % 3 == 0 ? line.endOffset : line.startOffset;
        final end = i % 3 == 0 ? start + 1 : start;
        final added = i % 3 == 0 ? '' : 'x\n';
        final next = index.source.replaceRange(start, end, added);
        index = SourceLineIndex.updated(
          previous: index,
          source: next,
          oldStart: start,
          oldEnd: end,
        );
        equalIndex(index, SourceLineIndex(next));
      }
    },
  );
}
