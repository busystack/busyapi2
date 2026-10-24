import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/localization.dart';
import '../designer/designer.dart' show editForm, FormFieldSpec;
import 'refactoring_review.dart';
import 'workspace_controller.dart';

Future<void> showFileMove(
  BuildContext context,
  WorkspaceController controller,
  String resource,
) async {
  final owner = controller.project,
      navigation = controller.navigationGeneration,
      selection = controller.resourceNavigationGeneration;
  bool current() =>
      context.mounted &&
      !controller.disposed &&
      identical(controller.project, owner) &&
      controller.navigationGeneration == navigation &&
      controller.resourceNavigationGeneration == selection;
  if (owner == null || !await controller.flush() || !current()) return;
  final source = await owner.buffer(resource);
  if (!context.mounted || !current()) return;
  final generation = source.generation, l = context.l10n;
  FileMovePlan? plan;
  await editForm(
    context,
    l.moveSourceFile,
    [
      FormFieldSpec('path', l.fileMoveDestination),
      FormFieldSpec('retainIdentity', l.retainResourceIdentity, boolean: true),
    ],
    {
      'path': p.relative(source.path, from: owner.access.boundary),
      'retainIdentity': false,
    },
    validate: (values) {
      final value = values['path'] as String? ?? '';
      if (value.trim().isEmpty) return l.fileMoveDestinationRequired;
      final path = p.normalize(p.join(owner.access.boundary, value));
      try {
        owner.accessFor(path).pathFor(path);
      } on CoreFailure {
        return l.fileMoveDestinationLocal;
      }
      if ((p.extension(path).toLowerCase() == '.json') !=
          (p.extension(source.path).toLowerCase() == '.json')) {
        return l.fileMoveSameFormat;
      }
      return null;
    },
    onApply: (values) async {
      if (!current() ||
          source.id != resource ||
          source.generation != generation) {
        throw CoreFailure('refactor.stale', l.objectActionStale);
      }
      try {
        plan = await controller.planFileMove(
          owner,
          resource,
          p.normalize(p.join(owner.access.boundary, values['path'] as String)),
          retainIdentity: values['retainIdentity'] == true,
        );
      } on CoreFailure catch (failure) {
        throw CoreFailure(
          failure.code,
          failure.code == 'file.move.literal.ownership'
              ? l.refactoringLiteralOwnershipBlocked
              : l.refactoringFailed(failure.code),
        );
      }
    },
  );
  if (context.mounted && current() && plan != null) {
    await showRefactoringReview(context, controller, owner, plan!);
  }
}
