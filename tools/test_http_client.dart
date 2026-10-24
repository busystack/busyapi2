// Focused native HTTP-client entry. Uses the existing owned XTest/AT-SPI driver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:busyapi/src/platform/secret_store.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';

List<Element> elements(bool Function(Widget) matches) {
  final found = <Element>[];
  void visit(Element e) {
    if (matches(e.widget)) found.add(e);
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

void check(bool okay, String code) {
  if (!okay) throw StateError(code);
}

Future<void> waitFor(bool Function() ready, String code) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    check(clock.elapsed < const Duration(seconds: 30), code);
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main(List<String> args) async {
  try {
    await exercise();
    stdout.writeln(
      Platform.environment['BUSYAPI_HTTP_INSPECT_ONLY'] == '1'
          ? 'BUSYAPI_FILE_CONTROLS_PASS HTTP-client native controller wire gzip headers narrow dark original-bytes AT-SPI (pointer/IME not qualified)'
          : 'BUSYAPI_FILE_CONTROLS_PASS HTTP-client native setup session-secret example send gzip headers keyboard narrow dark original-bytes',
    );
    exit(0);
  } on Object catch (error) {
    stderr.writeln(
      'BUSYAPI_FILE_CONTROLS_FAILED HTTP-client ${error is StateError ? error.message : error.runtimeType}',
    );
    exit(1);
  }
}

Future<void> exercise() async {
  final directory =
      Platform.environment['BUSYAPI_FILE_CONTROLS_DIRECTORY'] ?? '';
  check(
    RegExp(r'^/tmp/busyapi-file-controls-[A-Za-z0-9_-]+$').hasMatch(directory),
    'fixture-boundary',
  );
  final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final observed = Completer<void>();
  final responseBytes = gzip.encode(
    utf8.encode('{"id":9007199254740993,"message":"native response"}'),
  );
  endpoint.listen((request) async {
    final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    check(
      request.method == 'POST' && request.uri.path == '/items',
      'request-target',
    );
    check(utf8.decode(bytes) == 'hello', 'example-wire');
    check(
      request.headers.value('authorization') == 'Bearer fixture-token',
      'session-auth-wire',
    );
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('content-encoding', 'gzip');
    for (var i = 0; i < 150; i++) {
      request.response.headers.add('X-Fixture-$i', 'retained-$i');
    }
    request.response.add(responseBytes);
    await request.response.close();
    if (!observed.isCompleted) observed.complete();
  });
  final project = Directory('$directory/project')..createSync();
  final file = File('${project.path}/openapi.yaml');
  final original =
      '''openapi: 3.2.1
info: {title: Native HTTP client, version: '1'}
servers: [{url: 'http://127.0.0.1:${endpoint.port}'}]
security: [{access: []}]
components: {securitySchemes: {access: {type: http, scheme: bearer}}}
paths:
  /items:
    post:
      requestBody:
        required: true
        content: {text/plain: {schema: {}, example: hello}}
      responses:
        '200': {description: OK, content: {application/json: {schema: {type: object, required: [id], properties: {id: {type: integer}}}}}}
''';
  file.writeAsStringSync(original);
  await application.main([file.path]);
  WorkspaceController? owner;
  WorkspaceScreenState? workspace;
  await waitFor(() {
    for (final e in elements((w) => w is WorkspaceScreen)) {
      if (e is StatefulElement && e.state is WorkspaceScreenState) {
        workspace = e.state as WorkspaceScreenState;
        owner = workspace!.c;
      }
    }
    return owner?.projection != null;
  }, 'workspace-open');
  await windowManager
      .focus(); // Focus only this explicit, owned native fixture.
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
      void visit(Element e) {
        if (e.widget is EditableText) inputs.add(e);
        e.visitChildren(visit);
      }

      target.visitChildren(visit);
      check(inputs.length == 1, '$code-editable');
      target = inputs.single;
    }
    await Scrollable.ensureVisible(
      target,
      alignment: .35,
      duration: Duration.zero,
    );
    await WidgetsBinding.instance.endOfFrame;
    final box = target.findRenderObject() as RenderBox,
        point = box.localToGlobal(box.size.center(Offset.zero));
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

  Future<void> row(String title) =>
      click((w) => w is BusyApiActionRow && w.title == title, 'row-$title');
  Future<void> dialogButton(String title) => click(
    (w) => w is BusyApiDialogButton && w.label == title,
    'button-$title',
  );
  final operation = Map<String, dynamic>.from(
    (owner!.projection!['operations'] as List).single as Map,
  );
  await owner!.selectObject(operation);
  if (Platform.environment['BUSYAPI_HTTP_INSPECT_ONLY'] == '1') {
    final run = workspace!.requestRun;
    await run.open(operation);
    const reference = '123e4567-e89b-42d3-a456-426614174000';
    final configuration = await run.plan!.planEnvironment('local', {
      'baseUrl': 'http://127.0.0.1:${endpoint.port}',
      'authentication': {
        'alternative': 0,
        'schemes': {
          'access': {'tokenRef': reference},
        },
      },
    });
    await owner!.applyRefactoring(owner!.project!, configuration);
    await run.reconcileDraft();
    run.selectEnvironment('local');
    await run.writeSecret(
      reference,
      'fixture-token',
      SecretPersistence.sessionOnly,
    );
    final media =
        (run.plan!.result['requestBody']['content'] as List).single as Map;
    run.useBodyExample(media);
    await run.send();
    await observed.future.timeout(const Duration(seconds: 15));
    check(run.result?.conforming == true, 'native-render-conformance');
    check(run.result!.response.headers.length > 150, 'native-render-headers');
    final output = File('$directory/entity.bin');
    await run.result!.response.export(output.path);
    check(
      base64Encode(output.readAsBytesSync()) == base64Encode(responseBytes),
      'native-render-original-export',
    );
    check(
      file.readAsStringSync() == original &&
          !File('${project.path}/busyapi.yaml').existsSync(),
      'native-render-source-unchanged',
    );
    await windowManager.setSize(const Size(620, 820));
    await WidgetsBinding.instance.endOfFrame;
    final selector =
        elements((w) => w is BusyApiComboRow<String> && w.title == 'Responses')
                .single
                .widget
            as BusyApiComboRow<String>;
    selector.onSelected('headers');
    await WidgetsBinding.instance.endOfFrame;
    final search = elements(
      (w) =>
          w is BusyApiGroupedTextEntry && w.label == 'Search retained headers',
    ).single;
    await Scrollable.ensureVisible(
      search,
      alignment: .45,
      duration: Duration.zero,
    );
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await send({
      'kind': 'snapshot',
      'name': 'http-light-headers',
      'labels': ['Send', 'Search retained headers'],
    });
    await workspace!.widget.setTheme(ThemeMode.dark);
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await send({
      'kind': 'snapshot',
      'name': 'http-dark-headers',
      'labels': ['Send', 'Search retained headers'],
    });
    selector.onSelected('body');
    await WidgetsBinding.instance.endOfFrame;
    final raw = elements(
      (w) => w is BusyApiRawSourceView && w.source.contains('9007199254740993'),
    ).single;
    await Scrollable.ensureVisible(raw, alignment: .6, duration: Duration.zero);
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await send({
      'kind': 'snapshot',
      'name': 'http-dark-body',
      'labels': ['Search retained preview'],
      'texts': ['9007199254740993'],
    });
    await endpoint.close(force: true);
    await input.cancel();
    return;
  }
  await row('Try');
  final run = workspace!.requestRun;
  await waitFor(() => run.plan != null, 'request-open');
  await click(
    (w) => w is BusyApiComboRow && w.title == 'Authentication',
    'authentication',
  );
  await send({'kind': 'menu-ready'});
  await keys(['Home', 'Return']);
  await row('Set up environment and authentication…');
  await dialogButton('Review configuration changes');
  await dialogButton('Apply');
  await waitFor(
    () =>
        run.environment == 'local' &&
        run.plan?.configuration.environments['local'] != null &&
        !run.outdated,
    'setup-applied',
  );
  check(
    !File('${project.path}/busyapi.yaml').existsSync(),
    'setup-staged-not-published',
  );
  check(file.readAsStringSync() == original, 'contract-untouched');
  await click(
    (w) => w is BusyApiGroupedTextEntry && w.label == 'Credential value',
    'credential',
    editable: true,
  );
  await keys([
    'f',
    'i',
    'x',
    't',
    'u',
    'r',
    'e',
    'minus',
    't',
    'o',
    'k',
    'e',
    'n',
  ]);
  await waitFor(() {
    final entry =
        elements(
              (w) =>
                  w is BusyApiGroupedTextEntry && w.label == 'Credential value',
            ).single.widget
            as BusyApiGroupedTextEntry;
    return entry.controller?.text == 'fixture-token' &&
        entry.controller?.value.composing.isValid == false;
  }, 'credential-visible-value');
  await row('Use for this session');
  final reference =
      run.plan!.configuration.environments['local']!.authentication['schemes']
          as Map;
  final tokenReference = (reference['access'] as Map)['tokenRef'] as String;
  await waitFor(
    () => run.secrets.status(tokenReference)?.name == 'sessionOnly',
    'credential-session-submitted',
  );
  check(
    await run.secrets.read(tokenReference) == 'fixture-token',
    'credential-stored-value',
  );
  await row('Examples · text/plain · json');
  await waitFor(() => run.bodyText == 'hello' && run.canSend, 'example-ready');
  await keys(['Control_L+Return']);
  await observed.future.timeout(const Duration(seconds: 15));
  await waitFor(() => run.result != null && !run.busy, 'request-result');
  check(run.result!.conforming, 'conformance');
  check(run.result!.response.headers.length > 150, 'retained-header-total');
  final export = File('$directory/entity.bin');
  await run.result!.response.export(export.path);
  check(
    base64Encode(export.readAsBytesSync()) == base64Encode(responseBytes),
    'original-export',
  );
  await windowManager.setSize(const Size(620, 820));
  await waitFor(
    () => elements((w) => w is RequestRunPanel).isNotEmpty,
    'narrow-mounted',
  );
  await click(
    (w) => w is BusyApiComboRow<String> && w.title == 'Responses',
    'response-view',
  );
  await send({'kind': 'menu-ready'});
  await keys(['Down', 'Return']);
  await waitFor(
    () => elements(
      (w) =>
          w is BusyApiComboRow<String> &&
          w.title == 'Responses' &&
          w.selected == 'headers',
    ).isNotEmpty,
    'headers-selected',
  );
  await send({
    'kind': 'snapshot',
    'name': 'http-light-headers',
    'labels': ['Send', 'Search retained headers'],
  });
  await workspace!.widget.setTheme(ThemeMode.dark);
  await WidgetsBinding.instance.endOfFrame;
  await send({
    'kind': 'snapshot',
    'name': 'http-dark-headers',
    'labels': ['Send', 'Search retained headers'],
  });
  await endpoint.close(force: true);
  await input.cancel();
}
