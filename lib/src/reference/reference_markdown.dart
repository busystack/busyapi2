// Document block geometry adapted from BusyMark, Copyright 2026 BusyStack
// (Apache-2.0). BusyAPI adds bounded read-only projection and no resource loads.
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/localization.dart';

/// Read-only native text, using the existing BusyMark-derived document metrics.
/// The parser is cancellable/headless; no web surface or editable buffer exists.
class ReferenceMarkdownText extends StatefulWidget {
  const ReferenceMarkdownText({
    super.key,
    required this.text,
    this.base,
    this.parseMarkup = true,
    this.initialReadingState = const {},
    this.onReadingStateChanged,
  });
  final String text;
  final Uri? base;
  final bool parseMarkup;
  final Map initialReadingState;
  final ValueChanged<Map<String, Object?>>? onReadingStateChanged;
  @override
  State<ReferenceMarkdownText> createState() => _ReferenceMarkdownTextState();
}

class _ReferenceMarkdownTextState extends State<ReferenceMarkdownText> {
  ReferenceMarkdownJob? job;
  ReferenceMarkdown? document;
  int epoch = 0, page = 0, linkPage = 0;
  final collections = <String, int>{};
  bool failed = false, inspectLinks = false, copyFailed = false;
  Uri? copied;
  static const pageSize = 50;
  @override
  void initState() {
    super.initState();
    int number(Object? value) => value is int ? value.clamp(0, 1000000) : 0;
    final saved = widget.initialReadingState;
    page = number(saved['page']);
    linkPage = number(saved['linkPage']);
    inspectLinks = saved['inspectLinks'] == true;
    final selected = saved['collections'];
    if (selected is Map) {
      for (final entry in selected.entries.take(128)) {
        if (entry.key is String &&
            (entry.key as String).length <= 256 &&
            entry.value is int) {
          collections[entry.key as String] = number(entry.value);
        }
      }
    }
    load();
  }

  void readingChange(VoidCallback action) {
    setState(action);
    widget.onReadingStateChanged?.call({
      'page': page,
      'linkPage': linkPage,
      'inspectLinks': inspectLinks,
      'collections': Map<String, int>.unmodifiable(collections),
    });
  }

