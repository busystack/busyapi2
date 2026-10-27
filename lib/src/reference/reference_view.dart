import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:busyapi_core/busyapi_core.dart'
    show httpOperationMethod, referenceMarkdownBase;

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/busyapi_search_field.dart';
import '../app/localization.dart';
import '../app/busyapi_disclosure.dart';
import '../workspace/workspace_controller.dart';
import 'reference_object.dart';
import 'owned_reference_markdown.dart';

class ReferenceView extends StatelessWidget {
  const ReferenceView({
    super.key,
    required this.controller,
    required this.reveal,
    this.tryOperation,
  });
  final WorkspaceController controller;
  final void Function(Map<String, dynamic>) reveal;
  final ValueChanged<Map<String, dynamic>>? tryOperation;
  @override
  Widget build(BuildContext context) => _ReferenceBody(
    key: ValueKey((controller.project, controller.root)),
    controller: controller,
    reveal: reveal,
    tryOperation: tryOperation,
  );
}

class _ReferenceBody extends StatefulWidget {
  const _ReferenceBody({
    super.key,
    required this.controller,
    required this.reveal,
    this.tryOperation,
  });
  final WorkspaceController controller;
  final void Function(Map<String, dynamic>) reveal;
  final ValueChanged<Map<String, dynamic>>? tryOperation;
  @override
  State<_ReferenceBody> createState() => _ReferenceViewState();
}

class _ReferenceViewState extends State<_ReferenceBody> {
  String query = '';
  late final owner = widget.controller.project;
  late final root = widget.controller.root;
  late final TextEditingController search;
  late final ScrollController scroll;
  double lastOffset = 0;
  double? restoreOffset;
  bool restored = false, restoringScroll = false;
  late int semanticRevision = widget.controller.semanticViewRevision;
  Map<String, dynamic>? detail;
  final trail = <Map<String, dynamic>>[];
  String get stateKey => jsonEncode([root]);
  bool get current =>
      mounted &&
      !widget.controller.disposed &&
      identical(widget.controller.project, owner) &&
      widget.controller.root == root;
  @override
  void initState() {
    super.initState();
    search = TextEditingController();
    scroll = ScrollController()..addListener(remember);
  }

  void restore() {
    if (restored) return;
    restored = true;
    final states = widget.controller.layoutState['nativeReference'];
    final candidate = states is Map ? states[stateKey] : null;
    final saved = candidate is Map ? candidate : const {};
    final savedQuery = saved['query'];
    query = savedQuery is String ? savedQuery : '';
    search.text = query;
    final offset = saved['scroll'];
    if (offset is num && offset.isFinite) {
      lastOffset = offset.toDouble().clamp(0, 10000000);
      restoreOffset = lastOffset;
    }
    final target = saved['detail'];
    if (target is Map &&
        target['resource'] is String &&
        target['pointer'] is String) {
      detail = Map<String, dynamic>.from(target);
    }
    restoreTrail(saved['trail']);
  }

  void restoreTrail(Object? value) {
    trail.clear();
    if (value is! List) return;
    for (final target in value.take(64)) {
      if (target is Map &&
          target['resource'] is String &&
          target['pointer'] is String) {
        trail.add(Map<String, dynamic>.from(target));
      }
    }
  }

  void reconcileNavigation() {
    final c = widget.controller;
    if (semanticRevision != c.semanticViewRevision) {
      final states = c.layoutState['nativeReference'];
      final saved = states is Map ? states[stateKey] : null;
      if (saved is Map) {
        detail = saved['detail'] is Map
            ? Map<String, dynamic>.from(saved['detail'])
            : null;
        restoreTrail(saved['trail']);
      }
      semanticRevision = c.semanticViewRevision;
    }
    final target = c.consumeReferenceNavigation();
    if (target != null) {
      if (detail != null) trail.add(detail!);
      if (trail.length > 64) trail.removeAt(0);
      detail = target;
      remember();
    }
  }

