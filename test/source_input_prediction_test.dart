import 'dart:math';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tools/source_input_prediction.dart';

void main() {
  test('passive full-source predictions independently reconstruct folded bounded windows', () {
    final random = Random(863);
    final source = List.generate(
      2048,
      (i) => String.fromCharCode(65 + i % 26),
    ).join();
    for (var run = 0; run < 300; run++) {
      final start = random.nextInt(source.length),
          end = start + random.nextInt(source.length - start + 1);
      final edit = TextEdit(
        buffer: 'source',
        generation: 3,
        start: start,
        end: end,
        expected: source.substring(start, end),
        replacement: '雪😀${'new' * random.nextInt(20)}',
      );
      final prediction = SourceInputPrediction(source, edit);
      final full = source.replaceRange(start, end, edit.replacement);
      final hidden = List.generate(8, (_) {
        final from = random.nextInt(full.length);
        return SourceRange(from, from + random.nextInt(full.length - from + 1));
      });
      final map = SourceFoldMap(full.length, hidden),
          window = map.window(full, 0, map.visibleLength);
      expect(prediction.project(window.pieces), window.text);
      expect(prediction.accepted(edit), true);
      expect(
        prediction.accepted(
          TextEdit(
            buffer: 'source',
            generation: 4,
            start: start,
            end: end,
            expected: edit.expected,
            replacement: edit.replacement,
          ),
        ),
        false,
      );
    }
    expect(
      () => SourceInputPrediction(
        source,
        TextEdit(
          buffer: 'source',
          generation: 3,
          start: 0,
          end: 1,
          expected: 'wrong',
          replacement: 'x',
        ),
      ),
      throwsArgumentError,
    );
    final run = SourceInputPrediction(
      'head xxxx tail',
      TextEdit(
        buffer: 'source',
        generation: 1,
        start: 6,
        end: 6,
        expected: '',
        replacement: 'x',
      ),
    );
    expect(
      run.accepted(
        TextEdit(
          buffer: 'source',
          generation: 1,
          start: 9,
          end: 9,
          expected: '',
          replacement: 'x',
        ),
      ),
      true,
    );
    expect(
      run.accepted(
        TextEdit(
          buffer: 'source',
          generation: 1,
          start: 9,
          end: 9,
          expected: '',
          replacement: 'y',
        ),
      ),
      false,
    );
  });
}
