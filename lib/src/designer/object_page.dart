part of 'designer.dart';

/// Focused, lazy object surfaces over the canonical source snapshot. Reference
/// occurrences remain occurrences until Edit Definition is explicitly chosen.
class _NativeObjectPage extends StatefulWidget {
  const _NativeObjectPage({
    super.key,
    required this.designer,
    required this.root,
    required this.resource,
    required this.pointer,
  });
  final _DesignerState designer;
  final String root, resource, pointer;
  @override
  State<_NativeObjectPage> createState() => _NativeObjectPageState();
}

class _NativeObjectPageState extends State<_NativeObjectPage> {
  WorkspaceController get c => widget.designer.c;
  late final project = c.project!;
  Future<Map<String, dynamic>>? request;
  Object? identity;
  int offset = 0;
  bool typeUnionExpanded = false;
  late final ScrollController pageScroll;
  double lastScroll = 0;
  int loadEpoch = 0;
  late int semanticRevision;
  String get viewKey => '${widget.root}#${widget.resource}#${widget.pointer}';
  @override
  void initState() {
    super.initState();
    semanticRevision = c.semanticViewRevision;
    final savedPages = c.layoutState['objectPages'];
    final savedPage = savedPages is Map ? savedPages[viewKey] : null;
    final saved = savedPage is Map ? savedPage : const {};
    offset = saved['offset'] is int
        ? (saved['offset'] as int).clamp(0, 400000)
        : 0;
    typeUnionExpanded = saved['typeUnion'] == true;
    final scroll = saved['scroll'];
    if (scroll is num && scroll.isFinite) {
      lastScroll = scroll.toDouble().clamp(0, 10000000);
    }
    pageScroll = ScrollController(initialScrollOffset: lastScroll)
      ..addListener(remember);
    reload();
  }

  void remember() {
    if (c.disposed ||
        !identical(c.project, project) ||
        semanticRevision != c.semanticViewRevision) {
      return;
    }
    if (pageScroll.hasClients) lastScroll = pageScroll.offset;
    final stored = c.layoutState['objectPages'];
    final pages = <String, dynamic>{
      if (stored is Map)
        for (final entry in stored.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: entry.value,
    }..remove(viewKey);
    pages[viewKey] = {
      'offset': offset,
      'typeUnion': typeUnionExpanded,
      'scroll': lastScroll,
    };
    while (pages.length > 64) {
      pages.remove(pages.keys.first);
    }
    c.layoutState = {...c.layoutState, 'objectPages': pages};
  }

  @override
  void dispose() {
    loadEpoch++;
    remember();
    pageScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_NativeObjectPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(c.project, project) &&
        c.root == widget.root &&
        c.selectedResource == widget.resource &&
        c.selectedPointer == widget.pointer) {
      semanticRevision = c.semanticViewRevision;
    }
    final next = (
      c.analysis?['contextSnapshot'],
      c.store?.buffers[widget.resource]?.generation,
    );
    if (next != identity && !c.checking) reload();
  }

  void reload() {
    if (c.mode != 'Design' ||
        c.checking ||
        c.disposed ||
        !identical(c.project, project)) {
      return;
    }
    identity = (
      c.analysis?['contextSnapshot'],
      c.store?.buffers[widget.resource]?.generation,
    );
    final epoch = ++loadEpoch;
    request = project
        .inspectObject(
          widget.root,
          widget.resource,
          widget.pointer,
          offset: offset,
        )
        .then((result) {
          if (mounted && epoch == loadEpoch && identical(c.project, project)) {
            offset = result['offset'] as int? ?? offset;
            remember();
          }
          return result;
        });
  }

  void run(Future<void> Function() action) =>
      widget.designer.widget.run(action);
  String label(String key) => contractFieldLabel(context, key);
  String kindLabel(String kind) => switch (kind) {
    'root' => context.l10n.contractMetadata,
    'info' => context.l10n.overview,
    'server-array' => context.l10n.servers,
    'server' => context.l10n.server,
    'server-variable-map' => context.l10n.serverVariables,
    'server-variable' => context.l10n.serverVariable,
    'security' => context.l10n.securityScheme,
    'security-map' => context.l10n.securitySchemes,
    'security-array' => context.l10n.securityRequirements,
    'security-requirement' => context.l10n.securityRequirement,
    'oauth-flows' => context.l10n.oauthFlows,
    'oauth-flow' => context.l10n.oauthFlow,
    'schema' => context.l10n.schema,
    'schema-map' =>
      (widget.pointer == '/components/schemas' ||
              widget.pointer == '/definitions')
          ? context.l10n.schemas
          : context.l10n.properties,
    'parameter' => context.l10n.parameter,
    'parameter-array' || 'parameter-map' => context.l10n.parameters,
    'header' => context.l10n.header,
    'header-map' => context.l10n.headers,
    'request-body' => context.l10n.requestBody,
    'response' => context.l10n.response,
    'response-map' || 'response-component-map' => context.l10n.responses,
    'media' => context.l10n.mediaType,
    'content-map' => context.l10n.mediaTypes,
    'tag' => context.l10n.tag,
    'tag-array' => context.l10n.tags,
    'string-array' => context.l10n.textValues,
    'example' => context.l10n.example,
    'example-map' => context.l10n.examples,
    'operation' => context.l10n.operation,
    'path-item' => context.l10n.pathItem,
    'callback' => context.l10n.callback,
    'callback-map' => context.l10n.callbacks,
    'contact' => context.l10n.contact,
    'license' => context.l10n.license,
    _ => context.l10n.specificationField(kind),
  };
  Widget withReferenceSelector(
    Map<String, dynamic> item,
    String key,
    Widget input,
  ) {
    if (!const [r'$ref', r'$dynamicRef', 'operationRef'].contains(key)) {
      return input;
    }
    return Column(
      children: [
        input,
        BusyApiActionRow(
          title: context.l10n.chooseReferenceTarget,
          subtitle: context.l10n.referenceChoiceOccurrence,
          onTap: c.scopeSafe(item, referenceField: key)
              ? () => run(() async {
                  final prepared = await _prepareObjectAction(context, c, item),
                      owner = c.project;
                  if (prepared == null || owner == null || !mounted) return;
                  final plan = await showReferencePicker(
                    context,
                    c,
                    owner,
                    prepared,
                    key,
                  );
                  if (plan != null && mounted) {
                    await showRefactoringReview(context, c, owner, plan);
                  }
                })
              : null,
        ),
      ],
    );
  }

