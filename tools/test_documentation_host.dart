// Native application integration fixture, not an installed application entry.
// Use only a private temporary directory; see docs/tool-support.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/platform/documentation_window_service.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

Future<void> main(List<String> arguments) async {
  try {
    await _run();
    stdout.writeln(
      'BUSYAPI_DOCUMENTATION_NATIVE_CHANNEL_PASS '
      'source-reveal=owned aliases=occurrence/definition stale=revoked bytes=exact',
    );
    exit(0);
  } on Object {
    // Neither authored values nor private XDG/file locations belong in output.
    stderr.writeln('BUSYAPI_DOCUMENTATION_NATIVE_CHANNEL_FAILED');
    exit(1);
  }
}

void _expect(bool condition, String code) {
  if (!condition) throw StateError(code);
}

Future<void> _run() async {
  final directory =
      Platform.environment['BUSYAPI_DOCUMENTATION_SMOKE_DIRECTORY'] ?? '';
  _expect(
    RegExp(r'^/tmp/busyapi-documentation-host-smoke-[A-Za-z0-9]+$')
        .hasMatch(directory),
    'fixture-boundary',
  );
  final source = File('$directory/api.yaml');
  _expect(!source.existsSync(), 'fixture-collision');
  const original =
      '\ufeffopenapi: 3.2.1\r\n'
      'info: {title: "Native 雪😀", version: "1"}\n'
      'paths: {}\r\ncomponents:\n  schemas:\r\n    Boolean: false\n'
      '    Shared: &source_schema {type: string}\r\n'
      '    # Alias 雪😀\n    Alias: *source_schema\n'
      'x-data: {large: 9007199254740993.00, "\$ref": "literal payload"}';
  final originalBytes = utf8.encode(original);
  await source.writeAsBytes(originalBytes, flush: true);
  await application.main([source.path]);
  WorkspaceController? owner;
  WorkspaceScreenState? screen;
  final deadline = Stopwatch()..start();
  while (owner?.project == null || owner?.root == null || screen == null) {
    _expect(deadline.elapsed < const Duration(seconds: 30), 'open-timeout');
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    void visit(Element element) {
      if (element.widget case BusyApiApp app) owner = app.controller;
      if (element is StatefulElement && element.state is WorkspaceScreenState) {
        screen = element.state as WorkspaceScreenState;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final controller = owner!, project = controller.project!;
  _expect(controller.mode == 'Design', 'initial-mode');
  final presentation = await project.captureDocumentationPresentation(
    controller.root!,
  );
  final service = DocumentationWindowService();
  try {
    await service.attach();
    var sourceCount = 0;
    final snapshot = jsonEncode(presentation.snapshot.identity);
    for (final name in ['Alias', 'Shared', 'Boolean']) {
      final action = presentation.sourceActionFor('/components/schemas/$name')!,
          before = sourceCount,
          requested = Completer<void>();
      final stale = name == 'Boolean';
      final session = await service.open(
        presentation: presentation,
        resources: {
          'index.html': Uint8List.fromList(
            utf8.encode(
              '<!doctype html><html><head><meta charset="utf-8">'
              '<script type="module" src="bootstrap.mjs"></script></head>'
              '<body><h1>BusyAPI captured documentation fixture</h1></body></html>',
            ),
          ),
          'bootstrap.mjs': Uint8List.fromList(
            utf8.encode('''
const send=(kind,extra={})=>window.webkit.messageHandlers.busyapiDocumentation
  .postMessage({version:1,snapshot:$snapshot,kind,...extra});
send('ready');
setTimeout(()=>send('source',{index:${action.index}}),100);
${stale ? "setTimeout(()=>send('source',{index:${action.index}}),1200);" : ''}
'''),
          ),
        },
        title: 'BusyAPI native documentation protocol fixture',
        loadingLabel: 'Loading fixture',
        failureLabel: 'Fixture failed',
        outdatedLabel: 'Outdated snapshot · 雪😀',
        onSource: (location) async {
          presentation.resolveSourceAction(location.index);
          _expect(
            identical(controller.project, project) &&
                location.source['resource'] == source.uri.toString(),
            'source-owner',
          );
          await screen!.revealDocumentationSource(
            project,
            presentation,
            location.index,
          );
          sourceCount++;
          if (!requested.isCompleted) requested.complete();
        },
      );
      await session.ready;
      await requested.future.timeout(const Duration(seconds: 10));
      final range = action.source['occurrenceRange'] ?? action.source['range'];
      _expect(
        controller.mode == 'Source' &&
            controller.active == action.source['resource'] &&
            controller.buffer!.selection.base == range[0] &&
            sourceCount == before + 1,
        'source-reveal',
      );
      if (stale) {
        controller.sourceEdit(
          controller.buffer!.id,
          controller.buffer!.text.replaceFirst('Native', 'Changed'),
        );
        await service.synchronize();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        _expect(
          sourceCount == before + 1 &&
              session.state == DocumentationWindowState.outdated,
          'outdated-source-authority',
        );
        await controller.undo();
      }
      await session.close();
    }
    _expect(sourceCount == 3, 'source-count');
    // File.readAsString removes a UTF-8 BOM; this oracle compares actual bytes
    // and the core's deliberately separate text/BOM representation instead.
    _expect(
      listEquals(await source.readAsBytes(), originalBytes) &&
          controller.buffer!.hasBom &&
          controller.buffer!.text == original.substring(1),
      'exact-source',
    );
  } finally {
    await service.close();
  }
}
