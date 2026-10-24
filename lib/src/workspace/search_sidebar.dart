// Adapted from BusyMark's search_sidebar.dart and search_result_presentation.dart.
// Copyright 2026 BusyStack (Apache-2.0). BusyAPI search and command bindings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/busyapi_search_field.dart';
import '../app/command_registry.dart';
import '../app/keyboard_shortcut_badge.dart';
import '../app/localization.dart';
import 'project_search.dart';
import 'search_session.dart';

bool _searchResultHasFocus() {
  var result = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    if (element.widget is BusyApiSearchResultList) {
      result = true;
      return false;
    }
    return true;
  });
  return result;
}

// BusyMark's search-result preview limit, preserving Unicode scalar boundaries.
String _searchResultTitle(String value) {
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 120) return text;
  var end = 117;
  if (text.codeUnitAt(end) >= 0xdc00 &&
      text.codeUnitAt(end) <= 0xdfff &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff) {
    end--;
  }
  return '${text.substring(0, end)}...';
}

class BusyApiSearchResult {
  const BusyApiSearchResult({
    required this.identity,
    required this.title,
    required this.subtitle,
    required this.activate,
    this.enabled = true,
    this.icon = BusyApiGlyphs.document,
    this.shortcut,
    this.details,
  });
  final String identity, title, subtitle;
  final String? shortcut, details;
  final IconData icon;
  final bool enabled;
  final Future<void> Function() activate;
}

class BusyApiSearchSidebar extends StatefulWidget {
  const BusyApiSearchSidebar({
    super.key,
    required this.session,
    required this.registry,
    required this.onReveal,
    required this.run,
    this.navigation,
    this.onMoveNavigation,
    this.onActivateNavigation,
  });
  final BusyApiSearchSession session;
  final BusyApiCommandRegistry registry;
  final Widget? navigation;
  final ValueChanged<int>? onMoveNavigation;
  final Future<void> Function()? onActivateNavigation;
  final Future<void> Function(Map<String, dynamic>) onReveal;
  final void Function(Future<void> Function()) run;
  @override
  State<BusyApiSearchSidebar> createState() => BusyApiSearchSidebarState();
}

class BusyApiSearchSidebarState extends State<BusyApiSearchSidebar> {
  List<BusyApiSearchResult> results = const [];
  bool _activating = false;
  void reviewReplacement() {
    final s = widget.session;
    final captured = s.result, owner = s.workspace.project;
    if (captured == null ||
        captured.matches.isEmpty ||
        owner == null ||
        s.query.value.composing.isValid ||
        s.replacement.value.composing.isValid) {
      return;
    }
    final replacement = s.replacement.text;
    widget.run(
      () => showProjectReplacementReview(
        context,
        s.workspace,
        owner,
        captured,
        replacement,
      ),
    );
  }

  void move(int delta) {
    if (!mounted ||
        !widget.session.active ||
        widget.session.query.value.composing.isValid) {
      return;
    }
    if (widget.session.category == BusyApiSearchCategory.navigation) {
      widget.onMoveNavigation?.call(delta);
      return;
    }
    widget.session.move(delta, results.length);
  }

  Future<void> activateSelected() async {
    if (_activating) return;
    final session = widget.session;
    if (!mounted || !session.active || session.query.value.composing.isValid) {
      return;
    }
    if (session.category == BusyApiSearchCategory.navigation) {
      _activating = true;
      try {
        await widget.onActivateNavigation?.call();
      } finally {
        _activating = false;
      }
      return;
    }
    final request = (
      session.category,
      session.query.text,
      session.focusRequest,
      session.workspace.project,
      session.workspace.root,
      session.workspace.active,
    );
    if (session.running ||
        session.category != BusyApiSearchCategory.actions &&
            session.result == null &&
            session.semanticResult == null) {
      await session.search();
      if (!mounted ||
          !session.active ||
          request !=
              (
                session.category,
                session.query.text,
                session.focusRequest,
                session.workspace.project,
                session.workspace.root,
                session.workspace.active,
              )) {
        return;
      }
      results = _results(context);
    }
    final index = session.selected;
    if (index < 0 || index >= results.length || !results[index].enabled) return;
    _activating = true;
    try {
      await results[index].activate();
    } finally {
      _activating = false;
    }
  }

