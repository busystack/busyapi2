import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:busyapi_core/busyapi_core.dart' show httpOperationMethod;

import '../app/busyapi_design.dart';
import '../app/contract_labels.dart';
import '../app/localization.dart';
import '../app/review_viewport.dart';
import '../workspace/workspace_controller.dart';
import 'owned_reference_markdown.dart';

/// Focused read-only documentation in the existing Reference pane. Definitions,
/// compositions and data open deliberately instead of expanding recursive maps.
class ReferenceObjectView extends StatefulWidget {
  const ReferenceObjectView({
    super.key,
    required this.controller,
    required this.target,
    required this.reveal,
    required this.open,
    this.scrollable = true,
    this.direction,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> target;
  final void Function(Map<String, dynamic>) reveal, open;
  final bool scrollable;
  final String? direction;
  @override
  State<ReferenceObjectView> createState() => _ReferenceObjectViewState();
}

class _ReferenceObjectViewState extends State<ReferenceObjectView> {
  late final project = widget.controller.project!;
  late final root = widget.controller.root!;
  late final resource = widget.target['resource'] as String;
  late final pointer = widget.target['pointer'] as String;
  late final ScrollController scroll;
  Future<Map<String, dynamic>>? request;
  Object? identity;
  int offset = 0, textOffset = 0, parameterOffset = 0;
  int contextOffset = 0;
  String? occurrence;
  bool definitionOnly = true;
  double lastScroll = 0;
  bool restoring = false;
  double? restoreOffset;
  int epoch = 0;
  late int semanticRevision = widget.controller.semanticViewRevision;
  String get stateKey => jsonEncode([
    root,
    resource,
    pointer,
    widget.target['data'] == true,
    widget.target['occurrence'],
  ]);
  bool get current =>
      mounted &&
      !widget.controller.disposed &&
      identical(widget.controller.project, project) &&
      widget.controller.root == root;
  @override
  void initState() {
    super.initState();
    final states = widget.controller.layoutState['referenceObjects'];
    final candidate = states is Map
        ? states[stateKey] ??
              states[jsonEncode([
                root,
                resource,
                pointer,
                widget.target['data'] == true,
              ])]
        : null;
    final saved = candidate is Map ? candidate : const {};
    if (saved['offset'] is int) {
      offset = (saved['offset'] as int).clamp(0, 400000);
    }
    if (saved['textOffset'] is int) {
      textOffset = (saved['textOffset'] as int).clamp(0, 64000000);
    }
    if (saved['parameterOffset'] is int) {
      parameterOffset = (saved['parameterOffset'] as int).clamp(0, 400000);
    }
    if (saved['contextOffset'] is int) {
      contextOffset = (saved['contextOffset'] as int).clamp(0, 40000);
    }
    final targetOccurrence = widget.target['occurrence'];
    if (targetOccurrence is String &&
        targetOccurrence.startsWith('$root#/') &&
        (widget.target['method'] is String ||
            widget.target['kind'] == 'operation')) {
      occurrence = targetOccurrence;
      definitionOnly = false;
    }
    // The captured navigation target owns context selection. Older physical-
    // definition state may restore its reading offset, never retarget a new
    // explicit occurrence (or an explicit authored-definition navigation).
    final savedScroll = saved['scroll'];
    if (savedScroll is num && savedScroll.isFinite) {
      lastScroll = savedScroll.toDouble().clamp(0, 10000000);
    }
    restoreOffset = lastScroll;
    scroll = ScrollController()..addListener(remember);
    load();
  }

  void remember() {
    final c = widget.controller;
    if (c.disposed ||
        !identical(c.project, project) ||
        semanticRevision != c.semanticViewRevision) {
      return;
    }
    if (scroll.hasClients) lastScroll = scroll.offset;
    final stored = c.layoutState['referenceObjects'];
    final states = <String, dynamic>{
      if (stored is Map)
        for (final entry in stored.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: entry.value,
    }..remove(stateKey);
    states[stateKey] = {
      'offset': offset,
      'textOffset': textOffset,
      'parameterOffset': parameterOffset,
      'contextOffset': contextOffset,
      'occurrence': occurrence,
      'definitionOnly': definitionOnly,
      'scroll': lastScroll,
    };
    while (states.length > 64) {
      states.remove(states.keys.first);
    }
    c.layoutState = {...c.layoutState, 'referenceObjects': states};
  }

  void restoreScroll() {
    if (!widget.scrollable || restoreOffset == null || restoring) return;
    restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      restoring = false;
      if (!current || !scroll.hasClients) return;
      final value = restoreOffset!;
      restoreOffset = null;
      scroll.jumpTo(value.clamp(0, scroll.position.maxScrollExtent));
    });
  }

  void load() {
    final c = widget.controller;
    if (c.checking || !current) return;
    identity = (
      c.analysis?['contextSnapshot'],
      c.store?.buffers[resource]?.generation,
    );
    final captured = ++epoch;
    request = project
        .referencePage(
          root,
          resource,
          pointer,
          offset: offset,
          textOffset: textOffset,
          parameterOffset: parameterOffset,
          contextOffset: contextOffset,
          occurrence: occurrence,
          definitionOnly: definitionOnly,
          data: widget.target['data'] == true,
          onResourceRefreshed: (resource) =>
              c.resourceRefreshed(project, resource),
        )
        .then((page) {
          if (current && captured == epoch) {
            offset = page['offset'] as int;
            textOffset = page['textOffset'] as int? ?? 0;
            contextOffset = page['contextOffset'] as int? ?? 0;
            remember();
          }
          return page;
        });
  }

  @override
  void didUpdateWidget(ReferenceObjectView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final c = widget.controller;
    // Relocated pages have a different widget key. Only an unchanged physical
    // occurrence may resume writing its own state after reconciliation.
    semanticRevision = c.semanticViewRevision;
    final next = (
      c.analysis?['contextSnapshot'],
      c.store?.buffers[resource]?.generation,
    );
    if (next != identity && !c.checking) load();
  }

  @override
  void dispose() {
    epoch++;
    remember();
    scroll.dispose();
    super.dispose();
  }

  void open(Map target, {String? direction}) {
    if (current) {
      widget.open({
        ...Map<String, dynamic>.from(target),
        'direction': direction ?? widget.direction,
      });
    }
  }

  Widget link(
    String title,
    Map target, {
    String? subtitle,
    String? direction,
  }) => BusyApiActionRow(
    title: title,
    subtitle: subtitle,
    onTap: () => open(target, direction: direction),
  );
  Widget plain(String text) => SelectableText(
    text,
    style: TextStyle(
      fontFamily: BusyApiTypography.monoFontFamily,
      fontSize: Theme.of(context).textTheme.bodyMedium?.fontSize,
    ),
  );
  Widget description(String text, Map source, {bool complete = true}) =>
      OwnedReferenceMarkdownText(
        controller: widget.controller,
        root: root,
        resource: source['resource'] as String? ?? resource,
        pointer: source['pointer'] as String? ?? pointer,
        key: ValueKey((source['resource'], source['pointer'], 'description')),
        text: text,
        base: Uri.tryParse(source['resource'] as String? ?? resource),
        parseMarkup: complete,
      );
  Widget contextChoices(Map page, {required bool enabled}) {
    final l = context.l10n,
        values = <String, Map>{
          for (final value in (page['contexts'] as List).whereType<Map>())
            value['occurrence'] as String: value,
          if (page['selectedContext'] is Map)
            page['selectedContext']['occurrence'] as String:
                page['selectedContext'] as Map,
        };
    final selected = page['occurrence'] as String? ?? '';
    return BusyApiGroupedList(
      children: [
        BusyApiComboRow<String>(
          title: l.pathContext,
          enabled: enabled,
          values: ['', ...values.keys],
          selected: selected,
          labelFor: (value) {
            if (value.isEmpty) return l.referenceAuthoredDefinition;
            final item = values[value]!;
            return contractIdentityLabel(
              '${httpOperationMethod(item)} ${item['path']}',
            );
          },
          onSelected: (value) {
            if (value == selected) return;
            final item = values[value];
            widget.open({
              'root': root,
              'resource': resource,
              'pointer': pointer,
              'generation': page['generation'],
              'range': page['range'],
              'kind': 'operation',
              'data': false,
              if (item != null) ...{
                'occurrence': value,
                'path': item['path'],
                'method': item['method'],
                'role': item['role'],
              },
            });
          },
        ),
        if (page['selectedContext'] is Map)
          link(
            l.pathContext,
            page['selectedContext']['pathItem'] as Map,
            subtitle: l.inherited,
          ),
        if ((page['contextCount'] as int) > 50)
          Wrap(
            spacing: BusyApiSpacing.sm,
            children: [
              Text(
                l.searchPage(
                  (page['contextOffset'] as int) ~/ 50 + 1,
                  ((page['contextCount'] as int) + 49) ~/ 50,
                ),
              ),
              BusyApiPushButton.standard(
                onPressed: (page['contextOffset'] as int) == 0
                    ? null
                    : () => setState(() {
                        contextOffset = (page['contextOffset'] as int) - 50;
                        load();
                      }),
                child: Text(l.searchPreviousPage),
              ),
              BusyApiPushButton.standard(
                onPressed:
                    (page['contextOffset'] as int) + 50 >=
                        (page['contextCount'] as int)
                    ? null
                    : () => setState(() {
                        contextOffset = (page['contextOffset'] as int) + 50;
                        load();
                      }),
                child: Text(l.searchNextPage),
              ),
            ],
          ),
      ],
    );
  }

  Widget parameterList(Map field) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (field['complete'] == false || field['invalid'] == true)
        BusyApiStatusBox(
          message: context.l10n.parameterProjectionIncomplete,
          kind: BusyApiStatusKind.warning,
        ),
      for (final parameter in (field['entries'] as List).whereType<Map>()) ...[
        link(
          parameter['name'] as String? ?? context.l10n.parameter,
          parameter['source'] as Map,
          subtitle:
              '${parameter['location'] ?? ''} · ${parameter['inherited'] == true ? context.l10n.inherited : context.l10n.authoredValue}',
        ),
        if (parameter['definition'] is Map &&
            (parameter['definition']['resource'] !=
                    parameter['source']['resource'] ||
                parameter['definition']['pointer'] !=
                    parameter['source']['pointer']))
          link(
            context.l10n.referenceReadDefinition,
            parameter['definition'] as Map,
            subtitle: context.l10n.sharedDefinition,
          ),
      ],
      if ((field['count'] as int) > 50)
        Wrap(
          spacing: BusyApiSpacing.sm,
          children: [
            Text(
              context.l10n.searchPage(
                (field['offset'] as int) ~/ 50 + 1,
                ((field['count'] as int) + 49) ~/ 50,
              ),
            ),
            BusyApiPushButton.standard(
              onPressed: (field['offset'] as int) == 0
                  ? null
                  : () => setState(() {
                      parameterOffset = (field['offset'] as int) - 50;
                      load();
                    }),
              child: Text(context.l10n.searchPreviousPage),
            ),
            BusyApiPushButton.standard(
              onPressed:
                  (field['offset'] as int) + 50 >= (field['count'] as int)
                  ? null
                  : () => setState(() {
                      parameterOffset = (field['offset'] as int) + 50;
                      load();
                    }),
              child: Text(context.l10n.searchNextPage),
            ),
          ],
        ),
    ],
  );
  Widget dynamicTargets(Map reference) {
    final targets = (reference['dynamic']['candidates'] as List)
        .whereType<Map>()
        .toList();
    return BusyApiReviewViewport(
      shrinkWrap: true,
      child: ListView.builder(
        primary: false,
        shrinkWrap: true,
        itemCount: targets.length,
        itemBuilder: (_, index) => link(
          context.l10n.sourceGoToDefinition,
          targets[index],
          subtitle: targets[index]['pointer'] as String,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: request,
      builder: (context, result) {
        final l = context.l10n;
        if (!result.hasData) {
          return Padding(
            padding: const EdgeInsets.all(BusyApiSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.hasError ? l.referenceCurrentUnavailable : l.checking,
                ),
                BusyApiActionRow(
                  title: l.sourceLink,
                  onTap: () {
                    if (current) widget.reveal(widget.target);
                  },
                ),
              ],
            ),
          );
        }
        final page = result.data!;
        final kind = page['kind'];
        final rows = <Widget>[
          Text(
            l.objectOwner(
              project.roots
                      .where((entry) => entry.id == root)
                      .firstOrNull
                      ?.name ??
                  root,
              Uri.parse(resource).pathSegments.lastOrNull ?? resource,
              pointer,
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (widget.direction == 'request') Text(l.referenceRequestDirection),
          if (widget.direction == 'response')
            Text(l.referenceResponseDirection),
          if (result.connectionState == ConnectionState.waiting ||
              widget.controller.checking)
            Text(l.checking),
          if (result.hasError ||
              widget.controller.outdated ||
              page['syntaxSafe'] != true)
            Text(l.outdated),
          if (page['complete'] != true) Text(l.incomplete),
          if (page['kind'] == 'operation' &&
              (page['contextCount'] as int? ?? 0) == 0)
            Text(l.referenceDefinitionContext),
          if (page['contextSelectionRequired'] == true)
            BusyApiStatusBox(
              message: l.referenceContextRequired,
              kind: BusyApiStatusKind.information,
            ),
          if ((page['contextCount'] as int? ?? 0) > 0)
            contextChoices(
              page,
              enabled:
                  current &&
                  !widget.controller.checking &&
                  result.connectionState != ConnectionState.waiting &&
                  !result.hasError,
            ),
          if (page['interpretation'] == 'reference-object')
            Text(l.referenceObjectMeaning),
          if (page['interpretation'] == 'schema-applicators')
            Text(l.referenceSchemaMeaning),
          if (page['interpretation'] == 'path-item' &&
              (page['references'] as List).isNotEmpty)
            Text(l.referencePathMeaning),
          if (page['interpretation'] == 'data') Text(l.referenceDataMeaning),
          for (final reference
              in (page['references'] as List).whereType<Map>()) ...[
            Text(reference['value'] as String),
            if (reference['target'] is Map)
              link(
                l.referenceReadDefinition,
                reference['target'] as Map,
                subtitle: reference['dynamic'] is Map
                    ? l.sourceDynamicDefinition
                    : l.referenceOccurrence,
              ),
            if (reference['target'] is! Map)
              Text(
                l.sourceDefinitionUnavailable(
                  reference['resolution'].toString(),
                ),
              ),
            if (reference['dynamic'] is Map) dynamicTargets(reference),
          ],
          if (page['boolean'] is bool)
            Text('${l.booleanSchema}: ${page['boolean']}'),
          if (kind == 'security-array')
            Text(
              (page['count'] as int) == 0
                  ? pointer == '/security'
                        ? l.publicApiSecurity
                        : l.explicitNoSecurity
                  : l.securityAlternatives,
            ),
          if (kind == 'security-requirement')
            Text(
              (page['count'] as int) == 0
                  ? l.anonymousAlternative
                  : l.combinedSecuritySchemes,
            ),
          if (page['text'] is String) ...[
            page['richText'] == true
                ? description(
                    page['text'] as String,
                    page,
                    complete:
                        page['textOffset'] == 0 &&
                        page['textEnd'] == page['textLength'],
                  )
                : plain(page['text'] as String),
            if (page['textLength'] != page['textEnd'] ||
                (page['textOffset'] as int) != 0) ...[
              Text(
                l.referenceTextRange(
                  (page['textOffset'] as int) + 1,
                  page['textEnd'] as int,
                  page['textLength'] as int,
                ),
              ),
              Wrap(
                spacing: BusyApiSpacing.sm,
                children: [
                  BusyApiPushButton.standard(
                    onPressed: textOffset == 0
                        ? null
                        : () => setState(() {
                            textOffset = (textOffset - 16384).clamp(
                              0,
                              64000000,
                            );
                            load();
                          }),
                    child: Text(l.searchPreviousPage),
                  ),
                  BusyApiPushButton.standard(
                    onPressed: page['textEnd'] == page['textLength']
                        ? null
                        : () => setState(() {
                            textOffset = page['textEnd'] as int;
                            load();
                          }),
                    child: Text(l.searchNextPage),
                  ),
                ],
              ),
            ],
          ],
          if ((page['effective'] as List).isNotEmpty)
            BusyApiGroupedList(
              title: l.referenceEffective,
              children: [
                for (final field
                    in (page['effective'] as List).whereType<Map>())
                  if (field['ignored'] == true)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        BusyApiStatusBox(
                          message: l.requestBodyIgnored(
                            field['method'] as String,
                          ),
                        ),
                        link(
                          contractFieldLabel(context, field['name'] as String),
                          field['source'] as Map,
                        ),
                      ],
                    )
                  else if (field['complete'] == false &&
                      field['name'] != 'parameters')
                    BusyApiStatusBox(
                      message: l.referenceEffectiveIncomplete,
                      kind: BusyApiStatusKind.warning,
                    )
                  else if (field['source'] is Map)
                    link(
                      contractFieldLabel(context, field['name'] as String),
                      field['source'] as Map,
                      subtitle: field['inherited'] == true
                          ? l.inherited
                          : l.authoredValue,
                    )
                  else if (field['name'] == 'servers')
                    Text(l.referenceDefaultServer)
                  else if (field['name'] == 'security')
                    Text(l.referenceUnspecifiedSecurity)
                  else if (field['entries'] is List)
                    parameterList(field),
              ],
            ),
          for (final entry in (page['entries'] as List).whereType<Map>()) ...[
            if (entry['text'] is String)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: BusyApiSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contractFieldLabel(context, entry['name'] as String),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    entry['richText'] == true
                        ? description(
                            entry['text'] as String,
                            entry,
                            complete: entry['textEnd'] == entry['textLength'],
                          )
                        : plain(entry['text'] as String),
                    if (entry['textLength'] != entry['textEnd'])
                      link(l.referenceReadObject, entry),
                  ],
                ),
              )
            else
              link(
                contractFieldLabel(context, entry['name'] as String),
                entry,
                subtitle: entry['required'] == true
                    ? l.required
                    : l.authoredEntries(entry['count'] as int),
                direction: kind == 'operation' && entry['name'] == 'requestBody'
                    ? 'request'
                    : kind == 'operation' && entry['name'] == 'responses'
                    ? 'response'
                    : null,
              ),
          ],
          for (final preview in (page['previews'] as List).whereType<Map>())
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: (preview['depth'] as int) * BusyApiSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  link(
                    switch (preview['label']) {
                      'response' => '${l.response} ${preview['name']}',
                      'request-body' => l.requestBody,
                      'schema' =>
                        preview['name'] == 'schema'
                            ? l.schema
                            : contractFieldLabel(
                                context,
                                preview['name'] as String,
                              ),
                      'example' =>
                        preview['name'] == 'example'
                            ? l.example
                            : '${l.example} · ${preview['name']}',
                      _ => contractFieldLabel(
                        context,
                        preview['name'] as String,
                      ),
                    },
                    preview['source'] as Map,
                    direction: preview['direction'] as String,
                  ),
                  if (preview['text'] is String &&
                      (preview['text'] as String).isNotEmpty)
                    preview['richText'] == true
                        ? description(
                            preview['text'] as String,
                            preview['source'] as Map,
                            complete: preview['limited'] != true,
                          )
                        : plain(preview['text'] as String),
                  if (preview['limited'] == true)
                    Text(l.referencePreviewLimited),
                ],
              ),
            ),
          if (page['previewsLimited'] == true) Text(l.referencePreviewLimited),
          for (final field in (page['defaults'] as List).whereType<Map>())
            Text(
              '${contractFieldLabel(context, field['name'] as String)} · ${l.effectiveDefault(jsonEncode(field['value']))}',
            ),
          if ((page['count'] as int) > 50)
            Wrap(
              spacing: BusyApiSpacing.sm,
              children: [
                Text(
                  l.searchPage(
                    offset ~/ 50 + 1,
                    ((page['count'] as int) + 49) ~/ 50,
                  ),
                ),
                BusyApiPushButton.standard(
                  onPressed: offset == 0
                      ? null
                      : () => setState(() {
                          offset -= 50;
                          load();
                        }),
                  child: Text(l.searchPreviousPage),
                ),
                BusyApiPushButton.standard(
                  onPressed: offset + 50 >= (page['count'] as int)
                      ? null
                      : () => setState(() {
                          offset += 50;
                          load();
                        }),
                  child: Text(l.searchNextPage),
                ),
              ],
            ),
          BusyApiActionRow(
            title: l.sourceLink,
            onTap: () {
              if (current) widget.reveal(page);
            },
          ),
        ];
        if (!widget.scrollable) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          );
        }
        restoreScroll();
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.all(BusyApiSpacing.xl),
          children: rows,
        );
      },
    );
  }
}
