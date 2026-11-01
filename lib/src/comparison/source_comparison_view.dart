// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// Modified for BusyAPI source reviews; no local-history operations.
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import 'source_comparison.dart';
import 'source_comparison_pagination.dart';

class SourceComparisonView extends StatelessWidget {
  const SourceComparisonView({
    super.key,
    required this.comparison,
    required this.chunks,
  });

  final SourceComparison comparison;
  final List<SourceComparisonChunk> chunks;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(BusyApiSpacing.md),
    children: [
      for (final chunk in chunks)
        _UnifiedSourceChunk(
          source: chunk.text,
          marker: switch (chunk.kind) {
            SourceComparisonChunkKind.unchanged => null,
            SourceComparisonChunkKind.removed => '−',
            SourceComparisonChunkKind.added => '+',
          },
          label: chunk.kind == SourceComparisonChunkKind.removed
              ? comparison.oldInput.label
              : comparison.currentInput.label,
          background: switch (chunk.kind) {
            SourceComparisonChunkKind.unchanged => null,
            SourceComparisonChunkKind.removed => Theme.of(
              context,
            ).colorScheme.errorContainer,
            SourceComparisonChunkKind.added => Theme.of(
              context,
            ).colorScheme.primaryContainer,
          },
          emphasis: switch (chunk.kind) {
            SourceComparisonChunkKind.unchanged => null,
            SourceComparisonChunkKind.removed => Theme.of(
              context,
            ).colorScheme.error.withValues(alpha: 0.32),
            SourceComparisonChunkKind.added => Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.32),
          },
          intraline: chunk.intraline,
        ),
    ],
  );
}

class _UnifiedSourceChunk extends StatelessWidget {
  const _UnifiedSourceChunk({
    required this.source,
    this.marker,
    this.label,
    this.background,
    this.emphasis,
    this.intraline = const SourceComparisonRange(0, 0),
  });

  final String source;
  final String? marker;
  final String? label;
  final Color? background;
  final Color? emphasis;
  final SourceComparisonRange intraline;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(fontFamily: 'monospace');
    final start = intraline.start.clamp(0, source.length);
    final end = intraline.end.clamp(start, source.length);
    final text = SelectableText.rich(
      TextSpan(
        style: style?.copyWith(backgroundColor: background),
        children: [
          if (start > 0) TextSpan(text: source.substring(0, start)),
          if (end > start)
            TextSpan(
              text: source.substring(start, end),
              style: TextStyle(backgroundColor: emphasis),
            ),
          if (end < source.length) TextSpan(text: source.substring(end)),
        ],
      ),
    );
    if (marker == null || label == null) return text;
    return Semantics(
      label: '$label: $source',
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(
              color: marker == '−'
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
              width: 3,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: BusyApiSpacing.sm,
            bottom: BusyApiSpacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Text(
                  marker!,
                  style: style?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: BusyApiSpacing.xs),
              Expanded(child: text),
            ],
          ),
        ),
      ),
    );
  }
}