  @override
  void didUpdateWidget(ReferenceMarkdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.base != widget.base ||
        oldWidget.parseMarkup != widget.parseMarkup) {
      load();
    }
  }

  void load() {
    job?.cancel();
    final token = ++epoch;
    document = null;
    failed = copyFailed = false;
    copied = null;
    if (!widget.parseMarkup && widget.text.length <= 16384) {
      document = ReferenceMarkdown([
        ReferenceMarkup('text', text: widget.text),
      ], formatted: false);
      job = null;
      return;
    }
    if (widget.text.length > 16384) {
      job = null;
      return;
    }
    job = ReferenceMarkdownJob(widget.text, base: widget.base);
    job!.result.then(
      (value) {
        if (!mounted || token != epoch) return;
        setState(() {
          document = value;
          page = page.clamp(
            0,
            ((value.blocks.length - 1) ~/ pageSize).clamp(0, 1000000),
          );
        });
      },
      onError: (Object error) {
        if (!mounted || token != epoch) return;
        setState(() => failed = true);
      },
    );
  }

  @override
  void dispose() {
    epoch++;
    job?.cancel();
    super.dispose();
  }

  Future<void> copy(Uri target) async {
    final token = epoch;
    try {
      await Clipboard.setData(ClipboardData(text: target.toString()));
      if (mounted && epoch == token) {
        setState(() {
          copied = target;
          copyFailed = false;
        });
      }
    } on Object {
      if (mounted && epoch == token) setState(() => copyFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, current = document;
    final colors = BusyApiSurfaceColors.of(context);
    final body = Theme.of(context).textTheme.bodyMedium!
        .copyWith(height: BusyApiTypography.bodyLineHeight);
    final mono = body.copyWith(
      fontFamily: BusyApiTypography.monoFontFamily,
      fontFamilyFallback: BusyApiTypography.monoFontFamilyFallback,
      height: BusyApiTypography.codeLineHeight,
    );
    final links = <Uri, String>{};
    void collect(ReferenceMarkup node) {
      if (node.target case final target?) {
        links.putIfAbsent(target, () => node.plainText);
      }
      for (final child in node.children) {
        collect(child);
      }
    }

    if (current != null) {
      for (final block in current.blocks) {
        collect(block);
      }
    }
    var inlineCount = 0, blockCount = 0;
    bool plainLayout = false;
    InlineSpan inline(ReferenceMarkup node, TextStyle style) {
      if (++inlineCount > 512) {
        plainLayout = true;
        return TextSpan(text: node.plainText, style: style);
      }
      if (node.kind == 'text' || node.kind == 'image') {
        return TextSpan(text: node.text, style: style);
      }
      if (node.kind == 'br') return const TextSpan(text: '\n');
      final next = switch (node.kind) {
        'strong' => style.copyWith(fontWeight: FontWeight.w700),
        'em' => style.copyWith(fontStyle: FontStyle.italic),
        'code' => mono,
        _ => style,
      };
      return TextSpan(
        style: next,
        children: node.children.map((child) => inline(child, next)).toList(),
      );
    }

    late Widget Function(ReferenceMarkup, int, String) block;
    Widget surface(
      Widget child,
      EdgeInsetsGeometry margin,
      EdgeInsetsGeometry padding,
    ) => Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(BusyApiRadius.md),
        border: Border.all(
          color: colors.subtleBorder,
          width: BusyApiStroke.hairline,
        ),
      ),
      child: child,
    );
    List<Widget> childBlocks(
      ReferenceMarkup node,
      int depth,
      String path, {
      bool markers = false,
    }) {
      final count = node.children.length;
      final selected = (collections[path] ?? 0).clamp(
        0,
        ((count - 1) ~/ pageSize).clamp(0, 1000000),
      );
      void selectPage(int next) => readingChange(() {
        collections.remove(path);
        collections[path] = next;
        while (collections.length > 128) {
          collections.remove(collections.keys.first);
        }
      });
      return [
        for (
          var index = selected * pageSize;
          index < count && index < (selected + 1) * pageSize;
          index++
        )
          if (markers)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: BusyApiSizes.documentListMarkerWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      top: BusyApiSizes.documentListMarkerTopInset,
                    ),
                    child: node.kind == 'ol'
                        ? Text(
                            '${(node.start ?? 1) + index}.',
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            softWrap: false,
                            style: body.copyWith(
                              color: colors.foreground,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.only(
                              top: BusyApiSizes.listMarkerTopInset,
                            ),
                            child: SizedBox.square(
                              dimension: BusyApiSizes.markerDot,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.mutedForeground,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: BusyApiSpacing.sm),
                Expanded(
                  child: block(node.children[index], depth + 1, '$path/$index'),
                ),
              ],
            )
          else
            block(node.children[index], depth + 1, '$path/$index'),
        if (count > pageSize)
          Wrap(
            spacing: BusyApiSpacing.sm,
            children: [
              Text(
                l.searchPage(selected + 1, (count + pageSize - 1) ~/ pageSize),
              ),
              BusyApiPushButton.standard(
                onPressed: selected == 0
                    ? null
                    : () => selectPage(selected - 1),
                child: Text(l.searchPreviousPage),
              ),
              BusyApiPushButton.standard(
                onPressed: (selected + 1) * pageSize >= count
                    ? null
                    : () => selectPage(selected + 1),
                child: Text(l.searchNextPage),
              ),
            ],
          ),
      ];
    }

    block = (ReferenceMarkup node, int depth, String path) {
      // The shared parser already bounds depth. Native nesting and a styled
      // inline tree have tighter layout limits; plain text remains complete.
      if (depth > 8 || ++blockCount > 160) {
        plainLayout = true;
        return Text(node.plainText, style: body);
      }
      inlineCount = 0;
      if (node.kind == 'ul' || node.kind == 'ol') {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: childBlocks(node, depth, path, markers: true),
        );
      }
      if (node.kind == 'blockquote') {
        return surface(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(BusyApiGlyphs.blockquote, size: BusyApiSizes.iconMd),
              const SizedBox(width: BusyApiSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: childBlocks(node, depth, path),
                ),
              ),
            ],
          ),
          BusyApiInsets.documentCalloutBlock,
          BusyApiInsets.documentCalloutContent,
        );
      }
      if (node.kind == 'pre') {
        return surface(
          Text(node.plainText, style: mono),
          BusyApiInsets.documentCodeBlock,
          BusyApiInsets.documentCodeContent,
        );
      }
      if (node.kind == 'hr') return Divider(color: colors.border);
      if (node.kind == 'li') {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: childBlocks(node, depth, path),
        );
      }
      final level = RegExp(r'^h[1-6]$').hasMatch(node.kind)
          ? int.parse(node.kind.substring(1))
          : null;
      final style = level == null
          ? body
          : body.copyWith(
              fontSize:
                  (body.fontSize ?? BusyApiTypography.defaultFontSize) *
                  BusyApiTypography.markdownHeadingScale(level),
              height: BusyApiTypography.markdownHeadingLineHeight(level),
              fontWeight: FontWeight.w700,
            );
      return Padding(
        padding: level == null
            ? BusyApiInsets.documentParagraphBlock
            : BusyApiInsets.documentHeadingBlock,
        child: Text.rich(inline(node, style), style: style),
      );
    };

    final linkEntries = links.entries.toList();
    final lastLinkPage = ((linkEntries.length - 1) ~/ pageSize).clamp(
      0,
      1000000,
    );
    final visibleLinkPage = linkPage.clamp(0, lastLinkPage);
    final longText = widget.text.length > 16384;
    final rawPage = page.clamp(
      0,
      ((widget.text.length - 1) ~/ 16384).clamp(0, 1000000),
    );
    int boundary(int offset) {
      offset = offset.clamp(0, widget.text.length);
      if (offset > 0 &&
          offset < widget.text.length &&
          widget.text.codeUnitAt(offset) >= 0xdc00 &&
          widget.text.codeUnitAt(offset) <= 0xdfff) {
        offset--;
      }
      return offset;
    }

    final blocks = current == null
        ? const <Widget>[]
        : [
            for (
              var index = page * pageSize;
              index < current.blocks.length && index < (page + 1) * pageSize;
              index++
            )
              block(current.blocks[index], 0, '$index'),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failed)
          Text(
            l.referenceMarkdownFailed,
            style: body.copyWith(color: colors.mutedForeground),
          ),
        if (longText)
          Text(
            l.referenceMarkdownPlain,
            style: body.copyWith(color: colors.mutedForeground),
          ),
        if (plainLayout)
          Text(
            l.referenceMarkdownLayout,
            style: body.copyWith(color: colors.mutedForeground),
          ),
        if (current == null)
          SelectableText(
            longText
                ? widget.text.substring(
                    boundary(rawPage * 16384),
                    boundary((rawPage + 1) * 16384),
                  )
                : widget.text,
            style: body,
          )
        else
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: blocks,
            ),
          ),
        if (longText)
          Wrap(
            spacing: BusyApiSpacing.sm,
            children: [
              Text(
                l.searchPage(
                  rawPage + 1,
                  (widget.text.length + 16383) ~/ 16384,
                ),
              ),
              BusyApiPushButton.standard(
                onPressed: rawPage == 0
                    ? null
                    : () => readingChange(() => page = rawPage - 1),
                child: Text(l.searchPreviousPage),
              ),
              BusyApiPushButton.standard(
                onPressed: (rawPage + 1) * 16384 >= widget.text.length
                    ? null
                    : () => readingChange(() => page = rawPage + 1),
                child: Text(l.searchNextPage),
              ),
            ],
          ),
        if (current != null && current.blocks.length > pageSize)
          Wrap(
            spacing: BusyApiSpacing.sm,
            children: [
              Text(
                l.searchPage(
                  page + 1,
                  (current.blocks.length + pageSize - 1) ~/ pageSize,
                ),
              ),
              BusyApiPushButton.standard(
                onPressed: page == 0 ? null : () => readingChange(() => page--),
                child: Text(l.searchPreviousPage),
              ),
              BusyApiPushButton.standard(
                onPressed: (page + 1) * pageSize >= current.blocks.length
                    ? null
                    : () => readingChange(() => page++),
                child: Text(l.searchNextPage),
              ),
            ],
          ),
        if (linkEntries.isNotEmpty)
          BusyApiActionRow(
            title: l.referenceInspectLinks(linkEntries.length),
            onTap: () => readingChange(() => inspectLinks = !inspectLinks),
          ),
        if (inspectLinks) ...[
          for (final link
              in linkEntries.skip(visibleLinkPage * pageSize).take(pageSize))
            BusyApiActionRow(
              title: l.referenceCopyLink(link.value),
              subtitle: link.key.toString(),
              onTap: () => copy(link.key),
            ),
          if (linkEntries.length > pageSize)
            Wrap(
              spacing: BusyApiSpacing.sm,
              children: [
                Text(l.searchPage(visibleLinkPage + 1, lastLinkPage + 1)),
                BusyApiPushButton.standard(
                  onPressed: visibleLinkPage == 0
                      ? null
                      : () =>
                            readingChange(() => linkPage = visibleLinkPage - 1),
                  child: Text(l.searchPreviousPage),
                ),
                BusyApiPushButton.standard(
                  onPressed: visibleLinkPage == lastLinkPage
                      ? null
                      : () =>
                            readingChange(() => linkPage = visibleLinkPage + 1),
                  child: Text(l.searchNextPage),
                ),
              ],
            ),
          if (copied != null) Text(l.referenceLinkCopied),
          if (copyFailed) Text(l.referenceLinkCopyFailed),
        ],
      ],
    );
  }
}
