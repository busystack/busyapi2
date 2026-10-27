import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/localization.dart';
import 'workspace_controller.dart';
import 'diagnostic_fix.dart';
import '../source/source_editor.dart';

final _diagnosticViews =
    Expando<Map<(String, int, String), List<SourceDiagnostic>>>();
final _fieldDiagnosticViews =
    Expando<Map<(String, String, int), Map<String, Map<String, dynamic>>>>();

String workspaceCheckSummary(BuildContext context, WorkspaceController c) {
  final l = context.l10n, result = c.analysis;
  if (c.checking || c.checkingSemantics || result?['status'] == 'checking') {
    return l.checking;
  }
  if (c.error != null) return l.helperFailure;
  if (result == null) return l.checkNoCurrentResult;
  return result['complete'] == true ? l.checkCompleteForScope : l.incomplete;
}

/// A field error belongs to the current physical input, never the last-good
/// projection. Index once per immutable result, not once for every field.
String? authoredFieldProblem(
  BuildContext context,
  WorkspaceController controller,
  Map<String, dynamic> item,
  String field,
) {
  final result = controller.analysis, resource = item['resource'];
  final buffer = controller.store?.buffers[resource];
  if (result == null ||
      controller.root == null ||
      controller.checking ||
      controller.error != null ||
      item['root'] != controller.root ||
      buffer == null ||
      item['generation'] != buffer.generation ||
      !(result['resources'] as List? ?? []).whereType<Map>().any(
        (r) => r['id'] == resource && r['generation'] == buffer.generation,
      )) {
    return null;
  }
  final views = _fieldDiagnosticViews[result] ??= {};
  final key = (controller.root!, buffer.id, buffer.generation);
  final index = views.putIfAbsent(key, () {
    final output = <String, Map<String, dynamic>>{};
    for (final finding
        in (result['findings'] as List? ?? []).whereType<Map>()) {
      if (finding['root'] == controller.root &&
          finding['resource'] == buffer.id &&
          finding['severity'] == 'error' &&
          finding['pointer'] is String) {
        final pointer = finding['occurrencePointer'] ?? finding['pointer'];
        if (pointer is String) {
          output.putIfAbsent(pointer, () => Map<String, dynamic>.from(finding));
        }
      }
    }
    return output;
  });
  if (views.length > 4) views.remove(views.keys.first);
  final finding =
      index['${item['pointer']}/${field.replaceAll('~', '~0').replaceAll('/', '~1')}'];
  return finding == null ? null : problemMessage(context, finding);
}

List<SourceDiagnostic> sourceDiagnostics(
  BuildContext context,
  WorkspaceController controller,
) {
  final buffer = controller.buffer, result = controller.analysis;
  if (buffer == null ||
      result == null ||
      controller.checking ||
      controller.error != null) {
    return const [];
  }
  final resources = result['resources'] as List? ?? const [];
  if (!resources.whereType<Map>().any(
    (r) => r['id'] == buffer.id && r['generation'] == buffer.generation,
  )) {
    return const [];
  }
  final views = _diagnosticViews[result] ??= {};
  final key = (buffer.id, buffer.generation, context.l10n.localeName);
  final cached = views[key];
  if (cached != null) return cached;
  final output = <SourceDiagnostic>[];
  for (final finding
      in (result['findings'] as List? ?? const []).whereType<Map>()) {
    if (finding['resource'] != buffer.id ||
        finding['root'] != controller.root) {
      continue;
    }
    final range = finding['range'];
    if (range is! List ||
        range.length != 2 ||
        range[0] is! int ||
        range[1] is! int) {
      continue;
    }
    output.add(
      SourceDiagnostic(
        resource: buffer.id,
        generation: buffer.generation,
        start: range[0] as int,
        end: range[1] as int,
        code: finding['code'] as String,
        severity: finding['severity'] as String,
        message: problemMessage(context, Map<String, dynamic>.from(finding)),
      ),
    );
  }
  if (views.length >= 4) views.remove(views.keys.first);
  return views[key] = List.unmodifiable(output);
}

String problemCategoryLabel(BuildContext context, String category) =>
    switch (category) {
      'syntax' => context.l10n.syntaxChecks,
      'openapi' => context.l10n.openapiValidity,
      'policy' => context.l10n.policyGovernance,
      'security' => context.l10n.securityDesign,
      'runtime' => context.l10n.runtimeConformance,
      _ => context.l10n.allProblemCategories,
    };

