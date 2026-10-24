import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test('large source splices preserve bytes and shared undo history', () {
    final original = '${'a' * 150000}\r\n😀 é 漢字\n${'z' * 150000}\r';
    final buffer = DocumentBuffer.decode('/tmp/large.yaml', [
      239,
      187,
      191,
      ...utf8.encode(original),
    ]);
    final store = BufferStore()..buffers[buffer.id] = buffer;
    for (final offset in [0, 150002, original.length]) {
      final beforeGeneration = buffer.generation;
      store.apply([
        TextEdit(
          buffer: buffer.id,
          generation: beforeGeneration,
          start: offset,
          end: offset,
          expected: '',
          replacement: 'α😀\r\n',
        ),
      ]);
      final expected = original.replaceRange(offset, offset, 'α😀\r\n');
      expect(buffer.text, expected);
      expect(buffer.lines.source, expected);
      store.undo();
      expect(buffer.bytes(), [239, 187, 191, ...utf8.encode(original)]);
      store.redo();
      expect(buffer.text, expected);
      store.undo();
      expect(buffer.generation, greaterThan(beforeGeneration));
    }
    store.apply([
      TextEdit(
        buffer: buffer.id,
        generation: buffer.generation,
        start: 0,
        end: original.length,
        expected: original,
        replacement: 'field: "😀"\r\n',
      ),
    ]);
    expect(buffer.text, 'field: "😀"\r\n');
    store.undo();
    expect(buffer.bytes(), [239, 187, 191, ...utf8.encode(original)]);
  });
}