  Widget objectField(Map<String, dynamic> item, Map<String, dynamic> field) {
    final key = field['name'] as String, present = field['present'] == true;
    final title = label(key), type = field['type'];
    if (key == 'type' && item['kind'] == 'schema' && type == 'any') {
      if (present && !field.containsKey('raw')) {
        return BusyApiActionRow(
          title: title,
          subtitle: context.l10n.previewTextLimited,
          onTap: () => widget.designer.widget.reveal(
            Map<String, dynamic>.from(field['target']),
          ),
        );
      }
      final authored = field['raw'] == null
          ? null
          : jsonDecode(field['raw'] as String);
      const types = [
        'object',
        'array',
        'string',
        'number',
        'integer',
        'boolean',
        'null',
      ];
      final selected = authored is String
          ? [authored]
          : authored is List && authored.every((v) => v is String)
          ? authored.cast<String>()
          : <String>[];
      final scalar = authored is String && types.contains(authored)
          ? authored
          : present
          ? '@union'
          : '@absent';
      return Column(
        children: [
          BusyApiComboRow<String>(
            title: title,
            values: ['@absent', ...types, if (scalar == '@union') '@union'],
            selected: scalar,
            labelFor: (v) => v == '@absent'
                ? context.l10n.absentValue
                : v == '@union'
                ? context.l10n.schemaTypeUnion
                : v,
            subtitle: context.l10n.schemaTypePreservesConstraints,
            enabled: c.scopeSafe(item),
            onSelected: (v) => run(
              () => _changeSchemaTypes(
                context,
                c,
                item,
                field,
                v == '@absent' ? null : v,
              ),
            ),
          ),
          BusyApiActionRow(
            title: context.l10n.schemaTypeUnion,
            subtitle: selected.join(' | '),
            onTap: () => setState(() {
              typeUnionExpanded = !typeUnionExpanded;
              remember();
            }),
          ),
          if (typeUnionExpanded)
            for (final name in types)
              BusyApiSwitchRow(
                title: context.l10n.specificationField(name),
                value: selected.contains(name),
                enabled: c.scopeSafe(item),
                onChanged: (enabled) => run(() {
                  final changed = [
                    ...selected.where((t) => t != name),
                    if (enabled) name,
                  ];
                  return _changeSchemaTypes(
                    context,
                    c,
                    item,
                    field,
                    changed.isEmpty ? null : changed,
                  );
                }),
              ),
        ],
      );
    }
    final blocked = field['blockedBy'] as List? ?? const [];
    if (blocked.isNotEmpty || field['prohibited'] == true) {
      return BusyApiActionRow(
        title: title,
        subtitle: present
            ? context.l10n.fieldConflictAuthored(blocked.join(', '))
            : field['prohibited'] == true
            ? context.l10n.fieldUnavailable(blocked.join(', '))
            : context.l10n.fieldExclusive(blocked.join(', ')),
        onTap: present && c.scopeSafe(item)
            ? () => run(() => _editObjectValue(context, c, item, field))
            : null,
      );
    }
    if (key == 'openapi' || key == 'swagger') {
      return BusyApiActionRow(
        title: context.l10n.openapiVersion,
        subtitle: '${field['value']}',
      );
    }
    final options = field['options'] as List?;
    if (type == 'boolean' || options != null) {
      final values = [
        null,
        ...(options ?? (type == 'boolean' ? [true, false] : [])),
      ];
      final authored = present ? field['value'] : null;
      final selected = !present ? '@absent' : jsonEncode(authored);
      final choices = [
        if (field['required'] != true || !present) '@absent',
        ...values.skip(1).map(jsonEncode),
        if (present && !values.skip(1).contains(authored)) selected,
      ];
      return BusyApiComboRow<String>(
        title: title,
        values: choices,
        selected: selected,
        errorText: present && options != null && !options.contains(authored)
            ? context.l10n.fieldValueInvalid
            : null,
        subtitle: present
            ? options != null && !options.contains(authored)
                  ? context.l10n.fieldValueInvalid
                  : context.l10n.authoredValue
            : field['required'] == true
            ? context.l10n.requiredFieldAbsent
            : field.containsKey('effectiveDefault')
            ? context.l10n.effectiveDefault(
                jsonEncode(field['effectiveDefault']),
              )
            : context.l10n.absentValue,
        labelFor: (v) => v == '@absent'
            ? context.l10n.absentValue
            : jsonDecode(v) is String
            ? jsonDecode(v) as String
            : v,
        enabled: c.scopeSafe(item, authoredField: key),
        onSelected: (v) {
          if (v == selected) return;
          run(() async {
            final prepared = await _prepareObjectAction(context, c, item);
            if (prepared == null || !context.mounted) return;
            await c.mutate(prepared, [
              v == '@absent'
                  ? {
                      'kind': 'remove',
                      'pointer': '${prepared['pointer']}/${pointerEscape(key)}',
                    }
                  : {
                      'kind': 'setData',
                      'pointer': '${prepared['pointer']}/${pointerEscape(key)}',
                      'raw': v,
                    },
            ], authoredField: key);
          });
        },
      );
    }
    if (type == 'string' && (!present || field['value'] is String)) {
      final input = widget.designer.field(
        item,
        key,
        title,
        multiline: key == 'description',
      );
      return withReferenceSelector(item, key, input);
    }
    final target = field['target'] as Map?;
    if (target != null && target['kind'] != 'data' ||
        !present && field['childKind'] != null) {
      return BusyApiActionRow(
        title: title,
        subtitle: present
            ? context.l10n.authoredEntries(field['count'] as int? ?? 0)
            : context.l10n.absentValue,
        onTap: c.scopeSafe(item)
            ? () => run(() => _openObjectChild(context, c, item, field))
            : null,
      );
    }
    return withReferenceSelector(
      item,
      key,
      BusyApiActionRow(
        title: title,
        subtitle: present
            ? context.l10n.authoredValue
            : context.l10n.absentValue,
        onTap: c.scopeSafe(item)
            ? () => run(() => _editObjectValue(context, c, item, field))
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: request,
    builder: (context, state) {
      final l = context.l10n, item = state.data;
      if (item == null) {
        return BusyApiGroupedList(
          description: state.hasError ? l.objectPageUnavailable : l.checking,
          children: [
            if (state.hasError)
              BusyApiActionRow(
                title: l.retryObjectPage,
                onTap: () => setState(reload),
              ),
          ],
        );
      }
      if (item['absent'] == true) {
        final parent = Map<String, dynamic>.from(item['parent']);
        return BusyApiGroupedList(
          title: label(item['field']['name'] as String),
          description: l.absentValue,
          children: [
            BusyApiActionRow(
              title: l.addObjectEntry,
              onTap: c.scopeSafe(parent)
                  ? () => run(
                      () => _openObjectChild(
                        context,
                        c,
                        parent,
                        Map<String, dynamic>.from(item['field']),
                      ),
                    )
                  : null,
            ),
          ],
        );
      }
      final kind = item['kind'] as String;
      final binding = item['securityBinding'] == null
          ? null
          : SecurityBindingInspection.fromJson(item['securityBinding']);
      final uriBindings =
          item['capabilities'] != null &&
          SpecificationCapabilities.fromJson(item['capabilities'])
              .securityRequirementUris;
      final fields = (item['fields'] as List).cast<Map<String, dynamic>>();
      final entries = (item['entries'] as List).cast<Map<String, dynamic>>();
      final schema = kind == 'schema';
      final sourceCurrent =
          c.store?.buffers[widget.resource]?.generation == item['generation'];
      final visible = fields
          .where(
            (f) =>
                !item.containsKey('boolean') &&
                (!schema ||
                    f['present'] == true ||
                    const [
                      'type',
                      'title',
                      'description',
                      r'$ref',
                      'properties',
                      'required',
                      'items',
                      'allOf',
                      'anyOf',
                      'oneOf',
                    ].contains(f['name'])),
          )
          .toList();
      final collection =
          kind.endsWith('-map') ||
          kind.endsWith('-array') ||
          kind == 'callback' && (item['references'] as List).isEmpty;
      return ColoredBox(
        color: BusyApiSurfaceColors.of(context).view,
        child: SingleChildScrollView(
          controller: pageScroll,
          key: PageStorageKey(
            '${widget.root}#${widget.resource}#${widget.pointer}',
          ),
          padding: BusyApiInsets.settingsPage,
          child: BusyApiClamp(
            scrollable: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  kindLabel(kind),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  l.objectOwner(
                    c.project!.roots
                            .where((r) => r.id == widget.root)
                            .firstOrNull
                            ?.name ??
                        widget.root,
                    Uri.parse(widget.resource).scheme == 'file'
                        ? p.relative(
                            Uri.parse(widget.resource).toFilePath(),
                            from: c.project!.access.boundary,
                          )
                        : widget.resource,
                    contractIdentityLabel(
                      widget.pointer.isEmpty ? '/' : widget.pointer,
                    ),
                  ),
                ),
                if (c.checking ||
                    !sourceCurrent ||
                    !c.scopeSafe(item) ||
                    state.connectionState != ConnectionState.done ||
                    state.hasError)
                  BusyApiStatusBox(
                    message: c.checking
                        ? l.checking
                        : !sourceCurrent ||
                              state.connectionState != ConnectionState.done ||
                              state.hasError ||
                              c.outdated
                        ? l.outdated
                        : l.objectScopeNeedsCorrection,
                    kind: BusyApiStatusKind.warning,
                  ),
                if (state.hasError)
                  BusyApiActionRow(
                    title: l.retryObjectPage,
                    onTap: () => setState(reload),
                  ),
                if (kind == 'operation' &&
                    (c.projection?['operations'] as List? ?? const [])
                        .whereType<Map<String, dynamic>>()
                        .any(c.isSelected))
                  BusyApiActionRow(
                    title: l.tryOperation,
                    leading: const Icon(BusyApiGlyphs.play),
                    onTap: () => widget.designer.widget.tryOperation?.call(
                      (c.projection!['operations'] as List)
                          .whereType<Map<String, dynamic>>()
                          .firstWhere(c.isSelected),
                    ),
                  ),
                if (kind == 'operation' && item['operationContext'] is Map)
                  BusyApiActionRow(
                    title: l.relocateOperation,
                    subtitle: l.operationDefinitionOwnership,
                    onTap: c.scopeSafe(item)
                        ? () => run(() async {
                            final prepared = await _prepareObjectAction(
                              context,
                              c,
                              item,
                            );
                            if (prepared != null && context.mounted) {
                              await moveOperation(context, c, prepared);
                            }
                          })
                        : null,
                  ),
                if (item['schemaTreeRoot'] is String)
                  AuthoredSchemaTree(
                    key: ValueKey((
                      widget.root,
                      widget.resource,
                      item['schemaTreeRoot'],
                    )),
                    controller: c,
                    resource: widget.resource,
                    pointer: item['schemaTreeRoot'] as String,
                    selectedPointer: widget.pointer,
                    snapshot: (
                      c.analysis?['contextSnapshot'],
                      item['generation'],
                    ),
                    run: run,
                  ),
                if (widget.pointer.contains('/components/') ||
                    item['sharedTarget'] == true ||
                    c.selectedOccurrence?.startsWith('definition:') == true)
                  Text(l.sharedDefinition),
                if (item['responseStatusNamePolicy'] != null)
                  BusyApiActionRow(
                    title: l.renameResponseStatus,
                    onTap: c.scopeSafe(item)
                        ? () => run(
                            () => _renameObjectMember(
                              context,
                              c,
                              item,
                              kind: _ObjectRenameKind.responseStatus,
                            ),
                          )
                        : null,
                  ),
                if (item['componentDefinition'] == true)
                  BusyApiActionRow(
                    title: l.renameComponent,
                    onTap: c.scopeSafe(item)
                        ? () => run(() => _renameObjectMember(context, c, item))
                        : null,
                  ),
                if (item['componentFamily'] is String &&
                    item['componentDefinition'] == true &&
                    !(item['references'] as List).any(
                      (ref) =>
                          ref['keyword'] == r'$ref' ||
                          ref['keyword'] == r'$dynamicRef',
                    ))
                  BusyApiActionRow(
                    title: l.moveComponentDefinition,
                    onTap: c.scopeSafe(item)
                        ? () => run(
                            () => _extractObjectComponent(
                              context,
                              c,
                              item,
                              moving: true,
                            ),
                          )
                        : null,
                  ),
                if (item['componentFamily'] is String &&
                    item['componentDefinition'] != true &&
                    !(item['references'] as List).any(
                      (ref) =>
                          ref['keyword'] == r'$ref' ||
                          ref['keyword'] == r'$dynamicRef',
                    ))
                  BusyApiActionRow(
                    title: l.extractComponent,
                    onTap: c.scopeSafe(item)
                        ? () => run(
                            () => _extractObjectComponent(context, c, item),
                          )
                        : null,
                  ),
                if (kind == 'schema' &&
                    RegExp(r'/properties/[^/]*$').hasMatch(widget.pointer))
                  BusyApiActionRow(
                    title: l.renameProperty,
                    onTap: c.scopeSafe(item)
                        ? () => run(
                            () => _renameObjectMember(
                              context,
                              c,
                              item,
                              kind: _ObjectRenameKind.property,
                            ),
                          )
                        : null,
                  ),
                if (item['removable'] == true)
                  BusyApiActionRow(
                    title: l.deleteAuthoredObject,
                    destructive: true,
                    onTap: c.scopeSafe(item)
                        ? () =>
                              run(() => _reviewObjectDeletion(context, c, item))
                        : null,
                  ),
                if (kind == 'security-array') ...[
                  Text(l.securityAlternatives),
                  if (item['count'] == 0)
                    Text(
                      widget.pointer == '/security'
                          ? l.publicApiSecurity
                          : l.explicitNoSecurity,
                    ),
                ],
                if (kind == 'security-requirement') ...[
                  Text(l.combinedSecuritySchemes),
                  if (item['count'] == 0) Text(l.anonymousAlternative),
                  BusyApiGroupedList(
                    children: [
                      for (final entry in entries)
                        BusyApiActionRow(
                          title: (entry['name'] as String).isEmpty
                              ? l.emptyObjectName
                              : entry['name'] as String,
                          subtitle: _securityValuesLabel(context, entry),
                          onTap: () => run(() => c.selectObject(entry)),
                        ),
                      BusyApiActionRow(
                        title: l.addCombinedScheme,
                        onTap: c.scopeSafe(item)
                            ? () => run(
                                () => _addSecurityScheme(
                                  context,
                                  c,
                                  item,
                                  alternative: false,
                                ),
                              )
                            : null,
                      ),
                      if (uriBindings)
                        BusyApiActionRow(
                          title: l.addSecuritySchemeByUri,
                          onTap: c.scopeSafe(item)
                              ? () => run(
                                  () => _chooseSecurityBinding(
                                    context,
                                    c,
                                    item,
                                    bindingForm: SecurityBindingForm.uri,
                                  ),
                                )
                              : null,
                        ),
                    ],
                  ),
                ],
                if (binding != null) ...[
                  if (binding.kind == SecurityRequirementValueKind.empty)
                    Text(l.securityScopesEmpty),
                  if (binding.kind == SecurityRequirementValueKind.unresolved)
                    Text(l.securityBindingUnresolved),
                  BusyApiActionRow(
                    title: l.changeSecurityBinding,
                    onTap: c.scopeSafe(item)
                        ? () => run(
                            () => _chooseSecurityBinding(context, c, item),
                          )
                        : null,
                  ),
                ],
                for (final ref in item['references'] as List)
                  BusyApiGroupedList(
                    title: l.referenceOccurrence,
                    description: contractIdentityLabel('${ref['value']}'),
                    children: [
                      if (ref['dynamic'] != null)
                        Text(l.sourceDynamicDefinition),
                      BusyApiActionRow(
                        title: l.editDefinition,
                        subtitle: ref['resolution'] == 'resolved'
                            ? contractIdentityLabel(
                                '${ref['targetResource']}#${ref['targetPointer']}',
                              )
                            : l.incomplete,
                        onTap: ref['target'] == null
                            ? null
                            : () => run(
                                () => c.selectObject({
                                  ...Map<String, dynamic>.from(ref['target']),
                                  'occurrence':
                                      'definition:${ref['targetResource']}#${ref['targetPointer']}',
                                }),
                              ),
                      ),
                      if (ref['keyword'] == r'$ref')
                        BusyApiActionRow(
                          title: l.inlineReference,
                          onTap:
                              c.scopeSafe(item) &&
                                  ref['resolution'] == 'resolved'
                              ? () => run(
                                  () =>
                                      _inlineObjectReference(context, c, item),
                                )
                              : null,
                        ),
                    ],
                  ),
                if (item.containsKey('boolean'))
                  BusyApiComboRow<bool>(
                    title: l.booleanSchema,
                    values: const [true, false],
                    selected: item['boolean'] as bool,
                    labelFor: (v) => '$v',
                    enabled: c.scopeSafe(item),
                    onSelected: (v) {
                      if (v == item['boolean']) return;
                      run(
                        () => c.mutate(item, [
                          {
                            'kind': 'set',
                            'pointer': item['pointer'],
                            'value': v,
                          },
                        ]),
                      );
                    },
                  ),
                if (visible.isNotEmpty)
                  BusyApiGroupedList(
                    title: schema ? l.schemaConstraints : l.objectDetails,
                    children: [
                      for (final field in visible) objectField(item, field),
                    ],
                  ),
                if (const ['media', 'parameter', 'header'].contains(kind) &&
                    fields.any(
                      (f) => f['name'] == 'example' && f['present'] == true,
                    ))
                  BusyApiActionRow(
                    title: l.suggestSchema,
                    subtitle:
                        fields.any(
                          (f) =>
                              const ['schema', 'content'].contains(f['name']) &&
                              f['present'] == true,
                        )
                        ? l.schemaSuggestionDestinationOccupied
                        : l.schemaSuggestionDoesNotAuthor,
                    onTap:
                        c.scopeSafe(item) &&
                            !fields.any(
                              (f) =>
                                  const [
                                    'schema',
                                    'content',
                                  ].contains(f['name']) &&
                                  f['present'] == true,
                            )
                        ? () =>
                              run(() => _suggestObjectSchema(context, c, item))
                        : null,
                  ),
                if (schema && !item.containsKey('boolean'))
                  BusyApiActionRow(
                    title: l.addSchemaKeyword,
                    onTap: c.scopeSafe(item)
                        ? () => run(() async {
                            final available = fields
                                .where((f) => f['present'] != true)
                                .toList();
                            if (available.isEmpty) return;
                            final selected = await editForm(
                              context,
                              l.addSchemaKeyword,
                              [
                                FormFieldSpec(
                                  'keyword',
                                  l.name,
                                  options: available
                                      .map((f) => f['name'] as String)
                                      .toList(),
                                ),
                              ],
                              {'keyword': available.first['name']},
                            );
                            if (selected == null || !context.mounted) return;
                            await _editObjectValue(
                              context,
                              c,
                              item,
                              available.singleWhere(
                                (f) => f['name'] == selected['keyword'],
                              ),
                            );
                          })
                        : null,
                  ),
                if (collection) ...[
                  BusyApiGroupedList(
                    title: l.authoredEntries(item['count'] as int),
                    children: [
                      for (final entry in entries)
                        Column(
                          children: [
                            BusyApiActionRow(
                              title: kind == 'security-array'
                                  ? l.securityAlternative(
                                      int.parse(entry['name'] as String) + 1,
                                    )
                                  : (entry['name'] as String).isEmpty
                                  ? l.emptyObjectName
                                  : entry['name'] as String,
                              subtitle:
                                  kind == 'security-array' &&
                                      entry['count'] == 0
                                  ? l.anonymousAlternative
                                  : entry.containsKey('value')
                                  ? '${entry['value']}'
                                  : l.specificationField(
                                      entry['kind'] as String,
                                    ),
                              onTap: entry['kind'] == 'data'
                                  ? const [
                                              'string-map',
                                              'discriminator-map',
                                              'string-array',
                                            ].contains(kind) &&
                                            c.scopeSafe(item)
                                        ? () => run(
                                            () => _editObjectValue(
                                              context,
                                              c,
                                              item,
                                              {
                                                ...entry,
                                                'type': 'string',
                                                'present': true,
                                                'nativeString':
                                                    entry['value'] is String,
                                                'target': entry,
                                              },
                                            ),
                                          )
                                        : null
                                  : () => run(() => c.selectObject(entry)),
                            ),
                            if (item['ownerSchema'] != null)
                              BusyApiSwitchRow(
                                title: l.required,
                                subtitle: l.localRequiredMembership,
                                value: entry['required'] == true,
                                enabled:
                                    c.scopeSafe(item) &&
                                    c.scopeSafe(item['ownerSchema']),
                                onChanged: (v) => run(
                                  () => c.mutate(item, [
                                    {
                                      'kind': 'setRequired',
                                      'pointer': item['ownerSchema']['pointer'],
                                      'name': entry['name'],
                                      'required': v,
                                    },
                                  ]),
                                ),
                              ),
                          ],
                        ),
                      BusyApiActionRow(
                        title: kind == 'security-array'
                            ? l.addSecurityAlternative
                            : l.addObjectEntry,
                        leading: const Icon(BusyApiGlyphs.add),
                        onTap:
                            c.scopeSafe(item) && (binding?.allowsValues ?? true)
                            ? () => run(
                                () => kind == 'security-array'
                                    ? _addSecurityScheme(
                                        context,
                                        c,
                                        item,
                                        alternative: true,
                                      )
                                    : _addObjectEntry(context, c, item),
                              )
                            : null,
                      ),
                      if (kind == 'security-array' && uriBindings)
                        BusyApiActionRow(
                          title: l.addSecuritySchemeByUri,
                          onTap: c.scopeSafe(item)
                              ? () => run(
                                  () => _chooseSecurityBinding(
                                    context,
                                    c,
                                    item,
                                    bindingForm: SecurityBindingForm.uri,
                                  ),
                                )
                              : null,
                        ),
                      if (kind == 'security-array')
                        BusyApiActionRow(
                          title: l.addAnonymousAlternative,
                          onTap: c.scopeSafe(item)
                              ? () => run(
                                  () => c.mutate(item, [
                                    {
                                      'kind': 'append',
                                      'pointer': item['pointer'],
                                      'value': <String, Object?>{},
                                    },
                                  ]),
                                )
                              : null,
                        ),
                    ],
                  ),
                ],
                BusyApiActionRow(
                  title: l.sourceLink,
                  leading: const Icon(BusyApiGlyphs.code),
                  onTap: () => widget.designer.widget.reveal(item),
                ),
                if (item['allowsExtensions'] == true)
                  BusyApiActionRow(
                    title: l.addExtension,
                    leading: const Icon(BusyApiGlyphs.add),
                    onTap: c.scopeSafe(item)
                        ? () => run(() => _addObjectExtension(context, c, item))
                        : null,
                  ),
                if (schema &&
                    item['customSchemaKeywords'] == true &&
                    !item.containsKey('boolean'))
                  BusyApiActionRow(
                    title: l.addCustomSchemaKeyword,
                    subtitle: l.customSchemaKeywordExplanation,
                    onTap: c.scopeSafe(item)
                        ? () => run(
                            () => _addObjectExtension(
                              context,
                              c,
                              item,
                              keyword: true,
                            ),
                          )
                        : null,
                  ),
                if (!collection &&
                    kind != 'security-requirement' &&
                    entries.any(
                      (entry) => !fields.any(
                        (field) => field['name'] == entry['name'],
                      ),
                    ))
                  BusyApiGroupedList(
                    title: l.preservedCustomContent,
                    children: [
                      for (final entry in entries.where(
                        (entry) => !fields.any(
                          (field) => field['name'] == entry['name'],
                        ),
                      ))
                        BusyApiActionRow(
                          title: (entry['name'] as String).isEmpty
                              ? l.emptyObjectName
                              : entry['name'] as String,
                          subtitle: l.customContentIsData,
                          onTap: c.scopeSafe(item)
                              ? () => run(
                                  () => _editObjectValue(context, c, item, {
                                    ...entry,
                                    'present': true,
                                    'target': entry,
                                    'type': 'any',
                                  }),
                                )
                              : null,
                        ),
                    ],
                  ),
                if ((item['count'] as int) > 50) ...[
                  Text(l.authoredEntries(item['count'] as int)),
                  BusyApiReviewPages(
                    page: offset ~/ 50,
                    pages: ((item['count'] as int) + 49) ~/ 50,
                    enabled:
                        state.connectionState == ConnectionState.done &&
                        !state.hasError &&
                        c.scopeSafe(item),
                    onChanged: (page) => setState(() {
                      offset = page * 50;
                      reload();
                      remember();
                    }),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> _changeSchemaTypes(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  Map<String, dynamic> field,
  Object? next,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  field = _refreshedObjectField(item, field);
  final raw = field['raw'] as String?;
  if (raw == null && next == null) return;
  final previous = raw == null ? null : jsonDecode(raw);
  if (raw != null && jsonEncode(previous) == jsonEncode(next)) return;
  final beforeTypes = previous is List ? previous : [previous];
  final afterTypes = next is List ? next : [next];
  final removed =
      raw != null &&
      (next == null || beforeTypes.any((type) => !afterTypes.contains(type)));
  final pointer = '${item['pointer']}/type';
  if (removed) {
    final l = context.l10n;
    await editForm(
      context,
      l.reviewSchemaType,
      [
        FormFieldSpec(
          'choice',
          l.schemaTypeImpact(raw, jsonEncode(next)),
          options: const ['apply'],
          labels: {'apply': l.apply},
        ),
      ],
      {'choice': 'apply'},
      controller: c,
      target: item,
      kind: 'object.type',
      arguments: {
        'field': {'name': 'type', 'type': 'any'},
        'next': next,
      },
      onApply: (_) => c.mutate(item, [
        next == null
            ? {'kind': 'remove', 'pointer': pointer}
            : {'kind': 'set', 'pointer': pointer, 'value': next},
      ]),
    );
  } else {
    await c.mutate(item, [
      {'kind': 'set', 'pointer': pointer, 'value': next},
    ]);
  }
}

String _securityValuesLabel(BuildContext context, Map<String, dynamic> entry) {
  final l = context.l10n, value = entry['securityBinding'];
  if (value == null) return l.securityBindingUnresolved;
  return switch (SecurityBindingInspection.fromJson(value).kind) {
    SecurityRequirementValueKind.scopes => l.securityScopes(
      entry['count'] as int,
    ),
    SecurityRequirementValueKind.roles => l.securityRoles(
      entry['count'] as int,
    ),
    SecurityRequirementValueKind.empty => l.securityScopesEmpty,
    SecurityRequirementValueKind.unresolved => l.securityBindingUnresolved,
  };
}

Future<void> _chooseSecurityBinding(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item, {
  SecurityBindingForm? bindingForm,
}) async {
  final prepared = await _prepareObjectAction(context, c, item),
      owner = c.project;
  if (prepared == null || owner == null || !context.mounted) return;
  final plan = await showReferencePicker(
    context,
    c,
    owner,
    prepared,
    'security',
    bindingForm: bindingForm,
  );
  if (plan != null &&
      context.mounted &&
      !c.disposed &&
      identical(c.project, owner)) {
    await showRefactoringReview(context, c, owner, plan);
  }
}

Future<void> _addSecurityScheme(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item, {
  required bool alternative,
}) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  final l = context.l10n;
  final schemes = (c.projection?['components'] as List? ?? [])
      .where((v) => v['group'] == 'securitySchemes')
      .where(
        (v) =>
            alternative ||
            !(item['entries'] as List).any(
              (entry) => entry['name'] == v['name'],
            ),
      )
      .cast<Map<String, dynamic>>()
      .toList();
  if (schemes.isEmpty) {
    throw CoreFailure(
      'security.schemes.absent',
      alternative ? l.defineSecuritySchemeFirst : l.noUnusedSecurityScheme,
    );
  }
  await editForm(
    context,
    alternative ? l.addSecurityAlternative : l.addCombinedScheme,
    [
      FormFieldSpec(
        'scheme',
        l.securityScheme,
        options: schemes.map((s) => s['name'] as String).toList(),
        labels: {
          for (final s in schemes)
            s['name'] as String:
                '${s['name'] == '' ? l.emptyObjectName : s['name']} · ${Uri.parse(s['resource']).pathSegments.last}',
        },
      ),
    ],
    {'scheme': schemes.first['name']},
    controller: c,
    target: item,
    kind: 'object.security',
    arguments: {'alternative': alternative},
    onApply: (value) => c.mutate(item, [
      alternative
          ? {
              'kind': 'append',
              'pointer': item['pointer'],
              'value': {value['scheme'] as String: <String>[]},
            }
          : {
              'kind': 'create',
              'pointer': '${item['pointer']}/${pointerEscape(value['scheme'])}',
              'value': <String>[],
            },
    ]),
  );
}

Future<void> _openObjectChild(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  Map<String, dynamic> field,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  field = _refreshedObjectField(item, field);
  final pointer =
      field['destinationPointer'] as String? ??
      '${item['pointer']}/${pointerEscape(field['name'] as String)}';
  if (field['present'] != true) {
    await c.mutate(item, [
      {
        'kind': 'create',
        'pointer': pointer,
        'value': field['type'] == 'array' ? <Object?>[] : <String, Object?>{},
      },
    ]);
  }
  await c.selectObject({
    ...item,
    'pointer': pointer,
    if (c.selectedOccurrence?.startsWith('definition:') == true)
      'occurrence': 'definition:${item['resource']}#$pointer',
    'range': field['target']?['range'] ?? item['range'],
  });
}

Future<void> _editObjectValue(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  Map<String, dynamic> field,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  field = _refreshedObjectField(item, field);
  final name = field['name'] as String;
  final nativeString =
      field['nativeString'] == true ||
      field['type'] == 'string' && field['dataType'] == 'string';
  final owner = c.project!, root = c.root, navigation = c.navigationGeneration;
  String? complete;
  if (field['present'] == true && !field.containsKey('raw')) {
    complete = await owner.readDataValue(
      Map<String, dynamic>.from(field['target']),
      text: nativeString,
      cancelled: () =>
          !context.mounted ||
          c.disposed ||
          !identical(c.project, owner) ||
          c.root != root ||
          c.navigationGeneration != navigation,
    );
    if (!context.mounted ||
        c.disposed ||
        !identical(c.project, owner) ||
        c.root != root ||
        c.navigationGeneration != navigation) {
      return;
    }
  }
  final raw =
      complete ??
      field['raw'] as String? ??
      (field['type'] == 'array'
          ? '[]'
          : field['type'] == 'object' || field['type'] == 'schema'
          ? '{}'
          : field['type'] == 'string'
          ? '""'
          : 'null');
  final l = context.l10n;
  await editForm(
    context,
    l.specificationField(name),
    [
      FormFieldSpec(
        'value',
        nativeString ? l.textValue : l.dataValue,
        multiline: true,
        json: !nativeString,
      ),
    ],
    {'value': nativeString && complete == null ? jsonDecode(raw) : raw},
    removable: field['present'] == true && field['required'] != true,
    unchangedIsNoop: field['present'] == true,
    controller: c,
    target: item,
    kind: 'object.value',
    arguments: {
      'field': {
        'name': name,
        'type': field['type'],
        'nativeString': nativeString,
      },
    },
    validate: nativeString
        ? null
        : (values) =>
              _dataHasType(
                values['value'] as String,
                field['type'] as String? ?? 'any',
              )
              ? null
              : l.dataTypeRequired(field['type'] as String),
    onApply: (result) => c.mutate(item, [
      result['remove'] == true
          ? {
              'kind': 'remove',
              'pointer': '${item['pointer']}/${pointerEscape(name)}',
            }
          : {
              'kind': nativeString ? 'set' : 'setData',
              'pointer': '${item['pointer']}/${pointerEscape(name)}',
              if (nativeString)
                'value': result['value']
              else
                'raw': result['value'],
            },
    ]),
  );
}

// Only inspect the JSON type; the original lexeme is passed to setData. In
// particular, neither type checking nor integer checking round-trips numbers
// through Dart's machine-sized numeric values.
bool _dataHasType(String raw, String type) {
  final text = raw.trim();
  final value = jsonDecode(text);
  switch (type) {
    case 'string':
      return value is String;
    case 'object':
      return value is Map;
    case 'array':
      return value is List;
    case 'boolean':
      return value is bool;
    case 'null':
      return value == null;
    case 'schema':
      return value is Map || value is bool;
    case 'number':
      return value is num;
    case 'integer':
      if (value is! num) return false;
      final parts = text.toLowerCase().split('e');
      final mantissa = parts[0].replaceFirst('-', '').split('.');
      final digits = mantissa.join();
      if (!digits.contains(RegExp('[1-9]'))) return true;
      final zeros =
          digits.length - digits.replaceFirst(RegExp(r'0+$'), '').length;
      final fraction = mantissa.length == 2 ? mantissa[1].length : 0;
      final exponent = parts.length == 2 ? BigInt.parse(parts[1]) : BigInt.zero;
      return exponent + BigInt.from(zeros - fraction) >= BigInt.zero;
    default:
      return true;
  }
}

Future<void> _addObjectEntry(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  final array = item['nodeKind'] == 'array', kind = item['kind'] as String;
  final textValue = kind == 'string-array';
  final namePolicy = item['memberNamePolicy'] == null
      ? null
      : MemberNamePolicy.fromJson(item['memberNamePolicy']);
  final emptyNameAllowed =
      !array && (namePolicy?.allowEmpty ?? kind == 'schema-map');
  final l = context.l10n;
  final owner = c.project, root = c.root;
  String? createdPointer;
  int? acceptedGeneration;
  final result = await editForm(
    context,
    l.addObjectEntry,
    [
      if (!array) FormFieldSpec('name', l.name),
      if (emptyNameAllowed)
        FormFieldSpec('emptyName', l.useEmptyObjectName, boolean: true),
      if (kind == 'server-array') FormFieldSpec('url', l.serverUrl),
      if (textValue) FormFieldSpec('value', l.textValue),
    ],
    {'name': '', 'url': '', 'value': '', 'emptyName': false},
    controller: c,
    target: item,
    kind: 'object.add',
    arguments: const {},
    validate: (v) {
      if (!array && (v['name'] as String).isEmpty && v['emptyName'] != true ||
          kind == 'server-array' && (v['url'] as String).isEmpty) {
        return l.objectNameRequired;
      }
      if (namePolicy != null && !array) {
        final name = v['emptyName'] == true ? '' : v['name'] as String;
        if (!namePolicy.allows(name)) {
          return name.length > namePolicy.maxLength
              ? l.memberNameTooLong
              : kind == 'response-map'
              ? _responseStatusNameFailure(context, namePolicy)
              : l.componentNameInvalid;
        }
      }
      return null;
    },
    onApply: (v) async {
      final pointer =
          '${item['pointer']}/${array ? item['count'] : pointerEscape(v['emptyName'] == true ? '' : v['name'])}';
      await c.mutate(item, [
        {
          'kind': 'create',
          'pointer': pointer,
          'value': kind == 'server-array'
              ? {'url': v['url']}
              : textValue
              ? v['value']
              : const ['string-map', 'discriminator-map'].contains(kind)
              ? ''
              : <String, Object?>{},
        },
      ]);
      createdPointer = pointer;
      acceptedGeneration = c.store!.get(item['resource']).generation;
    },
  );
  // Applying a dialog does not authorize navigation out of its captured form.
  // Its route must finish before the newly created object's page takes over.
  if (result != null &&
      createdPointer != null &&
      context.mounted &&
      !c.disposed &&
      identical(c.project, owner) &&
      c.root == root &&
      c.store!.get(item['resource']).generation == acceptedGeneration) {
    if (!textValue) await c.selectObject({...item, 'pointer': createdPointer});
  }
}

Future<void> _addObjectExtension(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item, {
  bool keyword = false,
}) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  final l = context.l10n;
  if (item['allowsExtensions'] != true || keyword && item['kind'] != 'schema') {
    throw l.extensionContextUnavailable;
  }
  await editForm(
    context,
    keyword ? l.addCustomSchemaKeyword : l.addExtension,
    [
      FormFieldSpec('name', l.name),
      FormFieldSpec('value', l.dataValue, multiline: true, json: true),
    ],
    {'name': keyword ? '' : 'x-', 'value': 'null'},
    controller: c,
    target: item,
    kind: 'object.extension',
    arguments: {'keyword': keyword},
    validate: (values) {
      final name = values['name'] as String;
      if (name.startsWith('x-oai-') || name.startsWith('x-oas-')) {
        return l.extensionNameReserved;
      }
      if (keyword) {
        if (name.isEmpty || name.length > 4096) return l.objectNameRequired;
        if ((item['fields'] as List).any((field) => field['name'] == name)) {
          return l.standardSchemaKeyword;
        }
        return null;
      }
      if (!name.startsWith('x-') || name.length > 4096) {
        return l.extensionNameInvalid;
      }
      return null;
    },
    onApply: (values) => c.mutate(item, [
      {
        'kind': 'createData',
        'pointer': '${item['pointer']}/${pointerEscape(values['name'])}',
        'raw': values['value'],
      },
    ]),
  );
}

enum _ObjectRenameKind { component, property, responseStatus }

String _responseStatusNameFailure(
  BuildContext context,
  MemberNamePolicy policy,
) => policy.allows('2XX')
    ? context.l10n.responseStatusInvalid
    : context.l10n.responseStatusCodeInvalid;

Future<void> _renameObjectMember(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item, {
  _ObjectRenameKind kind = _ObjectRenameKind.component,
}) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  item = prepared;
  final owner = c.project!, l = context.l10n;
  final namePolicy = switch (kind) {
    _ObjectRenameKind.property => null,
    _ObjectRenameKind.component => MemberNamePolicy.fromJson(
      item['componentNamePolicy'],
    ),
    _ObjectRenameKind.responseStatus => MemberNamePolicy.fromJson(
      item['responseStatusNamePolicy'],
    ),
  };
  RefactoringPlan? plan;
  final name = (item['pointer'] as String)
      .split('/')
      .last
      .replaceAll('~1', '/')
      .replaceAll('~0', '~');
  final result = await editForm(
    context,
    switch (kind) {
      _ObjectRenameKind.property => l.renameProperty,
      _ObjectRenameKind.component => l.renameComponent,
      _ObjectRenameKind.responseStatus => l.renameResponseStatus,
    },
    [
      FormFieldSpec(
        'name',
        kind == _ObjectRenameKind.responseStatus ? l.status : l.name,
      ),
    ],
    {'name': name},
    controller: c,
    target: item,
    kind: switch (kind) {
      _ObjectRenameKind.property => 'object.renameProperty',
      _ObjectRenameKind.component => 'object.rename',
      _ObjectRenameKind.responseStatus => 'object.renameResponse',
    },
    waitForDismissal: true,
    validate: (value) => namePolicy == null || namePolicy.allows(value['name'])
        ? null
        : (value['name'] as String).length > namePolicy.maxLength
        ? l.memberNameTooLong
        : kind == _ObjectRenameKind.responseStatus
        ? _responseStatusNameFailure(context, namePolicy)
        : l.componentNameInvalid,
    onApply: (value) async {
      try {
        final target = <String, dynamic>{
          'resource': item['resource'],
          'generation': item['generation'],
          'pointer': item['pointer'],
          'range': item['range'],
        };
        plan = await switch (kind) {
          _ObjectRenameKind.property => owner.planPropertyRename(
            target,
            value['name'],
          ),
          _ObjectRenameKind.component => owner.planComponentRename(
            target,
            value['name'],
          ),
          _ObjectRenameKind.responseStatus => owner.planResponseRename(
            target,
            value['name'],
          ),
        };
      } on CoreFailure catch (failure) {
        throw CoreFailure(
          failure.code,
          refactoringFailureMessage(l, failure.code),
          kind: failure.kind,
          source: failure.source,
        );
      }
    },
  );
  if (result == null ||
      plan == null ||
      !context.mounted ||
      !identical(c.project, owner)) {
    return;
  }
  await showRefactoringReview(context, c, owner, plan!);
}

Future<void> _reviewObjectDeletion(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  final owner = c.project!, root = c.root, navigation = c.navigationGeneration;
  final selection = (
    c.selectedResource,
    c.selectedPointer,
    c.selectedOccurrence,
  );
  final failureText = context.l10n.refactoringFailed;
  RefactoringPlan plan;
  try {
    plan = await owner.planObjectDeletion({
      'resource': prepared['resource'],
      'generation': prepared['generation'],
      'pointer': prepared['pointer'],
      'range': prepared['range'],
    });
  } on CoreFailure catch (failure) {
    throw failureText(failure.code);
  }
  if (!context.mounted ||
      c.disposed ||
      !identical(c.project, owner) ||
      c.root != root ||
      c.navigationGeneration != navigation ||
      selection !=
          (c.selectedResource, c.selectedPointer, c.selectedOccurrence)) {
    return;
  }
  await showRefactoringReview(context, c, owner, plan);
}

String _suggestedExtractionFilename(String name, String extension) {
  // A JSON member name need not be a filename. This is only the editable
  // destination suggestion; the semantic name is retained independently.
  final basename =
      name.isNotEmpty &&
          name != '.' &&
          name != '..' &&
          !name.contains(RegExp(r'[/\\\x00-\x1f\x7f]')) &&
          utf8.encode(name).length <= 200
      ? name
      : 'component';
  return '$basename$extension';
}

Future<void> _extractObjectComponent(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item, {
  bool moving = false,
  String? fileName,
}) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  final owner = c.project!, l = context.l10n;
  final namePolicy = MemberNamePolicy.fromJson(prepared['componentNamePolicy']);
  final failureText = _copyRefactoringFailure(context);
  final capturedRoot = c.root, navigation = c.navigationGeneration;
  final capturedSelection = (
    c.selectedResource,
    c.selectedPointer,
    c.selectedOccurrence,
  );
  bool current() =>
      context.mounted &&
      !c.disposed &&
      identical(c.project, owner) &&
      c.root == capturedRoot &&
      c.navigationGeneration == navigation &&
      capturedSelection ==
          (c.selectedResource, c.selectedPointer, c.selectedOccurrence);
  const newFileDestination = 'busyapi:new-source-file';
  final destinations = <String, String>{
    for (final id
        in (prepared['componentDestinations'] as List? ?? const [])
            .whereType<String>())
      id: p.relative(Uri.parse(id).toFilePath(), from: owner.access.boundary),
    if (prepared['componentDestination'] == true)
      prepared['resource'] as String: p.relative(
        Uri.parse(prepared['resource']).toFilePath(),
        from: owner.access.boundary,
      ),
    for (final entry in owner.roots)
      entry.id:
          '${entry.name} · ${p.relative(Uri.parse(entry.id).toFilePath(), from: owner.access.boundary)}',
    if (!moving) newFileDestination: l.createSourceFile,
  };
  final destination = destinations.containsKey(prepared['resource'])
      ? prepared['resource'] as String
      : c.root!;
  RefactoringPlan? plan;
  final formResult = fileName != null
      ? {'name': fileName, 'destination': newFileDestination}
      : await editForm(
          context,
          moving ? l.moveComponentDefinition : l.extractComponent,
          [
            FormFieldSpec('name', moving ? l.destinationComponentName : l.name),
            if (!moving && namePolicy.allowEmpty)
              FormFieldSpec('emptyName', l.useEmptyObjectName, boolean: true),
            FormFieldSpec(
              'destination',
              l.componentDestination,
              options: destinations.keys.toList(),
              labels: destinations,
            ),
          ],
          {
            'name': moving
                ? (prepared['pointer'] as String)
                      .split('/')
                      .last
                      .replaceAll('~1', '/')
                      .replaceAll('~0', '~')
                : '',
            'destination': destination,
            'emptyName': false,
          },
          controller: c,
          target: prepared,
          kind: moving ? 'object.moveDefinition' : 'object.extract',
          waitForDismissal: true,
          validate: (values) {
            final name = values['emptyName'] == true
                ? ''
                : values['name'] as String;
            if (!moving && name.isEmpty && values['emptyName'] != true) {
              return l.objectNameRequired;
            }
            return namePolicy.allows(name)
                ? null
                : name.length > namePolicy.maxLength
                ? l.memberNameTooLong
                : l.componentNameInvalid;
          },
          onApply: (values) async {
            if (values['emptyName'] == true) values = {...values, 'name': ''};
            if (!moving && values['destination'] == newFileDestination) return;
            try {
              final prepare = moving
                  ? owner.planComponentDefinitionMove
                  : owner.planComponentExtraction;
              plan = await prepare(
                {
                  'root': prepared['root'],
                  'resource': prepared['resource'],
                  'generation': prepared['generation'],
                  'pointer': prepared['pointer'],
                  'range': prepared['range'],
                },
                values['name'],
                destinationResource: values['destination'],
              );
            } on CoreFailure catch (failure) {
              throw failureText(failure.code);
            }
          },
        );
  final result = formResult == null
      ? null
      : {...formResult, if (formResult['emptyName'] == true) 'name': ''};
  if (result != null &&
      !moving &&
      result['destination'] == newFileDestination &&
      current() &&
      context.mounted) {
    final name = result['name'] as String,
        sourcePath = Uri.parse(prepared['resource'] as String).toFilePath(),
        extension = p.extension(
          Uri.parse(prepared['resource'] as String).toFilePath(),
        );
    await editForm(
      context,
      l.extractComponentToFile,
      [FormFieldSpec('path', l.fileMoveDestination)],
      {
        'path': p.relative(
          p.join(
            p.dirname(sourcePath),
            _suggestedExtractionFilename(name, extension),
          ),
          from: owner.access.boundary,
        ),
      },
      controller: c,
      target: prepared,
      kind: 'object.extractFile',
      arguments: {'name': name},
      waitForDismissal: true,
      validate: (values) {
        final value = values['path'] as String? ?? '';
        if (value.trim().isEmpty) return l.fileMoveDestinationRequired;
        final path = p.normalize(p.join(owner.access.boundary, value));
        try {
          owner.accessFor(path).pathFor(path);
        } on CoreFailure {
          return l.fileMoveDestinationLocal;
        }
        if (![
          '.yaml',
          '.yml',
          '.json',
        ].contains(p.extension(path).toLowerCase())) {
          return l.sourceFileFormat;
        }
        if ((p.extension(path).toLowerCase() == '.json') !=
            (extension.toLowerCase() == '.json')) {
          return l.fileMoveSameFormat;
        }
        return null;
      },
      onApply: (values) async {
        if (!current()) {
          throw CoreFailure('refactor.stale', l.objectActionStale);
        }
        try {
          plan = await c.planComponentExtractionToFile(
            owner,
            {
              'root': prepared['root'],
              'resource': prepared['resource'],
              'generation': prepared['generation'],
              'pointer': prepared['pointer'],
              'range': prepared['range'],
            },
            name,
            p.normalize(
              p.join(owner.access.boundary, values['path'] as String),
            ),
          );
        } on CoreFailure catch (failure) {
          throw failureText(failure.code);
        }
      },
    );
  }
  if (result != null &&
      plan != null &&
      context.mounted &&
      !c.disposed &&
      identical(c.project, owner) &&
      c.root == capturedRoot &&
      c.navigationGeneration == navigation &&
      capturedSelection ==
          (c.selectedResource, c.selectedPointer, c.selectedOccurrence)) {
    await showRefactoringReview(context, c, owner, plan!);
  }
}

Future<void> _inlineObjectReference(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  final owner = c.project!, root = c.root, navigation = c.navigationGeneration;
  final selection = (
    c.selectedResource,
    c.selectedPointer,
    c.selectedOccurrence,
  );
  final failureText = _copyRefactoringFailure(context);
  RefactoringPlan plan;
  try {
    plan = await owner.planReferenceInlining({
      'root': prepared['root'],
      'resource': prepared['resource'],
      'generation': prepared['generation'],
      'pointer': prepared['pointer'],
      'range': prepared['range'],
    });
  } on CoreFailure catch (failure) {
    throw failureText(failure.code);
  }
  if (!context.mounted ||
      c.disposed ||
      !identical(c.project, owner) ||
      c.root != root ||
      c.navigationGeneration != navigation ||
      selection !=
          (c.selectedResource, c.selectedPointer, c.selectedOccurrence)) {
    return;
  }
  await showRefactoringReview(context, c, owner, plan);
}

String Function(String) _copyRefactoringFailure(BuildContext context) {
  final l = context.l10n;
  return (code) => switch (code) {
    'refactor.copy.schema-resource' ||
    'refactor.inline.schema-resource' ||
    'refactor.inline.dialect' => l.copySchemaResourceBlocked,
    'refactor.literal.ownership' => l.refactoringLiteralOwnershipBlocked,
    'refactor.inline.recursive' => l.inlineRecursiveBlocked,
    'refactor.inline.ignored' => l.inlineIgnoredBlocked,
    'refactor.inline.pathItem' => l.inlinePathItemBlocked,
    'refactor.copy.flow' ||
    'refactor.copy.format' ||
    'refactor.copy.indent' ||
    'refactor.copy.value' ||
    'refactor.copy.final-newline' => l.copyRepresentationBlocked,
    'refactor.inline.uri-context' => l.inlineUriContextBlocked,
    'refactor.copy.uri-context' => l.copyUriContextBlocked,
    'refactor.copy.retrieval' => l.copyRetrievalBlocked,
    'refactor.copy.resource-context' => l.copyRootContextBlocked,
    'refactor.copy.binding' => l.copyBindingBlocked,
    'refactor.context.ambiguous' ||
    'refactor.copy.implicit' => l.copyTypedContextBlocked,
    'refactor.extract.destination' => l.extractDestinationBlocked,
    _ => l.refactoringFailed(code),
  };
}

Future<void> _suggestObjectSchema(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) async {
  final prepared = await _prepareObjectAction(context, c, item);
  if (prepared == null || !context.mounted) return;
  final owner = c.project!, root = c.root!, l = context.l10n;
  RefactoringPlan? plan;
  final selected = await editForm(
    context,
    l.suggestSchema,
    [
      FormFieldSpec(
        'nullable',
        l.schemaSuggestionNullChoice,
        options: const ['observed', 'nullable'],
        labels: {
          'observed': l.schemaSuggestionObserved,
          'nullable': l.schemaSuggestionNullable,
        },
      ),
    ],
    {'nullable': 'observed'},
    controller: c,
    target: prepared,
    kind: 'object.suggest',
    onApply: (values) async {
      try {
        plan = await owner.planSchemaSuggestion(
          root,
          prepared['resource'],
          '${prepared['pointer']}/example',
          {
            'resource': prepared['resource'],
            'generation': prepared['generation'],
            'pointer': prepared['pointer'],
            'range': prepared['range'],
          },
          nullable: values['nullable'] == 'nullable',
        );
      } on CoreFailure catch (failure) {
        throw l.refactoringFailed(failure.code);
      }
    },
  );
  if (selected != null &&
      plan != null &&
      context.mounted &&
      identical(c.project, owner)) {
    await showRefactoringReview(context, c, owner, plan!);
  }
}

Map<String, dynamic> _refreshedObjectField(
  Map<String, dynamic> item,
  Map<String, dynamic> field,
) {
  final fixed = (item['fields'] as List? ?? [])
      .cast<Map<String, dynamic>>()
      .where((f) => f['name'] == field['name'])
      .firstOrNull;
  final entry = (item['entries'] as List? ?? [])
      .cast<Map<String, dynamic>>()
      .where((f) => f['name'] == field['name'])
      .firstOrNull;
  return {
    ...field,
    ...?fixed,
    if (fixed == null && entry != null) ...{
      ...entry,
      'present': true,
      'target': entry,
    },
  };
}

/// A dialog never detaches the inline draft it is replacing. Only an owned
/// flush may advance its generation; an independent source change is stale.
Future<Map<String, dynamic>?> _prepareObjectAction(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) async {
  final owner = c.project, root = c.root, navigation = c.navigationGeneration;
  final staleMessage = context.l10n.objectActionStale;
  final selection = (
    c.selectedResource,
    c.selectedPointer,
    c.selectedOccurrence,
  );
  final buffer = c.store?.buffers[item['resource']];
  bool current() =>
      context.mounted &&
      !c.disposed &&
      identical(c.project, owner) &&
      c.root == root &&
      c.navigationGeneration == navigation &&
      selection ==
          (c.selectedResource, c.selectedPointer, c.selectedOccurrence);
  bool rebound() =>
      c.draft?.buffer == item['resource'] &&
      c.draft?.pointer == item['pointer'] &&
      c.draft?.generation == buffer?.generation;
  if (owner == null || root == null || buffer == null || !current()) {
    return null;
  }
  if (buffer.generation != item['generation'] && !rebound()) {
    throw CoreFailure('draft.stale', staleMessage);
  }
  final before = buffer.generation;
  if (!await c.flush() || !current()) return null;
  if (buffer.generation != before && !rebound()) {
    throw CoreFailure('draft.stale', staleMessage);
  }
  final generation = buffer.generation;
  await c.analyse();
  if (!current()) return null;
  final fresh = await owner.inspectObject(
    root,
    item['resource'] as String,
    item['pointer'] as String,
    offset: item['offset'] as int? ?? 0,
  );
  if (!current()) return null;
  if (buffer.generation != generation || fresh['generation'] != generation) {
    throw CoreFailure('draft.stale', staleMessage);
  }
  return fresh;
}
