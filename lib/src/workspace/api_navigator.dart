import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:busyapi_core/busyapi_core.dart'
    show httpOperationMethod, SpecificationFamily;
import 'package:flutter/services.dart';

import '../app/busyapi_design.dart';
import '../app/localization.dart';
import 'api_tree_row.dart';
import 'search_session.dart';
import 'workspace_controller.dart';

String _bounded(String value) => value.length <= 240
    ? value
    : '${value.substring(0, value.codeUnitAt(239) >= 0xd800 && value.codeUnitAt(239) <= 0xdbff ? 239 : 240)}…';

class _Node {
  _Node(this.id, this.title, this.target, List<_Node> children)
    : _children = children,
      childCount = children.length;
  _Node.lazy(
    this.id,
    this.title,
    this.target,
    this.childCount,
    this.createChildren,
    this.selectionInChildren,
  );
  final String id, title;
  final Map<String, dynamic>? target;
  final int childCount;
  List<_Node>? _children;
  List<_Node> Function()? createChildren;
  bool Function()? selectionInChildren;
  List<_Node> get children => _children ??= createChildren!();
  bool get hasChildren => childCount != 0;
}

/// Semantic occurrences are navigation, not extra buffers or mutable objects.
/// Only the current canonical projection supplies the operation inventory.
class ApiNavigator extends StatefulWidget {
  const ApiNavigator({
    super.key,
    required this.controller,
    required this.projection,
    required this.filter,
    required this.run,
    this.search,
  });
  final WorkspaceController controller;
  final Map<String, dynamic>? projection;
  final String filter;
  final void Function(Future<void> Function()) run;
  final BusyApiSearchSession? search;
  @override
  State<ApiNavigator> createState() => ApiNavigatorState();
}

class ApiNavigatorState extends State<ApiNavigator> {
  WorkspaceController get c => widget.controller;
  late final Object? projectOwner;
  late final String? entryRoot;
  final scroll = ScrollController();
  double lastScroll = 0;
  final focusNodes = <String, FocusNode>{};
  final expanded = <String>{};
  String grouping = 'path';
  Object? selection, modelIdentity;
  List<_Node> _nodes = [];
  List<(_Node, int)> _visible = [];
  Map<String, int> indices = {};
  bool restored = false, freshView = true;
  int navigation = 0;
  (String, int)? _searchView;
  bool get searching =>
      widget.search?.active == true &&
      widget.search?.category == BusyApiSearchCategory.navigation;
  int get searchIndex => _visible.isEmpty
      ? -1
      : (widget.search?.selected ?? 0).clamp(0, _visible.length - 1);
  bool get currentSearch =>
      mounted &&
      !c.disposed &&
      searching &&
      widget.search!.query.text == widget.filter &&
      !widget.search!.query.value.composing.isValid &&
      identical(projectOwner, c.project) &&
      entryRoot == c.root;

  void moveSearchSelection(int delta) {
    if (!currentSearch || _visible.isEmpty) return;
    widget.search!.select((searchIndex + delta).clamp(0, _visible.length - 1));
    _revealSearchSelection();
  }

  void _revealSearchSelection() {
    if (!mounted || !currentSearch || searchIndex < 0) return;
    final index = searchIndex;
    if (scroll.hasClients) {
      final top = index * extent, bottom = top + extent;
      final position = scroll.position;
      if (top < position.pixels ||
          bottom > position.pixels + position.viewportDimension) {
        scroll.jumpTo(
          (top - (position.viewportDimension - extent) / 2).clamp(
            0,
            position.maxScrollExtent,
          ),
        );
      }
    }
  }

  Future<void> activateSearchSelection() async {
    if (!currentSearch || searchIndex < 0) return;
    final node = _visible[searchIndex].$1;
    if (node.target == null) {
      _toggle(node);
    } else {
      await _select(node);
    }
  }

  String get stateKey => jsonEncode(['api-tree', entryRoot]);
  static const extent =
      BusyApiSizes.sidebarTreeRowHeight + BusyApiStroke.hairline * 2;
  @override
  void initState() {
    super.initState();
    projectOwner = c.project;
    entryRoot = c.root;
    scroll.addListener(remember);
  }

  @override
  void dispose() {
    remember();
    scroll.dispose();
    super.dispose();
  }

  void remember() {
    if (c.disposed || !identical(projectOwner, c.project)) return;
    if (scroll.hasClients) lastScroll = scroll.offset;
    final stored = c.layoutState['apiTrees'];
    final states = <String, dynamic>{
      if (stored is Map)
        for (final entry in stored.entries)
          if (entry.key is String) entry.key as String: entry.value,
    }..remove(stateKey);
    states[stateKey] = {
      'grouping': grouping,
      'expanded': expanded.take(4096).toList(),
      'scroll': lastScroll,
    };
    while (states.length > 128) {
      states.remove(states.keys.first);
    }
    c.layoutState = {...c.layoutState, 'apiTrees': states};
  }

