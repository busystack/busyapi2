// Adapted from BusyMark's sidebar tree geometry and native row surface,
// Copyright 2026 BusyStack (Apache-2.0). No filesystem or Git UI is included.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/localization.dart';

class BusyApiTreeRow extends StatefulWidget {
  const BusyApiTreeRow({
    super.key,
    required this.title,
    required this.depth,
    required this.selected,
    required this.expanded,
    required this.hasChildren,
    required this.onToggle,
    required this.onTap,
    required this.onKey,
    required this.register,
    required this.unregister,
    this.tooltip,
  });
  final String title;
  final int depth;
  final bool selected, expanded, hasChildren;
  final String? tooltip;
  final VoidCallback onToggle, onTap;
  final KeyEventResult Function(KeyEvent event) onKey;
  final void Function(FocusNode node) register;
  final VoidCallback unregister;
  @override
  State<BusyApiTreeRow> createState() => _BusyApiTreeRowState();
}

class _BusyApiTreeRowState extends State<BusyApiTreeRow> {
  final focus = FocusNode();
  bool menuOpen = false;
  Future<void> showMenu([Offset? position]) async {
    if (menuOpen) return;
    final opening = widget;
    focus.requestFocus();
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final items = <PopupMenuEntry<String>>[
      BusyApiPopupMenuItem(value: 'open', label: context.l10n.open),
      if (opening.hasChildren)
        BusyApiPopupMenuItem(
          value: 'toggle',
          label: opening.expanded ? context.l10n.collapse : context.l10n.expand,
        ),
    ];
    setState(() => menuOpen = true);
    try {
      final selected = position == null
          ? await showBusyApiMenu<String>(
              context: context,
              anchorRect: box.localToGlobal(Offset.zero) & box.size,
              items: items,
              focusFirst: true,
            )
          : await showBusyApiContextMenu<String>(
              context,
              position,
              items: items,
            );
      if (!mounted) return;
      if (selected == 'open') opening.onTap();
      if (selected == 'toggle') opening.onToggle();
    } finally {
      if (mounted) {
        setState(() => menuOpen = false);
        focus.requestFocus();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    focus.addListener(focusChanged);
    widget.register(focus);
  }

  void focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.unregister();
    focus.removeListener(focusChanged);
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context),
        direction = Directionality.of(context);
    final row = Semantics(
      container: true,
      excludeSemantics: true,
      label: widget.title,
      button: true,
      focusable: true,
      focused: focus.hasFocus,
      selected: widget.selected,
      expanded: widget.hasChildren ? widget.expanded : null,
      onTap: widget.onTap,
      onFocus: focus.requestFocus,
      onExpand: widget.hasChildren && !widget.expanded ? widget.onToggle : null,
      onCollapse: widget.hasChildren && widget.expanded
          ? widget.onToggle
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BusyApiStroke.hairline),
        child: Material(
          color: widget.selected || menuOpen
              ? busyApiSelectedBackground(context)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(BusyApiRadius.md),
          clipBehavior: Clip.antiAlias,
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.contextMenu ||
                      event.logicalKey == LogicalKeyboardKey.f10 &&
                          HardwareKeyboard.instance.isShiftPressed)) {
                showMenu();
                return KeyEventResult.handled;
              }
              return widget.onKey(event);
            },
            child: InkWell(
              focusNode: focus,
              hoverColor: busyApiRowHoverColor(context),
              onTap: widget.onTap,
              onSecondaryTapUp: (details) => showMenu(details.globalPosition),
              child: SizedBox(
                height: BusyApiSizes.sidebarTreeRowHeight,
                child: Row(
                  children: [
                    SizedBox(
                      width:
                          BusyApiSizes.sidebarTreeDepthBase +
                          widget.depth * BusyApiSizes.sidebarTreeDepthIndent,
                    ),
                    SizedBox.square(
                      dimension: BusyApiSizes.sidebarTreeControl,
                      child: widget.hasChildren
                          ? GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onToggle,
                              child: AnimatedRotation(
                                turns: widget.expanded
                                    ? (direction == TextDirection.rtl
                                          ? -.25
                                          : .25)
                                    : 0,
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : BusyApiMotion.sidebarExpand,
                                child: Icon(
                                  BusyApiGlyphs.collapsedTreeArrowFor(
                                    direction,
                                  ),
                                  size: BusyApiSizes.sidebarTreeArrow,
                                  color: colors.mutedForeground,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(width: BusyApiSpacing.xs),
                    SizedBox.square(
                      dimension: BusyApiSizes.sidebarTreeControl,
                      child: Icon(
                        widget.hasChildren
                            ? (widget.expanded
                                  ? BusyApiGlyphs.folderOpen
                                  : BusyApiGlyphs.folder)
                            : BusyApiGlyphs.document,
                        size: BusyApiSizes.iconSm,
                        color: colors.mutedForeground,
                      ),
                    ),
                    const SizedBox(width: BusyApiSpacing.sm),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.foreground),
                      ),
                    ),
                    const SizedBox(width: BusyApiSpacing.xs),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? row
        : Tooltip(message: widget.tooltip, child: row);
  }
}
