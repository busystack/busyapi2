// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI file tabs retain native reference geometry and interactions.
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/path_label.dart';

class BusyApiWorkspaceTabButton extends StatelessWidget {
  const BusyApiWorkspaceTabButton({
    super.key,
    required this.title,
    required this.icon,
    required this.active,
    required this.dirty,
    required this.onSelected,
    required this.onClose,
    required this.onSecondaryTapUp,
  });

  final String title;
  final IconData? icon;
  final bool active;
  final bool dirty;
  final VoidCallback onSelected;
  final VoidCallback onClose;
  final GestureTapUpCallback onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final foreground = active ? colors.foreground : colors.mutedForeground;
    final background = active ? colors.view : BusyApiLinuxPalette.transparent;
    final borderColor = active
        ? colors.subtleBorder
        : BusyApiLinuxPalette.transparent;
    return Tooltip(
      message: title,
      child: Material(
        color: background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(BusyApiRadius.sm),
        ),
        child: GestureDetector(
          onTertiaryTapUp: (_) => onClose(),
          child: InkWell(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(BusyApiRadius.sm),
            ),
            hoverColor: colors.controlHover,
            onTap: onSelected,
            onSecondaryTapUp: onSecondaryTapUp,
            child: Container(
              height: BusyApiSizes.paneHeaderHeight - BusyApiSpacing.xs,
              constraints: const BoxConstraints(minWidth: 112, maxWidth: 240),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(BusyApiRadius.sm),
                ),
                border: Border.all(color: borderColor),
              ),
              padding: const EdgeInsetsDirectional.only(
                start: BusyApiSpacing.sm,
                end: BusyApiSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dirty) ...[
                    Container(
                      width: BusyApiSizes.markerDot,
                      height: BusyApiSizes.markerDot,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: BusyApiSpacing.sm),
                  ] else ...[
                    Icon(icon, size: BusyApiSizes.iconSm, color: foreground),
                    const SizedBox(width: BusyApiSpacing.sm),
                  ],
                  Flexible(
                    child: BusyApiPathLabel(
                      path: title,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: foreground,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: BusyApiSpacing.xs),
                  BusyApiCompactIconButton(
                    tooltip: MaterialLocalizations.of(context)
                        .closeButtonTooltip,
                    icon: BusyApiGlyphs.clear,
                    foregroundColor: foreground,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
