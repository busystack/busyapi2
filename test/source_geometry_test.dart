import 'dart:math' as math;

import 'package:busyapi_core/busyapi_core.dart';
import 'package:busyapi/src/source/source_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cached gutter paragraphs match the editable full-text geometry', (
    tester,
  ) async {
    final geometry = SourceGeometry();
    const texts = [
      'first\n\n😀 é 漢字\r\n\$value\nlast',
      'long wrapped 😀 line with several words and punctuation; repeated text '
          'that must occupy several visual rows\r\n\nlast',
      'first\r\nchanged\r\nlast',
      'first\r\nchanged again\r\nlast',
      'last wraps repeatedly with 😀 漢字 and enough words to reach the next row '
          'and another row with the same actual strut',
    ];
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final width in [120.0, 320.0]) {
        for (final text in texts) {
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Builder(
                  builder: (context) {
                    const style = TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.5,
                      leadingDistribution: TextLeadingDistribution.even,
                    );
                    final measured = geometry.measure(
                      context,
                      text,
                      style,
                      width,
                    );
                    final painter = TextPainter(
                      text: TextSpan(text: text, style: style),
                      strutStyle: StrutStyle.fromTextStyle(
                        style,
                        forceStrutHeight: true,
                      ),
                      textDirection: TextDirection.ltr,
                      textHeightBehavior: sourceTextHeightBehavior,
                      textScaler: TextScaler.linear(scale),
                    )..layout(minWidth: width, maxWidth: width);
                    final lines = SourceLineIndex(text);
                    final tops = [
                      for (final line in lines.lines)
                        painter
                            .getOffsetForCaret(
                              TextPosition(offset: line.startOffset),
                              Rect.zero,
                            )
                            .dy,
                    ];
                    for (var i = 0; i < lines.lineCount; i++) {
                      final expected = math.max(
                        scale * 21,
                        (i + 1 < tops.length ? tops[i + 1] : painter.height) -
                            tops[i],
                      );
                      expect(
                        measured[i],
                        closeTo(expected, .001),
                        reason: 'line $i, scale $scale, width $width',
                      );
                    }
                    expect(
                      geometry.measure(context, text, style, width),
                      same(measured),
                    );
                    painter.dispose();
                    return const SizedBox();
                  },
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
  });
}
