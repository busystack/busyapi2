// Adapted from BusyMark's command_registry.dart and command_presentation.dart.
// Copyright 2026 BusyStack (Apache-2.0). BusyAPI commands only.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'shortcut_binding.dart';

const busyApiDefaultKeyBindings = <String, BusyApiKeyBinding>{
  'request-send': BusyApiKeyBinding(LogicalKeyboardKey.enter, control: true),
  'save': BusyApiKeyBinding(LogicalKeyboardKey.keyS, control: true),
  'open': BusyApiKeyBinding(LogicalKeyboardKey.keyO, control: true),
  'create': BusyApiKeyBinding(LogicalKeyboardKey.keyN, control: true),
  'palette': BusyApiKeyBinding(
    LogicalKeyboardKey.keyP,
    control: true,
    shift: true,
  ),
  'close-tab': BusyApiKeyBinding(LogicalKeyboardKey.keyW, control: true),
  'quit': BusyApiKeyBinding(LogicalKeyboardKey.keyQ, control: true),
  'back': BusyApiKeyBinding(LogicalKeyboardKey.arrowLeft, alt: true),
  'forward': BusyApiKeyBinding(LogicalKeyboardKey.arrowRight, alt: true),
  'undo': BusyApiKeyBinding(LogicalKeyboardKey.keyZ, control: true),
  'redo': BusyApiKeyBinding(
    LogicalKeyboardKey.keyZ,
    control: true,
    shift: true,
  ),
  'search': BusyApiKeyBinding(LogicalKeyboardKey.keyF, control: true),
  'project-search': BusyApiKeyBinding(
    LogicalKeyboardKey.keyF,
    control: true,
    shift: true,
  ),
  'settings': BusyApiKeyBinding(LogicalKeyboardKey.comma, control: true),
  'sidebar': BusyApiKeyBinding(LogicalKeyboardKey.f9),
};

enum BusyApiCommandScope { application, documentView, editor, sidebar }

class BusyApiCommandIntent extends Intent {
  const BusyApiCommandIntent(this.commandId);
  final String commandId;
}

@immutable
class BusyApiCommand {
  const BusyApiCommand({
    required this.id,
    required this.label,
    required this.category,
    required this.execute,
    this.scope = BusyApiCommandScope.application,
    this.shortcut,
    this.enabled = _always,
    this.selected = _never,
  });

  final String id;
  final String Function(BuildContext) label, category;
  final FutureOr<void> Function()? execute;
  final BusyApiCommandScope scope;
  final BusyApiKeyBinding? shortcut;
  final bool Function() enabled, selected;
  bool get canExecute => execute != null && enabled();
  static bool _always() => true;
  static bool _never() => false;
}

class BusyApiCommandRegistry {
  BusyApiCommandRegistry(
    Iterable<BusyApiCommand> commands, {
    this.configureShortcut,
  }) : commands = List.unmodifiable(commands) {
    for (final command in this.commands) {
      if (_byId.containsKey(command.id)) {
        throw ArgumentError('Duplicate command: ${command.id}');
      }
      _byId[command.id] = command;
    }
  }

  final Future<void> Function(String id, BusyApiKeyBinding binding)?
  configureShortcut;
  final List<BusyApiCommand> commands;
  final _byId = <String, BusyApiCommand>{};
  BusyApiCommand? operator [](String id) => _byId[id];
  Future<bool> execute(String id) async {
    final command = _byId[id];
    if (command == null || !command.canExecute) return false;
    await command.execute!();
    return true;
  }

  Map<ShortcutActivator, Intent> shortcutIntents({
    Set<BusyApiCommandScope>? scopes,
    Intent Function(String)? intentFor,
  }) => {
    for (final command in commands)
      if (command.shortcut != null &&
          (scopes == null || scopes.contains(command.scope)))
        command.shortcut!.activator:
            intentFor?.call(command.id) ?? BusyApiCommandIntent(command.id),
  };
}

class BusyApiCommandRegistryScope extends InheritedWidget {
  const BusyApiCommandRegistryScope({
    super.key,
    required this.registry,
    required super.child,
  });
  final BusyApiCommandRegistry registry;
  static BusyApiCommandRegistry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<BusyApiCommandRegistryScope>()
      ?.registry;
  @override
  bool updateShouldNotify(BusyApiCommandRegistryScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

int? commandMatchRank({
  required String name,
  required String category,
  String? description,
  required String id,
  required String query,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final title = name.toLowerCase();
  if (title == q) return 0;
  if (title.startsWith(q)) return 1;
  final tokens = q.split(RegExp(r'\s+'));
  final words = title.split(RegExp(r'[\s\p{P}]+', unicode: true));
  if (tokens.every((t) => words.any((w) => w.startsWith(t)))) return 2;
  if (title.contains(q)) return 3;
  final text =
      '$title ${category.toLowerCase()} ${description?.toLowerCase() ?? ''}';
  if (tokens.every(text.contains)) return 4;
  return id.toLowerCase().contains(q) ? 5 : null;
}