  Map<String, dynamic> target(String pointer) => {
    ...?widget.projection?['info'] as Map?,
    'root': c.root,
    'resource': c.root,
    'pointer': pointer,
    'range': [0, 0],
    'occurrence': null,
  };
  List<_Node> _model(BuildContext context) {
    final l = context.l10n, projection = widget.projection;
    String id(String role, Object? value) => jsonEncode([c.root, role, value]);
    _Node node(
      String role,
      String title,
      Map<String, dynamic>? item, [
      List<_Node> children = const [],
    ]) => _Node(
      id(
        role,
        item == null
            ? null
            : [item['resource'], item['pointer'], item['occurrence']],
      ),
      _bounded(title),
      item,
      children,
    );
    final ops = (projection?['operations'] as List? ?? []).cast<Map>();
    final byRole = <String, Map<String, List<Map>>>{};
    for (final operation in ops) {
      byRole
          .putIfAbsent(operation['role'] as String? ?? 'operation', () => {})
          .putIfAbsent(operation['path'] as String, () => [])
          .add(operation);
    }
    final components = (projection?['components'] as List? ?? []).cast<Map>();
    final componentGroups = <String, List<Map>>{};
    for (final component in components) {
      if (component['group'] case final String group) {
        componentGroups.putIfAbsent(group, () => []).add(component);
      }
    }
    _Node operation(Map operation, String parent) => node(
      parent,
      '${httpOperationMethod(operation)} ${operation['path']}',
      Map<String, dynamic>.from(operation),
    );
    final paths = (projection?['pathItems'] as List? ?? []).cast<Map>();
    final pathNodes = <_Node>[];
    if (grouping == 'tag') {
      final tags = <String?, List<Map>>{};
      for (final op in ops.where(
        (o) => (o['role'] ?? 'operation') == 'operation',
      )) {
        final value = op['value'];
        final names = value is Map ? value['tags'] : null;
        final Set<String> values = names is List
            ? names.whereType<String>().toSet()
            : <String>{};
        for (final String? name in values.isEmpty ? <String?>[null] : values) {
          tags.putIfAbsent(name, () => []).add(op);
        }
      }
      for (final entry in tags.entries) {
        pathNodes.add(
          node(
            'tag-group:${jsonEncode(entry.key)}',
            entry.key == null ? l.untaggedOperations : entry.key!,
            null,
            [for (final op in entry.value) operation(op, 'tag:${entry.key}')],
          ),
        );
      }
    } else {
      for (final path in paths.where((p) => p['role'] == 'paths')) {
        pathNodes.add(
          node(
            'path',
            path['name'] as String,
            Map<String, dynamic>.from(path),
            [
              for (final op
                  in byRole['operation']?[path['name']] ?? const <Map>[])
                operation(op, 'path:${path['name']}'),
            ],
          ),
        );
      }
    }
    _Node componentGroup(String group, String title) {
      final pointer =
          (projection?['componentLocations'] as Map?)?[group] as String? ??
          '/components/$group';
      final item = target(pointer);
      return _Node.lazy(
        id('component-group', [item['resource'], pointer, null]),
        _bounded(title),
        item,
        componentGroups[group]?.length ?? 0,
        () => [
          for (final component in componentGroups[group] ?? const <Map>[])
            node(
              'component',
              component['name'] as String,
              Map<String, dynamic>.from(component),
            ),
        ],
        () =>
            c.selectedResource == entryRoot &&
            c.selectedPointer.startsWith('$pointer/'),
      );
    }

    final groups = {
      'parameters': l.parameters,
      'headers': l.headers,
      'requestBodies': l.requestBody,
      'responses': l.responses,
      'examples': l.examples,
      'links': l.links,
      'callbacks': l.callbacks,
      if (c.specification?.reusablePathItems == true) 'pathItems': l.pathItems,
      'securitySchemes': l.securitySchemes,
      'mediaTypes': l.mediaTypes,
    };
    return [
      node(
        'overview',
        l.overview,
        projection?['info'] == null
            ? null
            : Map<String, dynamic>.from(projection!['info']),
      ),
      node(
        'servers',
        l.servers,
        target(
          c.specification?.family == SpecificationFamily.swagger20
              ? ''
              : '/servers',
        ),
      ),
      node('security', l.security, target('/security')),
      node('tags', l.tags, target('/tags')),
      node('paths', l.paths, target('/paths'), pathNodes),
      componentGroup('schemas', l.schemas),
      node(
        'components',
        l.components,
        c.specification?.family == SpecificationFamily.swagger20
            ? null
            : target('/components'),
        [
          for (final group in groups.entries)
            if ((projection?['componentLocations'] as Map?)?.containsKey(
                  group.key,
                ) ==
                true)
              componentGroup(group.key, group.value),
        ],
      ),
      if (c.specification?.webhooks == true)
        node('webhooks', l.webhooks, target('/webhooks'), [
          for (final path in paths.where((p) => p['role'] == 'webhooks'))
            node(
              'webhook',
              path['name'] as String,
              Map<String, dynamic>.from(path),
              [
                for (final op
                    in byRole['webhook']?[path['name']] ?? const <Map>[])
                  operation(op, 'webhook:${path['name']}'),
              ],
            ),
        ]),
      if ((projection?['componentLocations'] as Map?)?.containsKey(
            'callbacks',
          ) ==
          true)
        node('callbacks', l.callbacks, null, [
          for (final op in ops.where((o) => o['role'] == 'callback'))
            operation(op, 'callback'),
        ]),
    ];
  }

