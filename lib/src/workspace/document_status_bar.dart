// Adapted from BusyMark's document_status_bar.dart (Apache-2.0).
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';

class BusyApiDocumentStatusBar extends StatelessWidget {
  const BusyApiDocumentStatusBar({
    super.key,
    required this.label,
    required this.onPressed,
    required this.location,
    this.details,
  });
  final String label, location;
  final String? details;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: colors.mutedForeground);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.headerbarFlat,
        border: Border(top: BorderSide(color: colors.subtleBorder)),
      ),
      child: SizedBox(
        height: BusyApiSizes.documentStatusBarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: BusyApiSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: details ?? label,
                  child: Material(
                    color: BusyApiLinuxPalette.transparent,
                    child: InkWell(
                      onTap: onPressed,
                      hoverColor: busyApiRowHoverColor(context),
                      borderRadius: BorderRadius.circular(BusyApiRadius.sm),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: BusyApiSpacing.sm,
                          vertical: BusyApiSpacing.xxs,
                        ),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: Tooltip(
                  message: location,
                  child: Text(
                    location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ),
              const SizedBox(width: BusyApiSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}
