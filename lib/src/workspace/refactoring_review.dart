import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/generated/app_localizations.dart';
import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';
import 'project_search.dart' show BusyApiChangeContext, BusyApiReviewPages;
import 'workspace_controller.dart';

String refactoringFailureMessage(
  AppLocalizations l,
  String code,
) => switch (code) {
  'file.move.case-file.content' => l.fileMoveCaseContent,
  'file.move.case-file.boundary' => l.fileMoveCaseBoundary,
  'file.configuration.conflict' => l.fileConfigurationConflict,
  'refactor.configuration.collision' => l.securityRefactoringSettingsConflict,
  'refactor.configuration.ambiguous' => l.securityRefactoringSettingsAmbiguous,
  'refactor.configuration.syntax' || 'refactor.configuration.authentication' =>
    l.securityRefactoringConfigurationInvalid,
  'refactor.configuration.ownership' =>
    l.securityRefactoringConfigurationShared,
  'limit.refactor.configuration' => l.securityRefactoringConfigurationLimit,
  _ => l.refactoringFailed(code),
};

Future<void> showRefactoringReview(
  BuildContext context,
  WorkspaceController controller,
  BusyProject owner,
  RefactoringPlan plan, {
  void Function()? onApplied,
  Future<void> Function(Map<String, dynamic>)? reveal,
}) async {
  if (!context.mounted ||
      controller.disposed ||
      !identical(controller.project, owner)) {
    return;
  }
  final opening = controller.navigationGeneration;
  final result = await showBusyApiModalDialog<Object>(
    context: context,
    builder: (_) => _RefactoringReview(
      controller: controller,
      owner: owner,
      plan: plan,
      canReveal: reveal != null,
    ),
  );
  if (result == true) onApplied?.call();
  if (result is Map<String, dynamic> &&
      !controller.disposed &&
      identical(controller.project, owner) &&
      controller.navigationGeneration == opening) {
    await reveal?.call(result);
  }
}

class _RefactoringReview extends StatefulWidget {
  const _RefactoringReview({
    required this.controller,
    required this.owner,
    required this.plan,
    required this.canReveal,
  });
  final WorkspaceController controller;
  final BusyProject owner;
  final RefactoringPlan plan;
  final bool canReveal;
  @override
  State<_RefactoringReview> createState() => _RefactoringReviewState();
}