  bool _selected(_Node node) =>
      node.target != null && c.isSelected(node.target!);
  void _flatten() {
    final rows = <(_Node, int)>[], needle = widget.filter.toLowerCase();
    List<(_Node, int)> visit(_Node node, int depth) {
      if (needle.isEmpty && !expanded.contains(node.id)) return [(node, depth)];
      final descendants = [
        for (final child in node.children) ...visit(child, depth + 1),
      ];
      final matches =
          needle.isEmpty || node.title.toLowerCase().contains(needle);
      if (!matches && descendants.isEmpty) return [];
      return [
        (node, depth),
        if (needle.isNotEmpty || expanded.contains(node.id)) ...descendants,
      ];
    }

    for (final node in _nodes) {
      rows.addAll(visit(node, 0));
    }
    _visible = rows;
    indices = {for (var i = 0; i < rows.length; i++) rows[i].$1.id: i};
  }

  void _toggle(_Node node) {
    if (!mounted ||
        c.disposed ||
        !identical(projectOwner, c.project) ||
        entryRoot != c.root) {
      return;
    }
    setState(() {
      expanded.contains(node.id)
          ? expanded.remove(node.id)
          : expanded.add(node.id);
      _flatten();
    });
    remember();
  }

  Future<void> _select(_Node node) async {
    if (!mounted ||
        c.disposed ||
        !identical(projectOwner, c.project) ||
        entryRoot != c.root) {
      return;
    }
    final item = node.target!;
    final request = ++navigation;
    if (c.mode != 'Source') {
      await c.selectObject(item);
      return;
    }
    final owner = c.project, root = c.root;
    final selected = (
      c.selectedResource,
      c.selectedPointer,
      c.selectedOccurrence,
    );
    if (owner == null || root == null || !await c.flush()) return;
    bool current() =>
        mounted &&
        !c.disposed &&
        identical(owner, c.project) &&
        root == c.root &&
        request == navigation &&
        selected ==
            (c.selectedResource, c.selectedPointer, c.selectedOccurrence);
    if (!current()) return;
    await owner.buffer(item['resource'] as String);
    if (!current()) return;
    await c.analyse();
    if (!current()) return;
    final fresh = await owner.inspectObject(
      root,
      item['resource'] as String,
      item['pointer'] as String,
    );
    if (!current()) return;
    await c.selectObject({
      ...item,
      ...fresh,
      if (fresh['absent'] == true) 'range': [0, 0],
      'occurrence': item['occurrence'],
    });
  }

