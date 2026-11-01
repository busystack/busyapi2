// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'command_registry.dart';

/// Only the currently focused editing owner can suppress app commands.
/// Retained, hidden queries and editors keep their composing values.
bool busyApiFocusedInputIsComposing() {
  final entry = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  return entry?.widget.controller.value.composing.isValid ?? false;
}

/// A disabled command still owns its combination in this context.
/// It must not fall through to a different platform text-editing operation.
class BusyApiCommandShortcuts extends StatefulWidget {
  const BusyApiCommandShortcuts({
    super.key,
    required this.shortcuts,
    required this.child,
    this.isComposing,
  });
  final Map<ShortcutActivator, Intent> shortcuts;
  final Widget child;
  final bool Function()? isComposing;
  @override
  State<BusyApiCommandShortcuts> createState() =>
      _BusyApiCommandShortcutsState();
}

class _BusyApiCommandShortcutsState extends State<BusyApiCommandShortcuts> {
  late final _CommandShortcutManager _manager = _CommandShortcutManager(
    widget.shortcuts,
    widget.isComposing,
  );
  @override
  void didUpdateWidget(BusyApiCommandShortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    _manager.update(widget.shortcuts, widget.isComposing);
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Shortcuts.manager(manager: _manager, child: widget.child);
}

class _CommandShortcutManager extends ShortcutManager {
  _CommandShortcutManager(
    Map<ShortcutActivator, Intent> bindings,
    bool Function()? isComposing,
  ) {
    update(bindings, isComposing);
  }
  bool Function()? _isComposing;
  final _commandKeys = <LogicalKeyboardKey, List<ShortcutActivator>>{};
  void update(
    Map<ShortcutActivator, Intent> bindings,
    bool Function()? isComposing,
  ) {
    _isComposing = isComposing;
    shortcuts = bindings;
    _commandKeys.clear();
    for (final entry in bindings.entries) {
      if (entry.value is! BusyApiCommandIntent) {
        continue;
      }
      for (final key in entry.key.triggers ?? <LogicalKeyboardKey>[]) {
        (_commandKeys[key] ??= []).add(entry.key);
      }
    }
  }

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (_isComposing?.call() ?? false) {
      return KeyEventResult.skipRemainingHandlers;
    }
    final result = super.handleKeypress(context, event);
    if (result == KeyEventResult.ignored &&
        (_commandKeys[event.logicalKey] ?? const []).any(
          (a) => a.accepts(event, HardwareKeyboard.instance),
        )) {
      return KeyEventResult.handled;
    }
    return result;
  }
}
