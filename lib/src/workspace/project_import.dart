import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';
import 'output_destination.dart';
import 'workspace_controller.dart';

class ProjectImportController extends ChangeNotifier {
  ProjectImportController(this.workspace) {
    workspace.addListener(_observe);
  }
  final WorkspaceController workspace;
  ProjectImportPlan? plan;
  BusyProject? _owner;
  int? _navigation;
  RunCancellation? _cancellation;
  bool _disposed = false;
  String phase = 'idle';
  String? failure;
  ProjectImportResult? acquired;
  List<String> neededApprovals = const [];
  bool get busy => phase == 'preparing' || phase == 'publishing';
  bool get canRevise =>
      !_disposed &&
      !busy &&
      plan != null &&
      !plan!.published &&
      acquired == null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _observe() {
    if (_navigation != null &&
        (!identical(workspace.project, _owner) ||
            workspace.navigationGeneration != _navigation)) {
      cancel();
    }
  }

  bool get _current =>
      !_disposed &&
      !workspace.disposed &&
      _cancellation?.cancelled == false &&
      identical(workspace.project, _owner) &&
      workspace.navigationGeneration == _navigation;
  bool _owns(RunCancellation token) =>
      _current && identical(_cancellation, token);
  Future<void> prepare({
    required ProjectImportKind kind,
    required String source,
    required String destination,
    Set<String> approvedUrls = const {},
    Future<String?> Function(List<ProjectRoot>)? selectRoot,
  }) async {
    if (busy || _disposed || acquired != null || plan?.published == true) {
      return;
    }
    _cancellation?.cancel();
    plan?.close();
    plan = null;
    failure = null;
    neededApprovals = const [];
    _owner = workspace.project;
    _navigation = workspace.navigationGeneration;
    final token = RunCancellation();
    _cancellation = token;
    phase = 'preparing';
    _notify();
    ProjectImportPlan? prepared;
    try {
      prepared = await ProjectImporter(workspace.engine).prepare(
        kind: kind,
        source: source,
        destination: destination,
        approvedUrls: approvedUrls,
        cancellation: token,
        selectRoot: selectRoot,
      );
      if (!_owns(token)) {
        prepared.close();
        return;
      }
      plan = prepared;
      phase = 'review';
    } on Object catch (error) {
      prepared?.close();
      if (_owns(token)) {
        failure = error is CoreFailure && error.code == 'cancelled'
            ? null
            : error is CoreFailure
            ? error.code
            : 'import.failure';
        if (error is ImportUrlApprovalRequired) neededApprovals = error.urls;
        phase = error is CoreFailure && error.code == 'cancelled'
            ? 'cancelled'
            : 'failed';
      }
    } finally {
      _notify();
    }
  }

  Future<void> publish({
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
  }) async {
    final captured = plan, token = _cancellation;
    if (token == null ||
        !_owns(token) ||
        captured == null ||
        phase != 'review') {
      return;
    }
    phase = 'publishing';
    _notify();
    try {
      final result = await captured.publish(
        cancellation: token,
        beforePublish: beforePublish,
        afterPublish: afterPublish,
      );
      if (_owns(token)) {
        acquired = result;
        phase = 'acquired';
      }
    } on Object catch (error) {
      if (_owns(token)) {
        if (error is OutputDirectoryChanged && error.published) {
          failure = 'output.published.uncertain';
          phase = 'partial';
        } else {
          failure = error is CoreFailure ? error.code : 'import.failure';
          phase = 'failed';
        }
      }
    } finally {
      _notify();
    }
  }

  void cancel() {
    _cancellation?.cancel();
    plan?.close();
    if (phase != 'acquired' && phase != 'partial') phase = 'cancelled';
    _notify();
  }

  void revise() {
    if (!canRevise) return;
    _cancellation?.cancel();
    _cancellation = null;
    plan?.close();
    plan = null;
    _owner = null;
    _navigation = null;
    phase = 'idle';
    failure = null;
    neededApprovals = const [];
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    workspace.removeListener(_observe);
    cancel();
    super.dispose();
  }
}

