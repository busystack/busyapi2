// Explicit native-test entry, never installed as the application entry point.
// The external driver sends real XTest input; this entry only locates mounted
// controls, observes state and compares the complete original source bytes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/designer/form_value_editor.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/designer/schema_tree.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart'
    show CoreFailure, FilePublication, SpecificationFamily;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main(List<String> arguments) async {
  try {
    final identity = await _run();
    stdout.writeln('BUSYAPI_FILE_CONTROLS_PASS $identity');
    exit(0);
  } on Object catch (error, stack) {
    // No authored values, environment or private filesystem paths in logs.
    stderr.writeln(
      'BUSYAPI_FILE_CONTROLS_FAILED ${error is StateError
          ? error.message
          : error is CoreFailure
          ? error.code
          : error.runtimeType}',
    );
    stderr.writeln(
      'BUSYAPI_FILE_CONTROLS_STACK ${jsonEncode([for (final line in stack.toString().split('\n').take(8))
        if (RegExp(r'^#\d+\s+(\S+)').firstMatch(line) case final match?) match.group(1)])}',
    );
    exit(1);
  }
}

void _expect(bool value, String code) {
  if (!value) throw StateError(code);
}

List<Element> _elements(bool Function(Widget) matches) {
  final found = <Element>[];
  void visit(Element e) {
    if (matches(e.widget)) found.add(e);
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<void> _wait(bool Function() ready, String code) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    _expect(clock.elapsed < const Duration(seconds: 30), code);
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<String> _run() async {
  final directory =
      Platform.environment['BUSYAPI_FILE_CONTROLS_DIRECTORY'] ?? '';
  _expect(
    RegExp(r'^/tmp/busyapi-file-controls-[A-Za-z0-9_-]+$').hasMatch(directory),
    'fixture-boundary',
  );
  final version =
          Platform.environment['BUSYAPI_FILE_CONTROLS_VERSION'] ?? '3.2.1',
      format = Platform.environment['BUSYAPI_FILE_CONTROLS_FORMAT'] ?? 'yaml',
      maintenance =
          Platform.environment['BUSYAPI_FILE_CONTROLS_SECURITY'] ?? '',
      selection =
          Platform.environment['BUSYAPI_FILE_CONTROLS_SECURITY_SELECTION'] ??
          '',
      memberNames =
          Platform.environment['BUSYAPI_FILE_CONTROLS_MEMBER_NAMES'] ?? '',
      responseStatus =
          Platform.environment['BUSYAPI_FILE_CONTROLS_RESPONSE_STATUS'] == '1';
  _expect(
    ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1'].contains(version) &&
        ['yaml', 'json'].contains(format),
    'fixture-version-format',
  );
  _expect(
    ['', 'named', 'uri'].contains(maintenance) &&
        (maintenance != 'uri' || version.startsWith('3.2.')),
    'fixture-security-mode',
  );
  _expect(
    ['', 'named', 'uri'].contains(selection) &&
        (selection != 'uri' || version.startsWith('3.2.')) &&
        (selection.isEmpty || maintenance.isEmpty),
    'fixture-security-selection-mode',
  );
  final swagger = version == '2.0',
      declaration = swagger ? 'swagger' : 'openapi',
      json = format == 'json',
      createdName = 'created.$format',
      unusedName = 'unused.$format';
  _expect(
    ['', 'empty', 'unicode'].contains(memberNames) &&
        (memberNames.isEmpty || swagger && maintenance == 'named'),
    'fixture-member-name-mode',
  );
  final originalName = memberNames == 'unicode' ? 'clé/雪 ~😀 #?%' : 'Old',
      renamedName = memberNames.isEmpty ? '__proto__' : '';
  final sourceDirectory = Directory('$directory/project');
  _expect(!sourceDirectory.existsSync(), 'project-collision');
  await sourceDirectory.create();
  final root = File('${sourceDirectory.path}/api.$format'),
      unused = File('${sourceDirectory.path}/$unusedName'),
      created = File('${sourceDirectory.path}/$createdName');
  _expect(
    !root.existsSync() && !unused.existsSync() && !created.existsSync(),
    'fixture-collision',
  );
  final binding = maintenance == 'uri'
      ? '#/components/securitySchemes/Old'
      : originalName;
  final securitySource =
      '${json ? '' : '# retained security source\r\n'}${jsonEncode({
        declaration: version,
        'info': {'title': 'Native security 雪😀', 'version': '1'},
        'paths': <String, Object?>{},
        'security': [
          {binding: <String>[]},
        ],
        if (swagger) 'securityDefinitions': {
            originalName: {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
            if (selection.isNotEmpty) 'New': {'type': 'apiKey', 'in': 'header', 'name': 'X-New'},
          } else 'components': {
            'securitySchemes': {
              'Old': {'type': 'apiKey', 'in': 'header', 'name': 'X-Key'},
              if (selection.isNotEmpty) 'New': {'type': 'apiKey', 'in': 'header', 'name': 'X-New'},
              if (selection == 'uri') 'Remote': {r'$ref': 'security.json#/Remote'},
            },
          },
        'x-example': {r'$ref': 'literal', 'large': '__exact__'},
      }).replaceAll('"__exact__"', '9007199254740993.00')}\r\n';
  final responseSource =
      '${json ? '' : '# retained response source\r\n'}${jsonEncode({
        declaration: version,
        'info': {'title': 'Native responses 雪😀', 'version': '1'},
        'paths': {
          '/items': {
            'get': {
              'responses': {
                '201': {'description': 'Kept response'},
              },
            },
          },
          '/consumer': {
            'get': {
              'responses': {
                '200': {r'$ref': '#/paths/~1items/get/responses/201'},
              },
            },
          },
        },
        'x-literal': {r'$ref': '#/paths/~1items/get/responses/201', 'number': 'EXACT'},
      }).replaceFirst('"EXACT"', '9007199254740993.00')}\r\n';
  final rootBytes = utf8.encode(
        responseStatus
            ? '\ufeff$responseSource'
            : maintenance.isNotEmpty || selection.isNotEmpty
            ? '\ufeff$securitySource'
            : json
            ? '\ufeff{\r\n "$declaration":"$version","info":{"title":"Native 雪😀","version":"1"},\n'
                  ' "paths":{},"x-example":{"\$ref":"literal","large":9007199254740993.00}}'
            : '\ufeff$declaration: ${swagger ? "'2.0'" : version}\r\ninfo: {title: "Native 雪😀", version: "1"}\n'
                  'paths: {}\r\nx-example: {"\$ref": "literal", large: 9007199254740993.00}',
      ),
      unusedBytes = utf8.encode(
        json
            ? '\ufeff{\r\n "Value":{"type":"string","description":"preserved 雪😀"},\n "x-data":1.000}\r\n'
            : '\ufeff# preserved 雪😀\r\nValue: {type: string}\nx-data: 1.000\n',
      );
  await root.writeAsBytes(rootBytes, flush: true);
  await unused.writeAsBytes(unusedBytes, flush: true);
  final manifest = File('${sourceDirectory.path}/busyapi.yaml');
  final configuration =
      '''version: 1
# retained environment settings
roots: [{name: api, path: api.$format}]
environments:
  manual:
    authentication:
      schemes:
        ${jsonEncode(binding)}: {secretRef: '11111111-1111-4111-8111-111111111111'} # retained reference
''';
  if (maintenance.isNotEmpty || selection.isNotEmpty) {
    await manifest.writeAsString(configuration, flush: true);
  }
  final externalSecurity = File('${sourceDirectory.path}/security.json');
  const externalSecuritySource =
      '{"Remote":{"type":"apiKey","in":"header","name":"X-Remote"}}';
  if (selection == 'uri') {
    await externalSecurity.writeAsString(externalSecuritySource, flush: true);
  }
  await application.main([sourceDirectory.path]);
  WorkspaceController? owner;
  await _wait(() {
    for (final e in _elements((w) => w is BusyApiApp)) {
      owner = (e.widget as BusyApiApp).controller;
    }
    return owner?.project != null && owner?.root != null;
  }, 'open-timeout');
  final controller = owner!, project = controller.project!;
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final pointerEvents = <Map<String, Object?>>[];
  var observingClick = false;
  void observePointer(PointerEvent event) {
    if (!observingClick ||
        pointerEvents.length >= 16 ||
        event is! PointerDownEvent && event is! PointerUpEvent) {
      return;
    }
    pointerEvents.add({
      'type': event.runtimeType.toString(),
      'point': [event.position.dx, event.position.dy],
      'buttons': event.buttons,
    });
  }

  GestureBinding.instance.pointerRouter.addGlobalRoute(observePointer);
  var step = 0;
  Future<void> send(Map<String, Object> action) async {
    final current = ++step;
    observingClick = action['kind'] == 'click';
    pointerEvents.clear();
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_INPUT ${jsonEncode({'version': 1, 'step': current, ...action})}',
    );
    _expect(
      await input.moveNext().timeout(const Duration(seconds: 30)) &&
          input.current == 'ack:$current',
      'input-owner',
    );
    if (observingClick) {
      stdout.writeln(
        'BUSYAPI_NATIVE_POINTER ${jsonEncode({'requested': action['point'], 'scale': action['scale'], 'viewport': action['viewport'], 'observed': pointerEvents})}',
      );
    }
    observingClick = false;
  }

  Future<void> click(
    bool Function(Widget) matches,
    String code, {
    bool editable = false,
    bool designOnly = false,
  }) async {
    List<Element> mountedCandidates() => _elements(matches)
        .where(
          (element) =>
              !designOnly ||
              element.findAncestorWidgetOfExactType<Designer>() != null &&
                  element.findAncestorWidgetOfExactType<AuthoredSchemaTree>() ==
                      null,
        )
        .toList();
    try {
      await _wait(
        () => mountedCandidates().length == 1,
        '$code-mounted-unique',
      );
    } on Object {
      stdout.writeln(
        'BUSYAPI_NATIVE_TARGET ${jsonEncode([
          for (final element in mountedCandidates()) (() {
              final chain = <String>[];
              element.visitAncestorElements((parent) {
                chain.add(parent.widget.runtimeType.toString());
                return chain.length < 18;
              });
              return {'ancestors': chain, 'currentRoute': ModalRoute.of(element)?.isCurrent};
            })(),
        ])}',
      );
      rethrow;
    }
    await WidgetsBinding.instance.endOfFrame;
    final candidates = mountedCandidates();
    _expect(candidates.length == 1, '$code-unique-${candidates.length}');
    var target = candidates.single;
    if (editable) {
      final inputs = <Element>[];
      void visit(Element e) {
        if (e.widget is EditableText) inputs.add(e);
        e.visitChildren(visit);
      }

      target.visitChildren(visit);
      _expect(inputs.length == 1, '$code-input-unique');
      target = inputs.single;
    }
    await Scrollable.ensureVisible(
      target,
      alignment: 0.4,
      duration: Duration.zero,
    );
    await WidgetsBinding.instance.endOfFrame;
    final box = target.findRenderObject();
    _expect(box is RenderBox && box.hasSize, '$code-geometry');
    final render = box as RenderBox,
        point = render.localToGlobal(render.size.center(Offset.zero));
    await send({
      'kind': 'click',
      'point': [point.dx, point.dy],
      'scale': View.of(target).devicePixelRatio,
      'viewport': [
        View.of(target).physicalSize.width,
        View.of(target).physicalSize.height,
      ],
    });
    if (editable) {
      await _wait(
        () =>
            target.mounted &&
            target.widget is EditableText &&
            (target.widget as EditableText).focusNode.hasFocus,
        '$code-focused',
      );
    }
  }

  Future<void> button(String label) => click(
    (w) => w is BusyApiDialogButton && w.label == label,
    'dialog-button',
  );
  Future<void> keys(List<String> chords) =>
      send({'kind': 'keys', 'chords': chords});
  List<String> ascii(String value) => value.split('').map((character) {
    if (RegExp(r'^[a-z0-9]$').hasMatch(character)) return character;
    if (RegExp(r'^[A-Z]$').hasMatch(character)) {
      return 'Shift_L+${character.toLowerCase()}';
    }
    return switch (character) {
      ' ' => 'space',
      '.' => 'period',
      '/' => 'slash',
      ':' => 'Shift_L+semicolon',
      '-' => 'minus',
      '_' => 'Shift_L+minus',
      '@' => 'Shift_L+2',
      '{' => 'Shift_L+bracketleft',
      '}' => 'Shift_L+bracketright',
      '[' => 'bracketleft',
      ']' => 'bracketright',
      '"' => 'Shift_L+apostrophe',
      ',' => 'comma',
      '#' => 'Shift_L+3',
      r'$' => 'Shift_L+4',
      _ => throw StateError('unsupported-fixture-key'),
    };
  }).toList();
  Future<void> entry(String label, String value, {bool dialog = false}) async {
    if (!dialog) {
      await _wait(
        () =>
            !controller.checking &&
            controller.projection?['info']?['generation'] ==
                project.store.get(root.uri.toString()).generation &&
            controller.draft?.buffer ==
                (controller.selectedResource ?? controller.root) &&
            controller.draft?.pointer == controller.selectedPointer,
        'native-field-current-model',
      );
    }
    stdout.writeln(
      'BUSYAPI_NATIVE_FIELD ${jsonEncode({'label': label, 'dialog': dialog, 'pointer': controller.selectedPointer, 'checking': controller.checking})}',
    );
    await click(
      (w) => dialog
          ? w is FormValueEditor && w.label == label && w.enabled
          : w is BusyApiGroupedTextEntry && w.label == label && !w.readOnly,
      'authoring-field',
      editable: true,
    );
    await keys([
      'Control_L+a',
      if (value.isEmpty) 'BackSpace',
      ...ascii(value),
      if (!dialog) 'Return',
    ]);
    try {
      await _wait(
        () =>
            _elements((w) => w is EditableText && w.controller.text == value)
                .isNotEmpty,
        'authoring-input-$label',
      );
    } on Object {
      stdout.writeln(
        'BUSYAPI_NATIVE_INPUT_STATE ${jsonEncode({
          'label': label,
          'expectedLength': value.length,
          'pointer': controller.selectedPointer,
          'checking': controller.checking,
          'fields': [
            for (final e in _elements((w) => w is EditableText)) {'length': (e.widget as EditableText).controller.text.length, 'focused': (e.widget as EditableText).focusNode.hasFocus, 'readOnly': (e.widget as EditableText).readOnly, 'composing': (e.widget as EditableText).controller.value.composing.isValid && !(e.widget as EditableText).controller.value.composing.isCollapsed},
          ],
        })}',
      );
      rethrow;
    }
    if (!dialog) {
      await _wait(
        () =>
            !controller.hasPendingFields &&
            !controller.checking &&
            controller.projection?['info']?['generation'] ==
                project.store.get(root.uri.toString()).generation,
        'authoring-commit-current-model',
      );
    }
  }

  Future<void> row(String title) => click(
    (w) => w is BusyApiActionRow && w.title == title && w.onTap != null,
    'authoring-action-$title',
    designOnly: true,
  );
  Future<void> choose(String title, String label) async {
    if (controller.form == null) {
      bool hasInlineFields() =>
          _elements((w) => w is BusyApiGroupedTextEntry && !w.readOnly).any(
            (element) =>
                element.findAncestorWidgetOfExactType<Designer>() != null &&
                element.findAncestorWidgetOfExactType<AuthoredSchemaTree>() ==
                    null,
          );
      bool currentModel() =>
          !controller.checking &&
          controller.projection?['info']?['generation'] ==
              project.store.get(root.uri.toString()).generation &&
          (!hasInlineFields() ||
              controller.draft?.buffer ==
                      (controller.selectedResource ?? controller.root) &&
                  controller.draft?.pointer == controller.selectedPointer);
      if (!currentModel()) {
        stdout.writeln(
          'BUSYAPI_NATIVE_COMBO_WAIT ${jsonEncode({'field': title, 'checking': controller.checking, 'currentGeneration': controller.projection?['info']?['generation'] == project.store.get(root.uri.toString()).generation})}',
        );
      }
      // A field becomes clean before its durable checkpoint and subsequent
      // current projection finish. Opening an old frame's menu in between
      // correctly retires that stale menu when controls reconcile. Observe
      // the completed model before the next action. A page with only a type
      // selector (such as a new Swagger security scheme) has no inline draft.
      await _wait(currentModel, 'native-combo-current-model');
    }
    await _wait(
      () => _elements(
        (w) => w is BusyApiComboRow<String> && w.title == title && w.enabled,
      ).isNotEmpty,
      'native-combo-mounted',
    );
    final matches = _elements(
      (w) => w is BusyApiComboRow<String> && w.title == title,
    );
    _expect(matches.length == 1, 'native-combo-unique');
    final combo = matches.single.widget as BusyApiComboRow<String>;
    final index = combo.values.indexWhere(
      (value) => combo.labelFor(value) == label,
    );
    _expect(index >= 0 && combo.enabled, 'native-combo-choice');
    await click(
      (w) => w is BusyApiComboRow<String> && w.title == title,
      'native-combo',
    );
    await send({'kind': 'menu-ready'});
    await keys(['Home', for (var i = 0; i < index; i++) 'Down', 'Return']);
    await _wait(
      () => _elements(
        (w) =>
            w is BusyApiComboRow<String> &&
            w.title == title &&
            w.labelFor(w.selected) == label,
      ).isNotEmpty,
      'native-combo-selected',
    );
  }

  Future<void> headerMenu(String tooltip, String label) async {
    await _wait(
      () =>
          _elements(
            (w) =>
                w is BusyApiHeaderPopupMenuButton<String> &&
                w.tooltip == tooltip,
          ).length ==
          1,
      'native-header-menu-unique',
    );
    final element = _elements(
      (w) => w is BusyApiHeaderPopupMenuButton<String> && w.tooltip == tooltip,
    ).single;
    final menu = element.widget as BusyApiHeaderPopupMenuButton<String>;
    final entries = (await menu.itemBuilder(element))
        .whereType<BusyApiPopupMenuItem<String>>()
        .where((entry) => entry.enabled)
        .toList();
    final index = entries.indexWhere((entry) => entry.label == label);
    _expect(index >= 0, 'native-header-menu-choice');
    await click(
      (w) => w is BusyApiHeaderPopupMenuButton<String> && w.tooltip == tooltip,
      'native-header-menu',
    );
    await send({'kind': 'menu-ready'});
    await keys(['Home', for (var i = 0; i < index; i++) 'Down', 'Return']);
  }

  bool selectedPageMounted() {
    final operation = (controller.projection?['operations'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where(controller.isSelected)
        .firstOrNull;
    if (controller.selectedPointer != '/info' &&
        (operation == null ||
            controller.specification?.family ==
                SpecificationFamily.swagger20)) {
      final identity = (
        controller.root,
        controller.selectedResource,
        controller.selectedPointer,
      );
      return _elements(
            (w) =>
                w is! AuthoredSchemaTree &&
                w.key is ValueKey &&
                (w.key as ValueKey).value == identity,
          ).length ==
          1;
    }
    final heading = operation == null
        ? 'Overview'
        : '${operation['method'].toString().toUpperCase()} ${operation['path']}';
    return _elements((w) => w is Text && w.data == heading)
            .where(
              (element) =>
                  element.findAncestorWidgetOfExactType<Designer>() != null &&
                  (element.widget as Text).style ==
                      Theme.of(element).textTheme.headlineSmall,
            )
            .length ==
        1;
  }

  Future<void> addEntry([String? name]) async {
    final parent = controller.selectedPointer;
    await row('Add entry');
    if (name != null) await entry('Name', name, dialog: true);
    await button('Apply');
    await _wait(
      () =>
          controller.form == null &&
          !controller.formApplying &&
          controller.selectedPointer != parent,
      'native-entry-close-and-selection',
    );
    // Selection changes before its current-generation object page replaces
    // the previous frame. Do not locate the next action in that old page.
    await _wait(
      () =>
          !controller.checking &&
          controller.projection?['info']?['generation'] ==
              project.store.get(root.uri.toString()).generation &&
          selectedPageMounted(),
      'native-entry-current-model',
    );
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> data(String field, String raw) async {
    await row(field);
    await entry('JSON-compatible data value', raw, dialog: true);
    await button('Apply');
    await _wait(() => controller.form == null, 'native-data-close');
  }

  Future<void> review(String title) async {
    await _wait(
      () => _elements((w) => w is Text && w.data == title).isNotEmpty,
      'native-refactoring-review',
    );
    await button('Apply');
    await _wait(
      () => _elements((w) => w is Text && w.data == title).isEmpty,
      'native-refactoring-close',
    );
  }

  Future<void> route(String pointer) async {
    // Route selection is not authoring or a navigator acceptance shortcut.
    // Only the real native inputs below may mutate the captured document.
    // form is cleared at transaction start, before publication/recovery and
    // modal dismissal finish. Navigation is not yet eligible in that frame.
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'route-form-completion',
    );
    controller.setMode('Design');
    await controller.selectObject({
      'root': controller.root,
      'resource': root.uri.toString(),
      'pointer': pointer,
      'range': [0, 0],
    });
    controller.setMode('Design');
    await _wait(() => !controller.checking, 'authoring-snapshot');
    await _wait(selectedPageMounted, 'native-selected-page-mounted');
  }

  Future<void> exerciseSource({
    required String modelPointer,
    required String modelReference,
    required File movedFile,
    required String movedReference,
    String movedPointer = '',
  }) async {
    await route(modelPointer);
    await headerMenu('View mode', 'Source');
    await _wait(() => controller.mode == 'Source', 'native-source-mounted');
    await _wait(
      () => _elements((w) => w is SourceEditor).length == 1,
      'native-source-control-mounted',
    );
    final sourceElements = _elements((w) => w is SourceEditor);
    _expect(sourceElements.length == 1, 'native-source-owner');
    final initialSourceState =
        (sourceElements.single as StatefulElement).state as SourceEditorState;
    SourceEditorState liveSource() {
      final active = _elements(
        (w) =>
            w is SourceEditor &&
            identical(w.buffer, controller.buffer) &&
            (w.isCurrent?.call() ?? true),
      );
      _expect(active.length == 1, 'native-source-current-owner');
      return (active.single as StatefulElement).state as SourceEditorState;
    }

    final beforeCompletion = controller.buffer!.text;
    final modelScope = await project.inspectObject(
      controller.root!,
      root.uri.toString(),
      modelPointer,
    );
    _expect(
      modelScope['generation'] == controller.buffer!.generation,
      'native-completion-captured-owner',
    );
    final modelRange = (modelScope['range'] as List).cast<int>();
    final stringType = RegExp(r'(?:"type"\s*:\s*"|type:\s*)(string)')
        .firstMatch(beforeCompletion.substring(modelRange[0], modelRange[1]));
    _expect(stringType != null, 'native-completion-context');
    liveSource().reveal(modelRange[0] + stringType!.end - 3);
    await keys(['Control_L+space']);
    await _wait(
      () =>
          _elements((w) => w.key == const ValueKey('source-assistance-popup'))
              .isNotEmpty &&
          _elements((w) => w is Text && w.data == 'object').isNotEmpty,
      'native-completion-popup',
    );
    await keys(['Return']);
    await _wait(
      () => controller.buffer!.text != beforeCompletion,
      'native-completion-accepted',
    );
    final completed = controller.buffer!.text;
    await keys(['Control_L+z']);
    await _wait(
      () => controller.buffer!.text == beforeCompletion,
      'native-completion-one-undo',
    );
    await keys(['Control_L+Shift_L+z']);
    await _wait(
      () => controller.buffer!.text == completed,
      'native-completion-one-redo',
    );
    await keys(['Control_L+z']);
    await _wait(
      () => controller.buffer!.text == beforeCompletion,
      'native-completion-restore',
    );
    liveSource().reveal(controller.buffer!.text.indexOf('title') + 2);
    await keys(['F1']);
    await _wait(
      () => _elements(
        (w) => w is Text && w.data?.startsWith('Authored title') == true,
      ).isNotEmpty,
      'native-field-help-origin',
    );
    await keys(['Escape']);
    final referenceOffset = controller.buffer!.text.indexOf(modelReference);
    _expect(referenceOffset >= 0, 'native-definition-reference');
    final modelDefinition = await project.inspectObject(
      controller.root!,
      root.uri.toString(),
      modelPointer,
    );
    final modelStart = (modelDefinition['range'] as List).first as int;
    liveSource().reveal(referenceOffset + 4);
    await keys(['Control_L+b']);
    await _wait(
      () =>
          controller.active == root.uri.toString() &&
          controller.mode == 'Source' &&
          controller.buffer!.selection.base == modelStart &&
          controller.buffer!.selection.extent == modelStart,
      'native-go-to-definition',
    );
    stdout.writeln(
      'BUSYAPI_NATIVE_SOURCE_OWNER ${jsonEncode({'initialMounted': initialSourceState.mounted, 'replaced': !identical(initialSourceState, liveSource()), 'checking': controller.checking})}',
    );
    liveSource().reveal(0);
    await _wait(
      () => _elements(
        (w) =>
            w is BusyApiCompactIconButton &&
            w.tooltip.startsWith('Fold source section at line ') &&
            w.onPressed != null,
      ).isNotEmpty,
      'native-fold-control',
    );
    final foldKey = _elements(
      (w) =>
          w is BusyApiCompactIconButton &&
          w.tooltip.startsWith('Fold source section at line ') &&
          w.onPressed != null,
    ).first.widget.key;
    await click(
      (w) => w is BusyApiCompactIconButton && w.key == foldKey,
      'native-fold',
    );
    await _wait(
      () => controller
          .sourceFolds(controller.root!, root.uri.toString())
          .isNotEmpty,
      'native-fold-view-state',
    );
    await keys(['Control_L+a', 'Control_L+c']);
    final copied = await Clipboard.getData(Clipboard.kTextPlain);
    _expect(
      copied?.text ==
              beforeCompletion
                  .replaceAll('\r\n', '\n')
                  .replaceAll('\r', '\n') &&
          controller.buffer!.text == beforeCompletion,
      'native-fold-full-document-copy',
    );
    final headerReference = controller.buffer!.text.indexOf(movedReference);
    _expect(headerReference >= 0, 'native-cross-file-reference');
    final movedDefinition = await project.inspectObject(
      controller.root!,
      movedFile.uri.toString(),
      movedPointer,
    );
    final movedStart = (movedDefinition['range'] as List).first as int;
    liveSource().reveal(headerReference + 5);
    await keys(['Control_L+b']);
    await _wait(
      () =>
          controller.active == movedFile.uri.toString() &&
          controller.mode == 'Source' &&
          controller.buffer!.selection.base == movedStart &&
          controller.buffer!.selection.extent == movedStart,
      'native-cross-file-definition',
    );
  }

  Future<void> history(
    String before,
    String after,
    String code, {
    bool restore = false,
  }) async {
    _expect(before != after, '$code-changed');
    String current() => project.store.get(root.uri.toString()).text;
    await keys(['Control_L+z']);
    await _wait(() => current() == before, '$code-one-undo');
    await keys(['Control_L+Shift_L+z']);
    await _wait(() => current() == after, '$code-one-redo');
    if (restore) {
      await keys(['Control_L+z']);
      await _wait(() => current() == before, '$code-restore');
    }
  }

  Future<void> stringEntry(String value) async {
    await row('Add entry');
    await entry('Text value', value, dialog: true);
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'native-string-entry-close',
    );
  }

  Future<void> exerciseSwagger() async {
    await route('/info');
    await entry('Title', 'Native accepted');
    await entry('API version', '2');
    await row('Contact');
    await entry('Name', 'Native owner');
    await entry('email', 'native@example.test');
    await route('/info');
    await row('License');
    await entry('Name', 'Example licence');
    await entry('url', 'https://example.test/licence');
    await route('');
    await entry('host', 'example.test');
    await entry('basePath', '/v1');
    for (final (field, value) in [
      ('schemes', 'https'),
      ('consumes', 'application/json'),
      ('produces', 'application/json'),
    ]) {
      await route('');
      await row(field);
      await stringEntry(value);
    }
    await route('');
    await row('Tags');
    await addEntry();
    await entry('Name', 'General');
    await entry('Description', 'Native tag');

    await route('');
    await row('definitions');
    await addEntry('Model');
    await choose('Type', 'object');
    await row('Properties');
    await addEntry('name');
    await choose('Type', 'string');
    await entry('Description', 'Native property');
    await route('/definitions/Model/properties');
    await click(
      (w) => w is BusyApiSwitchRow && w.title == 'Required',
      'swagger-required-property',
    );
    await _wait(
      () => _elements(
        (w) => w is BusyApiSwitchRow && w.title == 'Required' && w.value,
      ).isNotEmpty,
      'swagger-required-authored',
    );
    await addEntry('next');
    await entry(r'$ref', '#/definitions/Model');
    await route('/definitions/Model');
    await row('allOf');
    await addEntry();
    await choose('Type', 'object');
    await entry('Description', 'Authored composition branch');

    await route('');
    await row('securityDefinitions');
    await addEntry('ApiKey');
    await choose('Type', 'apiKey');
    await entry('Name', 'X-Native-Key');
    await choose('in', 'header');
    await route('/securityDefinitions');
    await addEntry('Basic');
    await choose('Type', 'basic');
    await route('/securityDefinitions');
    await addEntry('OAuth');
    await choose('Type', 'oauth2');
    await choose('flow', 'application');
    await entry('tokenUrl', 'https://example.test/token');
    await row('scopes');
    await addEntry('read');
    await route('/securityDefinitions/OAuth/scopes');
    await row('read');
    await entry('Text value', 'Read example data', dialog: true);
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'swagger-scope-close',
    );
    await route('');
    await row('Security');
    await row('Add scheme alternative (OR)');
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'swagger-security-or-close',
    );
    await row('Alternative 1');
    await row('Add combined scheme (AND)');
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'swagger-security-and-close',
    );
    await route('/security');
    await row('Add scheme alternative (OR)');
    await choose('Security scheme definition', 'Basic · api.$format');
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'swagger-security-second-close',
    );

    await route('/info');
    await row('Add Operation');
    await entry('Path', '/native', dialog: true);
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'swagger-operation-close',
    );
    await entry('Summary', 'Native operation');
    await entry('operationId', 'nativeOperation');
    await row('Parameters');
    await addEntry();
    await entry('Name', 'limit');
    await choose('in', 'query');
    await choose('Type', 'integer');
    await route('/paths/~1native/get/parameters');
    await addEntry();
    await entry('Name', 'payload');
    await choose('in', 'body');
    await choose('Required', 'true');
    await row('schema');
    await entry(r'$ref', '#/definitions/Model');
    await route('/paths/~1native/get');
    await row('Responses');
    await addEntry('204');
    await entry('Description', 'Bodyless native response');
    await route('/paths/~1native/get/responses');
    await addEntry('200');
    await entry('Description', 'Native response');
    await row('Headers');
    await addEntry('X-Trace');
    await choose('Type', 'string');
    await entry('Description', 'Native response header');
    await route('/paths/~1native/get/responses/200');
    await row('schema');
    await entry(r'$ref', '#/definitions/Model');
    await route('/paths/~1native/get/responses/200');
    await data(
      'Examples',
      r'{"application/json":{"name":"Model","$ref":"literal data","large":900719925474099312345678901.00}}',
    );

    await route('/paths');
    await addEntry('/upload');
    await row('post');
    await entry('Summary', 'Native upload');
    await row('consumes');
    await stringEntry('multipart/form-data');
    await route('/paths/~1upload/post');
    await row('Parameters');
    await addEntry();
    await entry('Name', 'asset');
    await choose('in', 'formData');
    await choose('Type', 'file');
    await choose('Required', 'true');
    await route('/paths/~1upload/post/parameters');
    await addEntry();
    await entry('Name', 'tags');
    await choose('in', 'formData');
    await choose('Type', 'array');
    await choose('collectionFormat', 'multi');
    await row('items');
    await choose('Type', 'string');
    await route('/paths/~1upload/post');
    await row('Responses');
    await addEntry('204');
    await entry('Description', 'Bodyless upload response');

    await route('/definitions/Model');
    final beforeRename = controller.buffer!.text;
    await row('Rename component');
    await entry('Name', 'Renamed', dialog: true);
    await button('Apply');
    await review('Review refactoring');
    final renamed = controller.buffer!.text;
    _expect(
      renamed.contains('#/definitions/Renamed') &&
          !renamed.contains('#/definitions/Model'),
      'swagger-rename-recursive-consumers',
    );
    await history(beforeRename, renamed, 'swagger-rename', restore: true);
    await route('/definitions/Model');
    await row('Add schema keyword');
    await choose('Name', 'discriminator');
    await button('Apply');
    await entry('JSON-compatible data value', '"name"', dialog: true);
    await button('Apply');
    await _wait(
      () => controller.form == null && !controller.formApplying,
      'swagger-discriminator-close',
    );
    await route('/paths/~1native/get/responses/200');
    final beforeExtraction = controller.buffer!.text;
    await row('Extract to component…');
    await entry('Name', 'SharedResponse', dialog: true);
    await button('Apply');
    await review('Review component extraction');
    final extracted = controller.buffer!.text;
    _expect(
      extracted.contains('#/responses/SharedResponse'),
      'swagger-native-response-reference',
    );
    await history(beforeExtraction, extracted, 'swagger-extract');
    await route('/paths/~1native/get/responses/200');
    await row('Inline this occurrence…');
    await review('Review reference inlining');
    final inlined = controller.buffer!.text;
    await history(extracted, inlined, 'swagger-inline');
    await route('/responses/SharedResponse');
    await row('Delete object…');
    await review('Review object deletion');
    await history(
      inlined,
      controller.buffer!.text,
      'swagger-definition-delete',
    );
    await route('/paths/~1native/get/responses/200');
    await row('Extract to component…');
    await entry('Name', 'ResponseFile', dialog: true);
    await choose('Component destination', 'New source file…');
    await button('Apply');
    await entry('Destination path', 'responses.$format', dialog: true);
    await button('Apply');
    await review('Review extraction to source file');
    final responseFile = File('${sourceDirectory.path}/responses.$format');
    final moved = File('${sourceDirectory.path}/moved-responses.$format');
    _expect(
      !responseFile.existsSync() &&
          project.store.buffers.containsKey(responseFile.uri.toString()),
      'swagger-extract-virtual-file',
    );
    await headerMenu('Sidebar view', 'Files');
    await _wait(
      () =>
          _elements(
            (w) =>
                w is BusyApiSidebarRecordRow<String> &&
                w.title == 'responses.$format',
          ).length ==
          1,
      'swagger-response-file-mounted',
    );
    final sourceRow = _elements(
      (w) =>
          w is BusyApiSidebarRecordRow<String> &&
          w.title == 'responses.$format',
    );
    _expect(sourceRow.length == 1, 'swagger-response-file-row');
    Element? fileMenu;
    void locate(Element e) {
      if (e.widget case Tooltip(message: 'File actions')) fileMenu = e;
      e.visitChildren(locate);
    }

    sourceRow.single.visitChildren(locate);
    _expect(fileMenu != null, 'swagger-move-menu');
    await click((w) => identical(w, fileMenu!.widget), 'swagger-file-move');
    await keys(['Down', 'Return']);
    await entry('Destination path', 'moved-responses.$format', dialog: true);
    await button('Apply');
    final beforeMove = project.store.get(root.uri.toString()).text;
    await review('Review file move');
    final afterMove = project.store.get(root.uri.toString()).text;
    await history(beforeMove, afterMove, 'swagger-file-move');
    final movedReference = await project.inspectObject(
      controller.root!,
      root.uri.toString(),
      '/paths/~1native/get/responses/200',
    );
    _expect(
      movedReference['value'][r'$ref'] ==
              'moved-responses.$format#/ResponseFile' &&
          !responseFile.existsSync() &&
          !moved.existsSync(),
      'swagger-file-reference-and-publication-boundary',
    );

    await exerciseSource(
      modelPointer: '/definitions/Model',
      modelReference: '#/definitions/Model',
      movedFile: moved,
      movedReference: 'moved-responses.$format',
      movedPointer: '/ResponseFile',
    );
    final checked = await project.check(controller.root!);
    _expect(
      checked['complete'] == true &&
          !(checked['findings'] as List).cast<Map>().any(
            (f) =>
                f['severity'] == 'error' &&
                ['syntax', 'openapi'].contains(f['category']),
          ),
      'swagger-authored-contract-validity',
    );
    final rootObject = await project.inspectObject(
      controller.root!,
      root.uri.toString(),
      '',
    );
    final value = jsonDecode(
      await project.readDataValue(rootObject),
    ) as Map<String, dynamic>;
    _expect(
      value['swagger'] == '2.0' &&
          !value.containsKey('openapi') &&
          !value.containsKey('components') &&
          !value.containsKey('servers'),
      'swagger-native-structure',
    );
    _expect(
      value['host'] == 'example.test' &&
          value['basePath'] == '/v1' &&
          listEquals((value['schemes'] as List).cast<String>(), ['https']),
      'swagger-native-server',
    );
    final model = value['definitions']['Model'] as Map;
    _expect(
      model['discriminator'] == 'name' &&
          model['properties']['next'][r'$ref'] == '#/definitions/Model' &&
          model['allOf'].length == 1 &&
          listEquals((model['required'] as List).cast<String>(), ['name']),
      'swagger-schema-recursion-composition-discriminator',
    );
    final native = value['paths']['/native']['get'] as Map;
    _expect(
      native['parameters'][0]['type'] == 'integer' &&
          native['parameters'][0]['in'] == 'query' &&
          native['parameters'][1]['in'] == 'body' &&
          native['parameters'][1]['schema'][r'$ref'] == '#/definitions/Model' &&
          !(native['responses']['204'] as Map).containsKey('schema') &&
          !native.containsKey('requestBody'),
      'swagger-native-parameter-and-response-shapes',
    );
    final movedObject = await project.inspectObject(
      controller.root!,
      moved.uri.toString(),
      '/ResponseFile',
    );
    final movedValue = jsonDecode(
      await project.readDataValue(movedObject),
    ) as Map<String, dynamic>;
    _expect(
      movedValue['schema'][r'$ref'] == 'api.$format#/definitions/Model',
      'swagger-moved-schema-reference',
    );
    _expect(
      movedValue['headers']['X-Trace']['type'] == 'string' &&
          movedValue['examples']['application/json'][r'$ref'] ==
              'literal data' &&
          utf8
              .decode(project.store.get(moved.uri.toString()).bytes())
              .contains('900719925474099312345678901.00'),
      'swagger-header-example-context-and-exact-source',
    );
    _expect(
      value['securityDefinitions']['Basic']['type'] == 'basic' &&
          value['securityDefinitions']['OAuth']['flow'] == 'application' &&
          value['securityDefinitions']['OAuth']['scopes']['read'] ==
              'Read example data' &&
          value['security'].length == 2,
      'swagger-security',
    );
    final upload = value['paths']['/upload']['post'] as Map;
    _expect(
      upload['parameters'][0]['type'] == 'file' &&
          upload['parameters'][0]['in'] == 'formData' &&
          upload['parameters'][1]['collectionFormat'] == 'multi' &&
          upload['parameters'][1]['items']['type'] == 'string',
      'swagger-file-and-items',
    );
    final authored = project.store.get(root.uri.toString()).bytes();
    _expect(
      utf8.decode(authored).contains('9007199254740993.00') &&
          utf8.decode(authored).contains('literal'),
      'swagger-exact-values',
    );
    await keys(['Control_L+s']);
    await _wait(
      () =>
          listEquals(root.readAsBytesSync(), authored) &&
          moved.existsSync() &&
          controller.publications.pendingFileBuffers(project).isEmpty,
      'swagger-save-publication',
    );
    _expect(
      !responseFile.existsSync() &&
          listEquals(
            moved.readAsBytesSync(),
            project.store.get(moved.uri.toString()).bytes(),
          ),
      'swagger-published-resource-bytes',
    );
    await controller.open(root.path);
    _expect(
      listEquals(controller.buffer!.bytes(), authored),
      'swagger-save-reopen',
    );
    stdout.writeln(
      'BUSYAPI_NATIVE_AUTHORING_PASS native-swagger host-basePath-schemes consumes-produces definitions body-formData-file collectionFormat-items headers-response-examples security-oauth discriminator recursion composition refactoring source history save-reopen swagger=2.0 format=$format',
    );
  }

  try {
    if (responseStatus) {
      const pointer = '/paths/~1items/get/responses/201';
      if (swagger) {
        await route(pointer);
        await row('Rename response status…');
        await entry('Status', '2XX', dialog: true);
        await button('Apply');
        await _wait(
          () => _elements(
            (w) =>
                w is Text &&
                w.data == 'Use default or a status code from 100 to 599.',
          ).isNotEmpty,
          'native-status-family-guidance',
        );
        _expect(
          listEquals(project.store.get(root.uri.toString()).bytes(), rootBytes),
          'native-status-invalid-retained-source',
        );
        await button('Cancel');
        await _wait(
          () => _elements((w) => w is BusyApiDialogShell).isEmpty,
          'native-status-invalid-cancel',
        );
      }
      for (final accept in [false, true]) {
        await route(pointer);
        await row('Rename response status…');
        await entry('Status', '202', dialog: true);
        await button('Apply');
        await _wait(
          () =>
              _elements((w) => w is Text && w.data == 'Review refactoring')
                  .isNotEmpty,
          'native-status-review',
        );
        _expect(
          listEquals(root.readAsBytesSync(), rootBytes) &&
              listEquals(
                project.store.get(root.uri.toString()).bytes(),
                rootBytes,
              ),
          'native-status-review-originals',
        );
        await button(accept ? 'Apply' : 'Cancel');
        await _wait(
          () =>
              _elements((w) => w is Text && w.data == 'Review refactoring')
                  .isEmpty,
          'native-status-review-close',
        );
      }
      await _wait(
        () =>
            !controller.checking &&
            !controller.formApplying &&
            controller.selectedPointer == '/paths/~1items/get/responses/202',
        'native-status-selection',
      );
      final accepted = project.store.get(root.uri.toString()).bytes(),
          text = project.store.get(root.uri.toString()).text;
      final data = jsonDecode(
        text.replaceFirst('# retained response source\r\n', ''),
      ) as Map;
      _expect(
        (data['paths']['/items']['get']['responses'] as Map).containsKey(
              '202',
            ) &&
            !(data['paths']['/items']['get']['responses'] as Map).containsKey(
              '201',
            ) &&
            data['paths']['/consumer']['get']['responses']['200'][r'$ref'] ==
                '#/paths/~1items/get/responses/202' &&
            data['x-literal'][r'$ref'] == '#/paths/~1items/get/responses/201' &&
            text.contains('9007199254740993.00'),
        'native-status-semantic-repair',
      );
      await keys(['Control_L+z']);
      await _wait(
        () => listEquals(
          project.store.get(root.uri.toString()).bytes(),
          rootBytes,
        ),
        'native-status-one-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () => listEquals(
          project.store.get(root.uri.toString()).bytes(),
          accepted,
        ),
        'native-status-one-redo',
      );
      await keys(['Control_L+s']);
      await _wait(
        () =>
            listEquals(root.readAsBytesSync(), accepted) &&
            !project.store.get(root.uri.toString()).dirty,
        'native-status-selected-save',
      );
      _expect(
        listEquals(unused.readAsBytesSync(), unusedBytes),
        'native-status-unrelated-source',
      );
      await controller.open(root.path);
      _expect(
        listEquals(controller.buffer!.bytes(), accepted),
        'native-status-reopen',
      );
      await keys(['Control_L+s']);
      await controller.shutdown();
      _expect(
        listEquals(root.readAsBytesSync(), accepted),
        'native-status-noop-save',
      );
      stdout.writeln(
        'BUSYAPI_NATIVE_RESPONSE_STATUS_PASS openapi=$version format=$format review=references cancel=unchanged history=one-step source=exact',
      );
      return 'response-status=reviewed openapi=$version format=$format';
    }
    if (selection.isNotEmpty) {
      final rootId = root.uri.toString();
      final stages = [
        (
          pointer: '/security/0/Old',
          action: 'Change security binding…',
          value: selection == 'uri' ? 'security.json#/Remote' : 'New',
        ),
        if (selection == 'uri') ...[
          (
            pointer: '/security',
            action: 'Add security scheme by URI…',
            value: '#/components/securitySchemes/New',
          ),
          (
            pointer: '/security/0',
            action: 'Add security scheme by URI…',
            value: '#/components/securitySchemes/Old',
          ),
        ],
      ];
      for (final stage in stages) {
        final before = project.store.get(rootId).bytes();
        for (final accept in [false, true]) {
          await route(stage.pointer);
          await row(stage.action);
          await _wait(
            () =>
                _elements(
                  (w) =>
                      w is BusyApiSearchField &&
                      w.hintText == 'Search compatible definitions',
                ).length ==
                1,
            'security-selection-search',
          );
          await click(
            (w) =>
                w is BusyApiSearchField &&
                w.hintText == 'Search compatible definitions',
            'security-selection-search-field',
            editable: true,
          );
          final query = stage.value.endsWith('/Remote')
              ? 'Remote'
              : stage.value.endsWith('/Old')
              ? 'Old'
              : 'New';
          await keys([
            'Control_L+a',
            for (final character in query.split('')) character,
          ]);
          final label =
              '${selection == 'uri' ? 'URI' : 'Named'} binding: ${stage.value}';
          await _wait(
            () => _elements((w) => w is Text && w.data == label).length == 1,
            'security-selection-loaded',
          );
          await click(
            (w) => w is Text && w.data == label,
            'security-selection-target',
          );
          await _wait(
            () => _elements(
              (w) => w is Text && w.data == 'Review reference change',
            ).isNotEmpty,
            'security-selection-review',
          );
          _expect(
            listEquals(project.store.get(rootId).bytes(), before) &&
                listEquals(root.readAsBytesSync(), rootBytes) &&
                manifest.readAsStringSync() == configuration,
            'security-selection-review-unpublished',
          );
          await button(accept ? 'Apply' : 'Cancel');
          await _wait(
            () => _elements(
              (w) => w is Text && w.data == 'Review reference change',
            ).isEmpty,
            'security-selection-review-close',
          );
          if (!accept) {
            _expect(
              listEquals(project.store.get(rootId).bytes(), before),
              'security-selection-cancel',
            );
          }
        }
        await _wait(
          () =>
              !controller.checking &&
              !controller.formApplying &&
              !listEquals(project.store.get(rootId).bytes(), before),
          'security-selection-accepted',
        );
        final accepted = project.store.get(rootId).bytes();
        await keys(['Control_L+z']);
        await _wait(
          () => listEquals(project.store.get(rootId).bytes(), before),
          'security-selection-one-undo',
        );
        await keys(['Control_L+Shift_L+z']);
        await _wait(
          () => listEquals(project.store.get(rootId).bytes(), accepted),
          'security-selection-one-redo',
        );
      }
      final accepted = project.store.get(rootId).bytes(),
          text = project.store.get(rootId).text;
      final data = jsonDecode(
        text.replaceFirst('# retained security source\r\n', ''),
      ) as Map;
      final security = data['security'] as List;
      _expect(
        selection == 'uri'
            ? security.length == 2 &&
                  security[0]['security.json#/Remote'] is List &&
                  security[0]['#/components/securitySchemes/Old'] is List &&
                  security[1]['#/components/securitySchemes/New'] is List
            : security.length == 1 &&
                  security[0]['New'] is List &&
                  !security[0].containsKey('Old'),
        'security-selection-actual-structure',
      );
      _expect(
        text.contains('9007199254740993.00') &&
            manifest.readAsStringSync() == configuration &&
            (!externalSecurity.existsSync() ||
                externalSecurity.readAsStringSync() == externalSecuritySource),
        'security-selection-preserved-owners',
      );
      await keys(['Control_L+s']);
      await _wait(
        () =>
            listEquals(root.readAsBytesSync(), accepted) &&
            !project.store.get(rootId).dirty,
        'security-selection-selected-save',
      );
      _expect(
        listEquals(unused.readAsBytesSync(), unusedBytes),
        'security-selection-unrelated-source',
      );
      await controller.open(root.path);
      _expect(
        listEquals(controller.buffer!.bytes(), accepted),
        'security-selection-reopen',
      );
      await keys(['Control_L+s']);
      await controller.shutdown();
      _expect(
        listEquals(root.readAsBytesSync(), accepted) &&
            manifest.readAsStringSync() == configuration,
        'security-selection-noop-save',
      );
      stdout.writeln(
        'BUSYAPI_NATIVE_SECURITY_SELECTION_PASS binding=$selection openapi=$version format=$format cancel=unchanged history=one-step source=exact publication=selected-file',
      );
      return 'security-selection=$selection openapi=$version format=$format';
    }
    if (maintenance.isNotEmpty) {
      final configId = manifest.uri.toString(), rootId = root.uri.toString();
      final pointer =
          '${swagger ? '/securityDefinitions' : '/components/securitySchemes'}/${originalName.replaceAll('~', '~0').replaceAll('/', '~1')}';
      for (final accept in [false, true]) {
        await route(pointer);
        await row('Rename component');
        await entry('Name', renamedName, dialog: true);
        await button('Apply');
        await _wait(
          () =>
              _elements((w) => w is Text && w.data == 'Review refactoring')
                  .isNotEmpty,
          'native-security-review',
        );
        _expect(
          listEquals(root.readAsBytesSync(), rootBytes) &&
              manifest.readAsStringSync() == configuration &&
              listEquals(project.store.get(rootId).bytes(), rootBytes),
          'native-security-originals-before-review',
        );
        await _wait(
          () => _elements(
            (w) => w is BusyApiGroupedList && w.title == 'busyapi.yaml',
          ).isNotEmpty,
          'native-security-configuration-reviewed',
        );
        await button(accept ? 'Apply' : 'Cancel');
        await _wait(
          () =>
              _elements((w) => w is Text && w.data == 'Review refactoring')
                  .isEmpty,
          'native-security-review-closed',
        );
        if (!accept) {
          _expect(
            listEquals(project.store.get(rootId).bytes(), rootBytes),
            'native-security-cancel',
          );
        }
      }
      await _wait(
        () =>
            !controller.checking &&
            !controller.formApplying &&
            !listEquals(project.store.get(rootId).bytes(), rootBytes),
        'native-security-accepted',
      );
      final accepted = project.store.get(rootId).bytes(),
          acceptedConfiguration = project.store.get(configId).text;
      _expect(
        (renamedName.isEmpty
                ? RegExp(
                    r'''^\s*(?:""|''):\s*''',
                    multiLine: true,
                  ).hasMatch(acceptedConfiguration)
                : acceptedConfiguration.contains(
                    maintenance == 'uri'
                        ? '#/components/securitySchemes/$renamedName'
                        : renamedName,
                  )) &&
            acceptedConfiguration.contains('# retained reference') &&
            project.store.get(rootId).text.contains('9007199254740993.00'),
        'native-security-bindings-and-exact-source',
      );
      if (memberNames.isNotEmpty) {
        final parsed = jsonDecode(
          project.store
              .get(rootId)
              .text
              .replaceFirst('# retained security source\r\n', ''),
        ) as Map;
        _expect(
          (parsed['securityDefinitions'] as Map).containsKey('') &&
              !(parsed['securityDefinitions'] as Map).containsKey(
                originalName,
              ) &&
              (parsed['security'] as List).single.containsKey(''),
          'native-empty-member-bindings',
        );
      }
      await keys(['Control_L+z']);
      await _wait(
        () =>
            listEquals(project.store.get(rootId).bytes(), rootBytes) &&
            project.store.get(configId).text == configuration,
        'native-security-one-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () =>
            listEquals(project.store.get(rootId).bytes(), accepted) &&
            project.store.get(configId).text == acceptedConfiguration,
        'native-security-one-redo',
      );
      if (json) await controller.openProjectConfiguration();
      await keys(['Control_L+s']);
      await _wait(
        () =>
            listEquals(root.readAsBytesSync(), accepted) &&
            manifest.readAsStringSync() == acceptedConfiguration &&
            !project.store.get(rootId).dirty &&
            !project.store.get(configId).dirty,
        'native-security-selected-file-publication',
      );
      _expect(
        listEquals(unused.readAsBytesSync(), unusedBytes),
        'native-security-unrelated-source',
      );
      await controller.open(root.path);
      _expect(
        listEquals(controller.buffer!.bytes(), accepted),
        'native-security-reopen',
      );
      await keys(['Control_L+s']);
      await controller.shutdown();
      _expect(
        listEquals(root.readAsBytesSync(), accepted) &&
            manifest.readAsStringSync() == acceptedConfiguration,
        'native-security-noop-save',
      );
      stdout.writeln(
        'BUSYAPI_NATIVE_SECURITY_MAINTENANCE_PASS binding=$maintenance openapi=$version format=$format review=two-sources cancel=unchanged history=one-step publication=selected-file exact-source=preserved',
      );
      return 'security=reviewed history=one-step publication=selected-file original-bytes=exact openapi=$version format=$format binding=$maintenance';
    }
    await headerMenu('Sidebar view', 'Files');
    for (final accept in [false, true]) {
      await headerMenu('Sidebar view', 'New source file…');
      await click(
        (w) => w is BusyApiGroupedTextEntry && w.label == 'Destination path',
        'filename',
        editable: true,
      );
      await keys([
        'Control_L+a',
        for (final character in createdName.split(''))
          character == '.' ? 'period' : character,
      ]);
      await _wait(
        () =>
            _elements(
              (w) => w is EditableText && w.controller.text == createdName,
            ).length ==
            1,
        'native-filename-input',
      );
      await button('Apply');
      await _wait(
        () =>
            _elements((w) => w is Text && w.data == 'Review file creation')
                .isNotEmpty,
        'creation-review',
      );
      _expect(!created.existsSync(), 'creation-review-must-not-publish');
      await button(accept ? 'Apply' : 'Cancel');
      await _wait(
        () =>
            _elements((w) => w is Text && w.data == 'Review file creation')
                .isEmpty,
        'creation-review-close',
      );
      if (!accept) {
        _expect(
          !project.store.buffers.containsKey(created.uri.toString()) &&
              !created.existsSync(),
          'cancelled-creation',
        );
      }
    }
    await _wait(
      () =>
          controller.active == created.uri.toString() &&
          controller.mode == 'Source',
      'created-source',
    );
    _expect(controller.buffer!.text.isEmpty, 'no-invented-source');
    await keys(['Control_L+s']);
    await _wait(() => created.existsSync(), 'creation-publication');
    _expect(created.readAsBytesSync().isEmpty, 'empty-source-preserved');
    await keys(['Control_L+z']);
    await _wait(
      () => !project.store.buffers.containsKey(created.uri.toString()),
      'creation-undo',
    );
    _expect(created.existsSync(), 'undo-must-not-publish');
    await keys(['Control_L+Shift_L+z']);
    await _wait(
      () => project.store.buffers.containsKey(created.uri.toString()),
      'creation-redo',
    );
    await _wait(
      () =>
          _elements(
            (w) =>
                w is BusyApiSidebarRecordRow<String> && w.title == unusedName,
          ).length ==
          1,
      'unused-file-row',
    );
    final fileRow = _elements(
      (w) => w is BusyApiSidebarRecordRow<String> && w.title == unusedName,
    ).single;
    Element? menu;
    void findMenu(Element e) {
      if (e.widget case Tooltip(message: 'File actions')) menu = e;
      e.visitChildren(findMenu);
    }

    fileRow.visitChildren(findMenu);
    _expect(menu != null, 'file-menu-mounted');
    final menuBox = menu!.findRenderObject() as RenderBox,
        menuPoint = menuBox.localToGlobal(menuBox.size.center(Offset.zero));
    await send({
      'kind': 'click',
      'point': [menuPoint.dx, menuPoint.dy],
      'scale': View.of(menu!).devicePixelRatio,
      'viewport': [
        View.of(menu!).physicalSize.width,
        View.of(menu!).physicalSize.height,
      ],
    });
    // A pointer-opened GTK menu starts unselected. These are actual native
    // key events, not a mocked platform response or a Dart callback shortcut.
    await keys(['Down', 'Down', 'Return']);
    await _wait(
      () =>
          _elements((w) => w is Text && w.data == 'Review file deletion')
              .isNotEmpty,
      'native-menu-deletion-review',
    );
    _expect(listEquals(unused.readAsBytesSync(), unusedBytes), 'review-bytes');
    await button('Apply');
    await _wait(
      () => !project.store.buffers.containsKey(unused.uri.toString()),
      'deletion-virtual',
    );
    // Apply updates buffers before its durable recovery checkpoint finishes.
    // A still-owned busy modal correctly blocks workspace Undo until it closes.
    await _wait(
      () =>
          _elements((w) => w is Text && w.data == 'Review file deletion')
              .isEmpty,
      'deletion-review-close',
    );
    _expect(unused.existsSync(), 'deletion-must-wait-for-save');
    await keys(['Control_L+z']);
    await _wait(
      () => project.store.buffers.containsKey(unused.uri.toString()),
      'deletion-undo',
    );
    await keys(['Control_L+Shift_L+z']);
    await _wait(
      () => !project.store.buffers.containsKey(unused.uri.toString()),
      'deletion-redo',
    );
    await keys(['Control_L+s']);
    // Physical archival precedes its durable receipt/final acknowledgement.
    // Inspect the receipt only after the existing publication owner finishes.
    await _wait(
      () =>
          !unused.existsSync() &&
          controller.publications.pendingFileBuffers(project).isEmpty,
      'deletion-publication-and-receipt',
    );
    _expect(
      listEquals(root.readAsBytesSync(), rootBytes) &&
          created.readAsBytesSync().isEmpty,
      'source-bytes',
    );
    final receipts = await Directory(
      '${controller.locations.state}/publication/archives',
    ).list().where((entry) => entry.path.endsWith('.json')).toList();
    final archives = <Map>[];
    for (final receipt in receipts) {
      final data = jsonDecode(await File(receipt.path).readAsString()) as Map;
      archives.addAll((data['archives'] as List).cast<Map>());
    }
    _expect(
      archives.any((entry) => entry['sourcePath'] == unused.path),
      'deletion-archive-receipt',
    );
    final archive = archives.lastWhere(
      (entry) => entry['sourcePath'] == unused.path,
    );
    _expect(
      listEquals(
        await File(archive['archive'] as String).readAsBytes(),
        unusedBytes,
      ),
      'deletion-archive-bytes',
    );
    if (Platform.environment['BUSYAPI_FILE_CONTROLS_AUTHORING'] == '1') {
      if (swagger) {
        await exerciseSwagger();
        return 'swagger=2.0 format=$format';
      }
      await route('/info');
      await entry('Title', 'Native accepted');
      await entry('API version', '2');
      await row('Contact');
      await entry('Name', 'Native owner');
      await entry('email', 'native@example.test');
      await route('/info');
      await row('License');
      await entry('Name', 'Example licence');
      await entry('url', 'https://example.test/licence');
      await route('/info');
      await row('Add Operation');
      await entry('Path', '/native', dialog: true);
      await button('Apply');
      await _wait(() => controller.form == null, 'operation-capture-close');
      await entry('Summary', 'Native operation');
      await entry('Operation ID', 'nativeOperation');
      await row('Add response');
      await entry('Status', '204', dialog: true);
      await entry('Description', 'Bodyless native response', dialog: true);
      await button('Apply');
      await _wait(() => controller.form == null, 'response-capture-close');
      await route('');
      await row('Servers');
      await row('Add entry');
      await entry(
        'Server URL template',
        'https://example.test/{region}',
        dialog: true,
      );
      await button('Apply');
      await _wait(() => controller.form == null, 'server-capture-close');
      await row('variables');
      await row('Add entry');
      await entry('Name', 'region', dialog: true);
      await button('Apply');
      await _wait(() => controller.form == null, 'variable-capture-close');
      await entry('default', 'west');
      // The remaining object families use the same production object pages,
      // native GTK menus and captured forms. No source/model mutation is used
      // to construct the contract: route() only selects already-authored nodes.
      await route('');
      await row('Tags');
      await addEntry();
      await entry('Name', 'General');
      await entry('Description', 'Native tag');
      await route('');
      await row('components');
      await row('Schemas');
      await addEntry('Model');
      await choose('Type', 'object');
      await row('Properties');
      await addEntry('name');
      await choose('Type', 'string');
      await entry('Description', 'Native property');
      await route('/components/schemas/Model/properties');
      await click(
        (w) => w is BusyApiSwitchRow && w.title == 'Required',
        'native-required-membership',
      );
      await _wait(
        () => _elements(
          (w) => w is BusyApiSwitchRow && w.title == 'Required' && w.value,
        ).isNotEmpty,
        'native-required-membership-authored',
      );
      await addEntry('next');
      await entry(r'$ref', '#/components/schemas/Model');
      await route('/components/schemas/Model');
      await row('allOf');
      await addEntry();
      await choose('Type', 'object');
      await entry('Description', 'Authored composition branch');

      await route('/components');
      await row('securitySchemes');
      await addEntry('ApiKey');
      await choose('Type', 'apiKey');
      await entry('Name', 'X-Native-Key');
      await choose('in', 'header');
      await route('/components/securitySchemes');
      await addEntry('Bearer');
      await choose('Type', 'http');
      await entry('scheme', 'bearer');
      await route('/components/securitySchemes');
      await addEntry('OAuth');
      await choose('Type', 'oauth2');
      await row('flows');
      await row('clientCredentials');
      await entry('tokenUrl', 'https://example.test/token');
      await row('scopes');
      await addEntry('read');
      await route(
        '/components/securitySchemes/OAuth/flows/clientCredentials/scopes',
      );
      await row('read');
      await entry('Text value', 'Read example data', dialog: true);
      await button('Apply');
      await _wait(() => controller.form == null, 'scope-capture-close');
      await route('');
      await row('Security');
      await row('Add scheme alternative (OR)');
      await button('Apply');
      await _wait(() => controller.form == null, 'security-alternative-close');
      await row('Alternative 1');
      await row('Add combined scheme (AND)');
      await button('Apply');
      await _wait(() => controller.form == null, 'security-combined-close');
      await route('/security');
      await row('Add scheme alternative (OR)');
      await choose('Security scheme definition', 'Bearer · api.$format');
      await button('Apply');
      await _wait(() => controller.form == null, 'security-alternative-close');

      await route('/paths/~1native/get');
      await row('Operation details and overrides');
      await row('Parameters');
      await addEntry();
      await entry('Name', 'limit');
      await choose('in', 'query');
      await entry('Description', 'Native query parameter');
      await row('schema');
      await choose('Type', 'integer');
      await route('/paths/~1native/get');
      await row('Operation details and overrides');
      await row('Request body');
      await entry('Description', 'Native request');
      await choose('Required', 'true');
      await row('content');
      await addEntry('application/json');
      await row('schema');
      await entry(r'$ref', '#/components/schemas/Model');
      await route('/paths/~1native/get/requestBody/content');
      await addEntry('text/plain');
      await row('schema');
      await choose('Type', 'string');
      await route('/paths/~1native/get');
      await row('Operation details and overrides');
      await row('Responses');
      await addEntry('200');
      await entry('Description', 'Native response');
      await row('Headers');
      await addEntry('X-Trace');
      await entry('Description', 'Native response header');
      await row('schema');
      await choose('Type', 'string');
      await route('/paths/~1native/get/responses/200');
      await row('content');
      await addEntry('application/json');
      await row('schema');
      await entry(r'$ref', '#/components/schemas/Model');
      await route(
        '/paths/~1native/get/responses/200/content/application~1json',
      );
      await row('Examples');
      await addEntry('payload');
      await data(
        'value',
        r'{"name":"native","$ref":"literal data","large":900719925474099312345678901.00}',
      );
      await route('/paths/~1native/get/responses/200');
      await row('links');
      await addEntry('self');
      await entry('operationId', 'nativeOperation');

      if (!version.startsWith('3.0.')) {
        await route('');
        await row('webhooks');
        await addEntry('event');
        await row('post');
        await entry('Summary', 'Native webhook');
        await row('Operation details and overrides');
        await row('Responses');
        await addEntry('204');
        await entry('Description', 'Bodyless webhook response');
      }
      await route('/paths/~1native/get');
      await row('Operation details and overrides');
      await row('Callbacks');
      await addEntry('onEvent');
      await addEntry(r'{$request.body#/callbackUrl}');
      await row('post');
      await entry('Summary', 'Native callback');
      await row('Operation details and overrides');
      await row('Responses');
      await addEntry('204');
      await entry('Description', 'Bodyless callback response');
      if (version.startsWith('3.2')) {
        await route('/paths/~1native');
        await row('query');
        await entry('Summary', 'Native QUERY');
        await row('Operation details and overrides');
        await row('Responses');
        await addEntry('204');
        await entry('Description', 'Bodyless QUERY response');
        await route('/paths/~1native');
        await row('additionalOperations');
        await addEntry('COPY');
        await entry('Summary', 'Native COPY');
        await row('Operation details and overrides');
        await row('Responses');
        await addEntry('204');
        await entry('Description', 'Bodyless COPY response');
      }

      await route('/components/schemas/Model');
      final beforeRename = controller.buffer!.text;
      await row('Rename component');
      await entry('Name', 'Renamed', dialog: true);
      await button('Apply');
      await review('Review refactoring');
      final renamed = controller.buffer!.text;
      _expect(
        renamed != beforeRename &&
            renamed.contains('#/components/schemas/Renamed') &&
            !renamed.contains('#/components/schemas/Model'),
        'native-rename-established-recursive-consumers',
      );
      await keys(['Control_L+z']);
      await _wait(
        () => controller.buffer!.text == beforeRename,
        'native-rename-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () => controller.buffer!.text == renamed,
        'native-rename-redo',
      );
      await keys(['Control_L+z']);
      await _wait(
        () => controller.buffer!.text == beforeRename,
        'native-rename-restore',
      );
      await route('/paths/~1native/get/responses/200/headers/X-Trace');
      final beforeExtraction = controller.buffer!.text;
      await row('Extract to component…');
      await entry('Name', 'SharedHeader', dialog: true);
      await button('Apply');
      await review('Review component extraction');
      final extracted = controller.buffer!.text;
      _expect(
        extracted.contains('#/components/headers/SharedHeader'),
        'native-extraction-occurrence',
      );
      await keys(['Control_L+z']);
      await _wait(
        () => controller.buffer!.text == beforeExtraction,
        'native-extraction-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () => controller.buffer!.text == extracted,
        'native-extraction-redo',
      );
      await route('/paths/~1native/get/responses/200/headers/X-Trace');
      await row('Inline this occurrence…');
      await review('Review reference inlining');
      final inlined = controller.buffer!.text;
      _expect(inlined != extracted, 'native-explicit-inline');
      await keys(['Control_L+z']);
      await _wait(
        () => controller.buffer!.text == extracted,
        'native-inline-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () => controller.buffer!.text == inlined,
        'native-inline-redo',
      );
      await route('/components/headers/SharedHeader');
      await row('Delete object…');
      await review('Review object deletion');
      final deleted = controller.buffer!.text;
      _expect(deleted != inlined, 'native-impact-reviewed-definition-delete');
      await keys(['Control_L+z']);
      await _wait(
        () => controller.buffer!.text == inlined,
        'native-definition-delete-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () => controller.buffer!.text == deleted,
        'native-definition-delete-redo',
      );

      await route('/paths/~1native/get/responses/200/headers/X-Trace');
      await row('Extract to component…');
      await entry('Name', 'HeaderFile', dialog: true);
      await choose('Component destination', 'New source file…');
      await button('Apply');
      await entry('Destination path', 'headers.$format', dialog: true);
      await button('Apply');
      await review('Review extraction to source file');
      final headerFile = File('${sourceDirectory.path}/headers.$format'),
          movedHeaderFile = File(
            '${sourceDirectory.path}/moved-headers.$format',
          );
      _expect(
        !headerFile.existsSync() &&
            !movedHeaderFile.existsSync() &&
            project.store.buffers.containsKey(headerFile.uri.toString()),
        'native-extraction-virtual-new-file',
      );
      await headerMenu('Sidebar view', 'Files');
      await _wait(
        () =>
            _elements(
              (w) =>
                  w is BusyApiSidebarRecordRow<String> &&
                  w.title == 'headers.$format',
            ).length ==
            1,
        'native-move-file-row',
      );
      final movingRow = _elements(
        (w) =>
            w is BusyApiSidebarRecordRow<String> &&
            w.title == 'headers.$format',
      ).single;
      Element? movingMenu;
      void findMovingMenu(Element element) {
        if (element.widget case Tooltip(message: 'File actions')) {
          movingMenu = element;
        }
        element.visitChildren(findMovingMenu);
      }

      movingRow.visitChildren(findMovingMenu);
      _expect(movingMenu != null, 'native-move-menu');
      await click(
        (w) => identical(w, movingMenu!.widget),
        'native-move-menu-control',
      );
      await keys(['Down', 'Return']);
      await entry('Destination path', 'moved-headers.$format', dialog: true);
      await button('Apply');
      final beforeFileMove = project.store.get(root.uri.toString()).text;
      await review('Review file move');
      final afterFileMove = project.store.get(root.uri.toString()).text;
      // Extraction deliberately retains the named component as a forwarding
      // occurrence and puts its bare definition at the new file's root. Do
      // not invent a components path in that separate physical resource.
      final movedOccurrence = await project.inspectObject(
        controller.root!,
        root.uri.toString(),
        '/components/headers/HeaderFile',
      );
      _expect(
        afterFileMove != beforeFileMove &&
            movedOccurrence['value'][r'$ref'] == 'moved-headers.$format' &&
            (movedOccurrence['references'] as List).cast<Map>().any(
              (reference) =>
                  reference['resolution'] == 'resolved' &&
                  reference['targetResource'] ==
                      movedHeaderFile.uri.toString() &&
                  reference['targetPointer'] == '',
            ) &&
            !project.store.buffers.containsKey(headerFile.uri.toString()) &&
            project.store.buffers.containsKey(movedHeaderFile.uri.toString()) &&
            !headerFile.existsSync() &&
            !movedHeaderFile.existsSync(),
        'native-move-virtual-identity-and-incoming-reference',
      );
      await keys(['Control_L+z']);
      await _wait(
        () =>
            project.store.get(root.uri.toString()).text == beforeFileMove &&
            project.store.buffers.containsKey(headerFile.uri.toString()),
        'native-file-move-one-undo',
      );
      await keys(['Control_L+Shift_L+z']);
      await _wait(
        () =>
            project.store.get(root.uri.toString()).text == afterFileMove &&
            project.store.buffers.containsKey(movedHeaderFile.uri.toString()),
        'native-file-move-one-redo',
      );

      await exerciseSource(
        modelPointer: '/components/schemas/Model',
        modelReference: '#/components/schemas/Model',
        movedFile: movedHeaderFile,
        movedReference: 'moved-headers.$format',
      );
      final analysis = await project.check(controller.root!);
      final projection = analysis['projection'] as Map;
      _expect(
        projection['info']['value']['title'] == 'Native accepted',
        'native-overview',
      );
      _expect(
        projection['info']['value']['version'] == '2' &&
            projection['info']['value']['contact']['name'] == 'Native owner' &&
            projection['info']['value']['contact']['email'] ==
                'native@example.test' &&
            projection['info']['value']['license']['name'] ==
                'Example licence' &&
            projection['info']['value']['license']['url'] ==
                'https://example.test/licence',
        'native-every-overview-field-authored',
      );
      final operation = (projection['operations'] as List)
          .cast<Map>()
          .singleWhere(
            (item) => item['path'] == '/native' && item['method'] == 'get',
          );
      final response = operation['value']['responses']['204'] as Map;
      _expect(
        operation['value']['operationId'] == 'nativeOperation',
        'native-operation-id-authored',
      );
      _expect(!response.containsKey('content'), 'native-bodyless-response');
      _expect(
        operation['value']['requestBody']['content'].length == 2 &&
            operation['value']['responses']['200']['headers']['X-Trace']
                is Map &&
            !(operation['value']['responses']['200']['headers']['X-Trace']
                    as Map)
                .containsKey('in'),
        'native-media-and-header-ownership',
      );
      final components = (projection['components'] as List).cast<Map>();
      final model =
          components.singleWhere(
                (item) => item['group'] == 'schemas' && item['name'] == 'Model',
              )['value']
              as Map;
      _expect(
        model['type'] == 'object' &&
            listEquals((model['required'] as List).cast<String>(), ['name']) &&
            model['properties']['next'][r'$ref'] ==
                '#/components/schemas/Model' &&
            model['allOf'].length == 1 &&
            model['allOf'][0]['description'] == 'Authored composition branch',
        'native-authored-recursion-composition-required',
      );
      final security =
          (projection['otherRootObjects'] as List).cast<Map>().singleWhere(
                (item) => item['name'] == 'security',
              )['value']
              as List;
      _expect(
        security.length == 2 &&
            security[0].length == 2 &&
            security[0].containsKey('ApiKey') &&
            security[0].containsKey('Bearer') &&
            security[1].length == 1 &&
            security[1].containsKey('Bearer') &&
            components.singleWhere(
                  (item) => item['name'] == 'OAuth',
                )['value']['flows']['clientCredentials']['scopes']['read'] ==
                'Read example data',
        'native-security-alternatives-combined-oauth',
      );
      for (final summary in [
        if (!version.startsWith('3.0.')) 'Native webhook',
        'Native callback',
      ]) {
        final related = (projection['operations'] as List)
            .cast<Map>()
            .singleWhere((item) => item['value']['summary'] == summary);
        _expect(
          related['method'] == 'post' &&
              !(related['value']['responses']['204'] as Map).containsKey(
                'content',
              ),
          'native-related-operation-bodyless',
        );
      }
      if (version.startsWith('3.2')) {
        for (final summary in ['Native QUERY', 'Native COPY']) {
          _expect(
            (projection['operations'] as List).cast<Map>().any(
              (item) => item['value']['summary'] == summary,
            ),
            'native-version-specific-operation',
          );
        }
      }
      _expect(
        !(analysis['findings'] as List).cast<Map>().any(
          (finding) =>
              finding['severity'] == 'error' &&
              const ['syntax', 'openapi'].contains(finding['category']),
        ),
        'native-authored-contract-validity',
      );
      final authored = project.store.get(root.uri.toString()).bytes();
      final authoredText = utf8.decode(authored);
      _expect(
        authoredText.contains('9007199254740993.00') &&
            authoredText.contains('900719925474099312345678901.00') &&
            authoredText.contains('literal'),
        'native-unknown-values',
      );
      await keys(['Control_L+s']);
      await _wait(
        () =>
            listEquals(root.readAsBytesSync(), authored) &&
            movedHeaderFile.existsSync() &&
            controller.publications.pendingFileBuffers(project).isEmpty &&
            listEquals(
              movedHeaderFile.readAsBytesSync(),
              project.store.get(movedHeaderFile.uri.toString()).bytes(),
            ),
        'native-authoring-save',
      );
      _expect(
        !headerFile.existsSync() &&
            movedHeaderFile.existsSync() &&
            listEquals(
              movedHeaderFile.readAsBytesSync(),
              project.store.get(movedHeaderFile.uri.toString()).bytes(),
            ),
        'native-file-move-published-identity-and-bytes',
      );
      await controller.open(root.path);
      _expect(
        listEquals(controller.buffer!.bytes(), authored),
        'native-authoring-reopen',
      );
      stdout.writeln(
        'BUSYAPI_NATIVE_AUTHORING_PASS overview tags contact licence operation parameter bodyless-response headers media examples links recursion composition security-oauth-requirements ${version.startsWith('3.0.') ? '' : 'webhook '}callback server-variable exact-save-reopen openapi=$version format=$format',
      );
    }
  } finally {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(observePointer);
    await input.cancel();
  }
  return 'creation=reviewed deletion=native-menu history=one-step publication=save-only original-bytes=exact openapi=$version format=$format';
}
