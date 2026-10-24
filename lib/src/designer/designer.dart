import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:path/path.dart' as p;

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/busyapi_glyphs.dart';
import '../app/contract_labels.dart';
import '../app/localization.dart';
import '../workspace/workspace_controller.dart';
import '../workspace/refactoring_review.dart';
import '../workspace/project_search.dart' show BusyApiReviewPages;
import '../workspace/problems_panel.dart' show authoredFieldProblem;
import 'schema_tree.dart';
import 'reference_picker.dart';
import 'form_value_editor.dart';

part 'object_page.dart';

String pointerEscape(String s) => s.replaceAll('~', '~0').replaceAll('/', '~1');

class Designer extends StatefulWidget {
  const Designer({
    super.key,
    required this.controller,
    required this.run,
    required this.reveal,
    this.tryOperation,
  });
  final WorkspaceController controller;
  final void Function(Future<void> Function()) run;
  final void Function(Map<String, dynamic>) reveal;
  final ValueChanged<Map<String, dynamic>>? tryOperation;
  @override
  State<Designer> createState() => _DesignerState();
}

class _DesignerState extends State<Designer> {
  WorkspaceController get c => widget.controller;
  bool fieldsAvailable(Map<String, dynamic> item, String field) =>
      c.scopeSafe(item, authoredField: field) ||
      (c.draft != null &&
          c.draft!.root == c.root &&
          c.draft!.buffer == item['resource'] &&
          c.draft!.pointer == item['pointer'] &&
          c.store!.get(c.draft!.buffer).generation == c.draft!.generation);
  Widget field(
    Map<String, dynamic> item,
    String key,
    String label, {
    bool multiline = false,
  }) {
    final available = fieldsAvailable(item, key);
    final source = c.store?.buffers[item['resource']];
    final captured = c.draft;
    final ownsDraft =
        captured?.root == c.root &&
        captured?.buffer == item['resource'] &&
        captured?.pointer == item['pointer'];
    final displayed =
        ((ownsDraft ? captured?.values[key] : null) ?? item['value']?[key])
            ?.toString() ??
        '';
    // Keep large values out of the ordinary page's text layout. Explicit
    // editing reads the complete captured value into its bounded form editor.
    if (displayed.length > 16384) {
      return Column(
        children: [
          BusyApiActionRow(
            title: label,
            subtitle: context.l10n.previewTextLimited,
            leading: const Icon(BusyApiGlyphs.code),
            onTap: () => widget.reveal(item),
          ),
          BusyApiActionRow(
            title: context.l10n.editCompleteCapturedValue,
            leading: const Icon(BusyApiGlyphs.edit),
            onTap: available
                ? () => widget.run(
                    () => _editObjectValue(context, c, item, {
                      'name': key,
                      'type': 'string',
                      'nativeString': true,
                    }),
                  )
                : null,
          ),
        ],
      );
    }
    final session = available
        ? c.bind(item)
        : ownsDraft
        ? captured
        : null;
    if (available) session!.bind(key, item['value']?[key] ?? '');
    final l = context.l10n;
    final definitions = item['fields'];
    final definition = definitions is List
        ? definitions
              .whereType<Map>()
              .where((f) => f['name'] == key)
              .firstOrNull
        : null;
    final value = item['value'];
    final present =
        definition?['present'] == true ||
        definition == null && value is Map && value.containsKey(key);
    // Keep the same field/focus resources through checks and source undo.
    // Stale projections are view-only and cannot bind or publish a target.
    return DraftField(
      key: ValueKey('${c.root}/${item['resource']}/${item['pointer']}/$key'),
      label: label,
      hint: present
          ? l.emptyStringValue
          : definition?['required'] == true
          ? l.requiredFieldAbsent
          : l.absentValue,
      trailing: !available
          ? null
          : BusyApiHeaderPopupMenuButton<String>(
              tooltip: l.fieldValueActions(label),
              icon: BusyApiGlyphs.menuHorizontal,
              itemBuilder: (_) => [
                BusyApiPopupMenuItem(value: 'edit', label: l.editAuthoredField),
              ],
              onSelected: (_) => widget.run(
                () => _editObjectValue(context, c, item, {
                  'name': key,
                  'type': 'string',
                  'nativeString': true,
                }),
              ),
            ),
      value: (session?.values[key] ?? item['value']?[key] ?? '').toString(),
      modelCurrent:
          source != null &&
          source.generation == item['generation'] &&
          (item['root'] == null || item['root'] == c.root),
      multiline: multiline,
      readOnly: !available,
      pending: session != null && session.values[key] != session.committed[key],
      error:
          session?.errors[key] ??
          (session?.composing == true ||
                  session?.values[key] != session?.committed[key]
              ? null
              : authoredFieldProblem(context, c, item, key)),
      onChanged: (value, composing) {
        if (!available) return;
        session!.composing = composing;
        session.edit(key, value);
        c.checkpoint();
      },
      onCommit: () => widget.run(() async {
        // Opening a captured dialog moves focus out of an inline field. The
        // launcher has already flushed it; that delayed blur must not flush or
        // report an error against the dialog's new ownership.
        if (!available || c.form != null || c.formApplying) return;
        await c.flush();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final projection = c.projection;
    if (projection == null) return Center(child: Text(c.error ?? l.checking));
    final operation = (projection['operations'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where(c.isSelected)
        .firstOrNull;
    if ((operation == null ||
            c.specification?.family == SpecificationFamily.swagger20) &&
        c.selectedPointer != '/info') {
      return _NativeObjectPage(
        key: ValueKey((c.root, c.selectedResource, c.selectedPointer)),
        designer: this,
        root: c.root!,
        resource: c.selectedResource ?? c.root!,
        pointer: c.selectedPointer,
      );
    }
    if (operation?['shared'] == true) {
      return BusyApiGroupedList(
        title: '${operation!['method']} ${operation['path']}',
        description: l.sharedOperationSource,
        children: [
          BusyApiActionRow(
            title: l.tryOperation,
            leading: const Icon(BusyApiGlyphs.play),
            onTap: () => widget.tryOperation?.call(operation),
          ),
          BusyApiActionRow(
            title: l.editDefinition,
            onTap: () => widget.run(
              () => c.selectObject({
                ...operation,
                'occurrence':
                    'definition:${operation['resource']}#${operation['pointer']}',
              }),
            ),
          ),
          BusyApiActionRow(
            title: l.sourceLink,
            onTap: () => widget.reveal(operation),
          ),
        ],
      );
    }
    final item = operation ?? Map<String, dynamic>.from(projection['info']);
    if (item['value'] is! Map) {
      return BusyApiGroupedList(
        description: context.l10n.outdated,
        children: [
          BusyApiActionRow(
            title: context.l10n.sourceLink,
            onTap: () => widget.reveal(item),
          ),
        ],
      );
    }
    final value = Map<String, dynamic>.from(item['value']);
    final inheritedValue = operation?['inheritedParameters'];
    final inherited = inheritedValue is List ? inheritedValue : const [];
    final ownParameters = value['parameters'] is List
        ? value['parameters'] as List
        : const [];
    final ownParametersValid =
        !value.containsKey('parameters') || value['parameters'] is List;
    final allResponses = value['responses'] is Map
        ? value['responses'] as Map
        : const {};
    // Extensions remain data, not Response Objects or schema/media previews.
    final responses = Map.fromEntries(
      allResponses.entries.where(
        (entry) => !entry.key.toString().startsWith('x-'),
      ),
    );
    final responsesValid =
        !value.containsKey('responses') || value['responses'] is Map;
    final pathFields = operation?['pathContext']?['fields'];
    final inheritedOwner =
        pathFields is Map &&
            pathFields['parameters'] is Map &&
            pathFields['parameters']['resource'] is String &&
            pathFields['parameters']['pointer'] is String &&
            pathFields['parameters']['kind'] == 'parameter-array'
        ? Map<String, dynamic>.from(pathFields['parameters'] as Map)
        : null;
    final inheritedContainerInvalid =
        inheritedOwner != null &&
        (c.analysis?['findings'] as List? ?? const []).whereType<Map>().any(
          (finding) =>
              finding['resource'] == inheritedOwner['resource'] &&
              finding['pointer'] == inheritedOwner['pointer'] &&
              const [
                'parameter.container.type',
                'structure.type',
              ].contains(finding['code']),
        );
    void openParameters(Map<String, dynamic> owner, [int? index]) {
      widget.run(
        () => c.selectObject({
          'root': item['root'],
          'resource': owner['resource'],
          'pointer': '${owner['pointer']}${index == null ? '' : '/$index'}',
          'kind': index == null ? 'parameter-array' : 'parameter',
        }),
      );
    }

    return ColoredBox(
      color: BusyApiSurfaceColors.of(context).view,
      child: SingleChildScrollView(
        padding: BusyApiInsets.settingsPage,
        child: BusyApiClamp(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!c.scopeSafe(item))
                BusyApiStatusBox(
                  kind: BusyApiStatusKind.warning,
                  message: c.checking
                      ? l.checking
                      : c.outdated
                      ? l.outdated
                      : l.objectScopeNeedsCorrection,
                ),
              if (c.draft?.errors['session'] != null)
                BusyApiGroupedList(
                  children: [
                    Text(c.draft!.errors['session']!),
                    BusyApiActionRow(
                      title: l.discardDrafts,
                      onTap: () {
                        widget.run(() async {
                          await c.discardDrafts();
                          if (mounted) setState(() {});
                        });
                      },
                    ),
                  ],
                ),
              if (operation == null) ...[
                Text(
                  l.overview,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text('${l.openapiVersion}: ${projection['openapi']}'),
                BusyApiGroupedList(
                  title: l.api,
                  children: [
                    field(item, 'title', l.title),
                    field(item, 'version', l.apiVersion),
                    if ((item['fields'] as List?)?.whereType<Map>().any(
                          (field) => field['name'] == 'summary',
                        ) ==
                        true)
                      field(item, 'summary', l.summary),
                    field(item, 'description', l.description, multiline: true),
                    field(item, 'termsOfService', l.termsOfService),
                  ],
                ),
                for (final name in ['contact', 'license'])
                  BusyApiActionRow(
                    title: name == 'contact' ? l.contact : l.license,
                    onTap: () => widget.run(
                      () => _openObjectChild(context, c, item, {
                        'name': name,
                        'present': value.containsKey(name),
                        'type': 'object',
                      }),
                    ),
                  ),
                BusyApiActionRow(
                  title: l.contractMetadata,
                  onTap: () => widget.run(
                    () => c.selectObject({
                      ...item,
                      'pointer': '',
                      'range': [0, 0],
                    }),
                  ),
                ),
                for (final other in projection['otherRootObjects'] ?? [])
                  BusyApiActionRow(
                    title: other['name'],
                    onTap: () => other['name'].toString().startsWith('x-')
                        ? widget.reveal(Map<String, dynamic>.from(other))
                        : widget.run(
                            () => c.selectObject(
                              Map<String, dynamic>.from(other),
                            ),
                          ),
                  ),
                BusyApiActionRow(
                  title: l.addOperation,
                  leading: const Icon(BusyApiGlyphs.add),
                  onTap: c.scopeSafe(item)
                      ? () => widget.run(() => addOperation(context, c))
                      : null,
                ),
              ] else ...[
                Text(
                  '${httpOperationMethod(operation)} ${operation['path']}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                BusyApiActionRow(
                  title: l.tryOperation,
                  leading: const Icon(BusyApiGlyphs.play),
                  onTap: c.scopeSafe(operation)
                      ? () => widget.tryOperation?.call(operation)
                      : null,
                ),
                BusyApiActionRow(
                  title: (operation['role'] ?? 'operation') == 'operation'
                      ? '${l.method} / ${l.path}'
                      : l.method,
                  subtitle: '${operation['method']} ${operation['path']}',
                  onTap: c.scopeSafe(item)
                      ? () => widget.run(
                          () => moveOperation(context, c, operation),
                        )
                      : null,
                ),
                BusyApiGroupedList(
                  children: [
                    field(item, 'summary', l.summary),
                    field(item, 'description', l.description, multiline: true),
                    field(item, 'operationId', l.operationId),
                  ],
                ),
                BusyApiActionRow(
                  title: l.operationDetails,
                  onTap: () => widget.run(
                    () => c.selectObject({
                      ...operation,
                      'occurrence':
                          'details:${operation['resource']}#${operation['pointer']}',
                    }),
                  ),
                ),
                BusyApiGroupedList(
                  title: l.parameters,
                  description: inherited.isEmpty
                      ? null
                      : l.pathItemParameterDeclarationsHelp,
                  children: [
                    if (inherited.isNotEmpty)
                      Text(l.pathItemParameterDeclarations),
                    if (operation['pathContext']?['complete'] == false)
                      Text(l.referenceEffectiveIncomplete),
                    if (inheritedContainerInvalid ||
                        inheritedValue != null && inheritedValue is! List)
                      BusyApiActionRow(
                        title: l.fieldValueInvalid,
                        subtitle: l.pathItemParameterDeclarations,
                        onTap: inheritedOwner == null
                            ? null
                            : () => openParameters(inheritedOwner),
                      ),
                    for (var i = 0; i < inherited.length && i < 50; i++)
                      BusyApiActionRow(
                        title: contractIdentityLabel(
                          inherited[i] is Map
                              ? '${inherited[i]['name'] ?? inherited[i]['\$ref']}'
                              : l.fieldValueInvalid,
                        ),
                        subtitle: contractIdentityLabel(
                          '${l.inherited} · ${inherited[i] is Map ? inherited[i]['in'] ?? l.referenceObject : l.fieldValueInvalid} · ${l.editDefinition}',
                        ),
                        onTap:
                            inheritedOwner == null ||
                                !c.scopeSafe(item, authoredField: 'parameters')
                            ? null
                            : () => openParameters(inheritedOwner, i),
                      ),
                    if (inherited.isNotEmpty && inheritedOwner != null)
                      BusyApiActionRow(
                        title: l.viewCollectionEntries(inherited.length),
                        subtitle: l.pathItemParameterDeclarations,
                        onTap: c.scopeSafe(item, authoredField: 'parameters')
                            ? () => openParameters(inheritedOwner)
                            : null,
                      ),
                    for (var i = 0; i < ownParameters.length && i < 50; i++)
                      BusyApiActionRow(
                        title: contractIdentityLabel(
                          ownParameters[i] is Map
                              ? '${ownParameters[i]['name'] ?? ownParameters[i]['\$ref']}'
                              : l.fieldValueInvalid,
                        ),
                        subtitle: contractIdentityLabel(
                          ownParameters[i] is Map
                              ? ownParameters[i]['in']?.toString() ??
                                    l.referenceObject
                              : l.fieldValueInvalid,
                        ),
                        onTap: () => openParameters({
                          'resource': item['resource'],
                          'pointer': '${item['pointer']}/parameters',
                        }, i),
                      ),
                    if (!ownParametersValid)
                      BusyApiActionRow(
                        title: l.fieldValueInvalid,
                        subtitle: l.parameters,
                        onTap: () => openParameters({
                          'resource': item['resource'],
                          'pointer': '${item['pointer']}/parameters',
                        }),
                      ),
                    if (ownParameters.length > 50)
                      BusyApiActionRow(
                        title: l.viewCollectionEntries(ownParameters.length),
                        onTap: c.scopeSafe(item)
                            ? () => openParameters({
                                'resource': item['resource'],
                                'pointer': '${item['pointer']}/parameters',
                              })
                            : null,
                      ),
                    BusyApiActionRow(
                      title: l.addParameter,
                      leading: const Icon(BusyApiGlyphs.add),
                      onTap: c.scopeSafe(item)
                          ? () => widget.run(
                              () => editParameter(context, c, item, null),
                            )
                          : null,
                    ),
                  ],
                ),
                BusyApiGroupedList(
                  title: l.responses,
                  children: [
                    for (final response in responses.entries.take(50))
                      BusyApiActionRow(
                        title: response.key,
                        subtitle: contractIdentityLabel(
                          response.value is! Map
                              ? l.fieldValueInvalid
                              : response.value['description']?.toString() ??
                                    response.value['\$ref']?.toString() ??
                                    '',
                        ),
                        onTap:
                            response.value is Map &&
                                !response.value.containsKey(r'$ref') &&
                                c.scopeSafe(item)
                            ? () => widget.run(
                                () => editResponse(
                                  context,
                                  c,
                                  item,
                                  response.key,
                                ),
                              )
                            : () => widget.run(
                                () => c.selectObject({
                                  'root': item['root'],
                                  'resource': item['resource'],
                                  'pointer':
                                      '${item['pointer']}/responses/${pointerEscape(response.key)}',
                                }),
                              ),
                      ),
                    if (!responsesValid)
                      BusyApiActionRow(
                        title: l.fieldValueInvalid,
                        subtitle: l.responses,
                        onTap: () => widget.run(
                          () => c.selectObject({
                            'root': item['root'],
                            'resource': item['resource'],
                            'pointer': '${item['pointer']}/responses',
                          }),
                        ),
                      ),
                    if (allResponses.length > 50 ||
                        responses.length != allResponses.length)
                      BusyApiActionRow(
                        title: l.viewCollectionEntries(allResponses.length),
                        onTap: () => widget.run(
                          () => c.selectObject({
                            'root': item['root'],
                            'resource': item['resource'],
                            'pointer': '${item['pointer']}/responses',
                          }),
                        ),
                      ),
                    BusyApiActionRow(
                      title: l.addResponse,
                      leading: const Icon(BusyApiGlyphs.add),
                      onTap: c.scopeSafe(item)
                          ? () => widget.run(
                              () => editResponse(context, c, item, null),
                            )
                          : null,
                    ),
                  ],
                ),
                for (final response in responses.entries.where(
                  (entry) => entry.value is Map,
                ))
                  for (final media
                      in (response.value['content'] is Map
                              ? response.value['content'] as Map
                              : const {})
                          .entries
                          .where((entry) => entry.value is Map)) ...[
                    BusyApiGroupedList(
                      title: '${response.key} · ${media.key}',
                      children: [
                        if (media.value.containsKey('schema'))
                          BusyApiActionRow(
                            title: media.value['schema'] is bool
                                ? l.booleanSchema
                                : l.editSchema,
                            onTap: () => widget.run(
                              () => c.selectObject(
                                Map<String, dynamic>.from(
                                  item['details']?['${item['pointer']}/responses/${pointerEscape(response.key)}/content/${pointerEscape(media.key)}/schema'] ??
                                      item,
                                ),
                              ),
                            ),
                          ),
                        for (final prop
                            in (media.value['schema'] is Map &&
                                        media.value['schema']['properties']
                                            is Map
                                    ? media.value['schema']['properties'] as Map
                                    : {})
                                .entries
                                .take(50))
                          BusyApiActionRow(
                            title: prop.key,
                            subtitle: prop.value is Map
                                ? prop.value['type']?.toString() ??
                                      l.advancedSchema
                                : l.booleanSchema,
                            onTap: () => widget.run(
                              () => editProperty(
                                context,
                                c,
                                item,
                                response.key,
                                media.key,
                                prop.key,
                              ),
                            ),
                          ),
                        BusyApiActionRow(
                          title: l.addProperty,
                          leading: const Icon(BusyApiGlyphs.add),
                          onTap:
                              c.scopeSafe(item) &&
                                  media.value['schema'] is Map &&
                                  media.value['schema']['type'] == 'object'
                              ? () => widget.run(
                                  () => editProperty(
                                    context,
                                    c,
                                    item,
                                    response.key,
                                    media.key,
                                    null,
                                  ),
                                )
                              : null,
                        ),
                        BusyApiActionRow(
                          title: l.example,
                          subtitle: media.value.containsKey('example')
                              ? _examplePreview(
                                  item['exampleTexts']?[response.key]?[media
                                          .key]
                                      as String?,
                                )
                              : l.absentValue,
                          onTap: c.scopeSafe(item)
                              ? () => widget.run(
                                  () => editExample(
                                    context,
                                    c,
                                    item,
                                    response.key,
                                    media.key,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ],
              ],
              BusyApiActionRow(
                title: l.sourceLink,
                leading: const Icon(BusyApiGlyphs.code),
                onTap: () => widget.reveal(item),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _examplePreview(String? source) {
  if (source == null) return '';
  if (source.length <= 240) return source;
  var end = 240;
  if (source.codeUnitAt(end) >= 0xdc00 && source.codeUnitAt(end) <= 0xdfff) {
    end--;
  }
  return '${source.substring(0, end)}…';
}

class DraftField extends StatefulWidget {
  const DraftField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onCommit,
    this.multiline = false,
    this.error,
    this.pending = false,
    this.readOnly = false,
    this.modelCurrent = true,
    this.hint,
    this.trailing,
  });
  final String label, value;
  final String? error;
  final String? hint;
  final Widget? trailing;
  final bool multiline;
  final bool pending;
  final bool readOnly;
  final bool modelCurrent;
  final void Function(String, bool) onChanged;
  final VoidCallback onCommit;
  @override
  State<DraftField> createState() => _DraftFieldState();
}

class _DraftFieldState extends State<DraftField> {
  late final TextEditingController controller = TextEditingController(
    text: widget.value,
  );
  final focus = FocusNode();
  bool _disposing = false, _reconciling = false;
  late String _lastInput = widget.value;
  bool _lastComposing = false;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    focus.addListener(() {
      if (!_disposing &&
          !focus.hasFocus &&
          controller.value.composing.isCollapsed) {
        widget.onCommit();
      }
    });
  }

  void _changed() {
    if (_disposing || _reconciling) return;
    final composing =
        controller.value.composing.isValid &&
        !controller.value.composing.isCollapsed;
    if (controller.text == _lastInput && composing == _lastComposing) return;
    _lastInput = controller.text;
    _lastComposing = composing;
    widget.onChanged(controller.text, composing);
  }

  @override
  void didUpdateWidget(DraftField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A pending page read retains its old projection, which must never roll
    // committed input back for a frame. Current model updates (including
    // focused undo/redo) still reconcile through the same controller path.
    if (!widget.modelCurrent ||
        widget.value == controller.text ||
        widget.pending ||
        _lastComposing) {
      return;
    }
    final selection = controller.selection;
    _reconciling = true;
    _lastInput = widget.value;
    controller.value = TextEditingValue(
      text: widget.value,
      selection: TextSelection(
        baseOffset: selection.baseOffset.clamp(0, widget.value.length),
        extentOffset: selection.extentOffset.clamp(0, widget.value.length),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
    );
    _reconciling = false;
  }

  @override
  void dispose() {
    _disposing = true;
    controller.removeListener(_changed);
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BusyApiGroupedTextEntry(
    label: widget.label,
    controller: controller,
    focusNode: focus,
    readOnly: widget.readOnly,
    minLines: widget.multiline ? 3 : 1,
    maxLines: widget.multiline ? 6 : 1,
    errorText: widget.error,
    hintText: widget.hint,
    trailing: widget.trailing,
    onSubmitted: (_) => widget.onCommit(),
  );
}

class FormFieldSpec {
  const FormFieldSpec(
    this.key,
    this.label, {
    this.options,
    this.labels,
    this.boolean = false,
    this.multiline = false,
    this.json = false,
  });
  final String key, label;
  final List<String>? options;
  final Map<String, String>? labels;
  final bool boolean, multiline, json;
}

Future<Map<String, dynamic>?> editForm(
  BuildContext context,
  String title,
  List<FormFieldSpec> fields,
  Map<String, dynamic> initial, {
  bool removable = false,
  bool unchangedIsNoop = false,
  bool waitForDismissal = false,
  bool Function()? waitForDismissalWhen,
  String? Function(Map<String, dynamic>)? validate,
  Future<void> Function(Map<String, dynamic>)? onApply,
  String? Function()? applyLabel,
  WorkspaceController? controller,
  Map<String, dynamic>? target,
  String? kind,
  Map<String, Object?> arguments = const {},
}) async {
  final fieldValues = <String, dynamic>{
    for (final field in fields) field.key: initial[field.key],
  };
  final owner = controller?.beginForm(kind!, target!, arguments, fieldValues);
  ModalRoute<Map<String, dynamic>>? route;
  final result = await showBusyApiModalDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    onRoutePushed: (value, _) => route = value,
    builder: (_) => _EditFormDialog(
      title: title,
      fields: fields,
      initial: fieldValues,
      removable: removable,
      unchangedIsNoop: unchangedIsNoop,
      validate: validate,
      onApply: onApply,
      applyLabel: applyLabel,
      controller: controller,
      owner: owner,
    ),
  );
  // A following modal must not borrow focus while this route still owns its
  // presentation controllers. Ordinary forms retain their existing result
  // timing; explicit capture → review workflows wait for actual teardown.
  if (waitForDismissal || (waitForDismissalWhen?.call() ?? false)) {
    await route?.completed;
  }
  return result;
}

/// Presentation resources belong to the route subtree, which outlives its
/// result future during dismissal. Domain drafts remain owned by the workspace.
class _EditFormDialog extends StatefulWidget {
  const _EditFormDialog({
    required this.title,
    required this.fields,
    required this.initial,
    required this.removable,
    required this.unchangedIsNoop,
    this.validate,
    this.onApply,
    this.applyLabel,
    this.controller,
    this.owner,
  });
  final String title;
  final List<FormFieldSpec> fields;
  final Map<String, dynamic> initial;
  final bool removable, unchangedIsNoop;
  final String? Function(Map<String, dynamic>)? validate;
  final Future<void> Function(Map<String, dynamic>)? onApply;
  final String? Function()? applyLabel;
  final WorkspaceController? controller;
  final FormSession? owner;

  @override
  State<_EditFormDialog> createState() => _EditFormDialogState();
}

class _EditFormDialogState extends State<_EditFormDialog> {
  late final Map<String, dynamic> values;
  final textControllers = <String, TextEditingController>{};
  final listeners = <String, VoidCallback>{};
  final composingValues = <String>{};
  ModalRoute<dynamic>? route;
  String? error;
  bool applying = false, closing = false;

  bool get active => mounted && !closing && (route?.isCurrent ?? false);
  bool get ownsDraft =>
      widget.owner == null || widget.controller!.ownsForm(widget.owner!);

  @override
  void initState() {
    super.initState();
    values = widget.owner?.values ?? Map<String, dynamic>.from(widget.initial);
    for (final field in widget.fields.where(
      (f) => !f.boolean && f.options == null,
    )) {
      final text = TextEditingController(
        text: values[field.key]?.toString() ?? '',
      );
      textControllers[field.key] = text;
      void changed() {
        // Focus/composition changes during exit must not recreate resolved drafts.
        if (!active || applying || !ownsDraft) return;
        if (widget.owner != null) {
          widget.owner!.edit(
            field.key,
            text.text,
            isComposing:
                !text.value.composing.isCollapsed ||
                composingValues.contains(field.key),
          );
          widget.controller!.checkpoint();
        } else {
          values[field.key] = text.text;
        }
      }

      listeners[field.key] = changed;
      text.addListener(changed);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    closing = true;
    for (final entry in textControllers.entries) {
      entry.value.removeListener(listeners[entry.key]!);
      entry.value.dispose();
    }
    // Teardown never applies or discards an owned source session.
    super.dispose();
  }

  void change(String field, Object? value) {
    if (!active || applying || !ownsDraft) return;
    setState(() {
      if (widget.owner == null) {
        values[field] = value;
      } else {
        widget.owner!.edit(field, value);
        widget.controller!.checkpoint();
      }
    });
  }

  void finish(Map<String, dynamic>? result) {
    final captured = route;
    if (!mounted || closing || captured == null || !captured.isActive) return;
    // Complete only this route, even when another modal is now above it.
    setState(() => closing = true);
    if (captured.isCurrent) {
      captured.navigator!.pop(result);
    } else {
      captured.navigator!.removeRoute(captured, result);
    }
  }

  Future<void> cancel() async {
    if (!active || applying) return;
    setState(() => applying = true);
    try {
      if (widget.owner != null) {
        await widget.controller!.cancelForm(widget.owner!);
      }
      finish(null);
    } on Object catch (e) {
      failed(e);
    }
  }

  void failed(Object e) {
    if (!mounted || closing || route?.isActive != true) return;
    setState(() {
      error = e.toString();
      applying = false;
    });
  }

  Future<void> submit({bool remove = false}) async {
    // Guard before the first await, including callbacks retained before rebuild.
    if (!active || applying) return;
    if (!ownsDraft) {
      failed(CoreFailure('draft.owner', context.l10n.capturedFormInactive));
      return;
    }
    setState(() => applying = true);
    try {
      final result = remove
          ? <String, dynamic>{'remove': true}
          : Map<String, dynamic>.from(values);
      if (!remove) {
        if (composingValues.isNotEmpty ||
            textControllers.values.any((c) => !c.value.composing.isCollapsed)) {
          throw CoreFailure(
            'draft.composing',
            context.l10n.finishCompositionBeforeApply,
          );
        }
        for (final f in widget.fields.where((f) => f.json)) {
          try {
            jsonDecode(result[f.key] as String);
          } on FormatException catch (failure) {
            // FormatException.toString includes a source excerpt. That can
            // duplicate a credential-like value into a routine error message.
            throw context.l10n.invalidDataAtOffset((failure.offset ?? 0) + 1);
          }
        }
        final problem = widget.validate?.call(result);
        if (problem != null) {
          failed(problem);
          return;
        }
      }
      // Accepted data is captured before asynchronous source/file work starts.
      final accepted = Map<String, dynamic>.unmodifiable(result);
      final owner = widget.owner;
      if (owner == null) {
        await widget.onApply?.call(accepted);
      } else {
        await widget.controller!.applyForm(owner, () async {
          if (!(widget.unchangedIsNoop && !owner.pending && !remove)) {
            await widget.onApply?.call(accepted);
          }
        });
      }
      finish(accepted);
    } on Object catch (e) {
      failed(e);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: widget.owner == null && !applying,
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) closing = true;
    },
    child: BusyApiDialogShell(
      title: widget.title,
      closable: false,
      actions: [
        if (widget.removable)
          BusyApiDialogButton(
            label: context.l10n.remove,
            onPressed: applying || closing ? null : () => submit(remove: true),
          ),
        BusyApiDialogButton(
          label: context.l10n.cancel,
          onPressed: applying || closing ? null : cancel,
        ),
        BusyApiDialogButton(
          label: widget.applyLabel?.call() ?? context.l10n.apply,
          suggested: true,
          onPressed: applying || closing ? null : submit,
        ),
      ],
      children: [
        BusyApiGroupedList(
          children: [
            for (final field in widget.fields)
              if (field.boolean)
                BusyApiSwitchRow(
                  title: field.label,
                  value: values[field.key] == true,
                  onChanged: (v) => change(field.key, v),
                )
              else if (field.options != null)
                BusyApiComboRow<String>(
                  title: field.label,
                  values: field.options!,
                  selected: field.options!.contains(values[field.key])
                      ? values[field.key] as String
                      : field.options!.first,
                  labelFor: (v) => field.labels?[v] ?? v,
                  onSelected: (v) => change(field.key, v),
                )
              else
                FormValueEditor(
                  label: field.label,
                  controller: textControllers[field.key]!,
                  enabled: !applying && !closing,
                  multiline: field.multiline,
                  json: field.json,
                  onCompositionChanged: (value) {
                    if (!active || applying || !ownsDraft) return;
                    if (value) {
                      composingValues.add(field.key);
                    } else {
                      composingValues.remove(field.key);
                    }
                    widget.owner?.edit(
                      field.key,
                      textControllers[field.key]!.text,
                      isComposing: value,
                    );
                    widget.controller?.checkpoint();
                  },
                ),
          ],
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}

Map<String, dynamic> currentItem(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) {
  if (item['root'] != null && item['root'] != c.root) {
    throw CoreFailure('draft.root', context.l10n.capturedOperationOtherRoot);
  }
  final projection = c.projection!;
  return (projection['operations'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere(
        (v) =>
            v['pointer'] == item['pointer'] &&
            v['resource'] == item['resource'] &&
            (item['occurrence'] == null ||
                v['occurrence'] == item['occurrence']),
      );
}

Future<void> addOperation(BuildContext context, WorkspaceController c) async {
  if (!await c.flush()) return;
  await c.analyse();
  if (!context.mounted) return;
  final l = context.l10n;
  final info = Map<String, dynamic>.from(c.projection!['info']);
  Future<void> apply(Map<String, dynamic> result) async {
    final pointer =
        '/paths/${pointerEscape(result['path'])}/${result['method']}';
    if ((c.projection!['operations'] as List).any(
      (x) => x['path'] == result['path'] && x['method'] == result['method'],
    )) {
      throw StateError(l.operationAlreadyExists);
    }
    await c.mutate(info, [
      {'kind': 'set', 'pointer': pointer, 'value': <String, Object?>{}},
    ]);
    c.selectedPointer = pointer;
    c.selectedResource = info['resource'];
    c.selectedOccurrence = '${c.root}#$pointer';
  }

  await editForm(
    context,
    l.addOperation,
    [
      FormFieldSpec(
        'method',
        l.method,
        options: [
          'get',
          'post',
          'put',
          'patch',
          'delete',
          'head',
          'options',
          if (c.specification?.family != SpecificationFamily.swagger20) 'trace',
          if (c.projection?['openapi'].startsWith('3.2')) 'query',
        ],
      ),
      FormFieldSpec('path', l.path),
    ],
    {'method': 'get', 'path': '/'},
    validate: (v) =>
        !v['path'].startsWith('/') ? l.pathMustBeginWithSlash : null,
    onApply: apply,
    controller: c,
    target: info,
    kind: 'operation.add',
    arguments: const {},
  );
}

Future<void> moveOperation(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
) async {
  final capturedOwner = c.project,
      capturedRoot = c.root,
      navigation = c.navigationGeneration;
  final selection = (
    c.selectedResource,
    c.selectedPointer,
    c.selectedOccurrence,
  );
  bool current() =>
      context.mounted &&
      !c.disposed &&
      identical(c.project, capturedOwner) &&
      c.root == capturedRoot &&
      c.navigationGeneration == navigation &&
      selection ==
          (c.selectedResource, c.selectedPointer, c.selectedOccurrence);
  if (!await c.flush()) return;
  await c.analyse();
  if (!context.mounted || !current()) return;
  if (item['kind'] != 'operation' || item['role'] != null) {
    item = currentItem(context, c, item);
  }
  final owner = c.project!, l = context.l10n;
  final descriptor = await owner.inspectObject(
    c.root!,
    item['resource'] as String,
    item['pointer'] as String,
  );
  if (!context.mounted || !current()) return;
  if (descriptor['generation'] != item['generation']) {
    throw CoreFailure('draft.stale', l.objectActionStale);
  }
  final family = descriptor['family'] as String;
  final operationContext = descriptor['operationContext'] as Map?;
  if (operationContext == null) throw l.operationMoveDestinationInvalid;
  final additional = operationContext['additional'] == true;
  final ordinaryPath = operationContext['canRelocatePath'] == true;
  const additionalChoice = '__busyapi_additional__';
  final methods = List<String>.from(descriptor['operationMethods'] as List);
  RefactoringPlan? plan;
  final selected = await editForm(
    context,
    ordinaryPath ? '${l.method} / ${l.path}' : l.method,
    [
      FormFieldSpec(
        'method',
        l.method,
        options: [...methods, if (family == '3.2') additionalChoice],
        labels: {
          for (final method in methods) method: method.toUpperCase(),
          additionalChoice: l.additionalOperationMethod,
        },
      ),
      if (family == '3.2')
        FormFieldSpec('additionalMethod', l.additionalOperationToken),
      if (ordinaryPath) FormFieldSpec('path', l.path),
      if (ordinaryPath)
        FormFieldSpec(
          'context',
          l.pathContext,
          options: ['preserve', 'destination'],
          labels: {
            'preserve': l.preservePathContext,
            'destination': l.useDestinationContext,
          },
        ),
    ],
    {
      'method': additional ? additionalChoice : operationContext['method'],
      'additionalMethod': additional ? operationContext['method'] : '',
      'path': operationContext['path'],
      'context': 'preserve',
    },
    validate: (value) {
      if (ordinaryPath && !(value['path'] as String).startsWith('/')) {
        return l.operationMoveDestinationInvalid;
      }
      if (value['method'] == additionalChoice &&
          ((value['additionalMethod'] as String).length > 256 ||
              !RegExp(r"^[-!#$%&'*+.^_`|~0-9A-Za-z]+$")
                  .hasMatch(value['additionalMethod'] as String) ||
              methods.any(
                (method) => method.toUpperCase() == value['additionalMethod'],
              ))) {
        return l.operationMoveMethodInvalid;
      }
      return null;
    },
    onApply: (value) async {
      try {
        plan = await owner.planOperationMove(
          {
            'root': item['root'],
            'resource': item['resource'],
            'generation': item['generation'],
            'pointer': item['pointer'],
            'range': item['range'],
          },
          method: value['method'] == additionalChoice
              ? value['additionalMethod'] as String
              : value['method'] as String,
          additional: value['method'] == additionalChoice,
          context: value['context'] as String,
          path: ordinaryPath ? value['path'] as String : null,
          destinationPointer: ordinaryPath
              ? null
              : operationContext['pathItemPointer'] as String,
        );
      } on CoreFailure catch (failure) {
        throw switch (failure.code) {
          'edit.method' => l.operationMoveMethodInvalid,
          'edit.path' ||
          'refactor.operation.destination' => l.operationMoveDestinationInvalid,
          'edit.path.context' ||
          'edit.path.parameters' ||
          'edit.path.servers' => l.operationMoveContextInvalid,
          'edit.path.template' => l.operationMoveTemplateInvalid,
          'refactor.operation.proof' ||
          'refactor.copy.schema-resource' ||
          'refactor.proof' => l.operationMoveIdentityInvalid,
          _ => l.refactoringFailed(failure.code),
        };
      }
    },
    unchangedIsNoop: true,
    waitForDismissal: true,
    controller: c,
    target: item,
    kind: 'operation.move',
    arguments: const {},
  );
  if (selected != null &&
      plan?.hasChanges == true &&
      context.mounted &&
      current() &&
      identical(c.project, owner)) {
    await showRefactoringReview(context, c, owner, plan!);
  }
}

Future<void> editParameter(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  int? index,
) async {
  if (!await c.flush()) return;
  await c.analyse();
  if (!context.mounted) return;
  item = currentItem(context, c, item);
  final existing = index == null
      ? <String, dynamic>{
          'name': '',
          'in': 'query',
          'required': false,
          'description': '',
          'type': 'string',
        }
      : Map<String, dynamic>.from(item['value']['parameters'][index]);
  if (existing.containsKey('\$ref')) {
    throw StateError(context.l10n.referencedParameterSource);
  }
  if (index != null &&
      existing['schema'] != null &&
      (existing['schema'] is! Map ||
          existing['schema']['type'] is! String ||
          existing['schema']['\$ref'] != null ||
          ![
            'string',
            'integer',
            'number',
            'boolean',
          ].contains(existing['schema']['type']))) {
    throw CoreFailure(
      'edit.schema.advanced',
      context.l10n.advancedSchemaSource,
    );
  }
  existing['type'] = existing['schema'] is Map
      ? existing['schema']['type'] ?? ''
      : index == null
      ? 'string'
      : '';
  final l = context.l10n, owner = c.project!;
  final target = index == null
      ? null
      : await owner.inspectObject(
          c.root!,
          item['resource'],
          '${item['pointer']}/parameters/$index',
        );
  if (!context.mounted || !identical(c.project, owner)) return;
  RefactoringPlan? review;
  Future<void> apply(Map<String, dynamic> result) async {
    final pointer = '${item['pointer']}/parameters';
    if (result['remove'] == true) {
      review = await owner.planObjectDeletion(target!);
      return;
    }
    if (index == null) {
      await c.mutate(item, [
        if (item['value']['parameters'] == null)
          {'kind': 'set', 'pointer': pointer, 'value': <Object?>[]},
        {
          'kind': 'append',
          'pointer': pointer,
          'value': {
            'name': result['name'],
            'in': result['in'],
            'required': result['required'],
            'description': result['description'],
            'schema': {'type': result['type']},
          },
        },
      ]);
    } else {
      await c.mutate(item, [
        for (final field in ['name', 'in', 'required', 'description'])
          if ((existing[field] ?? (field == 'required' ? false : '')) !=
              (result[field] ?? (field == 'required' ? false : '')))
            {
              'kind': 'set',
              'pointer': '$pointer/$index/$field',
              'value': result[field],
            },
        if (existing['type'] != result['type'])
          {
            'kind': 'set',
            'pointer': '$pointer/$index/schema/type',
            'value': result['type'],
          },
      ]);
    }
  }

  final result = await editForm(
    context,
    l.parameters,
    [
      FormFieldSpec('name', l.name),
      FormFieldSpec(
        'in',
        l.location,
        options: ['path', 'query', 'header', 'cookie'],
      ),
      FormFieldSpec('required', l.required, boolean: true),
      FormFieldSpec('description', l.description),
      FormFieldSpec(
        'type',
        l.type,
        options: ['string', 'integer', 'number', 'boolean'],
      ),
    ],
    existing,
    removable: index != null,
    validate: (v) {
      if (v['name'].trim().isEmpty) return l.nameRequired;
      if (v['in'] == 'path' && v['required'] != true) {
        return l.parameterPathRequired;
      }
      final params = item['value']['parameters'] as List? ?? [];
      for (var i = 0; i < params.length; i++) {
        if (i != index &&
            params[i]['name'] == v['name'] &&
            params[i]['in'] == v['in']) {
          return l.duplicateParameterIdentity;
        }
      }
      return null;
    },
    onApply: apply,
    unchangedIsNoop: index != null,
    controller: c,
    target: item,
    kind: 'parameter',
    waitForDismissalWhen: () => review != null,
    arguments: {'index': index},
  );
  if (result != null &&
      review != null &&
      context.mounted &&
      identical(c.project, owner)) {
    await showRefactoringReview(context, c, owner, review!);
  }
}

Future<void> editResponse(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  String? status,
) async {
  if (!await c.flush()) return;
  await c.analyse();
  if (!context.mounted) return;
  item = currentItem(context, c, item);
  final response = status == null
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(item['value']['responses'][status]);
  if (response.containsKey('\$ref')) {
    throw StateError(context.l10n.referencedResponseSource);
  }
  final l = context.l10n, owner = c.project!;
  final parent = '${item['pointer']}/responses';
  final target = status == null
      ? null
      : await owner.inspectObject(
          c.root!,
          item['resource'],
          '$parent/${pointerEscape(status)}',
        );
  if (!context.mounted || !identical(c.project, owner)) return;
  RefactoringPlan? review;
  Future<void> apply(Map<String, dynamic> result) async {
    final pointer = '$parent/${pointerEscape(status ?? result['status'])}';
    if (result['remove'] == true) {
      review = await owner.planObjectDeletion(target!);
      return;
    }
    final actions = <Map<String, Object?>>[
      if (status == null)
        {
          'kind': 'set',
          'pointer': pointer,
          'value': {'description': result['description']},
        }
      else if ((response['description'] ?? '') != result['description'])
        {
          'kind': 'set',
          'pointer': '$pointer/description',
          'value': result['description'],
        },
    ];
    final media = result['mediaType'] as String;
    if (media.isNotEmpty &&
        !(response['content'] as Map? ?? {}).containsKey(media)) {
      actions.add({
        'kind': 'set',
        'pointer': '$pointer/content/${pointerEscape(media)}',
        'value': {
          'schema': {'type': 'object', 'properties': <String, Object?>{}},
        },
      });
    }
    if (status != null && result['status'] != status) {
      review = await owner.planResponseRename(
        target!,
        result['status'],
        actions: actions,
      );
    } else {
      await c.mutate(item, actions);
    }
  }

  final result = await editForm(
    context,
    l.responses,
    [
      FormFieldSpec('status', l.status),
      FormFieldSpec('description', l.description),
      FormFieldSpec('mediaType', l.mediaType),
    ],
    {
      'status': status ?? '200',
      'description': response['description'] ?? '',
      'mediaType': (response['content'] as Map? ?? {}).keys.firstOrNull ?? '',
    },
    removable: status != null,
    validate: (v) =>
        !RegExp(r'^(default|[1-5](\d\d|XX))$').hasMatch(v['status'])
        ? l.responseStatusInvalid
        : (status == null &&
              (item['value']['responses'] as Map? ?? {}).containsKey(
                v['status'],
              ))
        ? l.responseAlreadyExists
        : null,
    onApply: apply,
    unchangedIsNoop: status != null,
    controller: c,
    target: item,
    kind: 'response',
    waitForDismissalWhen: () => review != null,
    arguments: {'status': status},
  );
  if (result != null &&
      review != null &&
      context.mounted &&
      identical(c.project, owner)) {
    await showRefactoringReview(context, c, owner, review!);
  }
}

Future<void> editProperty(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  String status,
  String media,
  String? name,
) async {
  if (!await c.flush()) return;
  await c.analyse();
  if (!context.mounted) return;
  item = currentItem(context, c, item);
  final schema = item['value']['responses'][status]['content'][media]['schema'];
  if (schema is! Map || schema['\$ref'] != null || schema['type'] != 'object') {
    throw StateError(context.l10n.inlineObjectSchemaRequired);
  }
  final property = name == null
      ? <String, dynamic>{}
      : schema['properties'][name];
  if (property is! Map ||
      property.containsKey('\$ref') ||
      property.containsKey('allOf') ||
      property.containsKey('oneOf') ||
      property.containsKey('anyOf') ||
      property['type'] != null &&
          ![
            'string',
            'integer',
            'number',
            'boolean',
          ].contains(property['type'])) {
    throw StateError(context.l10n.advancedPropertySource);
  }
  final l = context.l10n, owner = c.project!;
  final schemaPointer =
      '${item['pointer']}/responses/${pointerEscape(status)}/content/${pointerEscape(media)}/schema';
  final target = name == null
      ? null
      : await owner.inspectObject(
          c.root!,
          item['resource'],
          '$schemaPointer/properties/${pointerEscape(name)}',
        );
  if (!context.mounted || !identical(c.project, owner)) return;
  RefactoringPlan? review;
  Future<void> apply(Map<String, dynamic> result) async {
    if (result['remove'] == true) {
      review = await owner.planObjectDeletion(target!);
      return;
    }
    final nextName = result['name'] as String;
    final propertyPointer =
        '$schemaPointer/properties/${pointerEscape(name ?? nextName)}';
    final actions = <Map<String, Object?>>[
      if (name == null)
        {
          'kind': 'set',
          'pointer': propertyPointer,
          'value': {
            'type': result['type'],
            'description': result['description'],
          },
        }
      else
        for (final key in ['type', 'description'])
          if ((property[key] ?? '') != result[key])
            {
              'kind': 'set',
              'pointer': '$propertyPointer/$key',
              'value': result[key],
            },
      {
        'kind': 'setRequired',
        'pointer': schemaPointer,
        'name': nextName,
        'required': result['required'] == true,
      },
    ];
    if (name != null && name != nextName) {
      review = await owner.planPropertyRename(
        target!,
        nextName,
        actions: actions,
      );
    } else {
      await c.mutate(item, actions);
    }
  }

  final result = await editForm(
    context,
    l.properties,
    [
      FormFieldSpec('name', l.name),
      FormFieldSpec(
        'type',
        l.type,
        options: ['string', 'integer', 'number', 'boolean'],
      ),
      FormFieldSpec('description', l.description),
      FormFieldSpec('required', l.required, boolean: true),
    ],
    {
      'name': name ?? '',
      'type': property['type'] ?? (name == null ? 'string' : ''),
      'description': property['description'] ?? '',
      'required': (schema['required'] as List? ?? []).contains(name),
    },
    removable: name != null,
    validate: (v) => v['name'].trim().isEmpty
        ? l.nameRequired
        : name != v['name'] &&
              (schema['properties'] as Map? ?? {}).containsKey(v['name'])
        ? l.propertyNameOccupied
        : null,
    onApply: apply,
    unchangedIsNoop: name != null,
    controller: c,
    target: item,
    kind: 'property',
    waitForDismissalWhen: () => review != null,
    arguments: {'status': status, 'media': media, 'name': name},
  );
  if (result != null &&
      review != null &&
      context.mounted &&
      identical(c.project, owner)) {
    await showRefactoringReview(context, c, owner, review!);
  }
}

Future<void> editExample(
  BuildContext context,
  WorkspaceController c,
  Map<String, dynamic> item,
  String status,
  String media,
) async {
  if (!await c.flush()) return;
  await c.analyse();
  if (!context.mounted) return;
  item = currentItem(context, c, item);
  final value = item['value']['responses'][status]['content'][media];
  if (value['examples'] != null) {
    throw StateError(context.l10n.namedExamplesSource);
  }
  final initialExample =
      item['exampleTexts']?[status]?[media] as String? ??
      const JsonEncoder.withIndent('  ').convert(
        value.containsKey('example') ? value['example'] : <String, Object?>{},
      );
  final l = context.l10n;
  Future<void> apply(Map<String, dynamic> result) async {
    final initial = initialExample;
    if (value.containsKey('example') &&
        result['remove'] != true &&
        result['example'] == initial) {
      return;
    }
    final pointer =
        '${item['pointer']}/responses/${pointerEscape(status)}/content/${pointerEscape(media)}/example';
    await c.mutate(item, [
      result['remove'] == true
          ? {'kind': 'remove', 'pointer': pointer}
          : {
              'kind': 'setExample',
              'pointer': pointer,
              'raw': result['example'],
            },
    ]);
  }

  await editForm(
    context,
    l.example,
    [FormFieldSpec('example', l.example, multiline: true, json: true)],
    {'example': initialExample},
    removable: value.containsKey('example'),
    onApply: apply,
    unchangedIsNoop: value.containsKey('example'),
    controller: c,
    target: item,
    kind: 'example',
    arguments: {'status': status, 'media': media},
  );
}

/// Recovery may rebind a generation only after explicit resume and an exact
/// whole-buffer identity check. It never infers a target from a display label.
Future<void> resumeCapturedForm(
  BuildContext context,
  WorkspaceController c,
) async {
  final captured = c.form;
  if (captured == null) return;
  captured.verify(
    c.store!.get(captured.target.buffer),
    captured.target.root,
    restoring: true,
  );
  c.form = null;
  c.restoringForm = captured;
  try {
    if (c.root != captured.target.root) {
      await c.selectRoot(captured.target.root);
    }
    await c.analyse();
    if (!context.mounted) return;
    final item = captured.kind.startsWith('object.')
        ? await c.project!.inspectObject(
            captured.target.root,
            captured.target.buffer,
            captured.target.pointer,
          )
        : captured.kind == 'operation.add'
        ? Map<String, dynamic>.from(c.projection!['info'])
        : (c.projection!['operations'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere(
                (v) =>
                    v['pointer'] == captured.target.pointer &&
                    v['resource'] == captured.target.buffer,
              );
    if (!context.mounted) return;
    if (item['resource'] != captured.target.buffer ||
        item['pointer'] != captured.target.pointer) {
      throw CoreFailure(
        'draft.target',
        context.l10n.capturedOccurrenceUnavailable,
      );
    }
    final args = captured.arguments;
    switch (captured.kind) {
      case 'object.value':
        if (!context.mounted) return;
        await _editObjectValue(
          context,
          c,
          item,
          Map<String, dynamic>.from(args['field'] as Map),
        );
      case 'object.add':
        if (!context.mounted) return;
        await _addObjectEntry(context, c, item);
      case 'object.extension':
        if (!context.mounted) return;
        await _addObjectExtension(
          context,
          c,
          item,
          keyword: args['keyword'] == true,
        );
      case 'object.rename':
        if (!context.mounted) return;
        await _renameObjectComponent(context, c, item);
      case 'object.renameProperty':
        if (!context.mounted) return;
        await _renameObjectComponent(context, c, item, property: true);
      case 'object.extract':
        if (!context.mounted) return;
        await _extractObjectComponent(context, c, item);
      case 'object.extractFile':
        if (!context.mounted) return;
        await _extractObjectComponent(
          context,
          c,
          item,
          fileName: args['name'] as String,
        );
      case 'object.moveDefinition':
        if (!context.mounted) return;
        await _extractObjectComponent(context, c, item, moving: true);
      case 'object.suggest':
        if (!context.mounted) return;
        await _suggestObjectSchema(context, c, item);
      case 'object.security':
        if (!context.mounted) return;
        await _addSecurityScheme(
          context,
          c,
          item,
          alternative: args['alternative'] == true,
        );
      case 'object.type':
        if (!context.mounted) return;
        await _changeSchemaTypes(
          context,
          c,
          item,
          Map<String, dynamic>.from(args['field'] as Map),
          args['next'],
        );
      case 'operation.add':
        await addOperation(context, c);
      case 'operation.move':
        await moveOperation(context, c, item);
      case 'parameter':
        await editParameter(context, c, item, args['index'] as int?);
      case 'response':
        await editResponse(context, c, item, args['status'] as String?);
      case 'property':
        await editProperty(
          context,
          c,
          item,
          args['status'] as String,
          args['media'] as String,
          args['name'] as String?,
        );
      case 'example':
        await editExample(
          context,
          c,
          item,
          args['status'] as String,
          args['media'] as String,
        );
      default:
        throw CoreFailure('draft.kind', context.l10n.unsupportedCapturedDialog);
    }
  } finally {
    if (c.restoringForm != null) {
      c.form = captured;
      c.restoringForm = null;
      c.checkpoint();
    }
  }
}
