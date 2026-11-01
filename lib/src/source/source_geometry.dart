// Adapted from BusyMark source_gutter.dart, Copyright 2026 BusyStack, Apache-2.0.
// Modified to measure only BusyAPI's bounded visible source window.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:busyapi_core/busyapi_core.dart';

const sourceTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
  leadingDistribution: TextLeadingDistribution.even,
);

class SourceGeometry {
  String? _text;
  TextStyle? _style;
  double? _width;
  TextScaler? _scaler;
  List<double> _heights = [];
  final Map<String, double> _lineHeights = {};
  List<double> measure(
    BuildContext context,
    String text,
    TextStyle style,
    double width,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    if (_text == text &&
        _style == style &&
        _width == width &&
        _scaler == scaler) {
      return _heights;
    }
    if (_style != style || _width != width || _scaler != scaler) {
      _lineHeights.clear();
    }
    final index = SourceLineIndex(text);
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    final fallback = scaler.scale(style.fontSize ?? 14) * (style.height ?? 1);
    double height(SourceLine line) {
      // Hard line breaks separate shaping paragraphs. Reuse their measured
      // heights; an ordinary edit only shapes its changed logical line. The
      // sentinel measures the next paragraph's caret with the same strut and
      // height behavior as RenderEditable, including empty and wrapped lines.
      final key = '${line.text}${line.lineBreak}';
      return _lineHeights.putIfAbsent(key, () {
        final painter = TextPainter(
          text: TextSpan(
            text: line.hasLineBreak ? '${key}M' : key,
            style: style,
          ),
          strutStyle: strut,
          textDirection: TextDirection.ltr,
          textHeightBehavior: sourceTextHeightBehavior,
          textScaler: scaler,
        )..layout(minWidth: math.max(1, width), maxWidth: math.max(1, width));
        final measured = line.hasLineBreak
            ? painter
                  .getOffsetForCaret(
                    TextPosition(offset: key.length),
                    Rect.zero,
                  )
                  .dy
            : painter.height;
        painter.dispose();
        return math.max(fallback, measured);
      });
    }

    final heights = [for (final line in index.lines) height(line)];
    if (_heights.length != heights.length ||
        Iterable<int>.generate(heights.length)
            .any((i) => heights[i] != _heights[i])) {
      _heights = heights;
    }
    // Retain only this bounded viewport, not every line visited in a session.
    final visible = {
      for (final line in index.lines) '${line.text}${line.lineBreak}',
    };
    _lineHeights.removeWhere((key, _) => !visible.contains(key));
    _text = text;
    _style = style;
    _width = width;
    _scaler = scaler;
    return _heights;
  }
}
