// Captured replacement review composed from BusyMark's dialog, native rows
// and source-comparison controls. Search itself lives in the shared sidebar.
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/contract_labels.dart';
import '../app/localization.dart';
import '../app/review_viewport.dart';
import '../comparison/review_comparison.dart';
import 'workspace_controller.dart';

Future<void> showProjectReplacementReview(
  BuildContext context,
  WorkspaceController controller,
  BusyProject owner,
  SearchSnapshot captured,
  String replacement,
) => showBusyApiModalDialog<void>(
  context: context,
  builder: (_) => _ProjectReplacementReview(
    controller: controller,
    owner: owner,
    captured: captured,
    replacement: replacement,
  ),
);

class _ProjectReplacementReview extends StatefulWidget {
  const _ProjectReplacementReview({
    required this.controller,
    required this.owner,
    required this.captured,
    required this.replacement,
  });
  final WorkspaceController controller;
  final BusyProject owner;
  final SearchSnapshot captured;
  final String replacement;
  @override
  State<_ProjectReplacementReview> createState() =>
      _ProjectReplacementReviewState();
}

class _ProjectReplacementReviewState extends State<_ProjectReplacementReview> {
  static const pageSize = 50;
  int page = 0;
  bool applying = false, applied = false;
  CoreFailure? error;
  bool get current =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? false) &&
      !widget.controller.disposed &&
      identical(widget.controller.project, widget.owner);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  Future<void> apply() async {
    if (!current || applying || applied) return;
    setState(() => applying = true);
    try {
      await widget.controller.replaceProjectSearch(
        widget.owner,
        widget.captured,
        widget.replacement,
      );
      applied = true;
      if (mounted && current) Navigator.of(context).pop();
    } on Object catch (failure) {
      if (current) {
        setState(() {
          error = failure is CoreFailure
              ? failure
              : CoreFailure('search.io', '');
          applied = error?.code == 'search.applied.recovery';
        });
      }
    } finally {
      if (current) setState(() => applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, found = widget.captured;
    final matches = found.matches;
    final pages = ((matches.length + pageSize - 1) ~/ pageSize).clamp(
      1,
      100000,
    );
    final start = page * pageSize;
    final stale = !current || !found.current(widget.owner.store);
    final codeStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: BusyApiTypography.monoFontFamily,
      fontFamilyFallback: BusyApiTypography.monoFontFamilyFallback,
    );
    return PopScope(
      canPop: !applying,
      child: BusyApiDialogShell(
        title: l.reviewReplacement,
        maxWidth: BusyApiSizes.modalMaxWidth,
        closable: !applying,
        actions: [
          BusyApiDialogButton(
            label: l.close,
            onPressed: applying ? null : () => Navigator.pop(context),
          ),
          BusyApiDialogButton(
            label: l.replaceMatches(matches.length),
            onPressed: applying || applied || stale || matches.isEmpty
                ? null
                : apply,
            suggested: true,
          ),
        ],
        children: [
          Text(l.textReplacementExplanation),
          Text(
            l.searchReplacementScope(matches.length, found.resources.length),
          ),
          if (error != null)
            BusyApiStatusBox(
              message: searchFailure(context, error!),
              kind: BusyApiStatusKind.error,
            )
          else if (stale && !applied)
            BusyApiStatusBox(
              message: l.searchStale,
              kind: BusyApiStatusKind.warning,
            ),
          if (pages > 1)
            BusyApiReviewPages(
              page: page,
              pages: pages,
              enabled: !applying,
              onChanged: (value) => setState(() => page = value),
            ),
          BusyApiReviewViewport(
            child: ListView.builder(
              key: ValueKey(page),
              itemCount: (matches.length - start).clamp(0, pageSize),
              itemBuilder: (context, index) {
                final match = matches[start + index];
                final name = p.relative(
                  Uri.parse(match.resource).toFilePath(),
                  from: widget.owner.access.boundary,
                );
                return Column(
                  key: ValueKey('search-match-${start + index}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    BusyApiActionRow(title: '$name:${match.line}'),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: BusyApiSpacing.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SelectableText(
                            '− ${contractIdentityLabel(match.expected, limit: 240)}',
                            maxLines: 2,
                            style: codeStyle,
                          ),
                          SelectableText(
                            '+ ${contractIdentityLabel(widget.replacement, limit: 240)}',
                            maxLines: 2,
                            style: codeStyle,
                          ),
                          BusyApiChangeContext(
                            key: ValueKey((match.resource, match.start)),
                            preview: () =>
                                found.preview(match, widget.replacement),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class BusyApiReviewPages extends StatelessWidget {
  const BusyApiReviewPages({
    super.key,
    required this.page,
    required this.pages,
    required this.onChanged,
    this.enabled = true,
  });
  final int page, pages;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Wrap(
      spacing: BusyApiSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BusyApiDialogButton(
          label: l.searchFirstPage,
          onPressed: enabled && page > 0 ? () => onChanged(0) : null,
        ),
        BusyApiDialogButton(
          label: l.searchPreviousPage,
          onPressed: enabled && page > 0 ? () => onChanged(page - 1) : null,
        ),
        Text(l.searchPage(page + 1, pages)),
        BusyApiDialogButton(
          label: l.searchNextPage,
          onPressed: enabled && page + 1 < pages
              ? () => onChanged(page + 1)
              : null,
        ),
        BusyApiDialogButton(
          label: l.searchLastPage,
          onPressed: enabled && page + 1 < pages
              ? () => onChanged(pages - 1)
              : null,
        ),
      ],
    );
  }
}

class BusyApiChangeContext extends StatefulWidget {
  const BusyApiChangeContext({super.key, required this.preview});
  final SearchChangePreview Function() preview;
  @override
  State<BusyApiChangeContext> createState() => _SearchChangeContextState();
}

class _SearchChangeContextState extends State<BusyApiChangeContext> {
  SearchChangePreview? preview;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n, captured = preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BusyApiActionRow(
          title: captured == null ? l.searchShowContext : l.searchHideContext,
          onTap: () => setState(
            () => preview = captured == null ? widget.preview() : null,
          ),
        ),
        if (captured != null) BusyApiReviewComparison(preview: captured),
      ],
    );
  }
}

String searchFailure(BuildContext context, CoreFailure e) => switch (e.code) {
  'search.applied.recovery' => context.l10n.replacementAppliedRecoveryFailed,
  'search.pattern' => context.l10n.searchInvalidPattern,
  'search.timeout' => context.l10n.searchTimeout,
  'search.stale' => context.l10n.searchStale,
  'search.cancelled' => context.l10n.searchCancelled,
  'cancelled' => context.l10n.searchCancelled,
  'limit.search.matches' ||
  'limit.search' ||
  'limit.buffers' => context.l10n.searchLimited,
  _ => context.l10n.searchFailed(e.code),
};
