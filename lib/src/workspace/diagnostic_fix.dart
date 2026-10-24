import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';
import 'refactoring_review.dart';
import 'workspace_controller.dart';

/// Source assistance reads the current diagnostic snapshot; it neither reparses
/// a second editor buffer nor fabricates a repair for an arbitrary source span.
Future<void> showSourceDiagnosticFixes(
  BuildContext context,
  WorkspaceController controller,
  SourceSelection selection,
) async {
  final owner = controller.project,
      buffer = controller.buffer,
      checked = controller.analysis,
      root = controller.root;
  if (owner == null || buffer == null || controller.disposed || root == null) {
    return;
  }
  final generation = buffer.generation, snapshot = checked?['contextSnapshot'];
  final resources = checked?['resources'] as List? ?? const [];
  final current =
      !controller.checking &&
      controller.error == null &&
      snapshot is String &&
      resources.any(
        (r) => r['id'] == buffer.id && r['generation'] == generation,
      );
  final findings = current
      ? (checked?['findings'] as List? ?? const [])
            .whereType<Map>()
            .where(
              (finding) =>
                  finding['root'] == root &&
                  finding['resource'] == buffer.id &&
                  (finding['fixes'] as List? ?? const []).contains(
                    'path-parameter-required',
                  ) &&
                  finding['range'] is List &&
                  finding['range'].length == 2 &&
                  finding['range'][0] <= selection.extent &&
                  finding['range'][1] >= selection.extent,
            )
            .map((finding) => Map<String, dynamic>.from(finding))
            .toList()
      : <Map<String, dynamic>>[];
  ModalRoute<Map<String, dynamic>>? pickerRoute;
  final picked = await showBusyApiModalDialog<Map<String, dynamic>>(
    context: context,
    onRoutePushed: (route, _) => pickerRoute = route,
    builder: (context) => BusyApiDialogShell(
      title: context.l10n.sourceQuickFix,
      actions: [
        BusyApiDialogButton(
          label: context.l10n.cancel,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      children: [
        if (findings.isEmpty)
          Text(
            current
                ? context.l10n.sourceNoQuickFixes
                : context.l10n.sourceQuickFixesOutdated,
          )
        else
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: findings.length,
              itemBuilder: (context, index) => BusyApiActionRow(
                title: context.l10n.repairPathParameter,
                subtitle: context.l10n.parameterPathRequired,
                onTap: () => Navigator.pop(context, findings[index]),
              ),
            ),
          ),
      ],
    ),
  );
  // Pop completes before the exit transition. Restore that route/focus owner
  // before opening the next surface; no overlapping old Cancel buttons or
  // route-exit frames may receive input intended for the new review.
  await pickerRoute?.completed;
  if (picked != null &&
      context.mounted &&
      !controller.disposed &&
      identical(controller.project, owner) &&
      controller.root == root &&
      identical(controller.buffer, buffer) &&
      buffer.generation == generation &&
      buffer.selection.base == selection.base &&
      buffer.selection.extent == selection.extent &&
      snapshot is String) {
    await showDiagnosticFix(
      context,
      controller,
      picked,
      snapshot,
      'path-parameter-required',
    );
  }
}

Future<void> showDiagnosticFix(
  BuildContext context,
  WorkspaceController controller,
  Map<String, dynamic> diagnostic,
  String contextSnapshot,
  String fix,
) async {
  final owner = controller.project, root = controller.root;
  if (owner == null || controller.disposed || diagnostic['root'] != root) {
    return;
  }
  ModalRoute<RefactoringPlan>? planningRoute;
  final plan = await showBusyApiModalDialog<RefactoringPlan>(
    context: context,
    onRoutePushed: (route, _) => planningRoute = route,
    builder: (_) => _DiagnosticFixDialog(
      controller: controller,
      owner: owner,
      root: root!,
      diagnostic: diagnostic,
      contextSnapshot: contextSnapshot,
      fix: fix,
    ),
  );
  await planningRoute?.completed;
  if (plan != null &&
      context.mounted &&
      !controller.disposed &&
      identical(controller.project, owner) &&
      controller.root == root) {
    await showRefactoringReview(context, controller, owner, plan);
  }
}

class _DiagnosticFixDialog extends StatefulWidget {
  const _DiagnosticFixDialog({
    required this.controller,
    required this.owner,
    required this.root,
    required this.diagnostic,
    required this.contextSnapshot,
    required this.fix,
  });
  final WorkspaceController controller;
  final BusyProject owner;
  final String root, contextSnapshot, fix;
  final Map<String, dynamic> diagnostic;
  @override
  State<_DiagnosticFixDialog> createState() => _DiagnosticFixDialogState();
}

class _DiagnosticFixDialogState extends State<_DiagnosticFixDialog> {
  static int serial = 0;
  late final prefix = 'diagnostic-fix-${++serial}:';
  String? error;
  bool cancelled = false;
  bool get current =>
      mounted &&
      !cancelled &&
      (ModalRoute.of(context)?.isCurrent ?? false) &&
      !widget.controller.disposed &&
      identical(widget.controller.project, widget.owner) &&
      widget.controller.root == widget.root;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(prepare()));
  }

  Future<void> prepare() async {
    if (!current) return;
    try {
      final plan = await widget.controller.planDiagnosticFix(
        widget.owner,
        widget.diagnostic,
        contextSnapshot: widget.contextSnapshot,
        fix: widget.fix,
        requestId: '${prefix}plan',
        cancelled: () => !current,
      );
      if (mounted && current) Navigator.pop(context, plan);
    } on Object catch (failure) {
      if (current) {
        setState(
          () => error = failure is CoreFailure ? failure.code : 'fix.failure',
        );
      }
    }
  }

  @override
  void dispose() {
    cancelled = true;
    unawaited(widget.owner.engine.cancelPrefix(prefix));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BusyApiDialogShell(
    title: context.l10n.reviewDiagnosticRepair,
    actions: [
      BusyApiDialogButton(
        label: context.l10n.cancel,
        onPressed: () => Navigator.pop(context),
      ),
    ],
    children: [
      if (error == null)
        Text(context.l10n.preparingDiagnosticRepair)
      else
        BusyApiStatusBox(
          message: context.l10n.diagnosticRepairFailed(error!),
          kind: BusyApiStatusKind.error,
        ),
    ],
  );
}
