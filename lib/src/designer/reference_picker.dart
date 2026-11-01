import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/busyapi_glyphs.dart';
import '../app/busyapi_search_field.dart';
import '../app/contract_labels.dart';
import '../app/localization.dart';
import '../workspace/project_search.dart' show BusyApiReviewPages;
import '../workspace/workspace_controller.dart';

/// Captures an occurrence, not the current selection at eventual Apply time.
/// Definition editing is a different, explicit navigation action.
Future<RefactoringPlan?> showReferencePicker(
  BuildContext context,
  WorkspaceController controller,
  BusyProject owner,
  Map<String, dynamic> occurrence,
  String keyword, {
  SecurityBindingForm? bindingForm,
}) => showBusyApiModalDialog<RefactoringPlan>(
  context: context,
  builder: (_) => _ReferencePicker(
    controller: controller,
    owner: owner,
    occurrence: occurrence,
    keyword: keyword,
    bindingForm: bindingForm,
  ),
);

class _ReferencePicker extends StatefulWidget {
  const _ReferencePicker({
    required this.controller,
    required this.owner,
    required this.occurrence,
    required this.keyword,
    this.bindingForm,
  });
  final WorkspaceController controller;
  final BusyProject owner;
  final Map<String, dynamic> occurrence;
  final String keyword;
  final SecurityBindingForm? bindingForm;
  @override
  State<_ReferencePicker> createState() => _ReferencePickerState();
}

