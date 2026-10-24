// Uses BusyMark's SourceComparisonView and compact review controls. Paging
// retains complete captured input without laying out large source values.
import 'dart:math' as math;

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/localization.dart';
import '../workspace/project_search.dart' show BusyApiReviewPages;
import 'source_comparison.dart';
import 'source_comparison_pagination.dart';
import 'source_comparison_view.dart';

class BusyApiReviewComparison extends StatefulWidget {
  const BusyApiReviewComparison({
    super.key,
    this.before = '',
    this.after = '',
    this.preview,
  });
  final String before, after;
  final SearchChangePreview? preview;
  @override
  State<BusyApiReviewComparison> createState() =>
      _BusyApiReviewComparisonState();
}

class _BusyApiReviewComparisonState extends State<BusyApiReviewComparison> {
  int page = 0;
  SourceComparisonPages? _pages;
  String? _locale;
  @override
  void didUpdateWidget(BusyApiReviewComparison oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.before != widget.before ||
        oldWidget.after != widget.after ||
        oldWidget.preview != widget.preview) {
      page = 0;
      _pages = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (_locale != l.localeName) {
      _locale = l.localeName;
      _pages = null;
    }
    final preview = widget.preview;
    final presentation = _pages ??= SourceComparisonPages(
      compareSource(
        SourceComparisonInput(
          id: 'before',
          version: 0,
          label: l.searchBefore,
          source: preview == null
              ? widget.before
              : '${preview.prefix}${preview.before}${preview.suffix}',
        ),
        SourceComparisonInput(
          id: 'after',
          version: 0,
          label: l.searchAfter,
          source: preview == null
              ? widget.after
              : '${preview.prefix}${preview.after}${preview.suffix}',
        ),
      ),
      pageSize: SearchChangePreview.pageSize,
    );
    final pages = presentation.pages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pages > 1)
          BusyApiReviewPages(
            page: page,
            pages: pages,
            onChanged: (value) => setState(() => page = value),
          ),
        SizedBox(
          height: math.min(
            BusyApiSizes.problemsListHeight,
            MediaQuery.sizeOf(context).height *
                BusyApiSizes.modalMaxHeightFraction /
                2,
          ),
          child: SourceComparisonView(
            comparison: presentation.comparison,
            chunks: presentation.page(page),
          ),
        ),
      ],
    );
  }
}

class BusyApiRawSourceView extends StatefulWidget {
  const BusyApiRawSourceView({
    super.key,
    required this.source,
    this.patch = false,
  });
  final String source;
  final bool patch;
  @override
  State<BusyApiRawSourceView> createState() => _BusyApiRawSourceViewState();
}

class _BusyApiRawSourceViewState extends State<BusyApiRawSourceView> {
  int page = 0;
  @override
  void didUpdateWidget(BusyApiRawSourceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final preview = SearchChangePreview('', '', widget.source, '');
    final pages = preview.pages(true);
    final source = preview.page(true, page);
    final theme = Theme.of(context);
    final colors = BusyApiSurfaceColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pages > 1)
          BusyApiReviewPages(
            page: page,
            pages: pages,
            onChanged: (value) => setState(() => page = value),
          ),
        SelectableText.rich(
          TextSpan(
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: BusyApiTypography.monoFontFamily,
              fontFamilyFallback: BusyApiTypography.monoFontFamilyFallback,
              height: BusyApiTypography.codeLineHeight,
            ),
            children: [
              for (final line in source.split(RegExp(r'(?<=\n)')))
                TextSpan(
                  text: line,
                  style: widget.patch
                      ? TextStyle(
                          backgroundColor: line.startsWith('+')
                              ? colors.admonitionTip
                              : line.startsWith('-')
                              ? colors.admonitionWarning
                              : null,
                        )
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
