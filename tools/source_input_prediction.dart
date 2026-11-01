// Development-only independent input oracle. Never packaged with BusyAPI.
import 'package:busyapi_core/busyapi_core.dart';

class SourceInputPrediction {
  SourceInputPrediction(this.source, this.edit) {
    if (edit.start < 0 ||
        edit.end < edit.start ||
        edit.end > source.length ||
        source.substring(edit.start, edit.end) != edit.expected) {
      throw ArgumentError('Invalid captured input prediction');
    }
  }
  final String source;
  final TextEdit edit;
  bool accepted(TextEdit? actual) {
    if (actual == null ||
        actual.buffer != edit.buffer ||
        actual.generation != edit.generation ||
        actual.start < 0 ||
        actual.end < actual.start ||
        actual.end > source.length ||
        source.substring(actual.start, actual.end) != actual.expected)
      return false;
    if (actual.start == edit.start &&
        actual.end == edit.end &&
        actual.replacement == edit.replacement)
      return true;
    final delta = edit.replacement.length - (edit.end - edit.start);
    if (delta != actual.replacement.length - (actual.end - actual.start))
      return false;
    // A minimal diff may place an insertion at the other end of an identical
    // character run. Compare the actual effect, not one particular edit shape.
    int unit(TextEdit change, int offset) => offset < change.start
        ? source.codeUnitAt(offset)
        : offset < change.start + change.replacement.length
        ? change.replacement.codeUnitAt(offset - change.start)
        : source.codeUnitAt(offset - delta);
    final start = edit.start < actual.start ? edit.start : actual.start;
    final end = (edit.end > actual.end ? edit.end : actual.end) + delta;
    for (var i = start; i < end; i++) {
      if (unit(edit, i) != unit(actual, i)) return false;
    }
    return true;
  }

  /// Reconstruct only the rendered pieces of the independently predicted full
  /// edit. Never use the new controller/core text as the expected value, or
  /// allocate a second complete megabyte-sized source for each observed key.
  String project(Iterable<SourceRange> pieces) {
    final insertedEnd = edit.start + edit.replacement.length;
    final delta = edit.replacement.length - (edit.end - edit.start);
    final length = source.length + delta;
    final output = StringBuffer();
    var units = 0;
    for (final piece in pieces) {
      units += piece.end - piece.start;
      if (piece.start < 0 ||
          piece.end < piece.start ||
          piece.end > length ||
          units > 65536) {
        throw ArgumentError('Invalid or unbounded predicted input window');
      }
      var at = piece.start;
      if (at < edit.start) {
        final stop = piece.end < edit.start ? piece.end : edit.start;
        output.write(source.substring(at, stop));
        at = stop;
      }
      if (at < piece.end && at < insertedEnd) {
        final stop = piece.end < insertedEnd ? piece.end : insertedEnd;
        output.write(
          edit.replacement.substring(at - edit.start, stop - edit.start),
        );
        at = stop;
      }
      if (at < piece.end)
        output.write(source.substring(at - delta, piece.end - delta));
    }
    return output.toString();
  }
}