Future<ProjectImportResult?> showProjectImport(
  BuildContext context,
  WorkspaceController workspace,
) async {
  ModalRoute<ProjectImportResult>? route;
  final result = await showBusyApiModalDialog<ProjectImportResult>(
    context: context,
    onRoutePushed: (value, _) => route = value,
    builder: (_) => _ImportDialog(workspace),
  );
  await route?.completed;
  return result;
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog(this.workspace);
  final WorkspaceController workspace;
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final run = ProjectImportController(widget.workspace)
    ..addListener(_changed);
  final source = TextEditingController(),
      destination = TextEditingController(),
      approvals = TextEditingController();
  ProjectImportKind kind = ProjectImportKind.file;
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    run.removeListener(_changed);
    run.dispose();
    source.dispose();
    destination.dispose();
    approvals.dispose();
    super.dispose();
  }

  Future<void> browse() async {
    final entered = source.text, selectedKind = kind;
    final selected = kind == ProjectImportKind.file
        ? (await openFile())?.path
        : await getDirectoryPath();
    if (mounted &&
        selected != null &&
        !run.busy &&
        source.text == entered &&
        kind == selectedKind) {
      setState(() => source.text = selected);
    }
  }

  Future<void> chooseDestination() async {
    final entered = destination.text;
    final selected = await chooseOutputDestination(
      context,
      initialPath: destination.text.isEmpty
          ? p.join(p.current, 'imported-api')
          : destination.text,
    );
    if (mounted &&
        selected != null &&
        !run.busy &&
        destination.text == entered) {
      setState(() => destination.text = selected);
    }
  }

  Future<String?> chooseRoot(List<ProjectRoot> roots) async {
    if (!mounted) return null;
    ModalRoute<String>? route;
    final result = await showBusyApiModalDialog<String>(
      context: context,
      onRoutePushed: (value, _) => route = value,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.selectRoot,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.cancel,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        children: [
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: roots.length,
              itemBuilder: (_, index) => BusyApiActionRow(
                title: roots[index].name,
                subtitle: roots[index].id,
                onTap: () => Navigator.pop(context, roots[index].id),
              ),
            ),
          ),
        ],
      ),
    );
    await route?.completed;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, plan = run.plan;
    final editable = !run.busy && plan == null && run.acquired == null;
    return BusyApiDialogShell(
      title: l.importProject,
      actions: [
        BusyApiDialogButton(
          label: l.cancel,
          onPressed: () {
            run.cancel();
            Navigator.pop(context);
          },
        ),
        if (run.acquired != null)
          BusyApiDialogButton(
            label: l.open,
            suggested: true,
            onPressed: () => Navigator.pop(context, run.acquired),
          ),
        if (editable)
          BusyApiDialogButton(
            label: l.importReview,
            suggested: true,
            onPressed: () {
              if ([
                source,
                destination,
                approvals,
              ].any((c) => !c.value.composing.isCollapsed)) {
                return;
              }
              run.prepare(
                kind: kind,
                source: source.text,
                destination: destination.text,
                approvedUrls: kind == ProjectImportKind.url
                    ? approvals.text
                          .split('\n')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toSet()
                    : const {},
                selectRoot: chooseRoot,
              );
            },
          ),
        if (run.phase == 'review')
          BusyApiDialogButton(
            label: plan!.complete ? l.importAcquire : l.importAvailable,
            suggested: true,
            onPressed: run.publish,
          ),
        if (run.canRevise)
          BusyApiDialogButton(label: l.importRevise, onPressed: run.revise),
      ],
      children: [
        Text(l.importHelp),
        BusyApiGroupedList(
          children: [
            BusyApiComboRow<ProjectImportKind>(
              title: l.importKind,
              values: ProjectImportKind.values,
              selected: kind,
              labelFor: (value) => switch (value) {
                ProjectImportKind.file => l.importFile,
                ProjectImportKind.directory => l.openFolder,
                ProjectImportKind.url => l.importUrl,
                ProjectImportKind.git => l.importGit,
              },
              enabled: editable,
              onSelected: (value) => setState(() => kind = value),
            ),
            BusyApiGroupedTextEntry(
              label: l.importSource,
              controller: source,
              enabled: editable,
              trailing:
                  editable &&
                      [
                        ProjectImportKind.file,
                        ProjectImportKind.directory,
                      ].contains(kind)
                  ? BusyApiPushButton.standard(
                      onPressed: browse,
                      child: Text(l.open),
                    )
                  : null,
            ),
            BusyApiGroupedTextEntry(
              label: l.importDestination,
              controller: destination,
              enabled: editable,
              trailing: editable
                  ? BusyApiPushButton.standard(
                      onPressed: chooseDestination,
                      child: Text(l.chooseOutputFolder),
                    )
                  : null,
            ),
            if (kind == ProjectImportKind.url)
              BusyApiGroupedTextEntry(
                label: l.importUrlApprovals,
                controller: approvals,
                enabled: editable,
                minLines: 2,
                maxLines: 4,
              ),
          ],
        ),
        if (run.busy) const LinearProgressIndicator(),
        if (run.phase == 'partial') ...[
          BusyApiStatusBox(
            message: l.outputPartial,
            kind: BusyApiStatusKind.warning,
          ),
          SelectableText(plan!.destination),
        ] else if (run.failure != null)
          BusyApiStatusBox(
            message: l.importFailed(run.failure!),
            kind: BusyApiStatusKind.error,
          ),
        if (run.neededApprovals.isNotEmpty)
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: run.neededApprovals.length,
              itemBuilder: (_, index) => BusyApiActionRow(
                title: run.neededApprovals[index],
                titleWidget: SelectableText(run.neededApprovals[index]),
              ),
            ),
          ),
        if (plan != null) ...[
          BusyApiStatusBox(
            message: plan.complete ? l.importReady : l.importIncomplete,
            kind: plan.complete
                ? BusyApiStatusKind.information
                : BusyApiStatusKind.warning,
          ),
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: plan.files.length,
              itemBuilder: (_, index) => BusyApiActionRow(
                title: plan.files[index],
                leading: const Icon(BusyApiGlyphs.document),
                titleWidget: SelectableText('+ ${plan.files[index]}'),
              ),
            ),
          ),
          if (plan.unavailable.isNotEmpty)
            BusyApiReviewViewport(
              child: ListView.builder(
                itemCount: plan.unavailable.length,
                itemBuilder: (_, index) => BusyApiActionRow(
                  title: plan.unavailable[index],
                  titleWidget: SelectableText(plan.unavailable[index]),
                ),
              ),
            ),
        ],
        if (run.acquired != null)
          BusyApiStatusBox(
            message: l.importAcquired(run.acquired!.destination),
            kind: BusyApiStatusKind.success,
          ),
      ],
    );
  }
}
