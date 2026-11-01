import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';

/// Directory output is not a file-save operation: GTK navigates into existing
/// directories in its file-save chooser. Capture a new path here, or use the
/// native directory chooser for an existing output or its parent. Publication
/// still verifies ownership and presents its separate replacement review.
Future<String?> chooseOutputDestination(
  BuildContext context, {
  required String initialPath,
  Future<String?> Function(String initialDirectory)? chooseDirectory,
}) => showBusyApiModalDialog<String>(
  context: context,
  builder: (_) => _OutputDestinationDialog(
    initialPath: initialPath,
    chooseDirectory:
        chooseDirectory ??
        (directory) => getDirectoryPath(initialDirectory: directory),
  ),
);

class _OutputDestinationDialog extends StatefulWidget {
  const _OutputDestinationDialog({
    required this.initialPath,
    required this.chooseDirectory,
  });
  final String initialPath;
  final Future<String?> Function(String directory) chooseDirectory;

  @override
  State<_OutputDestinationDialog> createState() =>
      _OutputDestinationDialogState();
}

class _OutputDestinationDialogState extends State<_OutputDestinationDialog> {
  late final path = TextEditingController(text: widget.initialPath);
  bool choosing = false;
  String? error;

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> browse({required bool parent}) async {
    final captured = path.text;
    setState(() => choosing = true);
    try {
      final selected = await widget.chooseDirectory(
        p.isAbsolute(captured) ? p.dirname(captured) : p.current,
      );
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      // Do not let a late native chooser replace input captured after it opened.
      if (selected != null && path.text == captured) {
        path.text = parent ? p.join(selected, p.basename(captured)) : selected;
        setState(() => error = null);
      }
    } on Object {
      if (mounted) setState(() => error = context.l10n.outputChooseFailed);
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  void accept() {
    if (choosing) return;
    if (!path.value.composing.isCollapsed) {
      setState(() => error = context.l10n.outputFinishComposition);
      return;
    }
    // Spaces and Unicode are path data, not whitespace to trim. The anchored
    // core validates accessibility, source collisions and output ownership.
    if (!p.isAbsolute(path.text) ||
        path.text.contains(RegExp(r'[\x00\r\n]')) ||
        p.dirname(p.normalize(path.text)) == p.normalize(path.text)) {
      setState(() => error = context.l10n.outputAbsolutePathRequired);
      return;
    }
    Navigator.pop(context, p.normalize(path.text));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return BusyApiDialogShell(
      title: l.chooseOutputFolder,
      actions: [
        BusyApiDialogButton(
          label: l.cancel,
          onPressed: () => Navigator.pop(context),
        ),
        BusyApiDialogButton(
          label: l.outputReviewDestination,
          suggested: true,
          onPressed: choosing ? null : accept,
        ),
      ],
      children: [
        Text(l.outputDestinationHelp),
        BusyApiGroupedList(
          children: [
            BusyApiGroupedTextEntry(
              label: l.outputDestination,
              controller: path,
              autofocus: true,
              enabled: !choosing,
              autocorrect: false,
              enableSuggestions: false,
              errorText: error,
              onSubmitted: (_) => accept(),
            ),
            BusyApiActionRow(
              title: l.outputChooseParent,
              enabled: !choosing,
              onTap: choosing ? null : () => browse(parent: true),
            ),
            BusyApiActionRow(
              title: l.outputChooseExisting,
              enabled: !choosing,
              onTap: choosing ? null : () => browse(parent: false),
            ),
          ],
        ),
      ],
    );
  }
}
