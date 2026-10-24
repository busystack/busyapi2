import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/busyapi_glyphs.dart';
import '../app/localization.dart';
import '../platform/external_uri_service.dart';
import 'workspace_controller.dart';
import '../app/busyapi_motion_widgets.dart';
import '../app/busyapi_disclosure.dart';
import '../comparison/review_comparison.dart';

Future<void> showGitWorkspace(
  BuildContext context,
  WorkspaceController controller, {
  GitRepository? repository,
}) async {
  final project = controller.project;
  if (project == null) return;
  repository ??= await GitRepository.discover(project.access.boundary);
  if (!context.mounted ||
      controller.disposed ||
      !identical(project, controller.project)) {
    return;
  }
  if (repository == null) {
    throw CoreFailure('git.repository', context.l10n.gitNoRepository);
  }
  await showBusyApiModalDialog<void>(
    context: context,
    builder: (_) => _GitWorkspace(
      controller: controller,
      owner: project,
      repository: repository!,
    ),
  );
}

class _GitWorkspace extends StatefulWidget {
  const _GitWorkspace({
    required this.controller,
    required this.owner,
    required this.repository,
  });
  final WorkspaceController controller;
  final BusyProject owner;
  final GitRepository repository;
  @override
  State<_GitWorkspace> createState() => _GitWorkspaceState();
}