class _RefactoringReviewState extends State<_RefactoringReview> {
  static const pageSize = 50;
  int page = 0;
  bool applying = false, applied = false, usages = false;
  String? error;
  bool get current =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? false) &&
      !widget.controller.disposed &&
      identical(widget.controller.project, widget.owner);
  Future<void> apply() async {
    if (!current || applying || applied) return;
    setState(() => applying = true);
    try {
      await widget.controller.applyRefactoring(widget.owner, widget.plan);
      if (mounted && current) Navigator.pop(context, true);
    } on Object catch (failure) {
      if (!current) return;
      final code = failure is CoreFailure ? failure.code : 'refactor.failure';
      setState(() {
        applied = code == 'refactor.applied.recovery';
        error = applied
            ? context.l10n.refactoringRecoveryFailed
            : refactoringFailureMessage(context.l10n, code);
      });
    } finally {
      if (current) setState(() => applying = false);
    }
  }

  String location(String resource) => p.relative(
    Uri.parse(resource).toFilePath(),
    from: widget.owner.access.boundary,
  );
  @override
  Widget build(BuildContext context) {
    final l = context.l10n, plan = widget.plan;
    final changes = (plan.result['changes'] as List? ?? []).cast<Map>();
    final references = (plan.result['usages'] as List).cast<Map>();
    final blockers = plan.result['blockers'] as List? ?? const [];
    final count = usages ? references.length : changes.length,
        pages = ((count + pageSize - 1) ~/ pageSize).clamp(1, 100000);
    final start = page * pageSize, end = (start + pageSize).clamp(0, count);
    return PopScope(
      canPop: !applying,
      child: BusyApiDialogShell(
        title: plan.result['kind'] == 'reference-selection'
            ? l.reviewReferenceChange
            : plan.result['kind'] == 'root-remove'
            ? l.reviewRootRemoval
            : plan.result['kind'] == 'component-extract'
            ? l.reviewComponentExtraction
            : plan.result['kind'] == 'component-extract-file'
            ? l.reviewComponentFileExtraction
            : plan.result['kind'] == 'component-move'
            ? l.reviewComponentMove
            : plan.result['kind'] == 'file-move'
            ? l.reviewFileMove
            : plan.result['kind'] == 'file-create'
            ? l.reviewFileCreation
            : plan.result['kind'] == 'file-delete'
            ? l.reviewFileDeletion
            : plan.result['kind'] == 'operation-move'
            ? l.reviewOperationMove
            : plan.result['kind'] == 'reference-inline'
            ? l.reviewReferenceInlining
            : plan.result['kind'] == 'diagnostic-fix'
            ? l.reviewDiagnosticRepair
            : plan.result['kind'] == 'schema-suggestion'
            ? l.reviewSchemaSuggestion
            : plan.result['kind'] == 'response-example'
            ? l.reviewResponseExample
            : plan.result['kind'] == 'object-delete'
            ? l.reviewObjectDeletion
            : l.reviewRefactoring,
        maxWidth: BusyApiSizes.modalMaxWidth,
        closable: !applying,
        actions: [
          BusyApiDialogButton(
            label: l.cancel,
            onPressed: applying ? null : () => Navigator.pop(context),
          ),
          BusyApiDialogButton(
            label: l.apply,
            suggested: true,
            onPressed:
                applying || applied || !plan.hasChanges || blockers.isNotEmpty
                ? null
                : apply,
          ),
        ],
        children: [
          if (plan.result['kind'] == 'root-remove') ...[
            Text(l.rootRemovalImpact),
            if (blockers.isNotEmpty)
              BusyApiStatusBox(
                message: l.rootRemovalBlocked,
                kind: BusyApiStatusKind.error,
              ),
          ],
          if (plan.result['kind'] == 'component-extract')
            Text(l.componentExtractionImpact),
          if (plan.result['kind'] == 'response-example')
            Text(l.responseExampleImpact),
          if (plan.result['kind'] == 'component-extract-file') ...[
            Text(l.componentFileExtractionImpact),
            Text(l.componentFileBinding),
            SelectableText(
              '${location(plan.result['binding']['resource'])}#${plan.result['binding']['pointer']}',
            ),
          ],
          if (plan.result['kind'] == 'component-move')
            Text(
              plan.result['removedBinding'] == null
                  ? l.moveComponentImpact
                  : l.moveComponentRepairedConsumersImpact,
            ),
          if (plan.result['kind'] == 'file-move') Text(l.fileMoveImpact),
          if (plan.result['file']?['opaque'] == true)
            Text(l.fileMoveOpaqueImpact),
          if (blockers.any(
            (entry) => entry['code'] == 'file.move.policy-consumer',
          ))
            BusyApiStatusBox(
              message: l.fileMovePolicyBlocked,
              kind: BusyApiStatusKind.error,
            ),
          if (blockers.any(
            (entry) => entry['code'] == 'file.move.policy-analysis',
          ))
            BusyApiStatusBox(
              message: l.fileMovePolicyAnalysisBlocked,
              kind: BusyApiStatusKind.error,
            ),
          if (plan.result['kind'] == 'file-create') Text(l.fileCreationImpact),
          if (plan.result['kind'] == 'file-delete') ...[
            Text(
              plan.result['file']?['published'] == false
                  ? l.fileDeletionUnpublished
                  : l.fileDeletionImpact,
            ),
            if (plan.result['file']?['published'] == true &&
                plan.result['file']['source'] !=
                    plan.result['file']['publishedResource']) ...[
              Text(l.fileDeletionOriginalPath),
              SelectableText(
                location(plan.result['file']['publishedResource'] as String),
              ),
            ],
            if (blockers.any((entry) => entry['code'] == 'file.delete.root'))
              BusyApiStatusBox(
                message: l.fileDeletionRootBlocked,
                kind: BusyApiStatusKind.error,
              ),
            if (blockers.any(
              (entry) => entry['code'] == 'file.delete.analysis',
            ))
              BusyApiStatusBox(
                message: l.fileDeletionAnalysisBlocked,
                kind: BusyApiStatusKind.error,
              ),
            if (blockers.any(
              (entry) => entry['code'] == 'file.delete.consumer',
            ))
              BusyApiStatusBox(
                message: l.fileDeletionConsumersBlocked,
                kind: BusyApiStatusKind.error,
              ),
            if (blockers.any(
              (entry) => entry['code'] == 'file.delete.case-file',
            ))
              BusyApiStatusBox(
                message: l.fileDeletionCaseBlocked,
                kind: BusyApiStatusKind.error,
              ),
            if (blockers.any(
              (entry) => entry['code'] == 'file.delete.mapping-consumer',
            ))
              BusyApiStatusBox(
                message: l.fileDeletionMappingBlocked,
                kind: BusyApiStatusKind.error,
              ),
            if (blockers.any(
              (entry) => entry['code'] == 'file.delete.policy-consumer',
            ))
              BusyApiStatusBox(
                message: l.fileDeletionPolicyBlocked,
                kind: BusyApiStatusKind.error,
              ),
            if (blockers.any(
              (entry) => entry['code'] == 'file.delete.policy-analysis',
            ))
              BusyApiStatusBox(
                message: l.fileDeletionPolicyAnalysisBlocked,
                kind: BusyApiStatusKind.error,
              ),
          ],
          if (plan.result['file'] is Map &&
              plan.result['file']['retainedIdentity'] is String) ...[
            Text(l.retainedResourceIdentityImpact),
            SelectableText(plan.result['file']['retainedIdentity'] as String),
          ],
          if (plan.result['kind'] == 'reference-inline')
            Text(l.referenceInliningImpact),
          if (plan.result['kind'] == 'diagnostic-fix')
            Text(l.pathParameterRepairImpact),
          if (plan.result['kind'] == 'reference-selection') ...[
            Text(l.referenceChangeImpact),
            if (plan.result['dynamic'] == true) Text(l.sourceDynamicDefinition),
          ],
          if (plan.result['kind'] == 'object-delete') ...[
            Text(l.objectDeletionImpact),
            if (blockers.isNotEmpty)
              BusyApiStatusBox(
                message: plan.result['kind'] == 'file-move'
                    ? l.fileMoveBlocked(blockers.length)
                    : l.objectDeletionBlocked(blockers.length),
                kind: BusyApiStatusKind.error,
              ),
            if ((plan.result['preservedRelationships'] as List).isNotEmpty)
              Text(
                l.objectDeletionPreserved(
                  (plan.result['preservedRelationships'] as List).join(', '),
                ),
              ),
          ],
          if (plan.result['kind'] == 'schema-suggestion') ...[
            Text(l.schemaSuggestionAssumptions),
            Text(l.schemaSuggestionAlternatives),
            if ((plan.result['assumptions'] as List).contains('empty-array'))
              Text(l.schemaSuggestionEmptyArray),
            if ((plan.result['assumptions'] as List).contains(
              'heterogeneous-array',
            ))
              Text(l.schemaSuggestionDiverseArray),
          ],
          if (plan.result['kind'] == 'property-rename') ...[
            Text(l.propertyRenameImpact),
            if ((plan.result['preservedNameConstraints'] as List).isNotEmpty)
              Text(
                l.propertyRenameNameConstraints(
                  (plan.result['preservedNameConstraints'] as List).join(', '),
                ),
              ),
          ],
          Text(
            plan.result['kind'] == 'root-remove'
                ? l.rootRemovalScope
                : l.refactoringScope(changes.length, plan.checkedRoots.length),
          ),
          if (plan.result['kind'] == 'operation-move') ...[
            Text(l.operationMoveImpact),
            if (references.any(
              (reference) =>
                  reference['effect'] == 'containing-definition-changes',
            ))
              Text(l.operationMoveSharedImpact),
            Text(
              plan.result['context'] == 'preserve'
                  ? l.operationMovePreserveImpact
                  : l.operationMoveDestinationImpact,
            ),
          ],
          Text(l.refactoringExternalConsumers),
          SelectableText(
            const [
                  'reference-selection',
                  'component-extract',
                  'component-extract-file',
                  'component-move',
                  'file-move',
                  'file-create',
                  'file-delete',
                  'operation-move',
                  'reference-inline',
                ].contains(plan.result['kind'])
                ? '${location(plan.result['from']['resource'])}#${plan.result['from']['pointer']} → ${location(plan.result['to']['resource'])}#${plan.result['to']['pointer']}'
                : '${plan.result['from']['pointer']} → ${plan.result['to']['pointer']}',
          ),
          BusyApiSwitchRow(
            title: l.resolvedUsages(references.length),
            value: usages,
            onChanged: applying
                ? (_) {}
                : (value) => setState(() {
                    usages = value;
                    page = 0;
                  }),
            enabled: !applying,
          ),
          if (error != null)
            BusyApiStatusBox(message: error!, kind: BusyApiStatusKind.error),
          BusyApiReviewPages(
            page: page,
            pages: pages,
            enabled: !applying,
            onChanged: (value) => setState(() => page = value),
          ),
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: end - start,
              itemBuilder: (_, row) {
                final index = start + row;
                if (usages) {
                  final reference = references[index];
                  return BusyApiGroupedList(
                    children: [
                      BusyApiActionRow(
                        title: location(reference['resource']),
                        onTap: !applying && widget.canReveal
                            ? () => Navigator.pop(
                                context,
                                Map<String, dynamic>.from(reference),
                              )
                            : null,
                        subtitle:
                            '${reference['pointer']}\n${reference['connection'] == 'policy-input'
                                ? l.filePolicyInput
                                : reference['connection'] == 'case-file'
                                ? l.fileCaseInput
                                : reference['connection'] == 'root-analysis'
                                ? l.rootRemovalAnalysis
                                : reference['connection']} → ${reference['target']['pointer']}'
                            '${reference['roots'] is List ? '\n${l.refactoringUsageRoots((reference['roots'] as List).cast<String>().map(location).join(', '))}' : ''}'
                            '${reference['effect'] == 'retained-inline-target' ? '\n${l.inlineRetainedTarget}' : ''}'
                            '${reference['effect'] == 'containing-definition-changes' ? '\n${l.operationMoveSharedOccurrence}' : ''}',
                      ),
                    ],
                  );
                }
                final change = changes[index], id = change['resource'];
                if (change['fileAction'] == 'create' ||
                    change['fileAction'] == 'delete') {
                  return BusyApiGroupedList(
                    title: location(id),
                    children: [
                      if (change['before'] == '' && change['after'] == '')
                        Text(l.sourceFileEmpty)
                      else
                        BusyApiChangeContext(
                          key: ValueKey(id),
                          preview: () => SearchChangePreview(
                            '',
                            change['before'] as String,
                            change['after'] as String,
                            '',
                          ),
                        ),
                    ],
                  );
                }
                if (change['pathOnly'] == true) {
                  return BusyApiGroupedList(
                    title: location(id),
                    children: [Text(l.fileMoveUnchangedSource)],
                  );
                }
                return BusyApiGroupedList(
                  title: location(id),
                  children: [
                    BusyApiChangeContext(
                      key: ValueKey(id),
                      preview: () {
                        final edit = plan.edits.singleWhere(
                              (edit) => edit.buffer == id,
                            ),
                            before = change['before'] as String;
                        var a = (edit.start - 240).clamp(0, before.length),
                            b = (edit.end + 240).clamp(0, before.length);
                        if (a > 0 &&
                            before.codeUnitAt(a) >= 0xdc00 &&
                            before.codeUnitAt(a) <= 0xdfff) {
                          a--;
                        }
                        if (b < before.length &&
                            before.codeUnitAt(b) >= 0xdc00 &&
                            before.codeUnitAt(b) <= 0xdfff) {
                          b++;
                        }
                        return SearchChangePreview(
                          before.substring(a, edit.start),
                          edit.expected,
                          edit.replacement,
                          before.substring(edit.end, b),
                        );
                      },
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
