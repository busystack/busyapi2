import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../app/busyapi_design.dart';
import '../app/contract_labels.dart';
import '../app/localization.dart';
import '../workspace/api_tree_row.dart';
import '../workspace/workspace_controller.dart';

/// A bounded viewport over lazy authored graph levels. It owns view state only;
/// definition navigation and field changes retain the workspace's transactions.
class AuthoredSchemaTree extends StatefulWidget {
  const AuthoredSchemaTree({
    super.key,
    required this.controller,
    required this.resource,
    required this.pointer,
    required this.selectedPointer,
    required this.snapshot,
    required this.run,
  });
  final WorkspaceController controller;
  final String resource, pointer, selectedPointer;
  final Object? snapshot;
  final void Function(Future<void> Function()) run;
  @override
  State<AuthoredSchemaTree> createState() => _AuthoredSchemaTreeState();
}

class _AuthoredSchemaTreeState extends State<AuthoredSchemaTree> {
  WorkspaceController get c => widget.controller;
  late final project = c.project!, root = c.root!;
  late final stateKey = jsonEncode([root, widget.resource, widget.pointer]);
  final expanded = <String>{}, pages = <String, Map<String, dynamic>>{};
  final loading = <String>{}, failed = <String>{};
  final focus = <String, FocusNode>{};
  final scroll = ScrollController(keepScrollOffset: false);
  final restoredCounts = <String, int>{};
  double restoreScroll = 0;
  bool restoredScroll = false, jumping = false;
  bool revealSelection = false;
  int selectedIndex = -1;
  int builtRows = 0;
  static int owners = 0;
  late final requestPrefix = 'schema-tree-${++owners}:';
  Future<void> tail = Future.value();
  int serial = 0;
  int epoch = 0;
  int modelRevision = 0;
  late int semanticRevision = c.semanticViewRevision;
  bool get current =>
      mounted &&
      !c.disposed &&
      identical(c.project, project) &&
      c.root == root &&
      c.mode == 'Design';
  late bool active = current;
  @override
  void initState() {
    super.initState();
    restore();
    scroll.addListener(() {
      if (!jumping && restoredScroll) {
        restoreScroll = scroll.offset;
        remember();
      }
    });
    load(widget.pointer);
  }

  void restore() {
    expanded.clear();
    restoredCounts.clear();
    final saved = c.layoutState['schemaTrees'];
    final state = saved is Map ? saved[stateKey] : null;
    if (state is Map) {
      revealSelection =
          state['selection'] != widget.selectedPointer &&
          widget.selectedPointer != widget.pointer;
      final savedExpansion = state['expanded'], counts = state['counts'];
      if (savedExpansion is List) {
        expanded.addAll(savedExpansion.whereType<String>().take(4096));
      }
      if (counts is Map) {
        for (final entry in counts.entries) {
          if (entry.key is String && entry.value is int) {
            restoredCounts[entry.key] = (entry.value as int).clamp(0, 400000);
          }
        }
      }
      if (state['scroll'] is num && (state['scroll'] as num).isFinite) {
        restoreScroll = (state['scroll'] as num).toDouble().clamp(0, 10000000);
      }
    }
    expanded.add(widget.pointer);
    // Definition reveal expands authored ancestors, never referenced targets.
    var at = widget.selectedPointer;
    while (at.startsWith('${widget.pointer}/')) {
      at = at.substring(0, at.lastIndexOf('/'));
      expanded.add(at);
    }
  }

  @override
  void didUpdateWidget(AuthoredSchemaTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resumed = !active && current;
    if (active && !current) {
      ++epoch;
      cancelRequests();
      loading.clear();
    }
    active = current;
    final transitioned = semanticRevision != c.semanticViewRevision;
    if (transitioned) {
      semanticRevision = c.semanticViewRevision;
      restore();
    }
    if (oldWidget.snapshot != widget.snapshot || transitioned || resumed) {
      ++epoch;
      cancelRequests();
      if (!transitioned) {
        for (final entry in pages.entries) {
          final loaded = (entry.value['entries'] as List).length;
          if (loaded > (restoredCounts[entry.key] ?? 0)) {
            restoredCounts[entry.key] = loaded;
          }
        }
        if (scroll.hasClients) restoreScroll = scroll.offset;
      }
      restoredScroll = false;
      pages.clear();
      loading.clear();
      failed.clear();
      if (current) load(widget.pointer);
    }
  }