  void focusIndex(int index) {
    if (index < 0 || index >= _visible.length) return;
    final id = _visible[index].$1.id;
    if (focusNodes[id] case final focus?) {
      focus.requestFocus();
      return;
    }
    if (scroll.hasClients) {
      scroll.jumpTo((index * extent).clamp(0, scroll.position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusNodes[id]?.requestFocus();
    });
  }

  KeyEventResult _key(_Node node, int index, int depth, KeyEvent event) {
    if (!mounted ||
        c.disposed ||
        !identical(projectOwner, c.project) ||
        entryRoot != c.root) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final code = event.logicalKey,
        rtl = Directionality.of(context) == TextDirection.rtl;
    if (code == LogicalKeyboardKey.arrowDown) {
      if (searching) moveSearchSelection(1);
      focusIndex(index + 1);
      return KeyEventResult.handled;
    }
    if (code == LogicalKeyboardKey.arrowUp) {
      if (searching) moveSearchSelection(-1);
      focusIndex(index - 1);
      return KeyEventResult.handled;
    }
    if (code == LogicalKeyboardKey.home) {
      focusIndex(0);
      return KeyEventResult.handled;
    }
    if (code == LogicalKeyboardKey.end) {
      focusIndex(_visible.length - 1);
      return KeyEventResult.handled;
    }
    if (code ==
        (rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight)) {
      if (node.hasChildren) {
        if (!expanded.contains(node.id)) {
          _toggle(node);
        } else {
          focusIndex(index + 1);
        }
      }
      return KeyEventResult.handled;
    }
    if (code ==
        (rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft)) {
      if (node.hasChildren && expanded.contains(node.id)) {
        _toggle(node);
      } else {
        var parent = index - 1;
        while (parent >= 0 && _visible[parent].$2 >= depth) {
          parent--;
        }
        focusIndex(parent);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (c.root == null) return Center(child: Text(context.l10n.selectRoot));
    if (widget.projection == null) {
      return Center(child: Text(context.l10n.checking));
    }
    if (!restored) {
      restored = true;
      final states = c.layoutState['apiTrees'];
      final candidate = states is Map ? states[stateKey] : null;
      final saved = candidate is Map ? candidate : null;
      freshView = saved == null;
      if (saved != null) {
        selection = (
          c.root,
          c.selectedResource,
          c.selectedPointer,
          c.selectedOccurrence,
        );
      }
      grouping = saved?['grouping'] == 'tag' ? 'tag' : 'path';
      final savedExpansion = saved?['expanded'];
      if (savedExpansion is List) {
        expanded.addAll(savedExpansion.whereType<String>().take(4096));
      }
      final offset = saved?['scroll'];
      if (offset is num && offset.isFinite) {
        lastScroll = offset.toDouble().clamp(0, 10000000);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.hasClients) {
            scroll.jumpTo(
              offset.toDouble().clamp(0, scroll.position.maxScrollExtent),
            );
          }
        });
      }
    }
    final next = (
      widget.projection?['contextSnapshot'],
      widget.projection?['snapshot'],
      widget.filter,
      grouping,
      Localizations.localeOf(context),
    );
    if (modelIdentity != next) {
      modelIdentity = next;
      _nodes = _model(context);
      if (freshView) {
        freshView = false;
        for (final root in _nodes.where(
          (n) =>
              n.target?['pointer'] == '/paths' ||
              n.target?['pointer'] == '/webhooks',
        )) {
          expanded.add(root.id);
          if (root.children.length <= 20) {
            expanded.addAll(root.children.map((n) => n.id));
          }
        }
      }
    }
    final current = (
      c.root,
      c.selectedResource,
      c.selectedPointer,
      c.selectedOccurrence,
    );
    if (selection != current) {
      selection = current;
      bool reveal(_Node node) {
        final child = node.selectionInChildren?.call() == false
            ? false
            : node.children.any(reveal);
        if (child) expanded.add(node.id);
        return child || _selected(node);
      }

      for (final node in _nodes) {
        reveal(node);
      }
    }
    _flatten();
    final nextSearchView = searching ? (widget.filter, searchIndex) : null;
    if (_searchView != nextSearchView) {
      _searchView = nextSearchView;
      if (nextSearchView != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_searchView == nextSearchView) _revealSearchSelection();
        });
      }
    }
    return Column(
      children: [
        BusyApiComboRow<String>(
          title: context.l10n.groupOperations,
          values: const ['path', 'tag'],
          selected: grouping,
          labelFor: (v) =>
              v == 'path' ? context.l10n.byPath : context.l10n.byTag,
          onSelected: (value) => setState(() {
            grouping = value;
            modelIdentity = null;
            selection = null;
            remember();
          }),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemExtent: extent,
            itemCount: _visible.length,
            findChildIndexCallback: (key) =>
                key is ValueKey<String> ? indices[key.value] : null,
            itemBuilder: (context, index) {
              final (node, depth) = _visible[index];
              return BusyApiTreeRow(
                key: ValueKey(node.id),
                title: node.title,
                depth: depth,
                selected: searching ? index == searchIndex : _selected(node),
                expanded: expanded.contains(node.id),
                hasChildren: node.hasChildren,
                tooltip: node.target == null
                    ? node.title
                    : '${node.target!['resource']}#${node.target!['pointer']}',
                onToggle: () => _toggle(node),
                onTap: () {
                  if (searching) widget.search!.select(index);
                  if (node.target == null) {
                    _toggle(node);
                  } else {
                    widget.run(() => _select(node));
                  }
                },
                onKey: (event) => _key(node, index, depth, event),
                register: (focus) => focusNodes[node.id] = focus,
                unregister: () => focusNodes.remove(node.id),
              );
            },
          ),
        ),
      ],
    );
  }
}