class _GitWorkspaceState extends State<_GitWorkspace> {
  int page = 0;
  final commitMessage = TextEditingController(),
      branchName = TextEditingController();
  GitStatus? status;
  List<GitCommit> history = const [];
  List<String> branches = const [];
  String? selected, diff, error;
  GitFileReview? review;
  int _reloadRequest = 0, _reviewRequest = 0;
  bool busy = true;
  GitPullStrategy strategy = GitPullStrategy.fastForwardOnly;
  bool get current =>
      mounted && identical(widget.owner, widget.controller.project);
  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    commitMessage.dispose();
    branchName.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final request = ++_reloadRequest;
    _reviewRequest++;
    review = null;
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      final values = await Future.wait<Object>([
        widget.repository.status(),
        widget.repository.history(),
        widget.repository.branches(),
      ]);
      final observe = widget.repository.onPhase;
      if (observe != null) await observe('workspace:reload:captured');
      if (!current || request != _reloadRequest) return;
      setState(() {
        status = values[0] as GitStatus;
        history = values[1] as List<GitCommit>;
        branches = values[2] as List<String>;
      });
      if (selected != null) await _diff(selected!);
    } on Object catch (failure) {
      if (current && request == _reloadRequest) {
        setState(() => error = failure.toString());
      }
    } finally {
      if (current && request == _reloadRequest) setState(() => busy = false);
      final observe = widget.repository.onPhase;
      if (observe != null) await observe('workspace:reload:complete');
    }
  }

  Future<bool> _trust() async {
    if (widget.repository.trusted) return true;
    final accepted = await showBusyApiModalDialog<bool>(
      context: context,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.gitChanges,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.cancel,
            onPressed: () => Navigator.pop(context, false),
          ),
          BusyApiDialogButton(
            label: context.l10n.apply,
            suggested: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        children: [Text(context.l10n.gitTrustExplanation)],
      ),
    );
    if (!current) return false;
    if (accepted == true) widget.repository.trust();
    return accepted == true;
  }

  Future<void> _action(Future<void> Function() action) async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await _reload();
    } on Object catch (failure) {
      if (current) setState(() => error = failure.toString());
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _diff(String path) async {
    final request = ++_reviewRequest;
    if (!current) return;
    setState(() {
      selected = path;
      diff = null;
      review = null;
    });
    final change = status?.changes
        .where((value) => value.path == path)
        .firstOrNull;
    final value = await widget.repository.reviewFile(
      path,
      staged: change?.staged == true && change?.unstaged != true,
    );
    if (current && request == _reviewRequest) {
      setState(() {
        selected = path;
        diff = value.diff;
        review = value;
      });
    }
  }

  bool get unsaved =>
      widget.owner.store.fileBuffers.any((buffer) => buffer.dirty);
  Future<void> _stage(GitChange change) async {
    if (!await _trust()) return;
    final absolute = p.join(widget.repository.info.root, change.path);
    final id = Uri.file(p.normalize(absolute)).toString();
    if (widget.owner.store.buffers[id]?.dirty == true) {
      await widget.controller.saveAll();
      if (!current) return;
      await _diff(change.path);
      return;
    }
    if (!current) return;
    final captured = review;
    if (captured == null ||
        captured.path != change.path ||
        captured.staged ||
        !captured.stagingReady) {
      await _diff(change.path);
      return;
    }
    await widget.repository.stageReview(captured);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, currentStatus = status;
    final labels = [l.gitChangesPage, l.gitHistory, l.gitBranchesRemotes];
    final icons = [
      BusyApiGlyphs.edit,
      BusyApiGlyphs.history,
      BusyApiGlyphs.folder,
    ];
    final changes = currentStatus?.changes ?? const <GitChange>[];
    final colors = BusyApiSurfaceColors.of(context);
    final changesView = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView.builder(
            padding: BusyApiInsets.sidebarList,
            itemCount: changes.length,
            itemBuilder: (context, index) {
              final change = changes[index];
              return BusyApiSidebarRecordRow<void>(
                key: ValueKey(change.path),
                icon: BusyApiGlyphs.document,
                title: p.basename(change.path),
                subtitle: p.dirname(change.path) == '.'
                    ? null
                    : p.dirname(change.path),
                pathSubtitle: true,
                tooltip:
                    '${change.path} · ${change.index}${change.worktree}${change.originalPath == null ? '' : ' · ${change.originalPath}'}',
                selected: change.path == selected,
                compact: true,
                onTap: busy ? null : () => _action(() => _diff(change.path)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (change.unstaged)
                      BusyApiCompactIconButton(
                        tooltip: l.gitStageReviewed,
                        icon: BusyApiGlyphs.add,
                        onPressed: busy
                            ? null
                            : () => _action(() => _stage(change)),
                      ),
                    if (change.staged)
                      BusyApiCompactIconButton(
                        tooltip: l.gitUnstage,
                        icon: BusyApiGlyphs.undo,
                        onPressed: busy
                            ? null
                            : () => _action(() async {
                                if (await _trust()) {
                                  await widget.repository.unstage([
                                    change.path,
                                  ]);
                                }
                              }),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.secondarySidebar,
            border: Border(top: BorderSide(color: colors.subtleBorder)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(BusyApiSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BusyApiGroupedList(
                  filled: true,
                  children: [
                    BusyApiGroupedTextEntry(
                      label: l.gitCommitMessage,
                      controller: commitMessage,
                      minLines: 3,
                      maxLines: 5,
                      enabled: !busy,
                      textInputAction: TextInputAction.newline,
                    ),
                  ],
                ),
                if (unsaved)
                  BusyApiStatusBox(
                    message: l.gitUnsavedSource,
                    kind: BusyApiStatusKind.warning,
                  ),
                const SizedBox(height: BusyApiSpacing.sm),
                ValueListenableBuilder(
                  valueListenable: commitMessage,
                  builder: (context, value, _) => BusyApiPushButton.suggested(
                    child: Text(l.gitCommitReviewed),
                    onPressed:
                        busy ||
                            !changes.any((c) => c.staged) ||
                            value.text.trim().isEmpty
                        ? null
                        : () => _action(() async {
                            if (await _trust()) {
                              await widget.repository.commit(
                                commitMessage.text,
                              );
                              commitMessage.clear();
                            }
                          }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    final historyView = ListView.builder(
      padding: BusyApiInsets.sidebarList,
      itemCount: history.length,
      itemBuilder: (context, index) {
        final commit = history[index];
        return BusyApiSidebarRecordRow<void>(
          icon: BusyApiGlyphs.history,
          title: commit.subject,
          subtitle:
              '${commit.id.substring(0, 12)} · ${commit.author} · ${commit.timestamp}',
          onTap: null,
          tooltip: commit.id,
        );
      },
    );
    final branchesView = BusyApiEditorScrollBody(
      child: Column(
        children: [
          BusyApiGroupedList(
            title: l.gitBranchesRemotes,
            children: [
              for (final branch in branches)
                BusyApiActionRow(
                  title: branch,
                  subtitle: branch == status?.branch
                      ? l.gitCurrentBranch
                      : null,
                  onTap: busy || branch == status?.branch
                      ? null
                      : () => _action(() async {
                          if (await _trust()) {
                            await widget.repository.switchBranch(
                              branch,
                              hasUnsavedBuffers: unsaved,
                            );
                          }
                        }),
                ),
              BusyApiGroupedTextEntry(
                label: l.gitNewBranch,
                controller: branchName,
                enabled: !busy,
              ),
              BusyApiActionRow(
                title: l.gitCreateSwitch,
                enabled: !busy,
                onTap: busy
                    ? null
                    : () => _action(() async {
                        if (await _trust()) {
                          await widget.repository.createBranch(
                            branchName.text,
                            hasUnsavedBuffers: unsaved,
                          );
                          branchName.clear();
                        }
                      }),
              ),
              BusyApiComboRow<GitPullStrategy>(
                title: l.gitPullStrategy,
                values: GitPullStrategy.values,
                selected: strategy,
                enabled: !busy,
                labelFor: (value) => switch (value) {
                  GitPullStrategy.fastForwardOnly => l.gitFastForward,
                  GitPullStrategy.merge => l.gitMerge,
                  GitPullStrategy.rebase => l.gitRebase,
                },
                onSelected: (value) => setState(() => strategy = value),
              ),
              BusyApiActionRow(
                title: l.gitFetch,
                enabled: !busy,
                onTap: busy
                    ? null
                    : () => _action(() async {
                        if (await _trust()) await widget.repository.fetch();
                      }),
              ),
              BusyApiActionRow(
                title: l.gitPull,
                enabled: !busy,
                onTap: busy
                    ? null
                    : () => _action(() async {
                        if (await _trust()) {
                          await widget.repository.pull(
                            strategy,
                            hasUnsavedBuffers: unsaved,
                          );
                        }
                      }),
              ),
              BusyApiActionRow(
                title: l.gitPush,
                enabled: !busy,
                onTap: busy
                    ? null
                    : () => _action(() async {
                        if (await _trust()) await widget.repository.push();
                      }),
              ),
            ],
          ),
        ],
      ),
    );
    return BusyApiDialogShell(
      title: l.gitChanges,
      maxWidth: BusyApiSizes.modalMaxWidth,
      actions: [
        BusyApiDialogButton(
          label: l.close,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
      ],
      children: [
        BusyApiStatusBox(
          message: l.gitRepositoryStatus(
            (currentStatus == null
                    ? widget.repository.info.branch
                    : currentStatus.branch) ??
                (currentStatus == null
                        ? widget.repository.info.commit
                        : currentStatus.commit)
                    ?.substring(0, 12) ??
                l.gitUnborn,
            currentStatus?.ahead ?? 0,
            currentStatus?.behind ?? 0,
          ),
        ),
        if (widget.repository.info.inProgress != null)
          BusyApiStatusBox(
            message: l.gitInProgress(widget.repository.info.inProgress!),
            kind: BusyApiStatusKind.warning,
          ),
        if (busy && (ModalRoute.of(context)?.isCurrent ?? false))
          const LinearProgressIndicator(),
        if (error != null)
          BusyApiStatusBox(message: error!, kind: BusyApiStatusKind.error),
        BusyApiPopupSelector<int>(
          value: page,
          label: labels[page],
          tooltip: l.gitChanges,
          options: [
            for (var i = 0; i < labels.length; i++)
              BusyApiPopupSelectorOption(
                value: i,
                label: labels[i],
                icon: icons[i],
              ),
          ],
          onSelected: (value) => setState(() => page = value),
        ),
        SizedBox(
          height:
              MediaQuery.sizeOf(context).height *
              BusyApiSizes.modalMaxHeightFraction /
              2,
          child: BusyApiRetainedCrossfade(
            index: page,
            children: [changesView, historyView, branchesView],
          ),
        ),
        if (selected != null)
          BusyApiDisclosure(
            key: ValueKey(selected),
            initiallyExpanded: true,
            title: Text(selected!),
            subtitle: Text(l.gitDiffHelp),
            children: [BusyApiRawSourceView(source: diff ?? '', patch: true)],
          ),
        if (changes.isEmpty && !busy) Text(l.gitNoChanges),
      ],
    );
  }
}

Future<void> showSemanticReview(
  BuildContext context,
  WorkspaceController controller,
  Future<void> Function(Map<String, dynamic>) reveal,
) async {
  final project = controller.project, root = controller.root;
  if (project == null || root == null) return;
  final revision = TextEditingController(text: 'HEAD~1');
  final link = TextEditingController();
  var mergeBase = false;
  ModalRoute<bool>? selectionRoute;
  final accepted = await showBusyApiModalDialog<bool>(
    onRoutePushed: (route, _) => selectionRoute = route,
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => BusyApiDialogShell(
        title: context.l10n.semanticReview,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.cancel,
            onPressed: () => Navigator.pop(context, false),
          ),
          BusyApiDialogButton(
            label: context.l10n.semanticReview,
            suggested: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        children: [
          BusyApiGroupedList(
            children: [
              BusyApiGroupedTextEntry(
                controller: revision,
                label: context.l10n.semanticBaseline,
              ),
              BusyApiSwitchRow(
                value: mergeBase,
                title: context.l10n.semanticMergeBase,
                onChanged: (value) => setState(() => mergeBase = value),
              ),
              BusyApiGroupedTextEntry(
                controller: link,
                label: context.l10n.semanticReviewLink,
              ),
            ],
          ),
        ],
      ),
    ),
  );
  await selectionRoute?.completed;
  final revisionText = revision.text, linkText = link.text;
  revision.dispose();
  link.dispose();
  if (accepted != true || !context.mounted) return;
  final repository = await GitRepository.discover(project.access.boundary);
  if (!context.mounted) return;
  if (repository == null) {
    throw CoreFailure('git.repository', context.l10n.gitNoRepository);
  }
  final baselineRevision = mergeBase
      ? await repository.mergeBase('HEAD', revisionText)
      : revisionText;
  final historical = await repository.historicalSnapshot(
    revision: baselineRevision,
    projectBoundary: project.access.boundary,
    rootPath: p.relative(
      Uri.parse(root).toFilePath(),
      from: project.access.boundary,
    ),
    engine: project.engine,
  );
  final current = await project.captureContractSnapshot(root);
  final review = await OasdiffAdapter().compare(
    historical.snapshot,
    current.snapshot,
    project.engine,
    baselineAnalysis: historical.analysis,
    currentAnalysis: current.analysis,
  );
  if (!context.mounted || !identical(project, controller.project)) return;
  await showBusyApiModalDialog<void>(
    context: context,
    builder: (context) => BusyApiDialogShell(
      title: context.l10n.semanticReview,
      maxWidth: BusyApiSizes.modalMaxWidth,
      actions: [
        BusyApiDialogButton(
          label: context.l10n.close,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      children: [
        Text(
          review.complete
              ? context.l10n.semanticQualified
              : context.l10n.semanticIncomplete,
        ),
        SelectableText(
          context.l10n.semanticInputDetails(
            historical.commit,
            current.snapshot.sourceIdentity,
            review.toolVersion,
          ),
        ),
        SizedBox(
          height:
              MediaQuery.sizeOf(context).height *
              BusyApiSizes.modalMaxHeightFraction /
              2,
          child: ListView(
            children: [
              for (final change in review.changes)
                BusyApiActionRow(
                  title:
                      '${context.l10n.semanticSeverity(change.severity.name)} · ${change.rule}',
                  subtitle:
                      '${change.method ?? ''} ${change.path ?? ''} · ${change.message}',
                  onTap: change.after == null && change.before == null
                      ? null
                      : () => reveal(
                          Map<String, dynamic>.from(
                            change.after ?? change.before!,
                          ),
                        ),
                ),
            ],
          ),
        ),
        BusyApiDisclosure(
          title: Text(context.l10n.semanticRawDiff),
          children: [BusyApiRawSourceView(source: review.rawDiff, patch: true)],
        ),
        BusyApiDisclosure(
          title: Text(context.l10n.semanticDerivedInputs),
          children: [
            BusyApiReviewComparison(
              before: review.baselineText,
              after: review.currentText,
            ),
          ],
        ),
        Wrap(
          spacing: BusyApiSpacing.sm,
          children: [
            BusyApiPushButton.standard(
              onPressed: () async {
                final target = await getSaveLocation(
                  suggestedName: 'busyapi-semantic-review.txt',
                );
                if (target != null) {
                  await File(target.path)
                      .writeAsString(review.summary(), flush: true);
                }
              },
              child: Text(context.l10n.semanticExport),
            ),
            if (linkText.isNotEmpty)
              BusyApiPushButton.standard(
                onPressed: () => ExternalUriService().open(Uri.parse(linkText)),
                child: Text(context.l10n.semanticOpenLink),
              ),
          ],
        ),
      ],
    ),
  );
}