  void remember() {
    if (c.disposed ||
        !identical(c.project, project) ||
        semanticRevision != c.semanticViewRevision) {
      return;
    }
    final saved = c.layoutState['schemaTrees'];
    final states = <String, dynamic>{
      if (saved is Map) ...Map<String, dynamic>.from(saved),
    }..remove(stateKey);
    states[stateKey] = {
      'expanded': expanded.take(4096).toList(),
      'counts': Map<String, int>.from(restoredCounts),
      'scroll': restoreScroll,
      'selection': widget.selectedPointer,
    };
    while (states.length > 128) {
      states.remove(states.keys.first);
    }
    c.layoutState = {...c.layoutState, 'schemaTrees': states};
  }

  @override
  void dispose() {
    ++epoch;
    cancelRequests();
    remember();
    scroll.dispose();
    super.dispose();
  }

  void cancelRequests() {
    unawaited(
      project.engine.cancelPrefix(requestPrefix).catchError((Object _) {}),
    );
  }

  Future<void> load(String pointer, {bool more = false}) async {
    if (loading.contains(pointer) ||
        c.disposed ||
        !identical(c.project, project)) {
      return;
    }
    setState(() {
      loading.add(pointer);
      failed.remove(pointer);
    });
    final captured = epoch, previous = more ? pages[pointer] : null;
    final before = tail, completed = Completer<void>();
    tail = completed.future;
    bool continueLoading = false;
    try {
      await before;
      if (!current || captured != epoch) {
        return;
      }
      final page = await project.schemaTree(
        root,
        widget.resource,
        pointer,
        offset: previous == null ? 0 : (previous['entries'] as List).length,
        requestId: '$requestPrefix${++serial}',
        reveal: widget.selectedPointer,
        cancelled: () => !current || captured != epoch,
      );
      if (!current || captured != epoch) {
        return;
      }
      if (previous != null && previous['snapshot'] != page['snapshot']) {
        pages.clear();
        ++epoch;
        loading.clear();
        unawaited(load(widget.pointer));
        return;
      }
      setState(
        () => pages[pointer] = {
          ...page,
          'entries': [
            ...?previous?['entries'] as List?,
            ...page['entries'] as List,
          ],
        },
      );
      modelRevision++;
      final target = (restoredCounts[pointer] ?? 0).clamp(
        0,
        page['count'] as int,
      );
      final revealed = (page['revealOffset'] as int? ?? -50) + 50;
      final loaded = (pages[pointer]!['entries'] as List).length;
      // A route can leave while restoration is still reading its first page.
      // That partial presentation must not overwrite the deeper captured view
      // it was restoring. Clamp only against the current graph's real count.
      restoredCounts[pointer] = (loaded > target ? loaded : target).clamp(
        0,
        page['count'] as int,
      );
      continueLoading =
          loaded < page['count'] && (loaded < target || loaded < revealed);
      remember();
      for (final entry in page['entries'] as List) {
        if (expanded.contains(entry['pointer']) &&
            entry['childCount'] > 0 &&
            !pages.containsKey(entry['pointer'])) {
          load(entry['pointer']);
        }
      }
    } on Object {
      if (current && captured == epoch) setState(() => failed.add(pointer));
    } finally {
      completed.complete();
      if (mounted && captured == epoch) {
        loading.remove(pointer);
        if (current) {
          setState(() {});
          if (continueLoading && expanded.contains(pointer)) {
            unawaited(load(pointer, more: true));
          }
        }
      }
    }
  }

