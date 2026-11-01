// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
import 'package:flutter/material.dart';

import 'busyapi_design.dart';

class BusyApiKeyboardShortcutBadge extends StatelessWidget {
  const BusyApiKeyboardShortcutBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: BorderRadius.circular(BusyApiRadius.sm),
        border: Border.all(color: colors.subtleBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: BusyApiSpacing.sm,
          vertical: BusyApiSpacing.xxs,
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            // Let a narrow/scaled badge wrap between modifiers, rather than
            // splitting a name such as Shift. Identity never comes from text.
            label.replaceAll('+', '+\u200B'),
            semanticsLabel: label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontFamily: BusyApiTypography.monoFontFamily,
              fontFamilyFallback: BusyApiTypography.monoFontFamilyFallback,
              color: colors.foreground,
            ),
          ),
        ),
      ),
    );
  }
}
