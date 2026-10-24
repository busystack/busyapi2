// Explicit native-test entry, never installed as the application entry point.
// The external driver sends real XTest input; this entry only locates mounted
// controls, observes state and compares the complete original source bytes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/designer/form_value_editor.dart';
import 'package:busyapi/src/designer/designer.dart';
import 'package:busyapi/src/designer/schema_tree.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart'
    show CoreFailure, FilePublication;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main(List<String> arguments) async {
  try {
    final identity = await _run();
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_PASS creation=reviewed deletion=native-menu '
      'history=one-step publication=save-only original-bytes=exact $identity',
    );
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
      format = Platform.environment['BUSYAPI_FILE_CONTROLS_FORMAT'] ?? 'yaml';
  _expect(
    ['3.1.2', '3.2.1'].contains(version) && ['yaml', 'json'].contains(format),
    'fixture-version-format',
  );
  final json = format == 'json',
      createdName = 'created.$format',
      unusedName = 'unused.$format';
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
  final rootBytes = utf8.encode(
        json
            ? '\ufeff{\r\n "openapi":"$version","info":{"title":"Native 雪😀","version":"1"},\n'
                  ' "paths":{},"x-example":{"\$ref":"literal","large":9007199254740993.00}}'
            : '\ufeffopenapi: $version\r\ninfo: {title: "Native 雪😀", version: "1"}\n'
                  'paths: {}\r\nx-example: {"\$ref": "literal", large: 9007199254740993.00}',
      ),
      unusedBytes = utf8.encode(
        json
            ? '\ufeff{\r\n "Value":{"type":"string","description":"preserved 雪😀"},\n "x-data":1.000}\r\n'
            : '\ufeff# preserved 雪😀\r\nValue: {type: string}\nx-data: 1.000\n',
      );
  await root.writeAsBytes(rootBytes, flush: true);
  await unused.writeAsBytes(unusedBytes, flush: true);
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
  var step = 0;
  Future<void> send(Map<String, Object> action) async {
    final current = ++step;
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_INPUT ${jsonEncode({'version': 1, 'step': current, ...action})}',
    );
    _expect(
      await input.moveNext().timeout(const Duration(seconds: 30)) &&
          input.current == 'ack:$current',
      'input-owner',
    );
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
    await keys(['Control_L+a', ...ascii(value), if (!dialog) 'Return']);
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
      bool currentModel() =>
          !controller.checking &&
          controller.projection?['info']?['generation'] ==
              project.store.get(root.uri.toString()).generation &&
          controller.draft?.buffer ==
              (controller.selectedResource ?? controller.root) &&
          controller.draft?.pointer == controller.selectedPointer;
      if (!currentModel()) {
        stdout.writeln(
          'BUSYAPI_NATIVE_COMBO_WAIT ${jsonEncode({'field': title, 'checking': controller.checking, 'currentGeneration': controller.projection?['info']?['generation'] == project.store.get(root.uri.toString()).generation})}',
        );
      }
      // A field becomes clean before its durable checkpoint and subsequent
      // current projection finish. Opening an old frame's menu in between
      // correctly retires that stale menu when controls reconcile. Observe
      // the completed model, as inline entry() does, before the next action.
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
    final operation = (controller.projection?['operations'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where(controller.isSelected)
        .firstOrNull;
    final ownerIdentity = (controller.root, root.uri.toString(), pointer);
    await _wait(() {
      if (pointer != '/info' && operation == null) {
        // ValueKey equality includes its generic type. Compare the captured
        // record value, not an inferred nullable/non-nullable key type.
        return _elements(
              (w) =>
                  w is! AuthoredSchemaTree &&
                  w.key is ValueKey &&
                  (w.key as ValueKey).value == ownerIdentity,
            ).length ==
            1;
      }
      final heading = operation == null
          ? 'Overview'
          : '${operation['method'].toString().toUpperCase()} ${operation['path']}';
      return _elements((w) => w is Text && w.data == heading)
              .where(
                (element) =>
                    element.findAncestorWidgetOfExactType<Designer>() != null,
              )
              .length ==
          1;
    }, 'native-selected-page-mounted');
  }

  try {
    await click((w) => w is BusyApiActionRow && w.title == 'Files', 'files');
    for (final accept in [false, true]) {
      await click(
        (w) => w is BusyApiActionRow && w.title == 'New source file…',
        'new-file',
      );
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

      await route('');
      await row('webhooks');
      await addEntry('event');
      await row('post');
      await entry('Summary', 'Native webhook');
      await row('Operation details and overrides');
      await row('Responses');
      await addEntry('204');
      await entry('Description', 'Bodyless webhook response');
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
      await click(
        (w) => w is BusyApiActionRow && w.title == 'Files',
        'native-move-files',
      );
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

      await route('/components/schemas/Model');
      await click((w) => w is Text && w.data == 'Source', 'native-source-mode');
      await _wait(() => controller.mode == 'Source', 'native-source-mounted');
      await _wait(
        () => _elements((w) => w is SourceEditor).length == 1,
        'native-source-control-mounted',
      );
      final sourceElements = _elements((w) => w is SourceEditor);
      _expect(sourceElements.length == 1, 'native-source-owner');
      final sourceState =
          (sourceElements.single as StatefulElement).state as SourceEditorState;
      final beforeCompletion = controller.buffer!.text;
      final stringType = RegExp(r'(?:"type"\s*:\s*"|type:\s*)(string)')
          .firstMatch(beforeCompletion);
      _expect(stringType != null, 'native-completion-context');
      sourceState.reveal(stringType!.end - 3);
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
      sourceState.reveal(controller.buffer!.text.indexOf('title') + 2);
      await keys(['F1']);
      await _wait(
        () => _elements(
          (w) => w is Text && w.data?.startsWith('Authored title') == true,
        ).isNotEmpty,
        'native-field-help-origin',
      );
      await keys(['Escape']);
      final referenceOffset = controller.buffer!.text.indexOf(
        '#/components/schemas/Model',
      );
      _expect(referenceOffset >= 0, 'native-definition-reference');
      final modelDefinition = await project.inspectObject(
        controller.root!,
        root.uri.toString(),
        '/components/schemas/Model',
      );
      final modelStart = (modelDefinition['range'] as List).first as int;
      sourceState.reveal(referenceOffset + 4);
      await keys(['Control_L+b']);
      await _wait(
        () =>
            controller.active == root.uri.toString() &&
            controller.mode == 'Source' &&
            controller.buffer!.selection.base == modelStart &&
            controller.buffer!.selection.extent == modelStart,
        'native-go-to-definition',
      );
      sourceState.reveal(0);
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
      final headerReference = controller.buffer!.text.indexOf(
        'moved-headers.$format',
      );
      _expect(headerReference >= 0, 'native-cross-file-reference');
      final movedDefinition = await project.inspectObject(
        controller.root!,
        movedHeaderFile.uri.toString(),
        '',
      );
      final movedStart = (movedDefinition['range'] as List).first as int;
      sourceState.reveal(headerReference + 5);
      await keys(['Control_L+b']);
      await _wait(
        () =>
            controller.active == movedHeaderFile.uri.toString() &&
            controller.mode == 'Source' &&
            controller.buffer!.selection.base == movedStart &&
            controller.buffer!.selection.extent == movedStart,
        'native-cross-file-definition',
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
      for (final summary in ['Native webhook', 'Native callback']) {
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
        'BUSYAPI_NATIVE_AUTHORING_PASS overview tags contact licence operation parameter bodyless-response headers media examples links recursion composition security-oauth-requirements webhook callback server-variable exact-save-reopen openapi=$version format=$format',
      );
    }
  } finally {
    await input.cancel();
  }
  return 'openapi=$version format=$format';
}