  void toggle(String pointer) {
    setState(() {
      if (!expanded.remove(pointer)) {
        expanded.add(pointer);
        if (!pages.containsKey(pointer)) load(pointer);
      }
      remember();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, rows = <(Map<String, dynamic>, int)>[];
    void visit(Map<String, dynamic> node, int depth) {
      rows.add((node, depth));
      final pointer = node['pointer'] as String;
      if (!expanded.contains(pointer) || node['childCount'] == 0) return;
      final page = pages[pointer];
      for (final entry in page?['entries'] as List? ?? []) {
        visit(Map<String, dynamic>.from(entry), depth + 1);
      }
      if (page == null || (page['entries'] as List).length < page['count']) {
        rows.add(({'more': pointer}, depth + 1));
      }
    }

    final first = pages[widget.pointer];
    if (first != null) visit(Map<String, dynamic>.from(first['node']), 0);
    builtRows = rows.length;
    selectedIndex = rows.indexWhere(
      (row) => row.$1['pointer'] == widget.selectedPointer,
    );
    if (first != null && loading.isEmpty && !restoredScroll) {
      final builtRevision = modelRevision, builtEpoch = epoch;
      // Restore after this exact model has been laid out, not after an async
      // reply which may arrive during an earlier frame's post-frame phase.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            builtEpoch != epoch ||
            builtRevision != modelRevision ||
            restoredScroll ||
            loading.isNotEmpty ||
            !scroll.hasClients) {
          return;
        }
        final expectedExtent =
            (rows.length *
                        (BusyApiSizes.sidebarTreeRowHeight +
                            BusyApiStroke.hairline * 2) -
                    scroll.position.viewportDimension)
                .clamp(0, double.infinity);
        jumping = true;
        scroll.jumpTo(
          (revealSelection && selectedIndex >= 0
                  ? selectedIndex *
                        (BusyApiSizes.sidebarTreeRowHeight +
                            BusyApiStroke.hairline * 2)
                  : restoreScroll)
              // The fixed-row model is current; lazy scroll metrics can still
              // describe the former delegate until scrolling lays it out.
              .clamp(0, expectedExtent)
              .toDouble(),
        );
        restoreScroll = scroll.offset;
        revealSelection = false;
        jumping = false;
        restoredScroll = true;
        remember();
      });
    }
    final extent =
        BusyApiSizes.sidebarTreeRowHeight + BusyApiStroke.hairline * 2;
    void focusAt(int offset) {
      if (offset < 0 || offset >= rows.length || !scroll.hasClients) return;
      scroll
          .animateTo(
            (offset * extent).clamp(0, scroll.position.maxScrollExtent),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : BusyApiMotion.sidebarExpand,
            curve: Curves.easeOut,
          )
          .then((_) {
            if (!mounted) return;
            final target = rows[offset].$1;
            focus[target['pointer'] ?? 'more:${target['more']}']
                ?.requestFocus();
          });
    }

