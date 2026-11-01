// Explicit native review fixture. Production menu/dialogs receive real input;
// fixtures and independent assertions never replace their action callbacks.
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'native_controls.dart';

Future<void> main(List<String> arguments) async {
  try {
    await exercise();
    exit(0);
  } on Object catch (error) {
    stderr.writeln(
      'BUSYAPI_FILE_CONTROLS_FAILED migration ${error is StateError
          ? error.message
          : error is CoreFailure
          ? error.code
          : error.runtimeType}',
    );
    exit(1);
  }
}

Future<void> exercise() async {
  final boundary =
      Platform.environment['BUSYAPI_FILE_CONTROLS_DIRECTORY'] ?? '';
  nativeCheck(
    RegExp(r'^/tmp/busyapi-file-controls-[A-Za-z0-9_-]+$').hasMatch(boundary),
    'migration-fixture-boundary',
  );
  final version =
      Platform.environment['BUSYAPI_FILE_CONTROLS_VERSION'] ?? '2.0';
  final format = Platform.environment['BUSYAPI_FILE_CONTROLS_FORMAT'] ?? 'yaml';
  final target =
      Platform.environment['BUSYAPI_NATIVE_MIGRATION_TARGET'] ?? '3.0.4';
  nativeCheck(
    const ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1'].contains(version) &&
        const ['yaml', 'json'].contains(format),
    'migration-fixture-family',
  );
  nativeCheck(
    const ['2.0', '3.0.4', '3.1.2', '3.2.1'].contains(target) &&
        version != target,
    'migration-target',
  );
  final folder = await Directory('$boundary/project').create();
  final file = File('${folder.path}/api.$format');
  final swagger = version == '2.0';
  const schema = {
    'type': 'integer',
    'enum': [0, 9007199254740993],
  };
  final body = {
    'required': true,
    'content': {
      'application/json': {'schema': schema},
    },
  };
  const response = {
    'description': 'Shared response',
    'content': {
      'application/json': {'schema': schema},
    },
  };
  final document = <String, Object?>{
    swagger ? 'swagger' : 'openapi': version,
    'info': {'title': 'Original', 'version': '1'},
    if (swagger) ...{
      'host': 'api.invalid',
      'basePath': '/v1',
      'schemes': ['https'],
      'consumes': ['application/json'],
      'produces': ['application/json'],
    } else
      'servers': [
        {'url': 'https://api.invalid/v1'},
      ],
    'paths': {
      '/json': {
        'post': {
          if (swagger)
            'parameters': [
              {r'$ref': 'body.$format'},
            ]
          else
            'requestBody': body,
          'responses': {
            '200': swagger ? {r'$ref': 'response.$format'} : response,
          },
        },
      },
      if (swagger)
        '/text': {
          'post': {
            'consumes': ['text/plain'],
            'produces': ['text/plain'],
            'parameters': [
              {r'$ref': 'body.$format'},
            ],
            'responses': {
              '200': {r'$ref': 'response.$format'},
            },
          },
        },
    },
    'x-exact': [9007199254740993, false, null, 0],
  };
  String authored(Map<String, Object?> value, String label) =>
      '${format == 'yaml' ? '# Keep $label\r\n' : ''}${const JsonEncoder.withIndent('  ').convert(value).replaceAll('\n', '\r\n')}\r\n';
  final original = authored(document, 'root'),
      originals = <File, String>{file: original};
  if (swagger) {
    originals[File('${folder.path}/body.$format')] = authored({
      'in': 'body',
      'name': 'payload',
      'required': true,
      'description': 'Original body',
      'schema': schema,
      'x-data': {r'$ref': 'literal', 'empty': ''},
    }, 'body');
    originals[File('${folder.path}/response.$format')] = authored({
      'description': 'Shared response',
      'schema': schema,
      'examples': {'application/json': 9007199254740993},
    }, 'response');
  }
  for (final entry in originals.entries) {
    await entry.key.writeAsString(entry.value);
  }
  await application.main([file.path]);
  WorkspaceController? controller;
  await nativeWait(() {
    for (final element in nativeElements(
      (widget) => widget is WorkspaceScreen,
    )) {
      if (element is StatefulElement && element.state is WorkspaceScreenState) {
        controller = (element.state as WorkspaceScreenState).c;
      }
    }
    return controller?.projection != null;
  }, 'migration-workspace-open');
  final owner = controller!;
  nativeCheck(
    owner.specification?.declaredVersion == version,
    'migration-original-family',
  );
  final project = owner.project!, root = file.uri.toString();
  await windowManager.focus();
  final input = NativeControls();
  try {
    await input.click(
      (widget) => widget is BusyApiGroupedTextEntry && widget.label == 'Title',
      'migration-title',
      editable: true,
    );
    await input.keys([
      'Control_L+a',
      'Shift_L+u',
      'n',
      's',
      'a',
      'v',
      'e',
      'd',
      'Tab',
    ]);
    await nativeWait(
      () => project.store.get(root).text.contains('Unsaved') && !owner.checking,
      'migration-unsaved-title',
    );
    if (swagger) {
      final external = await project.buffer(
        File('${folder.path}/body.$format').uri.toString(),
      );
      project.store.replace(
        external.id,
        external.text.replaceFirst('Original body', 'Unsaved body'),
      );
      await owner.analyse();
    }
    final destination = Directory('${folder.path}/busyapi-migrated');
    Future<void> review() async {
      await input.menu('BusyAPI', 'migrate');
      await nativeWait(
        () =>
            nativeElements(
              (widget) =>
                  widget is BusyApiDialogButton &&
                  widget.label == 'Review migration',
            ).length ==
            1,
        'migration-dialog',
      );
      await input.combo('Target specification', target);
      await input.button('Review migration');
      await nativeWait(
        () =>
            nativeElements(
              (widget) =>
                  widget is BusyApiDialogButton &&
                  widget.label == 'Review output',
            ).length ==
            1,
        'migration-output-review',
      );
      await input.button('Review output');
      await nativeWait(
        () =>
            nativeElements((widget) => widget is BusyApiReviewComparison)
                .length ==
            1,
        'migration-changes',
      );
      nativeCheck(
        nativeElements(
              (widget) =>
                  widget is BusyApiDialogButton &&
                  widget.label == 'Create migrated copy' &&
                  widget.onPressed != null,
            ).length ==
            1,
        'migration-publish-enabled',
      );
      final changed = nativeElements(
        (widget) =>
            widget is BusyApiComboRow<int> &&
            widget.title == 'Review generated files',
      );
      nativeCheck(
        changed.length == 1 &&
            (changed.single.widget as BusyApiComboRow<int>).values.length ==
                originals.length,
        'migration-affected-resources',
      );
      nativeCheck(
        !await destination.exists(),
        'migration-review-no-publication',
      );
    }

    await review();
    await input.button('Close');
    await nativeWait(
      () => nativeElements(
        (widget) =>
            widget is BusyApiDialogButton && widget.label == 'Review migration',
      ).isEmpty,
      'migration-cancelled-review',
    );
    nativeCheck(
      !await destination.exists(),
      'migration-cancel-preserves-destination',
    );
    await review();
    project.store.replace(
      root,
      project.store.get(root).text.replaceFirst('Unsaved', 'Revised'),
    );
    await owner.analyse();
    await nativeWait(
      () =>
          nativeElements(
            (widget) =>
                widget is BusyApiDialogButton &&
                widget.label == 'Create migrated copy' &&
                widget.onPressed == null,
          ).length ==
          1,
      'migration-stale-publish-disabled',
    );
    nativeCheck(!await destination.exists(), 'migration-stale-no-publication');
    await input.button('Close');
    await review();
    await input.button('Create migrated copy');
    await nativeWait(
      () =>
          nativeElements(
            (widget) => widget is BusyApiStatusBox && widget.message == 'The migrated copy was created. Original documents are preserved.',
          ).length ==
          1,
      'migration-publication',
    );
    nativeCheck(
      owner.specification?.declaredVersion == version,
      'migration-original-stays-open',
    );
    for (final entry in originals.entries) {
      nativeCheck(
        await entry.key.readAsString() == entry.value,
        'migration-original-bytes',
      );
    }
    nativeCheck(
      project.store.get(root).dirty &&
          project.store.get(root).text.contains('Revised'),
      'migration-original-working-buffer',
    );
    final metadata = jsonDecode(
      await File('${destination.path}/migration.json').readAsString(),
    );
    nativeCheck(
      metadata is Map && metadata['producerVersion'] == '25',
      'migration-runtime-revision',
    );
    final copy = await BusyProject.open(destination.path, project.engine);
    try {
      final checked = await copy.check(copy.roots.single.id);
      nativeCheck(
        checked['complete'] == true &&
            checked['projection']['specification']['declaredVersion'] == target,
        'migration-target-native-validation',
      );
      nativeCheck(
        (await copy.buffer(copy.roots.single.id)).text.contains('Revised'),
        'migration-target-working-content',
      );
      if (swagger) {
        nativeCheck(
          (await File(
            '${destination.path}/busyapi.yaml',
          ).readAsString()).contains('resourceMappings'),
          'migration-shared-resource-map',
        );
        final files = await destination
            .list(recursive: true)
            .where(
              (entry) => entry is File && entry.path.contains('/resources/'),
            )
            .cast<File>()
            .toList();
        nativeCheck(
          files.length == 2 &&
              (await Future.wait(files.map((file) => file.readAsString())))
                  .any((text) => text.contains('Unsaved body')),
          'migration-unsaved-external-content',
        );
      }
    } finally {
      copy.close();
    }
    final independentDirectory = await Directory('${folder.path}/standalone')
        .create();
    for (final entity in await destination.list(recursive: true).toList()) {
      if (entity is! File) continue;
      final relative = entity.path.substring(destination.path.length + 1);
      if (relative == 'busyapi.yaml' || relative == 'migration.json') continue;
      final independent = File('${independentDirectory.path}/$relative');
      await independent.parent.create(recursive: true);
      await entity.copy(independent.path);
    }
    final independent = await BusyProject.open(
      '${independentDirectory.path}/openapi.$format',
      project.engine,
    );
    try {
      nativeCheck(
        (await independent.check(independent.roots.single.id))['complete'] ==
            true,
        'migration-standalone-relocated',
      );
    } finally {
      independent.close();
    }
    await input.button('Close');
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_PASS migration $version->$target $format inputs=${input.steps} originals=unchanged cancellation stale-review unsaved-resources target-validation standalone-relocated',
    );
  } finally {
    await input.close();
  }
}
