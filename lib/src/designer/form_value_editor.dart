import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/localization.dart';
import '../source/source_editor.dart';

/// Presentation of one captured form string/data value. This private draft
/// store has no ProjectAccess/publication capability and is never a project
/// buffer. Its accepted string belongs to the existing FormSession; only the
/// form's reviewed Apply can change canonical source. Reuse SourceEditor's
/// accepted input/windowing implementation rather than shaping a whole value.
class FormValueEditor extends StatefulWidget {
  const FormValueEditor({
    super.key,
    required this.label,
    required this.controller,
    required this.enabled,
    required this.multiline,
    required this.json,
    required this.onCompositionChanged,
  });
  final String label;
  final TextEditingController controller;
  final bool enabled, multiline, json;
  final ValueChanged<bool> onCompositionChanged;
  @override
  State<FormValueEditor> createState() => _FormValueEditorState();
}

class _FormValueEditorState extends State<FormValueEditor> {
  static int serial = 0;
  static const threshold = 16384;
  final editor = GlobalKey<SourceEditorState>();
  final changes = ValueNotifier(0);
  final store = BufferStore();
  DocumentBuffer? buffer;
  bool publishing = false, focused = false, composing = false;
  bool get expanded => buffer != null;
  bool get current => mounted && widget.enabled;
  @override
  void initState() {
    super.initState();
    if (widget.controller.text.length > threshold) expand();
    widget.controller.addListener(observe);
  }

  void expand() {
    final text = widget.controller.text;
    final draft = DocumentBuffer(
      id: 'form-value:${++serial}',
      path: widget.json ? 'value.json' : 'value.txt',
      text: text,
      baseline: text,
      diskIdentity: '',
      hasBom: false,
    );
    final selection = widget.controller.selection;
    draft.selection = SourceSelection(
      selection.baseOffset.clamp(0, text.length),
      selection.extentOffset.clamp(0, text.length),
    );
    buffer = draft;
    store.buffers[draft.id] = draft;
  }

  void observe() {
    if (!mounted || publishing) return;
    if (!expanded &&
        widget.controller.text.length > threshold &&
        widget.controller.value.composing.isCollapsed) {
      final restoreFocus = focused;
      setState(expand);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!current || !restoreFocus || buffer == null) return;
        final selection = buffer!.selection;
        editor.currentState?.reveal(selection.extent);
        editor.currentState?.select(selection, reveal: false);
      });
    } else if (expanded && buffer!.text != widget.controller.text) {
      // An explicit parent reconciliation is not a draft undo operation.
      buffer!.update(widget.controller.text);
      store.clearHistory();
      changes.value++;
    }
  }

  void publish() {
    if (!current) return;
    final draft = buffer!;
    publishing = true;
    try {
      widget.controller.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection(
          baseOffset: draft.selection.base,
          extentOffset: draft.selection.extent,
        ),
      );
    } finally {
      publishing = false;
    }
  }

  void composition(bool value) {
    if (!current || composing == value) return;
    composing = value;
    widget.onCompositionChanged(value);
  }

  void history(bool redo) {
    if (!current || composing) return;
    if (redo) {
      store.redo();
    } else {
      store.undo();
    }
    publish();
    changes.value++;
  }

  @override
  void didUpdateWidget(FormValueEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller.removeListener(observe);
      widget.controller.addListener(observe);
      store.buffers.clear();
      store.clearHistory();
      buffer = null;
      composing = false;
      if (widget.controller.text.length > threshold) expand();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(observe);
    changes.dispose();
    // No commits, checkpoint, parent-controller disposal or native IM updates.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!expanded) {
      return Focus(
        onFocusChange: (value) => focused = value,
        child: BusyApiGroupedTextEntry(
          label: widget.label,
          controller: widget.controller,
          enabled: widget.enabled,
          minLines: widget.multiline ? 3 : 1,
          maxLines: widget.multiline ? 8 : 1,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(BusyApiSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label),
          Text(context.l10n.capturedValueDraft),
          BusyApiReviewViewport(
            child: Semantics(
              label: widget.label,
              child: SourceEditor(
                key: editor,
                buffer: buffer!,
                owner: this,
                changes: changes,
                isCurrent: () => current,
                syntaxHighlight: widget.json,
                onCompositionChanged: composition,
                onEdit: (edit) {
                  if (!current) return;
                  store.apply([edit]);
                  publish();
                },
                onChanged: (text) {
                  if (!current) return;
                  store.replace(buffer!.id, text);
                  publish();
                },
                undo: () => history(false),
                redo: () => history(true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