    return BusyApiGroupedList(
      title: l.schemaTree,
      description: l.schemaTreeAuthored,
      children: [
        if (first == null)
          BusyApiActionRow(
            title: failed.contains(widget.pointer)
                ? l.retryObjectPage
                : l.checking,
            onTap: failed.contains(widget.pointer)
                ? () => load(widget.pointer)
                : null,
          )
        else
          NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.depth == 0 &&
                  notification.direction != ScrollDirection.idle) {
                restoredScroll = true;
                restoreScroll = scroll.hasClients
                    ? scroll.offset
                    : restoreScroll;
              }
              return false;
            },
            child: SizedBox(
              height: (rows.length * extent).clamp(extent * 2, extent * 8),
              child: ListView.builder(
                controller: scroll,
                padding: EdgeInsets.zero,
                itemExtent: extent,
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final (node, depth) = rows[index];
                  final more = node['more'] as String?;
                  if (more != null) {
                    void next() {
                      if (!loading.contains(more)) load(more, more: true);
                    }

                    return BusyApiTreeRow(
                      key: ValueKey('more:$more'),
                      title: failed.contains(more)
                          ? l.retryObjectPage
                          : loading.contains(more)
                          ? l.checking
                          : l.schemaTreeMore,
                      tooltip: l.schemaTreePage(
                        (pages[more]?['entries'] as List? ?? []).length,
                        pages[more]?['count'] as int? ?? 0,
                      ),
                      depth: depth.clamp(0, 16),
                      selected: false,
                      hasChildren: false,
                      expanded: false,
                      onToggle: () {},
                      onTap: next,
                      register: (value) => focus['more:$more'] = value,
                      unregister: () => focus.remove('more:$more'),
                      onKey: (event) {
                        if (event is! KeyDownEvent &&
                            event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          focusAt(index - 1);
                        } else if (event.logicalKey ==
                            LogicalKeyboardKey.arrowDown) {
                          focusAt(index + 1);
                        } else if (event.logicalKey ==
                                LogicalKeyboardKey.enter ||
                            event.logicalKey == LogicalKeyboardKey.space) {
                          next();
                        } else {
                          return KeyEventResult.ignored;
                        }
                        return KeyEventResult.handled;
                      },
                    );
                  }
                  final pointer = node['pointer'] as String;
                  final types = (node['types'] as List? ?? []).join(' | ');
                  final refs = node['references'] as List;
                  final name = depth == 0
                      ? l.schema
                      : node['kind'] == 'schema'
                      ? (node['name'] as String).isEmpty
                            ? l.emptyObjectName
                            : node['name'] as String
                      : contractFieldLabel(context, node['name'] as String);
                  final title =
                      '$name${node.containsKey('boolean')
                          ? ' · ${node['boolean']}'
                          : types.isNotEmpty
                          ? ' · $types'
                          : ''}'
                      '${node['required'] == true ? ' · ${l.required}' : ''}'
                      '${refs.isNotEmpty ? ' · ${l.referenceOccurrence}' : ''}';
                  void select() => widget.run(() => c.selectObject(node));

                  return BusyApiTreeRow(
                    key: ValueKey(pointer),
                    title: title,
                    depth: depth.clamp(0, 16),
                    tooltip:
                        '${contractIdentityLabel(pointer)}\n${refs.map((r) => '${r['keyword']}: ${r['value']}').join('\n')}',
                    selected: widget.selectedPointer == pointer,
                    hasChildren: node['childCount'] > 0,
                    expanded: expanded.contains(pointer),
                    onToggle: () => toggle(pointer),
                    onTap: select,
                    register: (value) => focus[pointer] = value,
                    unregister: () => focus.remove(pointer),
                    onKey: (event) {
                      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                        return KeyEventResult.ignored;
                      }
                      final key = event.logicalKey;
                      if (key == LogicalKeyboardKey.arrowDown) {
                        focusAt(index + 1);
                      } else if (key == LogicalKeyboardKey.arrowUp) {
                        focusAt(index - 1);
                      } else if (key == LogicalKeyboardKey.home) {
                        focusAt(0);
                      } else if (key == LogicalKeyboardKey.end) {
                        focusAt(rows.length - 1);
                      } else if (key == LogicalKeyboardKey.arrowRight &&
                          node['childCount'] > 0) {
                        if (!expanded.contains(pointer)) {
                          toggle(pointer);
                        } else {
                          focusAt(index + 1);
                        }
                      } else if (key == LogicalKeyboardKey.arrowLeft) {
                        if (expanded.contains(pointer)) {
                          toggle(pointer);
                        } else {
                          var at = index - 1;
                          while (at >= 0 && rows[at].$2 >= depth) {
                            at--;
                          }
                          focusAt(at);
                        }
                      } else if (key == LogicalKeyboardKey.enter ||
                          key == LogicalKeyboardKey.space) {
                        select();
                      } else {
                        return KeyEventResult.ignored;
                      }
                      return KeyEventResult.handled;
                    },
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
