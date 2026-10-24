import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/widgets.dart';

import '../app/localization.dart';
import 'refactoring_review.dart';
import 'workspace_controller.dart';

Future<void> showRootRemoval(
  BuildContext context,
  WorkspaceController controller,
  ProjectRoot declaration, {
  required Future<void> Function(Map<String, dynamic>) reveal,
}) async {
  final owner = controller.project,
      navigation = controller.navigationGeneration,
      selection = controller.resourceNavigationGeneration;
  bool current() =>
      context.mounted &&
      !controller.disposed &&
      identical(controller.project, owner) &&
      controller.navigationGeneration == navigation &&
      controller.resourceNavigationGeneration == selection;
  if (owner == null || !current() || !await controller.flush() || !current()) {
    return;
  }
  RootRemovalPlan plan;
  try {
    plan = await controller.planRootRemoval(owner, declaration);
  } on CoreFailure catch (failure) {
    if (!context.mounted || !current()) return;
    throw CoreFailure(
      failure.code,
      context.l10n.refactoringFailed(failure.code),
    );
  }
  if (context.mounted && current()) {
    await showRefactoringReview(
      context,
      controller,
      owner,
      plan,
      reveal: reveal,
    );
  }
}
