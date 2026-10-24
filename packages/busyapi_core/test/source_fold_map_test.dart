import 'dart:math';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test('folded windows map exact full source and both boundary affinities', () {
    const text = 'header\r\n雪😀 hidden\nclosing\nnext';
    final start = text.indexOf('雪'), end = text.indexOf('closing');
    final map = SourceFoldMap(text.length, [SourceRange(start, end)]);
    final view = map.window(text, 0, map.visibleLength);
    expect(view.text, 'header\r\nclosing\nnext');
    expect(view.fullOffset(start), end);
    expect(view.fullOffset(start, affinity: SourceFoldAffinity.before), start);
    expect(map.visibleOffset(start + 3), start);
    expect(view.visibleOffset(text.indexOf('next')), view.text.indexOf('next'));
    expect(map.hides(start), true);
    expect(map.hides(end), false);
    expect(map.intersects(start, end), true);
    expect(map.intersects(end, text.length), false);
    expect(text.substring(start, end), '雪😀 hidden\n');
  });
  test(
    'large folded source only materializes the requested bounded window',
    () {
      final source = 'start\n${List.filled(1024 * 1024, 'a').join()}\nend\n';
      final end = source.indexOf('end');
      final map = SourceFoldMap(source.length, [SourceRange(6, end)]);
      final window = map.window(source, 0, map.visibleLength);
      expect(window.text, 'start\nend\n');
      expect(window.pieces, hasLength(2));
      expect(window.pieces.last.start, end);
      expect(map.window(source, 6, map.visibleLength).text, 'end\n');
      expect(
        () => SourceFoldMap(source.length, []).window(source, 0, 65537),
        throwsA(isA<CoreFailure>()),
      );
    },
  );
  test('nested and adjacent masks normalize without changing their source', () {
    final map = SourceFoldMap(30, [
      const SourceRange(4, 8),
      const SourceRange(5, 6),
      const SourceRange(8, 10),
      const SourceRange(20, 25),
    ]);
    expect(map.ranges.map((r) => (r.start, r.end)), [(4, 10), (20, 25)]);
    for (var i = 0; i <= 30; i++) {
      final visible = map.visibleOffset(i);
      if (!map.hides(i)) expect(map.fullOffset(visible), i);
    }
    expect(
      () => SourceFoldMap(4, [const SourceRange(2, 5)]),
      throwsA(isA<CoreFailure>()),
    );
  });
  test(
    'accepted source changes shift masks or expand only intersected boundaries',
    () {
      final map = SourceFoldMap(40, [
        const SourceRange(5, 15),
        const SourceRange(25, 35),
      ]);
      SourceFoldMap edited(int start, int end, String replacement) =>
          map.afterEdit(
            TextEdit(
              buffer: 'test',
              generation: 1,
              start: start,
              end: end,
              expected: 'x' * (end - start),
              replacement: replacement,
            ),
          );
      expect(edited(0, 1, 'abc').ranges.map((r) => (r.start, r.end)), [
        (7, 17),
        (27, 37),
      ]);
      expect(edited(8, 9, '😀').ranges.map((r) => (r.start, r.end)), [
        (5, 16),
        (26, 36),
      ]);
      expect(edited(4, 7, '').ranges.map((r) => (r.start, r.end)), [(22, 32)]);
      expect(edited(5, 15, 'replacement').ranges.map((r) => (r.start, r.end)), [
        (26, 36),
      ]);
      expect(map.ranges.map((r) => (r.start, r.end)), [(5, 15), (25, 35)]);
    },
  );
  test(
    'all bounded windows agree with an independent retained-character oracle',
    () {
      final random = Random(531);
      final source = List.generate(
        512,
        (i) => String.fromCharCode(65 + i % 26),
      ).join();
      for (var run = 0; run < 100; run++) {
        final ranges = List.generate(30, (_) {
          final start = random.nextInt(source.length);
          return SourceRange(
            start,
            start + random.nextInt(source.length - start + 1),
          );
        });
        final hidden = List.generate(
          source.length,
          (i) => ranges.any((r) => r.start <= i && i < r.end),
        );
        final expected = [
          for (var i = 0; i < source.length; i++)
            if (!hidden[i]) source[i],
        ].join();
        final map = SourceFoldMap(source.length, ranges);
        expect(map.visibleLength, expected.length);
        for (var sample = 0; sample < 10; sample++) {
          final start = random.nextInt(expected.length + 1),
              end = start + random.nextInt(expected.length - start + 1);
          expect(
            map.window(source, start, end).text,
            expected.substring(start, end),
          );
        }
      }
    },
  );
}
