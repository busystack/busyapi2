// Gutter marker geometry follows BusyMark's Source diagnostic controls,
// Copyright 2026 BusyStack (Apache-2.0). No diagnostic parser is introduced.
part of 'source_editor.dart';

@immutable
class SourceDiagnostic {
  const SourceDiagnostic({
    required this.resource,
    required this.generation,
    required this.start,
    required this.end,
    required this.code,
    required this.severity,
    required this.message,
  });
  final String resource, code, severity, message;
  final int generation, start, end;
  int get rank => switch (severity) {
    'error' => 3,
    'warning' => 2,
    'information' => 1,
    _ => 0,
  };
  bool current(DocumentBuffer buffer) =>
      resource == buffer.id &&
      generation == buffer.generation &&
      start >= 0 &&
      end >= start &&
      end <= buffer.text.length;
  Color color(BuildContext context) => switch (severity) {
    'error' => busyApiStatusColor(context, BusyApiStatusKind.error),
    'warning' => busyApiStatusColor(context, BusyApiStatusKind.warning),
    'information' => busyApiStatusColor(context, BusyApiStatusKind.information),
    _ => BusyApiSurfaceColors.of(context).mutedForeground,
  };
}

class _SourceDiagnosticDot extends StatelessWidget {
  const _SourceDiagnosticDot(this.diagnostics);
  final List<SourceDiagnostic> diagnostics;
  @override
  Widget build(BuildContext context) {
    final primary = diagnostics.reduce((a, b) => a.rank >= b.rank ? a : b);
    // Never turn large schema explanations or a dense error line into an
    // unbounded tooltip/layout. Messages have already been localized/masked.
    final message = diagnostics
        .take(4)
        .map((d) => '${d.code}: ${d.message}'.characters.take(240).toString())
        .join('\n');
    return Tooltip(
      message: diagnostics.length > 4
          ? '$message\n${context.l10n.sourceMoreDiagnostics(diagnostics.length - 4)}'
          : message,
      child: SizedBox.square(
        dimension: 6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: primary.color(context),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

typedef _DiagnosticDecoration = ({int start, int end, Color color});

List<_DiagnosticDecoration> _diagnosticDecorations(
  BuildContext context,
  List<SourceDiagnostic> diagnostics,
  DocumentBuffer? buffer,
  int start,
  int length, [
  SourceFoldWindow? window,
]) {
  if (buffer == null || diagnostics.isEmpty) return const [];
  // Four difference counters per visible UTF-16 unit keep dense/overlapping
  // findings linear in findings + bounded source-window length. Later-file
  // findings are not discarded by a global first-N display cap.
  Int32List? changes;
  final colors = <int, Color>{};
  for (final diagnostic in diagnostics) {
    if (!diagnostic.current(buffer) ||
        diagnostic.start >= (window?.end ?? start + length) ||
        diagnostic.end <= start) {
      continue;
    }
    changes ??= Int32List((length + 1) * 4);
    int boundary(int offset, bool forward) {
      final at = window?.fullOffset(offset) ?? start + offset;
      if (at > 0 &&
          at < buffer.text.length &&
          buffer.text.codeUnitAt(at) >= 0xdc00 &&
          buffer.text.codeUnitAt(at) <= 0xdfff &&
          buffer.text.codeUnitAt(at - 1) >= 0xd800 &&
          buffer.text.codeUnitAt(at - 1) <= 0xdbff) {
        return (offset + (forward ? 1 : -1)).clamp(0, length);
      }
      return offset;
    }

    final from = boundary(
          window?.visibleOffset(diagnostic.start) ??
              (diagnostic.start - start).clamp(0, length),
          false,
        ),
        to = boundary(
          window?.visibleOffset(diagnostic.end) ??
              (diagnostic.end - start).clamp(0, length),
          true,
        ),
        rank = diagnostic.rank;
    changes[from * 4 + rank]++;
    changes[to * 4 + rank]--;
    colors.putIfAbsent(rank, () => diagnostic.color(context));
  }
  if (changes == null) return const [];
  final output = <_DiagnosticDecoration>[];
  final active = [0, 0, 0, 0];
  var previous = -1, from = 0;
  for (var unit = 0; unit <= length; unit++) {
    var primary = -1;
    for (var rank = 0; rank < 4; rank++) {
      active[rank] += changes[unit * 4 + rank];
      if (active[rank] > 0) primary = rank;
    }
    if (primary == previous) continue;
    if (previous >= 0) {
      output.add((start: from, end: unit, color: colors[previous]!));
    }
    previous = primary;
    from = unit;
  }
  return output;
}
