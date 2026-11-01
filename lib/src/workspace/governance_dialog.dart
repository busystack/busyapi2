import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/busyapi_search_field.dart';
import '../app/localization.dart';
import 'workspace_controller.dart';

Future<Map<String, dynamic>?> showGovernance(
  BuildContext context,
  WorkspaceController controller,
) async {
  final owner = controller.project, root = controller.root;
  if (owner == null || root == null || controller.disposed) return null;
  ModalRoute<Map<String, dynamic>>? route;
  final target = await showBusyApiModalDialog<Map<String, dynamic>>(
    context: context,
    onRoutePushed: (value, _) => route = value,
    builder: (_) => _GovernanceDialog(controller: controller),
  );
  if (route case final TransitionRoute<dynamic> exiting) {
    await exiting.completed;
  }
  return !controller.disposed &&
          identical(owner, controller.project) &&
          controller.root == root
      ? target
      : null;
}

class _GovernanceDialog extends StatefulWidget {
  const _GovernanceDialog({required this.controller});
  final WorkspaceController controller;
  @override
  State<_GovernanceDialog> createState() => _GovernanceDialogState();
}

class _GovernanceDialogState extends State<_GovernanceDialog> {
  late final owner = widget.controller.project;
  late final root = widget.controller.root;
  final search = TextEditingController();
  String query = '', selected = '';
  String? failure;
  bool starting = false;
  PolicyCodeReview? codeReview;
  Map<String, dynamic>? codeTrust;
  late final reviewPrefix = 'policy-review-${identityHashCode(this)}-';
  int reviewGeneration = 0;
  @override
  void initState() {
    super.initState();
    final views = widget.controller.layoutState['governanceViews'];
    final saved = views is Map ? views[root] : null;
    if (saved is Map) {
      final value = saved['query'], name = saved['selected'];
      if (value is String && value.length <= 4096) {
        search.text = query = value;
      }
      if (name is String && name.length <= 128) {
        selected = name;
      }
    }
  }

  void remember() {
    final c = widget.controller;
    if (c.disposed || !identical(owner, c.project)) return;
    final old = c.layoutState['governanceViews'];
    final views = <String, dynamic>{
      if (old is Map)
        for (final entry in old.entries)
          if (entry.key is String) entry.key as String: entry.value,
    }..remove(root);
    if (query.length <= 4096) {
      views[root!] = {'query': query, 'selected': selected};
    }
    while (views.length > 16) {
      views.remove(views.keys.first);
    }
    c.layoutState = {...c.layoutState, 'governanceViews': views};
  }

  bool get current =>
      mounted &&
      !widget.controller.disposed &&
      identical(owner, widget.controller.project) &&
      root == widget.controller.root;
  @override
  void dispose() {
    unawaited(
      widget.controller.engine
          .cancelPrefix(reviewPrefix)
          .catchError((Object _) {}),
    );
    remember();
    search.dispose();
    super.dispose();
  }

