import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../workspace/workspace_controller.dart';
import 'reference_markdown.dart';

/// Reading state belongs to root/resource/occurrence, never the projected text
/// or whichever object happens to be selected when an old callback completes.
class OwnedReferenceMarkdownText extends StatelessWidget {
  const OwnedReferenceMarkdownText({
    super.key,
    required this.controller,
    required this.root,
    required this.resource,
    required this.pointer,
    required this.text,
    this.base,
    this.parseMarkup = true,
  });
  final WorkspaceController controller;
  final String root, resource, pointer, text;
  final Uri? base;
  final bool parseMarkup;
  @override
  Widget build(BuildContext context) {
    final owner = controller.project,
        revision = controller.semanticViewRevision;
    final stateKey = jsonEncode([root, resource, pointer, 'commonmark']);
    final stored = controller.layoutState['referenceText'];
    final previous = stored is Map ? stored[stateKey] : null;
    return ReferenceMarkdownText(
      key: ValueKey((owner, stateKey)),
      text: text,
      base: base,
      parseMarkup: parseMarkup,
      initialReadingState: previous is Map ? previous : const {},
      onReadingStateChanged: (state) {
        if (controller.disposed ||
            !identical(controller.project, owner) ||
            controller.root != root ||
            controller.semanticViewRevision != revision) {
          return;
        }
        final current = controller.layoutState['referenceText'];
        final states = <String, Object?>{
          if (current is Map)
            for (final entry in current.entries)
              if (entry.key is String && entry.value is Map)
                entry.key as String: entry.value,
        }..remove(stateKey);
        states[stateKey] = state;
        while (states.length > 64) {
          states.remove(states.keys.first);
        }
        controller.layoutState = {
          ...controller.layoutState,
          'referenceText': states,
        };
      },
    );
  }
}
