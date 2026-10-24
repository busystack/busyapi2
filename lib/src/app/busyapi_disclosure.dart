// Adapted from _PropertySection in BusyMark's writerside_properties.dart.
// Copyright 2026 BusyStack (Apache-2.0). Retains BusyAPI drafts while hidden.
import 'package:flutter/material.dart';

import 'busyapi_design.dart';
import 'busyapi_glyphs.dart';

class BusyApiDisclosure extends StatefulWidget {
  const BusyApiDisclosure({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
  });
  final Widget title;
  final Widget? subtitle;
  final List<Widget> children;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  @override
  State<BusyApiDisclosure> createState() => _BusyApiDisclosureState();
}

class _BusyApiDisclosureState extends State<BusyApiDisclosure> {
  late bool expanded = widget.initiallyExpanded;
  bool visited = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: BusyApiSpacing.sm),
      Semantics(
        expanded: expanded,
        button: true,
        child: TextButton(
          onPressed: () {
            setState(() => expanded = !expanded);
            widget.onExpansionChanged?.call(expanded);
          },
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.titleSmall,
                      child: widget.title,
                    ),
                    if (widget.subtitle != null)
                      DefaultTextStyle.merge(
                        style: Theme.of(context).textTheme.bodySmall,
                        child: widget.subtitle!,
                      ),
                  ],
                ),
              ),
              Icon(expanded ? BusyApiGlyphs.upArrow : BusyApiGlyphs.downArrow),
            ],
          ),
        ),
      ),
      if (expanded || visited)
        Offstage(
          offstage: !expanded,
          child: ExcludeFocus(
            excluding: !expanded,
            child: TickerMode(
              enabled: expanded,
              child: Builder(
                builder: (_) {
                  visited = true;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  );
                },
              ),
            ),
          ),
        ),
    ],
  );
}
