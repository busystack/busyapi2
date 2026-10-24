import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';
import '../comparison/review_comparison.dart';
import 'output_destination.dart';
import 'workspace_controller.dart';
import 'project_search.dart' show BusyApiReviewPages;

Future<void> showMigrationReview(
  BuildContext context,
  WorkspaceController workspace, {
  required Future<void> Function(Map<String, dynamic>) reveal,
}) async {
  final owner = workspace.project, root = workspace.root;
  if (owner == null ||
      root == null ||
      !await workspace.flush() ||
      !context.mounted ||
      !identical(workspace.project, owner) ||
      workspace.root != root) {
    return;
  }
  final result = await showBusyApiModalDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) =>
        _MigrationReview(workspace: workspace, owner: owner, root: root),
  );
  if (result != null &&
      context.mounted &&
      !workspace.disposed &&
      identical(workspace.project, owner) &&
      workspace.root == root) {
    await reveal(result);
  }
}

class _MigrationReview extends StatefulWidget {
  const _MigrationReview({
    required this.workspace,
    required this.owner,
    required this.root,
  });
  final WorkspaceController workspace;
  final BusyProject owner;
  final String root;
  @override
  State<_MigrationReview> createState() => _MigrationReviewState();
}

class _MigrationReviewState extends State<_MigrationReview> {
  String target = '3.2.1';
  String? destination, failure, request;
  MigrationOutput? output;
  final decisions = <String, String>{};
  bool busy = false, publishing = false, published = false, cancelled = false;
  int epoch = 0, resourceIndex = 0, problemPage = 0;
  bool get current =>
      mounted &&
      !widget.workspace.disposed &&
      identical(widget.workspace.project, widget.owner) &&
      widget.workspace.root == widget.root;
  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.workspace.removeListener(changed);
    cancelled = true;
    epoch++;
    output?.close();
    unawaited(cancelRequest());
    super.dispose();
  }

  Future<void> cancelRequest() async {
    final id = request;
    if (id == null) return;
    try {
      await widget.owner.engine.cancelPrefix(id);
    } on CoreFailure catch (error) {
      if (mounted) setState(() => failure = '${error.code}: ${error.message}');
    }
  }

  Future<void> cancel() async {
    cancelled = true;
    if (!publishing) epoch++;
    await cancelRequest();
    if (mounted && !publishing) setState(() => busy = false);
  }

  void invalidate() {
    output?.close();
    output = null;
    published = false;
    resourceIndex = 0;
    problemPage = 0;
    failure = null;
  }

  Future<void> chooseDestination() async {
    if (!current || busy) return;
    final captured = epoch,
        selected = await chooseOutputDestination(
          context,
          initialPath:
              destination ??
              p.join(widget.owner.access.boundary, 'busyapi-migrated'),
        );
    if (selected != null && current && captured == epoch) {
      setState(() {
        invalidate();
        destination = selected;
      });
    }
  }

  Future<void> prepare() async {
    if (!current || busy) return;
    final captured = ++epoch;
    final selected =
        destination ??
        await chooseOutputDestination(
          context,
          initialPath: p.join(widget.owner.access.boundary, 'busyapi-migrated'),
        );
    if (selected == null || !current || captured != epoch) return;
    setState(() {
      invalidate();
      destination = selected;
      cancelled = false;
      busy = true;
      request = 'migration-review-$captured:';
    });
    try {
      final result = await widget.owner.prepareMigration(
        widget.root,
        selected,
        targetVersion: target,
        decisions: decisions,
        requestId: request,
        cancelled: () => cancelled || !current || captured != epoch,
        onResourceRefreshed: (resource) =>
            widget.workspace.resourceRefreshed(widget.owner, resource),
      );
      if (!current || captured != epoch) {
        result.close();
        return;
      }
      setState(() => output = result);
    } on CoreFailure catch (error) {
      if (current && captured == epoch) {
        setState(() => failure = '${error.code}: ${error.message}');
      }
    } finally {
      if (mounted && captured == epoch) setState(() => busy = false);
    }
  }

  Future<void> publish() async {
    final reviewed = output;
    if (!current ||
        busy ||
        reviewed == null ||
        !reviewed.publishable ||
        reviewed.outdated) {
      return;
    }
    final captured = epoch;
    setState(() {
      busy = true;
      publishing = true;
      failure = null;
      cancelled = false;
    });
    try {
      if (await reviewed.existing() != null) {
        if (current) {
          setState(() => failure = context.l10n.migrationOutputExists);
        }
        return;
      }
      await reviewed.publish(cancelled: () => cancelled || !current);
      if (current && captured == epoch && identical(output, reviewed)) {
        setState(() => published = true);
      }
    } on CoreFailure catch (error) {
      if (current) setState(() => failure = '${error.code}: ${error.message}');
    } on OutputDirectoryChanged catch (error) {
      if (current) {
        setState(
          () => failure = error.published
              ? context.l10n.outputOutdated
              : context.l10n.migrationOutputExists,
        );
      }
    } finally {
      if (mounted && captured == epoch && identical(output, reviewed)) {
        setState(() {
          busy = false;
          publishing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n,
        review = output,
        changes = review?.changes ?? const <MigrationChange>[];
    return BusyApiDialogShell(
      title: l.migrateContract,
      actions: [
        BusyApiDialogButton(
          label: busy ? l.cancel : l.close,
          onPressed: busy
              ? () => unawaited(cancel())
              : () => Navigator.pop(context),
        ),
        if (!published)
          BusyApiDialogButton(
            label: l.migrationReview,
            onPressed: current && !busy ? () => unawaited(prepare()) : null,
          ),
        if (!published)
          BusyApiDialogButton(
            label: l.migrationPublish,
            suggested: true,
            onPressed:
                current &&
                    !busy &&
                    review?.publishable == true &&
                    review?.outdated == false
                ? () => unawaited(publish())
                : null,
          ),
      ],
      children: [
        Text(l.migrationHelp),
        BusyApiComboRow<String>(
          title: l.migrationTarget,
          selected: target,
          values: const ['2.0', '3.0.4', '3.1.2', '3.2.1'],
          labelFor: (value) => value,
          enabled: !busy && !published,
          onSelected: (value) => setState(() {
            invalidate();
            target = value;
            decisions.clear();
          }),
        ),
        if (destination != null)
          BusyApiActionRow(
            title: l.chooseOutputFolder,
            subtitle: destination!,
            onTap: !busy && !published
                ? () => unawaited(chooseDestination())
                : null,
          ),
        if (busy) const LinearProgressIndicator(),
        if (failure != null)
          BusyApiStatusBox(message: failure!, kind: BusyApiStatusKind.error),
        if (published)
          BusyApiStatusBox(
            message: l.migrationPublished,
            kind: BusyApiStatusKind.information,
          ),
        if (review != null) ...[
          BusyApiStatusBox(
            message: review.outdated || !current
                ? l.outputOutdated
                : switch (review.status) {
                    MigrationStatus.faithfullyConvertible =>
                      l.migrationFaithful,
                    MigrationStatus.requiresDecision => l.migrationDecisions,
                    MigrationStatus.blocked => l.migrationBlocked,
                  },
            kind: review.publishable
                ? BusyApiStatusKind.information
                : BusyApiStatusKind.warning,
          ),
          SelectableText(review.identity),
          if ((review.result['presentationChanges'] as List).isNotEmpty)
            Text(l.migrationPresentation),
          if (review.problems.length > 50)
            BusyApiReviewPages(
              page: problemPage,
              pages: (review.problems.length / 50).ceil(),
              onChanged: (page) => setState(() => problemPage = page),
            ),
          for (final problem
              in review.problems.skip(problemPage * 50).take(50)) ...[
            BusyApiActionRow(
              title: problem.message,
              subtitle: '${problem.resource} ${problem.pointer}',
              onTap: busy
                  ? null
                  : () => Navigator.pop(context, <String, dynamic>{
                      'root': widget.root,
                      'resource': problem.resource,
                      'pointer': problem.pointer,
                      'generation': review.snapshot.resources.firstWhere(
                        (resource) => resource['id'] == problem.resource,
                      )['generation'],
                      'range': [problem.range.start, problem.range.end],
                      'data': false,
                    }),
            ),
            if (problem.choices.isNotEmpty)
              BusyApiComboRow<String>(
                title: problem.code,
                selected: decisions[problem.id] ?? '',
                values: ['', ...problem.choices],
                labelFor: (value) => value.isEmpty
                    ? l.migrationKeepUnresolved
                    : value == 'discard-ignored-siblings'
                    ? l.migrationDiscardIgnored
                    : value == 'discard-unrecognized-schema-keyword'
                    ? l.migrationDiscardAnnotation
                    : value,
                enabled: !busy,
                onSelected: (value) => setState(() {
                  if (value.isEmpty) {
                    decisions.remove(problem.id);
                  } else {
                    decisions[problem.id] = value;
                  }
                }),
              ),
          ],
          if (changes.isNotEmpty) ...[
            BusyApiComboRow<int>(
              title: l.generatedFiles,
              selected: resourceIndex,
              values: List.generate(changes.length, (index) => index),
              labelFor: (index) => changes[index].resource,
              enabled: !busy,
              onSelected: (value) => setState(() => resourceIndex = value),
            ),
            SelectableText(changes[resourceIndex].destination),
            BusyApiReviewComparison(
              before: changes[resourceIndex].before,
              after: changes[resourceIndex].after,
            ),
          ] else
            for (final resource
                in (review.result['affectedResources'] as List).cast<Map>())
              SelectableText(resource['resource'] as String),
        ],
      ],
    );
  }
}