String problemMessage(BuildContext context, Map<String, dynamic> finding) {
  final code = finding['code'] as String;
  final l = context.l10n;
  return switch (code) {
    _ when code.startsWith('policy.rule.') => l.policyRuleFinding,
    'policy.code.approval-required' => l.policyCodeApprovalRequired,
    'policy.expression.isolation' => l.policyExpressionIsolation,
    'policy.numeric.incomplete' => l.policyNumericIncomplete,
    _ when code.startsWith('policy.') => l.policyExecutionIncomplete,
    _ when code.startsWith('limit.policy.') => l.policyExecutionIncomplete,
    'parameter.container.type' => l.parameterContainerInvalid,
    'parameter.object.type' => l.parameterObjectInvalid,
    'parameter.duplicate' => l.parameterDuplicate,
    'parameter.reference.cycle' => l.parameterReferenceCycle,
    'path.reference.overlap' => l.pathReferenceOverlap,
    'path.reference.cycle.incomplete' => l.pathReferenceCycle,
    'callback.reference.cycle.incomplete' => l.callbackReferenceCycle,
    'limit.path.reference.depth' => l.pathReferenceLimit,
    'limit.operation.occurrences' => l.operationOccurrenceLimit,
    'parameter.path.required' => l.parameterPathRequired,
    'parameter.path.missing' => l.parameterPathMissing,
    'parameter.path.name' => l.parameterPathName,
    'parameter.querystring.field' => l.parameterQuerystringField,
    'parameter.querystring.content' => l.parameterQuerystringContent,
    'parameter.querystring.duplicate' => l.parameterQuerystringDuplicate,
    'parameter.querystring.mixed' => l.parameterQuerystringMixed,
    'parameter.cookie.explode' => l.parameterCookieExplode,
    'operation.id.duplicate' => l.operationIdDuplicate,
    'schema.keyword.invalid' => l.schemaKeywordInvalid,
    'schema.dialect.location' => l.schemaDialectLocation,
    'server.variable.default-enum' => l.serverVariableDefaultEnum,
    'server.url.template' => l.serverTemplateInvalid,
    'server.url.query-fragment' => l.serverQueryFragment,
    'server.variable.repeated' => l.serverVariableRepeated,
    'server.name.duplicate' => l.serverNameDuplicate,
    'limit.authoring.template' => l.serverTemplateLimit,
    'tag.name.duplicate' => l.tagNameDuplicate,
    'tag.parent.missing' => l.tagParentMissing,
    'tag.parent.ambiguous' => l.tagParentAmbiguous,
    'tag.parent.cycle' => l.tagParentCycle,
    'example.schema.incompatible' => l.schemaExampleIncompatible,
    'schema.dialect.malformed' => l.schemaDialectMalformed,
    'schema.dialect.incomplete' => l.schemaDialectIncomplete,
    'schema.execution.incomplete' => l.schemaExecutionIncomplete,
    'schema.numeric.provenance' => l.schemaNumericProvenance,
    _ when code.startsWith('limit.schema.') => l.schemaEvaluationLimit,
    'security.credential-like.aws' => l.securityIdentifierAdvice,
    'security.uri.credentials' => l.securityUriCredentialsAdvice,
    'security.uri.credential-like-query' => l.securityUriQueryAdvice,
    'security.declaration.implicit-public' => l.securityPublicAdvice,
    'security.resource.unencrypted' => l.securityResourceAdvice,
    'security.limit' => l.securityLimitAdvice,
    _ when code.startsWith('security.credential-like.') =>
      l.securityCredentialAdvice,
    _ => finding['message'] as String,
  };
}

/// Display filters are private view state, never policy enablement or severity.
class ProblemsPanel extends StatefulWidget {
  const ProblemsPanel({
    super.key,
    required this.controller,
    required this.reveal,
  });
  final WorkspaceController controller;
  final void Function(Map<String, dynamic>) reveal;
  @override
  State<ProblemsPanel> createState() => _ProblemsPanelState();
}

class _ProblemsPanelState extends State<ProblemsPanel> {
  static const categories = [
    'all',
    'syntax',
    'openapi',
    'policy',
    'security',
    'runtime',
  ];
  @override
  Widget build(BuildContext context) {
    final c = widget.controller, l = context.l10n;
    final saved = c.layoutState['problemCategory'];
    final selected = categories.contains(saved) ? saved as String : 'all';
    final findings = (c.analysis?['findings'] as List? ?? [])
        .whereType<Map>()
        .where(
          (finding) => selected == 'all' || finding['category'] == selected,
        )
        .toList();
    final metadata = c.analysis?['categories']?[selected];
    return ListView.builder(
      key: PageStorageKey((c.project, c.root, selected)),
      itemCount: findings.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return BusyApiComboRow<String>(
            title: l.problemCategory,
            values: categories,
            selected: selected,
            labelFor: (value) => problemCategoryLabel(context, value),
            onSelected: (value) {
              if (!mounted || c.disposed) return;
              setState(
                () => c.layoutState = {
                  ...c.layoutState,
                  'problemCategory': value,
                },
              );
            },
          );
        }
        if (index == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (selected == 'security')
                Tooltip(
                  message: l.securityDesignExplanation,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BusyApiSpacing.md,
                    ),
                    child: Text(
                      l.securityDesignExplanation,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (selected != 'all')
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BusyApiSpacing.md,
                  ),
                  child: Text(
                    c.checking || selected == 'openapi' && c.checkingSemantics
                        ? l.checking
                        : c.analysis == null || c.error != null
                        ? l.outdated
                        : metadata is! Map
                        ? l.checkNoCurrentResult
                        : metadata['complete'] == true
                        ? l.checkCompleteForScope
                        : metadata['status'] == 'not-implemented'
                        ? l.checkNotImplemented
                        : metadata['status'] == 'not-run'
                        ? l.checkNotRun
                        : l.incomplete,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        }
        final finding = Map<String, dynamic>.from(findings[index - 2]);
        final contextSnapshot = c.analysis?['contextSnapshot'];
        final fixes = finding['fixes'] as List? ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BusyApiActionRow(
              title:
                  '${problemCategoryLabel(context, finding['category'] as String)} · ${finding['code']}',
              subtitle: problemMessage(context, finding),
              onTap: () => widget.reveal(finding),
            ),
            if (!c.checking &&
                c.error == null &&
                contextSnapshot is String &&
                fixes.contains('path-parameter-required'))
              BusyApiActionRow(
                title: l.repairPathParameter,
                onTap: () => showDiagnosticFix(
                  context,
                  c,
                  finding,
                  contextSnapshot,
                  'path-parameter-required',
                ),
              ),
          ],
        );
      },
    );
  }
}
