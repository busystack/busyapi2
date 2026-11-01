import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/localization.dart';
import '../designer/designer.dart' show editForm, FormFieldSpec;
import 'refactoring_review.dart';
import 'workspace_controller.dart';

Future<void> showFileCreation(
  BuildContext context,
  WorkspaceController controller,
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
  if (owner == null ||
      !await controller.flush() ||
      !context.mounted ||
      !current()) {
    return;
  }
  final l = context.l10n;
  FileCreationPlan? plan;
  await editForm(
    context,
    l.createSourceFile,
    [FormFieldSpec('path', l.fileMoveDestination)],
    {
      'path':
          'fragment.${controller.root?.endsWith('.json') == true ? 'json' : 'yaml'}',
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
      if (![
        '.json',
        '.yaml',
        '.yml',
      ].contains(p.extension(path).toLowerCase())) {
        return l.sourceFileFormat;
      }
      return null;
    },
    onApply: (values) async {
      if (!current()) throw CoreFailure('refactor.stale', l.objectActionStale);
      try {
        plan = await owner.planFileCreation(
          p.normalize(p.join(owner.access.boundary, values['path'] as String)),
        );
      } on CoreFailure catch (failure) {
        throw CoreFailure(failure.code, l.refactoringFailed(failure.code));
      }
    },
  );
  if (!context.mounted || !current() || plan == null) return;
  var applied = false;
  await showRefactoringReview(
    context,
    controller,
    owner,
    plan!,
    onApplied: () => applied = true,
  );
  if (!applied ||
      !current() ||
      !owner.store.buffers.containsKey(plan!.creation.id)) {
    return;
  }
  final command = controller.resourceNavigationGeneration + 1;
  await controller.openFile(plan!.creation.id);
  if (!controller.disposed &&
      identical(controller.project, owner) &&
      controller.navigationGeneration == navigation &&
      controller.resourceNavigationGeneration == command &&
      controller.active == plan!.creation.id) {
    controller.setMode('Source');
    await controller.persistView();
  }
}

Future<void> showFileDeletion(
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
  if (owner == null ||
      !await controller.flush() ||
      !context.mounted ||
      !current()) {
    return;
  }
  final l = context.l10n;
  FileDeletionPlan plan;
  try {
    plan = await controller.planFileDeletion(owner, resource);
  } on CoreFailure catch (failure) {
    if (!current()) return;
    throw CoreFailure(failure.code, l.refactoringFailed(failure.code));
  }
  if (context.mounted && current()) {
    await showRefactoringReview(context, controller, owner, plan);
  }
}