  Future<void> reviewCode() async {
    if (!current || starting || widget.controller.governanceRunning) return;
    final generation = ++reviewGeneration;
    setState(() {
      starting = true;
      failure = null;
      codeReview = null;
      codeTrust = null;
    });
    bool owns() => current && generation == reviewGeneration;
    try {
      final review = await widget.controller.reviewGovernanceCode(
        requestId: '$reviewPrefix$generation',
        cancelled: () => !owns(),
      );
      if (!owns()) return;
      codeReview = review;
      if (review.complete) {
        final trust = await owner!.policyCodeTrust(review);
        if (!owns()) return;
        codeTrust = trust;
      }
    } on Object catch (error) {
      if (owns()) {
        failure = error is CoreFailure ? error.code : 'policy.execution.failed';
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> runApprovedCode() async {
    final review = codeReview, trust = codeTrust;
    if (!current ||
        starting ||
        review == null ||
        trust == null ||
        !review.complete) {
      return;
    }
    setState(() {
      starting = true;
      failure = null;
    });
    try {
      final approval = await owner!.approvePolicyCode(
        review,
        expectedIdentity: trust['identity'] as String,
      );
      if (!current) return;
      await widget.controller.runGovernance(codeApproval: approval);
      if (current) {
        codeReview = null;
        codeTrust = null;
      }
    } on Object catch (error) {
      if (current) {
        failure = error is CoreFailure ? error.code : 'policy.execution.failed';
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> inspectCodeSource(Map source, {List? range}) async {
    final review = codeReview;
    if (!current || starting || review == null) return;
    setState(() {
      starting = true;
      failure = null;
    });
    try {
      await owner!.verifyPolicyCodeReview(review);
      if (!mounted || !current) return;
      Navigator.pop(context, <String, dynamic>{
        'resource': source['id'],
        'root': root,
        'identity':
            source['identity'] ??
            textIdentity(
              '${source['hasBom'] == true ? '\ufeff' : ''}${source['text']}',
            ),
        'pointer': '',
        'range': range ?? [0, 0],
      });
    } on Object catch (error) {
      if (current) {
        failure = error is CoreFailure ? error.code : 'policy.execution.failed';
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> run() async {
    if (!current || starting || widget.controller.governanceRunning) return;
    setState(() {
      starting = true;
      failure = null;
    });
    try {
      await widget.controller.runGovernance();
    } on Object catch (error) {
      if (current) {
        failure = error is CoreFailure ? error.code : 'policy.execution.failed';
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, l = context.l10n;
      final result = current ? c.analysis : null;
      final metadata = result?['categories']?['policy'];
      final rules = (result?['effectiveRules'] as List? ?? const [])
          .whereType<Map>()
          .where(
            (rule) =>
                query.isEmpty ||
                (rule['name'] as String).toLowerCase().contains(
                  query.toLowerCase(),
                ),
          )
          .toList();
      final state = !current || c.error != null
          ? l.outdated
          : c.governanceRunning
          ? l.checking
          : metadata?['complete'] == true
          ? l.checkCompleteForScope
          : metadata?['status'] == 'not-run' || metadata == null
          ? l.checkNotRun
          : l.incomplete;
      String bounded(String value, [int maximum = 512]) {
        if (value.length <= maximum) return value;
        if (value.codeUnitAt(maximum - 1) >= 0xd800 &&
            value.codeUnitAt(maximum - 1) <= 0xdbff) {
          maximum--;
        }
        return '${value.substring(0, maximum)}…';
      }

      final review = codeReview,
          sources =
              review?.resources.where((r) => r['text'] is String).toList() ??
              <Map<String, Object?>>[],
          bindings = review?.result['bindings'] as List? ?? const [],
          issues = review?.result['issues'] as List? ?? const [];

      return BusyApiDialogShell(
        title: l.policyGovernance,
        maxWidth: BusyApiSizes.modalMaxWidth,
        actions: [
          BusyApiDialogButton(
            label: l.close,
            onPressed: () => Navigator.pop(context),
          ),
          if (c.governanceRunning)
            BusyApiDialogButton(label: l.cancel, onPressed: c.cancelGovernance),
          if (review != null)
            BusyApiDialogButton(
              label: l.policyCodeBack,
              onPressed: starting
                  ? null
                  : () => setState(() {
                      codeReview = null;
                      codeTrust = null;
                    }),
            ),
          BusyApiDialogButton(
            label: l.policyCodeReview,
            onPressed: !current || starting || c.governanceRunning
                ? null
                : () => unawaited(reviewCode()),
          ),
          if (review != null)
            BusyApiDialogButton(
              label: l.policyCodeApproveOnce,
              suggested: true,
              onPressed:
                  !current ||
                      starting ||
                      c.governanceRunning ||
                      !review.complete ||
                      codeTrust == null
                  ? null
                  : () => unawaited(runApprovedCode()),
            ),
          if (review == null)
            BusyApiDialogButton(
              label: l.runGovernance,
              suggested: true,
              onPressed: !current || starting || c.governanceRunning
                  ? null
                  : () => unawaited(run()),
            ),
        ],
        children: [
          Text(
            review == null
                ? state
                : review.complete
                ? l.checkCompleteForScope
                : l.incomplete,
          ),
          if (failure != null)
            BusyApiStatusBox(
              message: l.governanceFailed(failure!),
              kind: BusyApiStatusKind.warning,
            ),
          Text(
            l.governancePrivacy,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (review != null) ...[
            Text(l.policyCodeTrust),
            Text(
              l.policyCodeIsolation,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              l.policyCodeInspect,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(review.unsaved ? l.outputUnsavedCopy : l.outputSavedSource),
            Text(
              l.policyCodeCounts(
                sources.length,
                (review.result['modules'] as List).length,
                bindings.length,
              ),
            ),
            if (codeTrust?['identity'] case final String identity)
              SelectableText(l.policyCodeIdentity(identity)),
            BusyApiReviewViewport(
              child: ListView.builder(
                itemCount: sources.length + bindings.length + issues.length,
                itemBuilder: (context, index) {
                  if (index < sources.length) {
                    final source = sources[index],
                        identity =
                            source['identity'] as String? ??
                            textIdentity(source['text'] as String);
                    return Tooltip(
                      message: bounded(source['id'] as String, 4096),
                      child: BusyApiActionRow(
                        title: bounded(source['id'] as String),
                        subtitle: l.policyCodeSource(identity),
                        onTap: starting
                            ? null
                            : () => unawaited(inspectCodeSource(source)),
                      ),
                    );
                  }
                  final at = index - sources.length;
                  if (at < bindings.length) {
                    final binding = bindings[at],
                        origin = binding['origin'] as Map,
                        source = sources
                            .where((s) => s['id'] == origin['resource'])
                            .firstOrNull;
                    return BusyApiActionRow(
                      title: bounded(
                        '${binding['specifier']} → ${binding['target'] ?? l.policyCodeUnavailable}',
                      ),
                      subtitle: l.policyCodeBinding(binding['mode'] as String),
                      onTap: starting || source == null
                          ? null
                          : () => unawaited(
                              inspectCodeSource(
                                source,
                                range: origin['range'] as List?,
                              ),
                            ),
                    );
                  }
                  final issue = issues[at - bindings.length];
                  final source = sources
                      .where((s) => s['id'] == issue['resource'])
                      .firstOrNull;
                  return BusyApiActionRow(
                    title: bounded(issue['code'] as String),
                    subtitle: bounded(
                      '${issue['resource'] ?? issue['from'] ?? ''}',
                    ),
                    onTap: starting || source == null
                        ? null
                        : () => unawaited(
                            inspectCodeSource(
                              source,
                              range: issue['range'] as List?,
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
          if (review == null) ...[
            if (metadata is Map && metadata['producer'] is String)
              SelectableText(
                '${metadata['producer']} ${metadata['producerVersion']}',
              ),
            if (metadata is Map && metadata['failSeverity'] is String)
              Text(
                l.governanceThreshold(
                  l.governanceSeverity(metadata['failSeverity'] as String),
                ),
              ),
            if (result?['configuration'] case final String identity)
              Tooltip(
                message: identity,
                child: Text(
                  l.governanceConfiguration(
                    identity.substring(0, identity.length.clamp(0, 12)),
                  ),
                ),
              ),
            BusyApiSearchField(
              controller: search,
              hintText: l.search,
              onChanged: (value) {
                setState(() => query = value);
                remember();
              },
            ),
            BusyApiReviewViewport(
              child: ListView.builder(
                itemCount: rules.length,
                itemBuilder: (context, index) {
                  final rule = rules[index],
                      name = rule['name'] as String,
                      expanded = selected == name;
                  final declarations = (rule['provenance'] as List? ?? const [])
                      .whereType<Map>()
                      .toList();
                  final expressions = rule['given'] as List? ?? const [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      BusyApiActionRow(
                        title: bounded(name, 128),
                        subtitle:
                            '${l.governanceSeverity(rule['severity'] as String)} · ${rule['applicable'] == true ? l.governanceApplicable : l.governanceNotApplicable}',
                        onTap: () {
                          setState(() => selected = expanded ? '' : name);
                          remember();
                        },
                      ),
                      if (expanded)
                        BusyApiGroupedList(
                          title: l.governanceRuleConfiguration,
                          children: [
                            BusyApiActionRow(
                              title: rule['enabled'] == true
                                  ? l.governanceEnabled
                                  : l.governanceDisabled,
                            ),
                            BusyApiActionRow(
                              title: rule['resolved'] == true
                                  ? l.governanceResolvedView
                                  : l.governanceAuthoredView,
                            ),
                            BusyApiReviewViewport(
                              child: ListView.builder(
                                itemCount:
                                    expressions.length + declarations.length,
                                itemBuilder: (context, index) {
                                  if (index < expressions.length) {
                                    return Tooltip(
                                      message: bounded(
                                        expressions[index].toString(),
                                        4096,
                                      ),
                                      child: BusyApiActionRow(
                                        title: bounded(
                                          expressions[index].toString(),
                                        ),
                                      ),
                                    );
                                  }
                                  final declaration =
                                      declarations[index - expressions.length];
                                  final resource = declaration['resource'];
                                  final source =
                                      (result?['policyResources'] as List? ??
                                              const [])
                                          .whereType<Map>()
                                          .where(
                                            (source) =>
                                                source['id'] == resource,
                                          )
                                          .firstOrNull;
                                  final canReveal =
                                      source != null &&
                                      declaration['range'] is List &&
                                      current &&
                                      !c.governanceRunning;
                                  return BusyApiActionRow(
                                    title: bounded(
                                      '$resource${declaration['pointer']}',
                                    ),
                                    subtitle: l.governanceDeclaration,
                                    onTap: !canReveal
                                        ? null
                                        : () => Navigator.pop(
                                            context,
                                            <String, dynamic>{
                                              ...Map<String, dynamic>.from(
                                                declaration,
                                              ),
                                              'root': root,
                                              'snapshot': result?['snapshot'],
                                              'identity': source['identity'],
                                            },
                                          ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ),
            Text(l.governanceRuleCount(rules.length)),
          ],
        ],
      );
    },
  );
}
