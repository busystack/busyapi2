// Composed from BusyMark's compact document headers, EditorScrollBody and
// semantic surfaces. BusyAPI tools retain their on-demand controller ownership.
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/busyapi_search_field.dart';

class BusyApiToolSurface extends StatelessWidget {
  const BusyApiToolSurface({
    super.key,
    required this.title,
    required this.status,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.actions = const [],
    this.kind = BusyApiStatusKind.information,
  });
  final String title, status;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> actions;
  final Widget child;
  final BusyApiStatusKind kind;
  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final colors = BusyApiSurfaceColors.of(context);
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: constraints.hasBoundedHeight
                ? constraints.maxHeight
                : MediaQuery.sizeOf(context).height *
                      BusyApiSizes.modalMaxHeightFraction /
                      2,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.view,
              border: Border(top: BorderSide(color: colors.subtleBorder)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: BusyApiSizes.paneHeaderHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BusyApiSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Tooltip(
                            message: '$title · $status',
                            child: Text(
                              expanded ? title : '$title · $status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                        ...actions,
                        BusyApiCompactIconButton(
                          tooltip: title,
                          icon: expanded
                              ? BusyApiGlyphs.upArrow
                              : BusyApiGlyphs.downArrow,
                          onPressed: onToggle,
                        ),
                      ],
                    ),
                  ),
                ),
                Flexible(
                  child: Offstage(
                    offstage: !expanded,
                    child: ExcludeFocus(
                      excluding: !expanded,
                      child: TickerMode(
                        enabled: expanded,
                        child: BusyApiLocalTextEditingShortcuts(
                          child: BusyApiEditorScrollBody(
                            maxWidth: BusyApiSizes.modalMaxWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                BusyApiStatusBox(message: status, kind: kind),
                                child,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