class _ReferencePickerState extends State<_ReferencePicker> {
  static int serial = 0;
  late final prefix = 'reference-picker-${++serial}:';
  late final root = widget.controller.root!;
  late final navigation = widget.controller.navigationGeneration;
  final query = TextEditingController();
  Timer? debounce;
  ReferenceChoicePage? page;
  int epoch = 0, offset = 0;
  String? error;
  bool loading = true, planning = false;
  bool get ownerCurrent =>
      !widget.controller.disposed &&
      identical(widget.controller.project, widget.owner) &&
      widget.controller.root == root &&
      widget.controller.navigationGeneration == navigation &&
      widget.owner.store.buffers[widget.occurrence['resource']]?.generation ==
          widget.occurrence['generation'];
  bool get current =>
      mounted && ownerCurrent && (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  void initState() {
    super.initState();
    query.addListener(changed);
    widget.controller.addListener(observe);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current) unawaited(load());
    });
  }

  void cancel() {
    unawaited(
      widget.owner.engine.cancelPrefix(prefix).catchError((Object _) {}),
    );
  }

  void observe() {
    if (!mounted) return;
    if (!ownerCurrent || page != null && !page!.current) {
      epoch++;
      cancel();
      debounce?.cancel();
      loading = false;
      planning = false;
    }
    setState(() {});
  }

  void changed() {
    if (!current || planning) return;
    epoch++;
    cancel();
    debounce?.cancel();
    setState(() {
      page = null;
      error = null;
      loading = true;
      offset = 0;
    });
    if (!query.value.composing.isCollapsed) return;
    debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(load()),
    );
  }

  Future<void> load() async {
    if (!current || planning || !query.value.composing.isCollapsed) return;
    final token = ++epoch, text = query.text;
    setState(() {
      loading = true;
      error = null;
      page = null;
    });
    try {
      final result = await widget.owner.referenceChoices(
        root,
        widget.occurrence['resource'],
        widget.occurrence['pointer'],
        keyword: widget.keyword,
        bindingForm: widget.bindingForm,
        query: text,
        offset: offset,
        requestId: '$prefix$token',
        cancelled: () => !mounted || !ownerCurrent || token != epoch,
      );
      if (!current || token != epoch) return;
      setState(() {
        page = result;
        offset = result.result['offset'] as int;
      });
    } on Object catch (failure) {
      if (!current || token != epoch) return;
      setState(
        () => error = failure is CoreFailure
            ? failure.code
            : 'reference.choice.failure',
      );
    } finally {
      if (current && token == epoch) setState(() => loading = false);
    }
  }

  Future<void> choose(int index) async {
    final captured = page;
    if (!current ||
        captured == null ||
        !captured.current ||
        loading ||
        planning ||
        !query.value.composing.isCollapsed) {
      return;
    }
    debounce?.cancel();
    final token = ++epoch;
    setState(() {
      planning = true;
      error = null;
    });
    try {
      final plan = await widget.controller.planReferenceSelection(
        widget.owner,
        captured,
        index,
        requestId: '${prefix}plan:$token',
        cancelled: () => !mounted || !ownerCurrent || token != epoch,
      );
      if (!mounted || !current || token != epoch) return;
      Navigator.pop(context, plan.edits.isEmpty ? null : plan);
    } on Object catch (failure) {
      if (current && token == epoch) {
        setState(
          () => error = failure is CoreFailure
              ? failure.code
              : 'reference.choice.failure',
        );
      }
    } finally {
      if (mounted && token == epoch) setState(() => planning = false);
    }
  }

  @override
  void dispose() {
    epoch++;
    debounce?.cancel();
    cancel();
    widget.controller.removeListener(observe);
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, result = page?.result;
    final entries = (result?['entries'] as List? ?? const []).cast<Map>();
    final count = result?['count'] as int? ?? 0;
    final stale = !ownerCurrent || page != null && !page!.current;
    final enabled =
        current &&
        !loading &&
        !planning &&
        !stale &&
        query.value.composing.isCollapsed;
    return PopScope(
      canPop: !planning,
      child: BusyApiDialogShell(
        title: l.chooseReferenceTarget,
        maxWidth: BusyApiSizes.modalMaxWidth,
        closable: !planning,
        actions: [
          BusyApiDialogButton(
            label: l.cancel,
            onPressed: planning ? null : () => Navigator.pop(context),
          ),
        ],
        children: [
          Text(
            widget.keyword == 'security'
                ? l.securityBindingChoiceExplanation
                : l.referenceChoiceExplanation,
          ),
          Text(
            contractIdentityLabel(
              '${p.relative(Uri.parse(widget.occurrence['resource']).toFilePath(), from: widget.owner.access.boundary)}#${widget.occurrence['pointer']} · ${widget.keyword}',
            ),
          ),
          if (widget.keyword == r'$dynamicRef') Text(l.sourceDynamicDefinition),
          IgnorePointer(
            ignoring: planning || !ownerCurrent,
            child: BusyApiSearchField(
              controller: query,
              hintText: l.searchReferenceTargets,
              autofocus: true,
              onSubmitted: (_) => unawaited(load()),
              clearButtonSemanticLabel: l.clearReferenceQuery,
            ),
          ),
          if (stale)
            BusyApiStatusBox(
              message: l.referenceChoiceStale,
              kind: BusyApiStatusKind.warning,
            ),
          if (error != null)
            BusyApiStatusBox(
              message: l.referenceChoiceFailed(error!),
              kind: BusyApiStatusKind.error,
            ),
          if (loading || planning) Text(l.checking),
          if (result != null && result['complete'] != true)
            BusyApiStatusBox(
              message: l.referenceChoiceIncomplete,
              kind: BusyApiStatusKind.warning,
            ),
          if (result != null) Text(l.referenceChoiceScope(count)),
          if (!loading && !planning && error != null && ownerCurrent)
            BusyApiActionRow(
              title: l.retryObjectPage,
              onTap: () => unawaited(load()),
            ),
          if (result != null)
            BusyApiReviewPages(
              page: offset ~/ 50,
              pages: ((count + 49) ~/ 50).clamp(1, 400),
              enabled: enabled,
              onChanged: (value) {
                offset = value * 50;
                unawaited(load());
              },
            ),
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (_, index) {
                final entry = entries[index], target = entry['target'] as Map;
                final role = switch (entry['role']) {
                  'component' => l.sharedDefinition,
                  'schema-resource' => l.referenceSchemaResource,
                  _ => l.referenceInlineTarget,
                };
                return BusyApiActionRow(
                  key: ValueKey(entry['semanticId']),
                  title: entry['label'] == ''
                      ? l.emptyObjectName
                      : entry['label'],
                  subtitleWidget: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${contractIdentityLabel(p.relative(Uri.parse(target['resource']).toFilePath(), from: widget.owner.access.boundary))}#${contractIdentityLabel(target['pointer'])}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (entry['bindingForm'] != null)
                        Text(
                          entry['bindingForm'] == 'uri'
                              ? l.securityUriBinding(
                                  contractIdentityLabel(
                                    entry['value'] as String,
                                  ),
                                )
                              : l.securityNamedBinding(
                                  contractIdentityLabel(
                                    entry['value'] as String,
                                  ),
                                ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        '${entry['reference'] == true ? '${l.referenceOccurrence} · ' : ''}$role',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (entry['sharedSource'] == true)
                        Text(
                          l.referenceSharedSyntax,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                  trailing: entry['selected'] == true
                      ? const Icon(BusyApiGlyphs.check)
                      : null,
                  onTap: enabled ? () => unawaited(choose(index)) : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
