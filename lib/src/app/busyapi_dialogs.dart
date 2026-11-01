// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// Modified for BusyAPI commands and the Flutter/GTK chrome host.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'busyapi_design.dart';
import 'command_registry.dart';

Color busyApiModalBarrierColor(BuildContext context) =>
    BusyApiSurfaceColors.of(context).shade;

Future<T?> showBusyApiModalDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  void Function(ModalRoute<T>, NavigatorState)? onRoutePushed,
}) async {
  final previousFocus = FocusManager.instance.primaryFocus;
  try {
    return await _showBusyApiFlutterDialog<T>(
      context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      onRoutePushed: onRoutePushed,
    );
  } finally {
    if (previousFocus?.context != null && previousFocus!.canRequestFocus) {
      previousFocus.requestFocus();
    }
  }
}

class _DismissBusyApiModalIntent extends Intent {
  const _DismissBusyApiModalIntent();
}

final _busyApiModalShortcuts = <ShortcutActivator, Intent>{
  for (final binding in busyApiDefaultKeyBindings.values)
    binding.activator: const DoNothingAndStopPropagationIntent(),
  const SingleActivator(LogicalKeyboardKey.escape):
      const _DismissBusyApiModalIntent(),
};

/// Prevents application and workspace shortcuts from escaping a modal surface.
///
/// Use this around modal UI that is not presented by
/// [showBusyApiModalDialog], such as an in-page editor overlay.
class BusyApiModalShortcutBoundary extends StatefulWidget {
  const BusyApiModalShortcutBoundary({super.key, required this.child});

  final Widget child;

  @override
  State<BusyApiModalShortcutBoundary> createState() =>
      _BusyApiModalShortcutBoundaryState();
}

class _BusyApiModalShortcutBoundaryState
    extends State<BusyApiModalShortcutBoundary> {
  final _fallbackFocusNode = FocusNode(
    debugLabel: 'BusyApi modal shortcut fallback',
  );
  FocusScopeNode? _enclosingScope;

  @override
  void initState() {
    super.initState();
    // DialogRoute initially parks focus on its own scope. Wait for that focus
    // transition, then move it below Shortcuts only when no child requested
    // focus, so Escape works without overriding a field's autofocus.
    FocusManager.instance.addListener(_focusFallbackIfNeeded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusFallbackIfNeeded();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enclosingScope = FocusScope.of(context);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusFallbackIfNeeded);
    _fallbackFocusNode.dispose();
    super.dispose();
  }

  void _focusFallbackIfNeeded() {
    if (!mounted || _fallbackFocusNode.context == null) return;
    if (FocusManager.instance.primaryFocus == _enclosingScope) {
      _fallbackFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        ...?BusyApiCommandRegistryScope.maybeOf(context)?.shortcutIntents(
          intentFor: (_) => const DoNothingAndStopPropagationIntent(),
        ),
        if (BusyApiCommandRegistryScope.maybeOf(context) == null)
          ..._busyApiModalShortcuts,
        const SingleActivator(LogicalKeyboardKey.escape):
            const _DismissBusyApiModalIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissBusyApiModalIntent:
              CallbackAction<_DismissBusyApiModalIntent>(
                onInvoke: (_) {
                  unawaited(Navigator.maybePop(context));
                  return null;
                },
              ),
        },
        child: Focus(
          focusNode: _fallbackFocusNode,
          skipTraversal: true,
          includeSemantics: false,
          child: DefaultTextEditingShortcuts(child: widget.child),
        ),
      ),
    );
  }
}

Future<T?> _showBusyApiFlutterDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  Color? barrierColor,
  bool barrierDismissible = true,
  void Function(ModalRoute<T>, NavigatorState)? onRoutePushed,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final registry = BusyApiCommandRegistryScope.maybeOf(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final route = _BusyApiDialogRoute<T>(
    context: context,
    builder: builder,
    registry: registry,
    themes: themes,
    fixedBarrierColor: barrierColor,
    initialBarrierColor: barrierColor ?? busyApiModalBarrierColor(context),
    barrierDismissible: barrierDismissible,
  );
  final result = navigator.push<T>(route);
  onRoutePushed?.call(route, navigator);
  return result;
}

class _BusyApiDialogRoute<T> extends DialogRoute<T> {
  _BusyApiDialogRoute({
    required super.context,
    required WidgetBuilder builder,
    required CapturedThemes themes,
    required BusyApiCommandRegistry? registry,
    required this._fixedBarrierColor,
    required Color initialBarrierColor,
    required super.barrierDismissible,
  }) : _initialBarrierColor = initialBarrierColor,
       super(
         builder: (dialogContext) => registry == null
             ? BusyApiModalShortcutBoundary(child: builder(dialogContext))
             : BusyApiCommandRegistryScope(
                 registry: registry,
                 child: Builder(
                   builder: (context) =>
                       BusyApiModalShortcutBoundary(child: builder(context)),
                 ),
               ),
         themes: themes,
         barrierColor: initialBarrierColor,
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
       );

  final Color? _fixedBarrierColor;
  final Color _initialBarrierColor;

  /// Unlike [DialogRoute]'s constructor value, this getter is reevaluated
  /// when the Navigator's inherited theme changes.
  @override
  Color? get barrierColor {
    final fixedColor = _fixedBarrierColor;
    if (fixedColor != null) {
      return fixedColor;
    }
    final navigatorContext = navigator?.context;
    return navigatorContext == null
        ? _initialBarrierColor
        : busyApiModalBarrierColor(navigatorContext);
  }
}