  List<BusyApiSearchResult> _results(BuildContext context) {
    final s = widget.session;
    final owner = s.workspace.project;
    final category = s.category, query = s.query.text;
    bool current() =>
        mounted &&
        s.active &&
        identical(s.workspace.project, owner) &&
        s.category == category &&
        s.query.text == query &&
        !s.query.value.composing.isValid;
    String path(String id) {
      final uri = Uri.parse(id);
      return uri.scheme == 'file' && owner != null
          ? p.relative(uri.toFilePath(), from: owner.access.boundary)
          : id;
    }

    if (s.category == BusyApiSearchCategory.actions) {
      final ranked = [
        for (final command in widget.registry.commands)
          if (commandMatchRank(
                name: command.label(context),
                category: command.category(context),
                id: command.id,
                query: s.query.text,
              )
              case final rank?)
            (command, rank),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [
        for (final (command, _) in ranked)
          BusyApiSearchResult(
            identity: command.id,
            title: command.label(context),
            subtitle: command.category(context),
            enabled: command.canExecute,
            icon: BusyApiGlyphs.keyboard,
            shortcut: command.shortcut?.label,
            activate: () async {
              s.close();
              await widget.registry.execute(command.id);
            },
          ),
      ];
    }
    if (s.category == BusyApiSearchCategory.navigation) {
      // The retained API tree or Files list owns both the visible model and
      // its keyboard selection. There is no parallel file-match inventory.
      return const [];
    }
    if (s.category == BusyApiSearchCategory.semantic) {
      final captured = s.semanticResult;
      if (captured == null) return const [];
      return [
        for (final match in captured.matches)
          BusyApiSearchResult(
            identity: match['semanticId'] as String,
            title: _searchResultTitle(match['label'] as String),
            subtitle:
                '${path(match['resource'] as String)} · ${match['pointer']}',
            details:
                '${match['root']}\n${match['resource']}\n${match['pointer']}',
            activate: () async {
              if (!current() || !identical(s.semanticResult, captured)) return;
              if (!captured.current) {
                s.setError(CoreFailure('search.stale', ''));
                return;
              }
              await widget.onReveal(Map<String, dynamic>.from(match));
            },
          ),
      ];
    }
    final captured = s.result;
    if (captured == null) return const [];
    return [
      for (final match in captured.matches)
        BusyApiSearchResult(
          identity: '${match.resource}:${match.start}',
          title: _searchResultTitle(match.expected),
          subtitle: '${path(match.resource)}:${match.line}',
          details: match.resource,
          activate: () async {
            if (!current() || !identical(s.result, captured)) return;
            if (owner == null || !captured.current(owner.store)) {
              s.error = CoreFailure('search.stale', '');
              if (mounted) setState(() {});
              return;
            }
            await widget.onReveal({
              'resource': match.resource,
              'range': [match.start, match.end],
              'generation': match.generation,
            });
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session, l = context.l10n;
    String label(BusyApiSearchCategory category) => switch (category) {
      BusyApiSearchCategory.document => l.documentSearch,
      BusyApiSearchCategory.project => l.projectSearch,
      BusyApiSearchCategory.semantic => l.semanticSearch,
      BusyApiSearchCategory.navigation => l.navigation,
      BusyApiSearchCategory.actions => l.actions,
    };
    results = _results(context);
    final text =
        s.category == BusyApiSearchCategory.document ||
        s.category == BusyApiSearchCategory.project;
    final stale =
        s.result != null &&
        s.workspace.store != null &&
        !s.result!.current(s.workspace.store!);
    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent ||
            s.query.value.composing.isValid ||
            s.replacement.value.composing.isValid) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          s.close();
          return KeyEventResult.handled;
        }
        if (!_searchResultHasFocus()) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          move(event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          widget.run(activateSelected);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BusyApiSpacing.sm,
              vertical: BusyApiSpacing.xs,
            ),
            child: Row(
              children: [
                const Icon(BusyApiGlyphs.search, size: BusyApiSizes.iconSm),
                const SizedBox(width: BusyApiSpacing.xs),
                Text(l.search),
                Expanded(
                  child: BusyApiPopupSelector<BusyApiSearchCategory>(
                    value: s.category,
                    label: label(s.category),
                    tooltip: l.searchMode,
                    fullWidth: true,
                    maxLabelLines: 2,
                    options: [
                      for (final category in BusyApiSearchCategory.values)
                        if (category == BusyApiSearchCategory.actions ||
                            (category == BusyApiSearchCategory.document
                                ? s.workspace.buffer != null
                                : s.workspace.project != null))
                          BusyApiPopupSelectorOption(
                            value: category,
                            label: label(category),
                          ),
                    ],
                    onSelected: s.open,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            fit: FlexFit.loose,
            child: BusyApiLocalTextEditingShortcuts(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (text)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: BusyApiSpacing.sm,
                        ),
                        child: BusyApiGroupedList(
                          children: [
                            BusyApiSwitchRow(
                              title: l.regularExpression,
                              value: s.regex,
                              onChanged: (value) {
                                s.regex = value;
                                s.optionsChanged();
                              },
                            ),
                            BusyApiSwitchRow(
                              title: l.caseSensitive,
                              value: s.sensitive,
                              onChanged: (value) {
                                s.sensitive = value;
                                s.optionsChanged();
                              },
                            ),
                            BusyApiGroupedTextEntry(
                              label: l.replacement,
                              controller: s.replacement,
                            ),
                            BusyApiActionRow(
                              title: l.reviewReplacement,
                              enabled:
                                  s.result?.matches.isNotEmpty == true &&
                                  s.workspace.project != null &&
                                  !s.query.value.composing.isValid &&
                                  !s.replacement.value.composing.isValid,
                              onTap:
                                  s.result?.matches.isNotEmpty == true &&
                                      s.workspace.project != null &&
                                      !s.query.value.composing.isValid &&
                                      !s.replacement.value.composing.isValid
                                  ? reviewReplacement
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    if (s.category == BusyApiSearchCategory.semantic)
                      BusyApiComboRow<String>(
                        title: l.semanticCategory,
                        values: const [
                          'all',
                          'operations',
                          'components',
                          'definitions',
                          'usages',
                        ],
                        selected: s.semanticCategory,
                        labelFor: (value) => switch (value) {
                          'operations' => l.operations,
                          'components' => l.components,
                          'definitions' => l.definitions,
                          'usages' => l.sourceFindUsages,
                          _ => l.semanticObjects,
                        },
                        onSelected: (value) {
                          s.semanticCategory = value;
                          s.optionsChanged();
                        },
                      ),
                    if (s.running) const LinearProgressIndicator(),
                    if (s.running)
                      BusyApiActionRow(title: l.cancel, onTap: s.cancel),
                    if (s.error != null)
                      BusyApiStatusBox(
                        message: searchFailure(context, s.error!),
                        kind: BusyApiStatusKind.error,
                      ),
                    if (stale)
                      BusyApiStatusBox(
                        message: l.searchStale,
                        kind: BusyApiStatusKind.warning,
                      ),
                    if (s.semanticResult?.complete == false)
                      BusyApiStatusBox(
                        message: l.semanticSearchIncomplete,
                        kind: BusyApiStatusKind.warning,
                      ),
                    if (s.result case final captured?)
                      _SearchNotice(
                        l.searchMatchCount(
                          captured.matches.length,
                          captured.matches
                              .map((m) => m.resource)
                              .toSet()
                              .length,
                        ),
                      ),
                    if (s.semanticResult case final captured?)
                      _SearchNotice(
                        l.semanticMatchCount(
                          captured.matches.length,
                          captured.checkedRoots.length,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child:
                widget.navigation ??
                (results.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(BusyApiSpacing.sm),
                          child: Text(
                            s.running || s.error != null
                                ? ''
                                : s.query.text.isEmpty
                                ? l.searchEnterText
                                : l.noSearchResults,
                          ),
                        ),
                      )
                    : BusyApiSearchResultList(
                        key: ValueKey(s.category),
                        results: results,
                        selected: s.selected,
                        scroll: s.scroll,
                        onSelected: s.select,
                        onActivate: (index) {
                          s.select(index);
                          widget.run(activateSelected);
                        },
                      )),
          ),
        ],
      ),
    );
  }
}

// BusyMark's _SearchNotice: compact context and completeness information.
class _SearchNotice extends StatelessWidget {
  const _SearchNotice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: BusyApiSpacing.md,
      vertical: BusyApiSpacing.xs,
    ),
    child: Text(
      text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

class BusyApiSearchResultList extends StatefulWidget {
  const BusyApiSearchResultList({
    super.key,
    required this.results,
    required this.selected,
    required this.scroll,
    required this.onSelected,
    required this.onActivate,
  });
  final List<BusyApiSearchResult> results;
  final int selected;
  final ScrollController scroll;
  final ValueChanged<int> onSelected, onActivate;
  @override
  State<BusyApiSearchResultList> createState() =>
      _BusyApiSearchResultListState();
}

class _BusyApiSearchResultListState extends State<BusyApiSearchResultList> {
  final _keys = <int, GlobalKey>{};
  final _focus = <String, FocusNode>{};
  @override
  void didUpdateWidget(BusyApiSearchResultList oldWidget) {
    super.didUpdateWidget(oldWidget);
    var changed = oldWidget.results.length != widget.results.length;
    if (!changed) {
      for (var index = 0; index < widget.results.length; index++) {
        final before = oldWidget.results[index], after = widget.results[index];
        if (before.identity != after.identity ||
            before.title != after.title ||
            before.subtitle != after.subtitle ||
            before.enabled != after.enabled) {
          changed = true;
          break;
        }
      }
    }
    if (changed) _keys.clear();
    final retained = {for (final result in widget.results) result.identity};
    final released = [
      for (final id in _focus.keys.toList())
        if (!retained.contains(id)) _focus.remove(id)!,
    ];
    if (released.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in released) {
          node.dispose();
        }
      });
    }
    if (oldWidget.selected != widget.selected || changed) {
      final index = widget.selected;
      final restoreFocus = _focus.values.any((f) => f.hasFocus);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_reveal(index, restoreFocus)),
      );
    }
  }

  Future<void> _reveal(int index, bool restoreFocus) async {
    if (!mounted || index < 0 || index >= widget.results.length) return;
    final identity = widget.results[index].identity;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    while (mounted &&
        widget.scroll.hasClients &&
        widget.selected == index &&
        index < widget.results.length &&
        widget.results[index].identity == identity) {
      final target = _keys[index]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: .5,
          duration: reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 80),
        );
        if (restoreFocus &&
            mounted &&
            widget.selected == index &&
            index < widget.results.length) {
          _focus[widget.results[index].identity]?.requestFocus();
        }
        return;
      }
      final mountedRows = _keys.entries.where(
        (e) => e.value.currentContext != null,
      );
      final before = mountedRows.isNotEmpty && index < mountedRows.first.key;
      final position = widget.scroll.position;
      final offset =
          (position.pixels + position.viewportDimension * (before ? -.8 : .8))
              .clamp(0.0, position.maxScrollExtent);
      if (offset == position.pixels) return;
      widget.scroll.jumpTo(offset);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  void dispose() {
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: PageStorageKey(widget.scroll),
    controller: widget.scroll,
    padding: BusyApiInsets.sidebarList,
    itemCount: widget.results.length,
    itemBuilder: (context, index) {
      final result = widget.results[index];
      return BusyApiSidebarRecordRow<void>(
        key: ValueKey(result.identity),
        geometryKey: _keys.putIfAbsent(index, GlobalKey.new),
        icon: result.icon,
        compact: true,
        selected: index == widget.selected,
        focusNode: _focus.putIfAbsent(result.identity, FocusNode.new),
        onFocusChange: (focus) {
          if (focus) widget.onSelected(index);
        },
        tooltip: result.details,
        semanticsLabel: '${result.title}\n${result.subtitle}',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: result.enabled
                    ? BusyApiSurfaceColors.of(context).foreground
                    : BusyApiSurfaceColors.of(context).mutedForeground,
              ),
            ),
            Text(
              result.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: BusyApiSurfaceColors.of(context).mutedForeground,
              ),
            ),
          ],
        ),
        trailing: result.shortcut == null
            ? null
            : ConstrainedBox(
                // BusyMark SearchResultList uses the same badge bound.
                constraints: const BoxConstraints(maxWidth: 120),
                child: BusyApiKeyboardShortcutBadge(result.shortcut!),
              ),
        onTap: result.enabled ? () => widget.onActivate(index) : null,
      );
    },
  );
}