  void restoreScroll() {
    if (restoreOffset == null || restoringScroll) return;
    restoringScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      restoringScroll = false;
      if (!current || !scroll.hasClients) return;
      final offset = restoreOffset!;
      restoreOffset = null;
      scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
    });
  }

  void remember() {
    final c = widget.controller;
    if (!restored ||
        c.disposed ||
        !identical(c.project, owner) ||
        semanticRevision != c.semanticViewRevision) {
      return;
    }
    if (scroll.hasClients) lastOffset = scroll.offset;
    final stored = c.layoutState['nativeReference'];
    final states = <String, dynamic>{
      if (stored is Map)
        for (final entry in stored.entries)
          if (entry.key is String) entry.key as String: entry.value,
    }..remove(stateKey);
    states[stateKey] = {
      'query': query,
      'scroll': lastOffset,
      'detail': detail,
      'trail': List.of(trail),
    };
    while (states.length > 128) {
      states.remove(states.keys.first);
    }
    c.layoutState = {...c.layoutState, 'nativeReference': states};
  }

  @override
  void dispose() {
    remember();
    scroll.dispose();
    search.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _renderedProjection;
  WorkspaceController? _renderedController;
  ThemeData? _renderedTheme;
  Locale? _renderedLocale;
  String? _renderedQuery;
  Widget? _content;
  void open(Map<String, dynamic> target) {
    if (!current) return;
    if (detail != null) trail.add(detail!);
    if (trail.length > 64) trail.removeAt(0);
    setState(() => detail = Map<String, dynamic>.from(target));
    remember();
  }

  Widget text(String value, {TextStyle? style, Map<String, dynamic>? source}) {
    const maximum = 16384;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (source != null)
          OwnedReferenceMarkdownText(
            controller: widget.controller,
            root: root!,
            resource: source['resource'] as String? ?? root!,
            pointer: source['pointer'] as String? ?? '',
            text: value,
            base: referenceMarkdownBase(source),
          )
        else
          SelectableText(
            value.length <= maximum
                ? value
                : value.substring(
                    0,
                    value.codeUnitAt(maximum - 1) >= 0xd800 &&
                            value.codeUnitAt(maximum - 1) <= 0xdbff
                        ? maximum - 1
                        : maximum,
                  ),
            style: style,
          ),
        if (value.length > maximum)
          BusyApiActionRow(
            title: context.l10n.previewTextLimited,
            onTap: source == null ? null : () => widget.reveal(source),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, l = context.l10n, p = c.projection;
    if (p == null) return Center(child: Text(c.error ?? l.checking));
    final info = p['info']['value'];
    if (info is! Map) {
      return BusyApiStatusBox(
        message: l.outdated,
        kind: BusyApiStatusKind.warning,
      );
    }
    restore();
    reconcileNavigation();
    if (detail case final target?) {
      return ColoredBox(
        color: BusyApiSurfaceColors.of(context).view,
        child: Column(
          children: [
            BusyApiActionRow(
              title: l.navigationBack,
              onTap: () {
                if (!current) return;
                setState(() {
                  detail = trail.isEmpty ? null : trail.removeLast();
                });
                if (detail == null) restoreOffset = lastOffset;
                remember();
              },
            ),
            Expanded(
              child: ReferenceObjectView(
                key: ValueKey((
                  owner,
                  root,
                  target['resource'],
                  target['pointer'],
                  target['data'],
                  target['occurrence'],
                )),
                controller: c,
                target: target,
                reveal: widget.reveal,
                open: open,
                direction: target['direction'] as String?,
              ),
            ),
          ],
        ),
      );
    }
    restoreScroll();
    final theme = Theme.of(context), locale = Localizations.localeOf(context);
    if (_content != null &&
        identical(p, _renderedProjection) &&
        identical(c, _renderedController) &&
        theme == _renderedTheme &&
        locale == _renderedLocale &&
        query == _renderedQuery) {
      return _content!;
    }
    _renderedProjection = p;
    _renderedController = c;
    _renderedTheme = theme;
    _renderedLocale = locale;
    _renderedQuery = query;
    final needle = query.toLowerCase();
    bool contains(Object? value) =>
        value is String && value.toLowerCase().contains(needle);
    final ops = (p['operations'] as List).where((o) {
      if (needle.isEmpty) return true;
      final value = o['value'];
      return contains(o['method']) ||
          contains(o['path']) ||
          value is Map &&
              (contains(value['operationId']) ||
                  contains(value['summary']) ||
                  value['tags'] is List &&
                      (value['tags'] as List).any(contains));
    }).toList();
    return _content = ColoredBox(
      color: BusyApiSurfaceColors.of(context).view,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(BusyApiSpacing.md),
            child: BusyApiSearchField(
              controller: search,
              hintText: l.search,
              onChanged: (s) {
                if (!current) return;
                setState(() => query = s);
                remember();
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.all(BusyApiSpacing.xl),
              itemCount: ops.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info['title']?.toString() ?? '',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text('${info['version']} · OpenAPI ${p['openapi']}'),
                      ListenableBuilder(
                        listenable: c,
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (c.checking) Text(l.checking),
                            if (c.outdated) Text(l.outdated),
                            if (!c.outdated &&
                                c.analysis?['status'] == 'incomplete')
                              Text(l.incomplete),
                            if (c.error != null) Text(c.error!),
                          ],
                        ),
                      ),
                      text(
                        info['description']?.toString() ?? '',
                        source: Map<String, dynamic>.from(p['info']),
                      ),
                      BusyApiActionRow(
                        title: l.referenceReadOverview,
                        onTap: () => open({'resource': root!, 'pointer': ''}),
                      ),
                    ],
                  );
                }
                final op = Map<String, dynamic>.from(ops[index - 1]);
                final value = op['value'];
                if (value is! Map) {
                  return BusyApiActionRow(
                    title: '${op['method']} ${op['path']}',
                    subtitle: l.outdated,
                    onTap: () => widget.reveal(op),
                  );
                }
                return BusyApiDisclosure(
                  key: ValueKey(
                    '${op['root']}/${op['resource']}/${op['pointer']}/${op['occurrence']}',
                  ),
                  initiallyExpanded:
                      ops.length == 1 ||
                      c.expandedReferences.contains(op['occurrence']),
                  onExpansionChanged: (expanded) {
                    if (!current) return;
                    final id = op['occurrence'] as String;
                    if (expanded) {
                      c.expandedReferences.add(id);
                    } else {
                      c.expandedReferences.remove(id);
                    }
                    setState(() => _content = null);
                  },
                  title: Text('${httpOperationMethod(op)} ${op['path']}'),
                  subtitle: Text(value['summary']?.toString() ?? ''),
                  children: [
                    BusyApiActionRow(
                      title: l.tryOperation,
                      leading: const Icon(BusyApiGlyphs.play),
                      onTap: () => widget.tryOperation?.call(op),
                    ),
                    if (op['syntaxSafe'] != true || op['outdated'] == true)
                      Text(l.outdated),
                    if (ops.length == 1 ||
                        c.expandedReferences.contains(op['occurrence']))
                      ReferenceObjectView(
                        key: ValueKey((
                          owner,
                          root,
                          op['resource'],
                          op['pointer'],
                          op['occurrence'],
                        )),
                        controller: c,
                        target: op,
                        reveal: widget.reveal,
                        open: open,
                        scrollable: false,
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
