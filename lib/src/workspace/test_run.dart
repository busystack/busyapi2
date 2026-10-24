import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';
import '../platform/secret_store.dart';
import 'workspace_controller.dart';

Future<void> showContractTests(
  BuildContext context,
  WorkspaceController workspace,
  EnvironmentSecretStore secrets,
) async {
  final project = workspace.project, root = workspace.root;
  if (project == null || root == null || !await workspace.flush()) return;
  final captured = await project.captureContractSnapshot(root);
  if (!context.mounted ||
      !identical(project, workspace.project) ||
      root != workspace.root) {
    return;
  }
  final configuration = ExecutionConfiguration.parse(
    captured.snapshot.configuration.singleOrNull,
    project.access.boundary,
  );
  await showBusyApiModalDialog<void>(
    context: context,
    builder: (_) => ContractTestsDialog(
      workspace: workspace,
      owner: project,
      root: root,
      captured: captured,
      configuration: configuration,
      secrets: secrets,
    ),
  );
}

class ContractTestsDialog extends StatefulWidget {
  const ContractTestsDialog({
    super.key,
    required this.workspace,
    required this.owner,
    required this.root,
    required this.captured,
    required this.configuration,
    required this.secrets,
  });
  final WorkspaceController workspace;
  final BusyProject owner;
  final String root;
  final CapturedContractSnapshot captured;
  final ExecutionConfiguration configuration;
  final EnvironmentSecretStore secrets;

  @override
  State<ContractTestsDialog> createState() => _ContractTestsDialogState();
}

class _ContractTestsDialogState extends State<ContractTestsDialog> {
  final selected = <String>{};
  RunCancellation? cancellation;
  ContractTestReport? report;
  String? environment, failure;
  bool get current =>
      mounted &&
      identical(widget.owner, widget.workspace.project) &&
      widget.root == widget.workspace.root;
  bool get busy => cancellation != null;

  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(_observe);
  }

  void _observe() {
    if (!current) cancellation?.cancel();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_observe);
    cancellation?.cancel();
    super.dispose();
  }

  Future<void> run() async {
    if (!current || busy || selected.isEmpty) return;
    if (!await widget.workspace.flush() || !current) return;
    final token = RunCancellation(), cases = List<String>.of(selected);
    setState(() {
      cancellation = token;
      report = null;
      failure = null;
    });
    try {
      final result = await const ContractTestRunner().run(
        widget.owner,
        widget.root,
        selectedCases: cases,
        resolveSecret: widget.secrets.read,
        environment: environment,
        cancellation: token,
        saved: false,
        expectedSourceIdentity: widget.captured.snapshot.sourceIdentity,
      );
      if (current && !token.cancelled) setState(() => report = result);
    } on Object catch (error) {
      if (current) {
        setState(
          () => failure = error is CoreFailure
              ? '${error.code}: ${error.message}'
              : context.l10n.contractTestExecutionFailed,
        );
      }
    } finally {
      if (mounted && identical(cancellation, token)) {
        setState(() {
          cancellation = null;
          if (token.cancelled) {
            failure = context.l10n.contractTestCancelled;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stale = !widget.captured.snapshot.current(widget.owner.store);
    final result = report;
    return BusyApiDialogShell(
      title: context.l10n.contractTests,
      maxWidth: BusyApiSizes.modalMaxWidth,
      actions: [
        BusyApiDialogButton(
          label: context.l10n.close,
          onPressed: () => Navigator.pop(context),
        ),
        if (busy)
          BusyApiDialogButton(
            label: context.l10n.cancel,
            onPressed: cancellation!.cancel,
          )
        else
          BusyApiDialogButton(
            label: context.l10n.contractTestSelected,
            suggested: true,
            onPressed: current && !stale && selected.isNotEmpty ? run : null,
          ),
      ],
      children: [
        Text(context.l10n.contractTestHelp),
        SelectableText(
          context.l10n.outputSnapshot(
            widget.captured.snapshot.sourceIdentity,
            context.l10n.outputUnsavedCopy,
          ),
        ),
        if (stale || !current)
          BusyApiStatusBox(
            message: context.l10n.contractTestOutdated,
            kind: BusyApiStatusKind.warning,
          ),
        if (widget.configuration.tests.isEmpty)
          Text(context.l10n.contractTestEmpty),
        if (widget.configuration.environments.isNotEmpty)
          BusyApiGroupedList(
            children: [
              BusyApiComboRow<String>(
                title: context.l10n.contractTestEnvironment,
                values: ['', ...widget.configuration.environments.keys],
                selected: environment ?? '',
                labelFor: (value) => value.isEmpty
                    ? context.l10n.contractTestCaseEnvironment
                    : value,
                enabled: !busy,
                onSelected: (value) =>
                    setState(() => environment = value.isEmpty ? null : value),
              ),
            ],
          ),
        BusyApiGroupedList(
          children: [
            for (final definition in widget.configuration.tests)
              if (definition['name'] case final String name)
                BusyApiActionRow(
                  title: name,
                  subtitle:
                      '${definition['operation']} · ${definition['environment'] ?? context.l10n.contractTestAuthoredServer}',
                  leading: BusyApiCheckbox(
                    value: selected.contains(name),
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              selected.add(name);
                            } else {
                              selected.remove(name);
                            }
                          }),
                  ),
                  onTap: busy
                      ? null
                      : () => setState(() {
                          if (!selected.remove(name)) selected.add(name);
                        }),
                ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (failure != null)
          BusyApiStatusBox(message: failure!, kind: BusyApiStatusKind.error),
        if (result != null) ...[
          BusyApiStatusBox(
            message: !result.complete
                ? context.l10n.contractTestIncomplete
                : result.passed
                ? context.l10n.contractTestPassed
                : context.l10n.contractTestFailed,
            kind: !result.complete
                ? BusyApiStatusKind.warning
                : result.passed
                ? BusyApiStatusKind.success
                : BusyApiStatusKind.error,
          ),
          Text(
            context.l10n.contractTestCoverage(
              result.executedOperations.length,
              result.untestedOperations.length,
            ),
          ),
          for (final value in result.cases)
            BusyApiGroupedList(
              children: [
                BusyApiActionRow(
                  title: value.name,
                  subtitle:
                      '${value.operation} · ${context.l10n.contractCaseStatus(value.status)} · ${value.dispatched ? context.l10n.contractTestDispatched : context.l10n.contractTestNotSent}${value.responseStatus == null ? '' : ' · HTTP ${value.responseStatus}'}',
                ),
                for (final finding in value.findings)
                  BusyApiActionRow(
                    title: '${finding['code']}',
                    subtitle: '${finding['message']}',
                    titleWidget: SelectableText('${finding['code']}'),
                    subtitleWidget: SelectableText('${finding['message']}'),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}
