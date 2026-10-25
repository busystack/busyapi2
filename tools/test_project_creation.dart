// Native creation forms use the production app and its existing directory
// chooser callback. The callback selects only this fixture's private parent;
// operating-system folder chooser behavior is outside this check.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_settings.dart';
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/system_accent.dart';
import 'package:busyapi/src/designer/form_value_editor.dart';
import 'package:busyapi/src/platform/gtk_animation_settings_service.dart';
import 'package:busyapi/src/platform/gtk_header_icon_service.dart';
import 'package:busyapi/src/platform/gtk_window_preferences_service.dart';
import 'package:busyapi/src/platform/linux_gtk_accent_service.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yaru/yaru.dart';

import 'test_http_client.dart' show check, elements, waitFor;

Future<void> main(List<String> arguments) async {
  try {
    await exercise();
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_PASS project-creation=native '
      'directory-picker=fixture-callback collision=preserved no-op-save=exact',
    );
    exit(0);
  } on Object catch (error) {
    stderr.writeln(
      'BUSYAPI_FILE_CONTROLS_FAILED project-creation '
      '${error is StateError ? error.message : error.runtimeType}',
    );
    exit(1);
  }
}

Future<void> exercise() async {
  final directory =
      Platform.environment['BUSYAPI_FILE_CONTROLS_DIRECTORY'] ?? '';
  final version = Platform.environment['BUSYAPI_FILE_CONTROLS_VERSION'] ?? '';
  final format = Platform.environment['BUSYAPI_FILE_CONTROLS_FORMAT'] ?? '';
  check(
    RegExp(r'^/tmp/busyapi-file-controls-[A-Za-z0-9_-]+$').hasMatch(directory),
    'fixture-boundary',
  );
  check(
    const ['2.0', '3.0.4', '3.1.2', '3.2.1'].contains(version) &&
        const ['yaml', 'json'].contains(format),
    'fixture-family',
  );
  final parent = Directory('$directory/parent')..createSync();
  final destination = Directory('${parent.path}/api');
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await YaruWindow.ensureInitialized();
  final accent = LinuxAccentCoordinator(
    sources: [const LinuxGtkAccentService(), const LinuxPortalAppearance()],
  );
  await accent.initialize();
  final chrome = await Future.wait<Object?>([
    const GtkAnimationSettingsService().getAnimationsEnabled(),
    const GtkWindowPreferencesService().load(),
  ]);
  final icons = GtkHeaderIconService();
  await icons.initialize();
  final controller = WorkspaceController(
    EngineProcess.bundled(),
    StateLocations.xdg(),
  );
  await controller.initialize();
  final appearance = await BusyApiAppearance.load(controller.locations);
  var chooserCalls = 0;
  runApp(
    ProviderScope(
      overrides: [
        initialGtkAnimationsEnabledProvider.overrideWithValue(
          chrome[0] as bool?,
        ),
        initialGtkWindowPreferencesProvider.overrideWithValue(
          chrome[1] as GtkWindowPreferences?,
        ),
        gtkHeaderIconServiceProvider.overrideWith((ref) {
          ref.onDispose(icons.dispose);
          return icons;
        }),
        initialSystemAccentColorProvider.overrideWithValue(accent.color),
        linuxAccentCoordinatorProvider.overrideWith((ref) {
          ref.onDispose(() => unawaited(accent.dispose()));
          return accent;
        }),
      ],
      child: BusyApiApp(
        controller: controller,
        initialAppearance: appearance,
        chooseProjectDirectory: () async {
          chooserCalls++;
          return parent.path;
        },
      ),
    ),
  );
  await waitFor(
    () => elements((w) => w is WorkspaceScreen).length == 1,
    'workspace-mounted',
  );
  final context = elements((w) => w is WorkspaceScreen).single;
  final l = AppLocalizations.of(context)!;
  await windowManager.focus();
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  var step = 0;
  Future<void> send(Map<String, Object> action) async {
    final current = ++step;
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_INPUT ${jsonEncode({'version': 1, 'step': current, ...action})}',
    );
    check(
      await input.moveNext().timeout(const Duration(seconds: 30)) &&
          input.current == 'ack:$current',
      'input-owner',
    );
  }

  Future<void> keys(List<String> chords) =>
      send({'kind': 'keys', 'chords': chords});
  Future<void> click(
    bool Function(Widget) matches,
    String code, {
    bool editable = false,
  }) async {
    await waitFor(() => elements(matches).length == 1, '$code-mounted');
    var target = elements(matches).single;
    if (editable) {
      final inputs = <Element>[];
      void visit(Element element) {
        if (element.widget is EditableText) inputs.add(element);
        element.visitChildren(visit);
      }

      target.visitChildren(visit);
      check(inputs.length == 1, '$code-editable');
      target = inputs.single;
    }
    await Scrollable.ensureVisible(
      target,
      alignment: .4,
      duration: Duration.zero,
    );
    await WidgetsBinding.instance.endOfFrame;
    final box = target.findRenderObject() as RenderBox;
    final point = box.localToGlobal(box.size.center(Offset.zero));
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
      await waitFor(
        () =>
            target.mounted &&
            (target.widget as EditableText).focusNode.hasFocus,
        '$code-focused',
      );
    }
  }

  Future<void> button(String label) => click(
    (w) => w is BusyApiDialogButton && w.label == label,
    'button-$label',
  );
  Future<void> text(String label, String value) async {
    await click(
      (w) => w is FormValueEditor && w.label == label,
      'field-$label',
      editable: true,
    );
    await keys([
      'Control_L+a',
      for (final character in value.split(''))
        switch (character) {
          ' ' => 'space',
          '.' => 'period',
          _ => character,
        },
    ]);
  }

  Future<void> combo(String label, String value) async {
    await waitFor(
      () =>
          elements((w) => w is BusyApiComboRow<String> && w.title == label)
              .length ==
          1,
      'combo-$label',
    );
    final combo =
        elements((w) => w is BusyApiComboRow<String> && w.title == label)
                .single
                .widget
            as BusyApiComboRow<String>;
    final index = combo.values.indexOf(value);
    check(index >= 0, 'combo-family-choice');
    await click(
      (w) => w is BusyApiComboRow<String> && w.title == label,
      'combo-$label',
    );
    await send({'kind': 'menu-ready'});
    await keys(['Home', for (var i = 0; i < index; i++) 'Down', 'Return']);
    await waitFor(
      () =>
          elements(
            (w) =>
                w is BusyApiComboRow<String> &&
                w.title == label &&
                w.selected == value,
          ).length ==
          1,
      'combo-selected',
    );
  }

  Future<void> mode(String label) async {
    final target = elements(
      (w) =>
          w is BusyApiHeaderPopupMenuButton<String> && w.tooltip == l.viewMode,
    ).single;
    final menu = target.widget as BusyApiHeaderPopupMenuButton<String>;
    final entries = (await menu.itemBuilder(target))
        .whereType<BusyApiPopupMenuItem<String>>()
        .where((entry) => entry.enabled)
        .toList();
    final index = entries.indexWhere((entry) => entry.label == label);
    check(index >= 0, 'mode-choice');
    await click(
      (w) =>
          w is BusyApiHeaderPopupMenuButton<String> && w.tooltip == l.viewMode,
      'mode-menu',
    );
    await send({'kind': 'menu-ready'});
    await keys(['Home', for (var i = 0; i < index; i++) 'Down', 'Return']);
    await waitFor(() => controller.mode == label, 'mode-selected');
  }

  await keys(['Control_L+n']);
  await waitFor(
    () =>
        elements((w) => w is FormValueEditor && w.label == l.title).length == 1,
    'creation-dialog',
  );
  check(
    chooserCalls == 1 && !destination.existsSync(),
    'creation-not-published',
  );
  await button(l.apply);
  check(!destination.existsSync(), 'invalid-creation-published');
  await text(l.title, 'native api');
  await text(l.apiVersion, '9.8.7');
  await combo(l.openapiVersion, version);
  await combo(l.format, format);
  await button(l.apply);
  await waitFor(
    () =>
        controller.root != null &&
        controller.analysis?['complete'] == true &&
        !controller.checking &&
        elements((w) => w is FormValueEditor && w.label == l.title).isEmpty,
    'created-project-open',
  );
  check(controller.analysis!['status'] == 'complete', 'created-project-valid');
  check(
    controller.specification?.declaredVersion == version,
    'created-native-version',
  );
  check(controller.mode == 'Design', 'created-design');
  final root = controller.root!;
  final source = File.fromUri(Uri.parse(root));
  check(
    source.parent.path == destination.path && source.path.endsWith('.$format'),
    'created-standard-format',
  );
  final original = source.readAsBytesSync();
  final manifest = File('${destination.path}/busyapi.yaml');
  final configuration = manifest.readAsBytesSync();
  final info = await controller.project!.inspectObject(root, root, '/info');
  check(
    info['value']['title'] == 'native api' &&
        info['value']['version'] == '9.8.7',
    'created-api-information',
  );
  await keys(['Control_L+s']);
  await mode(l.source);
  await waitFor(
    () => elements((w) => w is SourceEditor).length == 1,
    'source-mounted',
  );
  check(
    base64Encode(controller.buffer!.bytes()) == base64Encode(original),
    'created-source-exact',
  );
  await mode(l.reference);
  await waitFor(
    () => elements((w) => w is ReferenceView).length == 1,
    'reference-mounted',
  );
  await send({
    'kind': 'snapshot',
    'name': 'create-${version.replaceAll('.', '-')}-$format-reference',
    'texts': ['native api'],
  });
  check(
    base64Encode(source.readAsBytesSync()) == base64Encode(original),
    'view-or-save-mutated-source',
  );
  await keys(['Control_L+n']);
  await waitFor(
    () =>
        elements((w) => w is FormValueEditor && w.label == l.title).length == 1,
    'collision-dialog',
  );
  await text(l.title, 'native replacement');
  await button(l.apply);
  await waitFor(
    () => elements(
      (w) =>
          w is BusyApiDialogButton && w.label == l.apply && w.onPressed != null,
    ).isNotEmpty,
    'collision-settled',
  );
  check(chooserCalls == 2 && controller.root == root, 'collision-owner');
  check(
    elements((w) => w is FormValueEditor && w.label == l.title).length == 1,
    'collision-form-retained',
  );
  check(
    base64Encode(source.readAsBytesSync()) == base64Encode(original) &&
        base64Encode(manifest.readAsBytesSync()) == base64Encode(configuration),
    'collision-mutated-files',
  );
  await button(l.cancel);
  await waitFor(
    () => elements((w) => w is FormValueEditor && w.label == l.title).isEmpty,
    'collision-cancelled',
  );
  await controller.open(destination.path);
  await controller.analyse();
  check(
    controller.specification?.declaredVersion == version &&
        controller.analysis?['status'] == 'complete',
    'reopened-native-version',
  );
  check(
    base64Encode(source.readAsBytesSync()) == base64Encode(original) &&
        base64Encode(manifest.readAsBytesSync()) == base64Encode(configuration),
    'reopen-mutated-files',
  );
  await input.cancel();
  await controller.shutdown();
  stdout.writeln(
    'BUSYAPI_NATIVE_CREATION_PASS version=$version format=$format',
  );
}
