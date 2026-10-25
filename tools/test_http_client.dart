// Focused native HTTP-client entry. Uses the existing owned XTest/AT-SPI driver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/request_run.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart' show OperationRequestDraft;
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

Future<void> resize(Size size) async {
  await windowManager.setSize(size);
  // GTK acknowledges the resize request before Flutter receives new metrics.
  // Input coordinates must belong to the rendered size, not the previous frame.
  await waitFor(() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    return view != null && view.physicalSize / view.devicePixelRatio == size;
  }, 'native-resize-metrics');
  await WidgetsBinding.instance.endOfFrame;
}

Future<void> main(List<String> args) async {
  try {
    await exercise();
    if (Platform.environment['BUSYAPI_NATIVE_HEADER_COMPOSITIONS'] == '1') {
      stdout.writeln(
        'BUSYAPI_NATIVE_HEADER_COMPOSITIONS_PASS version=${Platform.environment['BUSYAPI_FILE_CONTROLS_VERSION']} format=${Platform.environment['BUSYAPI_FILE_CONTROLS_FORMAT']}',
      );
    }
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
  final version =
      Platform.environment['BUSYAPI_FILE_CONTROLS_VERSION'] ?? '3.2.1';
  final format = Platform.environment['BUSYAPI_FILE_CONTROLS_FORMAT'] ?? 'yaml';
  check(
    const ['2.0', '3.0.0', '3.0.4', '3.1.2', '3.2.1'].contains(version) &&
        const ['yaml', 'json'].contains(format),
    'fixture-version-format',
  );
  final swagger = version == '2.0';
  final headerCompositions =
      Platform.environment['BUSYAPI_NATIVE_HEADER_COMPOSITIONS'] == '1';
  check(!headerCompositions || !swagger, 'header-composition-family');
  final modern = version.startsWith('3.1.') || version.startsWith('3.2.');
  final multiline = version.startsWith('3.2.');
  final cookies = Platform.environment['BUSYAPI_NATIVE_HTTP_COOKIES'] == '1';
  final openId = Platform.environment['BUSYAPI_NATIVE_HTTP_OPENID'] == '1';
  final credentialMode =
      Platform.environment['BUSYAPI_NATIVE_CREDENTIAL_MODE'] ?? 'normal';
  check(
    const ['normal', 'basic-empty', 'key-empty'].contains(credentialMode),
    'credential-mode',
  );
  final basic = credentialMode == 'basic-empty';
  final emptyCredential = credentialMode != 'normal';
  final credential = emptyCredential ? '' : 'fixture-token';
  final binding =
      Platform.environment['BUSYAPI_NATIVE_HTTP_BINDING'] ?? 'named';
  check(const ['named', 'prototype', 'uri'].contains(binding), 'binding-mode');
  check(binding != 'uri' || version.startsWith('3.2.'), 'binding-family');
  check(!openId || binding == 'named', 'binding-authentication');
  check(!cookies || !swagger && !openId && binding == 'named', 'cookie-family');
  check(
    !emptyCredential ||
        !openId &&
            !cookies &&
            binding == 'named' &&
            Platform.environment['BUSYAPI_HTTP_INSPECT_ONLY'] != '1',
    'credential-mode-workflow',
  );
  final schemeName = binding == 'prototype'
      ? '__proto__'
      : binding == 'uri'
      ? 'security.$format#/Alias'
      : 'access';
  final apiKey =
      !basic &&
      (swagger || binding != 'named' || credentialMode == 'key-empty');
  check(!swagger || !openId, 'openid-family');
  final secretField = basic
      ? 'passwordRef'
      : apiKey
      ? 'secretRef'
      : openId
      ? 'accessTokenRef'
      : 'tokenRef';
  final evidencePrefix =
      'http-${version.replaceAll('.', '-')}-$format${openId ? '-openid' : ''}${binding == 'named' ? '' : '-$binding'}${cookies ? '-cookies' : ''}${emptyCredential ? '-$credentialMode' : ''}';
  final directory =
      Platform.environment['BUSYAPI_FILE_CONTROLS_DIRECTORY'] ?? '';
  check(
    RegExp(r'^/tmp/busyapi-file-controls-[A-Za-z0-9_-]+$').hasMatch(directory),
    'fixture-boundary',
  );
  final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ServerSocket? provider;
  var discoveryConnections = 0;
  if (openId) {
    provider = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((socket) {
      discoveryConnections++;
      socket.destroy();
    });
  }
  final discoveryUrl = openId
      ? 'https://127.0.0.1:${provider!.port}/.well-known/openid-configuration'
      : null;
  final observed = Completer<void>();
  final responseBytes = gzip.encode(
    utf8.encode('{"id":9007199254740993,"message":"native response"}'),
  );
  const responseCookies = [
    'lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT',
    'foo=bar',
  ];
  var validHeaders = true;
  endpoint.listen((request) async {
    final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    check(
      request.method == 'POST' && request.uri.toString() == '/items',
      'request-target',
    );
    check(utf8.decode(bytes) == 'hello', 'example-wire');
    if (cookies) {
      check(
        request.headers.value('cookie') == 'Colors=%E9%9B%AA&Colors=a%26b; zero=0&flag=false&%E9%9B%AA=0; Plain=100%25',
        'native-cookie-wire',
      );
    }
    check(
      basic
          ? request.headers.value('authorization') == 'Basic dXNlcjo=' &&
                request.headers.value('x-fixture-key') == null
          : apiKey
          ? request.headers.value('x-fixture-key') == credential &&
                request.headers.value('authorization') == null
          : request.headers.value('authorization') == 'Bearer $credential',
      'session-auth-wire',
    );
    check(
      request.headers.contentType?.mimeType == 'text/plain',
      'request-media',
    );
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('content-encoding', 'gzip');
    request.response.headers.noFolding('X-Values');
    request.response.headers.set('X-Values', [
      '0',
      (validHeaders ? '9007199254740993.000' : '9007199254740992') +
          (headerCompositions ? ',false,x' : ''),
    ]);
    request.response.headers.set('X-Empty', '');
    request.response.headers.set('X-Flag', 'false');
    if (modern) {
      request.response.headers.set('X-Any', 'literal,false');
      if (!validHeaders) request.response.headers.set('X-Reject', 'anything');
    }
    if (multiline) {
      request.response.headers.set(
        'Set-Cookie',
        validHeaders ? responseCookies : [responseCookies.first, 'foo=wrong'],
      );
    }
    for (var i = 0; i < 150; i++) {
      request.response.headers.add('X-Fixture-$i', 'retained-$i');
    }
    request.response.add(responseBytes);
    await request.response.close();
    if (!observed.isCompleted) observed.complete();
  });
  final project = Directory('$directory/project')..createSync();
  final file = File('${project.path}/api.$format');
  final declaration = basic
      ? swagger
            ? {'type': 'basic'}
            : {'type': 'http', 'scheme': 'basic'}
      : apiKey
      ? {'type': 'apiKey', 'in': 'header', 'name': 'X-Fixture-Key'}
      : openId
      ? {'type': 'openIdConnect', 'openIdConnectUrl': discoveryUrl}
      : {'type': 'http', 'scheme': 'bearer'};
  final fragment = File('${project.path}/security.$format');
  final fragmentText = format == 'yaml'
      ? '''# URI-owned authentication
Alias: {\$ref: '#/Provider~1~0'}
Provider/~: {type: apiKey, in: header, name: X-Fixture-Key}
'''
      : jsonEncode({
          'Alias': {r'$ref': '#/Provider~1~0'},
          'Provider/~': declaration,
        });
  if (binding == 'uri') fragment.writeAsStringSync(fragmentText);
  const schema = {
    'type': 'object',
    'required': ['id'],
    'properties': {
      'id': {'type': 'integer', 'minimum': '@exact-minimum'},
    },
  };
  final exactHeader = {
    'type': 'array',
    'minItems': 2,
    'maxItems': 2,
    'items': {
      'type': 'integer',
      'enum': [0, '@exact-response-header'],
    },
  };
  final responseHeaders = {
    'X-Values': swagger
        ? {...exactHeader, 'collectionFormat': 'csv'}
        : {
            'schema': headerCompositions
                ? {
                    ...exactHeader,
                    'minItems': 4,
                    'maxItems': 4,
                    'items': {
                      'anyOf': [
                        {
                          'type': 'integer',
                          'enum': [0, '@exact-response-header'],
                        },
                        {
                          'type': 'boolean',
                          'enum': [false],
                        },
                        {
                          'type': 'string',
                          'enum': ['x'],
                        },
                      ],
                    },
                  }
                : exactHeader,
          },
    'X-Empty': swagger
        ? {
            'type': 'string',
            'enum': [''],
          }
        : {
            'schema': {
              'type': 'string',
              'enum': [''],
            },
          },
    'X-Flag': swagger
        ? {
            'type': 'boolean',
            'enum': [false],
          }
        : {
            'schema': {
              'type': 'boolean',
              'enum': [false],
            },
          },
    if (modern) 'X-Any': {'schema': true},
    if (modern) 'X-Reject': {'schema': false},
    if (multiline)
      'Set-Cookie': {
        'content': {
          'text/plain': {
            'schema': {
              'type': 'string',
              'enum': [responseCookies.join('\n')],
            },
          },
        },
      },
  };
  final responseHeaderYaml = jsonEncode(responseHeaders)
      .replaceAll('"@exact-response-header"', '9007199254740993.00');
  final cookieParameters = <Map<String, Object?>>[
    {
      'name': 'Colors',
      'in': 'cookie',
      'required': true,
      'style': 'form',
      'explode': true,
      'schema': {
        'type': 'array',
        'minItems': 2,
        'maxItems': 2,
        'items': {
          'type': 'string',
          'enum': ['雪', 'a&b'],
        },
      },
      'example': ['雪', 'a&b'],
    },
    {
      'name': 'Object',
      'in': 'cookie',
      'required': true,
      'style': 'form',
      'explode': true,
      'schema': {
        'type': 'object',
        'required': ['zero', 'flag', '雪'],
        'additionalProperties': false,
        'properties': {
          'zero': {
            'type': 'integer',
            'enum': [0],
          },
          'flag': {
            'type': 'boolean',
            'enum': [false],
          },
          '雪': {
            'type': 'integer',
            'enum': [0],
          },
        },
      },
      'example': {'zero': 0, 'flag': false, '雪': 0},
    },
    {
      'name': 'Plain',
      'in': 'cookie',
      'required': true,
      'schema': {
        'type': 'string',
        'enum': ['100%'],
      },
      'example': '100%',
    },
  ];
  final contract = <String, Object?>{
    if (swagger) 'swagger': version else 'openapi': version,
    'info': {'title': 'Native HTTP client', 'version': '1'},
    'security': [
      {schemeName: <String>[]},
    ],
    if (swagger) ...{
      'host': '127.0.0.1:${endpoint.port}',
      'basePath': '/',
      'schemes': ['http'],
      'consumes': ['text/plain'],
      'produces': ['application/json'],
      'securityDefinitions': {schemeName: declaration},
    } else ...{
      'servers': [
        {'url': 'http://127.0.0.1:${endpoint.port}'},
      ],
      'components': {
        'securitySchemes': {if (binding != 'uri') schemeName: declaration},
      },
    },
    'paths': {
      '/items': {
        'post': {
          if (cookies) 'parameters': cookieParameters,
          if (swagger)
            'parameters': [
              {
                'name': 'payload',
                'in': 'body',
                'required': true,
                'schema': {'type': 'string'},
              },
            ]
          else
            'requestBody': {
              'required': true,
              'content': {
                'text/plain': {
                  'schema': <String, Object?>{},
                  'example': 'hello',
                },
              },
            },
          'responses': {
            '200': {
              'description': 'OK',
              'headers': responseHeaders,
              if (swagger)
                'schema': schema
              else
                'content': {
                  'application/json': {'schema': schema},
                },
            },
          },
        },
      },
    },
  };
  final yaml = swagger
      ? '''swagger: '2.0'
info: {title: Native HTTP client, version: '1'}
host: '127.0.0.1:${endpoint.port}'
basePath: /
schemes: [http]
consumes: [text/plain]
produces: [application/json]
security: [{${jsonEncode(schemeName)}: []}]
securityDefinitions: {${jsonEncode(schemeName)}: ${jsonEncode(declaration)}}
paths:
  /items:
    post:
      parameters: [{name: payload, in: body, required: true, schema: {type: string}}]
      responses:
        '200': {description: OK, headers: $responseHeaderYaml, schema: {type: object, required: [id], properties: {id: {type: integer, minimum: 9007199254740993}}}}
'''
      : '''openapi: $version
info: {title: Native HTTP client, version: '1'}
servers: [{url: 'http://127.0.0.1:${endpoint.port}'}]
security: [{${jsonEncode(schemeName)}: []}]
components: {securitySchemes: ${binding == 'uri' ? '{}' : '{${jsonEncode(schemeName)}: ${jsonEncode(declaration)}}'}}
paths:
  /items:
    post:
${cookies ? '      parameters: ${jsonEncode(cookieParameters)}\n' : ''}      requestBody:
        required: true
        content: {text/plain: {schema: {}, example: hello}}
      responses:
        '200': {description: OK, headers: $responseHeaderYaml, content: {application/json: {schema: {type: object, required: [id], properties: {id: {type: integer, minimum: 9007199254740993}}}}}}
''';
  final original = format == 'yaml'
      ? yaml
      : jsonEncode(contract)
            .replaceFirst('"@exact-minimum"', '9007199254740993')
            .replaceAll('"@exact-response-header"', '9007199254740993.00');
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
  check(
    owner!.specification?.declaredVersion == version,
    'native-family-owner',
  );
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
    if (editable) {
      await waitFor(
        () =>
            target.mounted &&
            target.widget is EditableText &&
            (target.widget as EditableText).focusNode.hasFocus,
        '$code-focused',
      );
    }
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
          schemeName: {secretField: reference},
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
    if (swagger) {
      run.bodyText = 'hello';
      run.refresh();
    } else {
      run.useBodyExample(media);
    }
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
    await resize(const Size(620, 820));
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
      'name': '$evidencePrefix-light-headers',
      'labels': ['Send', 'Search retained headers'],
    });
    await workspace!.widget.setTheme(ThemeMode.dark);
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await send({
      'kind': 'snapshot',
      'name': '$evidencePrefix-dark-headers',
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
      'name': '$evidencePrefix-dark-body',
      'labels': ['Search retained preview'],
      'texts': ['9007199254740993'],
    });
    await endpoint.close(force: true);
    await provider?.close();
    check(discoveryConnections == 0, 'manual-token-no-discovery');
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
  if (basic) {
    await click(
      (widget) =>
          widget is BusyApiGroupedTextEntry && widget.label == 'Basic username',
      'basic-username',
      editable: true,
    );
    await keys(['u', 's', 'e', 'r']);
    await waitFor(
      () =>
          elements(
            (widget) =>
                widget is BusyApiGroupedTextEntry &&
                widget.label == 'Basic username',
          ).any(
            (element) =>
                (element.widget as BusyApiGroupedTextEntry).controller?.text ==
                'user',
          ),
      'basic-username-value',
    );
  }
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
  if (!emptyCredential) {
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
  }
  await waitFor(() {
    final entry =
        elements(
              (w) =>
                  w is BusyApiGroupedTextEntry && w.label == 'Credential value',
            ).single.widget
            as BusyApiGroupedTextEntry;
    return entry.controller?.text == credential &&
        entry.controller?.value.composing.isValid == false;
  }, 'credential-visible-value');
  await row('Use for this session');
  final reference =
      run.plan!.configuration.environments['local']!.authentication['schemes']
          as Map;
  final tokenReference = (reference[schemeName] as Map)[secretField] as String;
  await waitFor(
    () => run.secrets.status(tokenReference)?.name == 'sessionOnly',
    'credential-session-submitted',
  );
  check(
    await run.secrets.read(tokenReference) == credential,
    'credential-stored-value',
  );
  if (swagger) {
    await click(
      (w) =>
          w is BusyApiGroupedTextEntry &&
          w.label == 'Authored text or exact JSON bytes',
      'swagger-native-body',
      editable: true,
    );
    await keys(['Control_L+a', 'h', 'e', 'l', 'l', 'o']);
  } else {
    await row('Examples · text/plain · json');
  }
  if (cookies) {
    for (final name in ['Colors', 'Object', 'Plain']) {
      await row('Examples · $name · json');
      final key = OperationRequestDraft.parameterKey('cookie', name);
      await waitFor(
        () =>
            run.values.containsKey(key) &&
            run.structuredValues.contains(key) &&
            !run.omittedValues.contains(key),
        'native-cookie-example-$name',
      );
    }
  }
  await waitFor(() => run.bodyText == 'hello' && run.canSend, 'example-ready');
  await keys(['Control_L+Return']);
  await observed.future.timeout(const Duration(seconds: 15));
  await waitFor(() => run.result != null && !run.busy, 'request-result');
  check(run.result!.conforming, 'conformance');
  check(
    run.result!.response.headers
            .where((header) => header.$1 == 'x-values')
            .map((header) => header.$2)
            .join('|') ==
        '0|9007199254740993.000${headerCompositions ? ',false,x' : ''}',
    'native-header-lines',
  );
  if (multiline) {
    check(
      run.result!.response.headers
              .where((header) => header.$1 == 'set-cookie')
              .map((header) => header.$2)
              .join('\n') ==
          responseCookies.join('\n'),
      'native-header-cookie-lines',
    );
  }
  final firstResponse = run.result;
  validHeaders = false;
  await keys(['Control_L+Return']);
  await waitFor(
    () =>
        run.result != null &&
        !run.busy &&
        !identical(run.result, firstResponse),
    'native-invalid-header-result',
  );
  check(
    run.result!.received.complete &&
        !run.result!.received.valid &&
        !run.result!.conforming,
    'native-header-refused',
  );
  for (final name in [
    'X-Values',
    if (modern) 'X-Reject',
    if (multiline) 'Set-Cookie',
  ]) {
    check(
      run.result!.received.findings.any((finding) {
        final source = finding['schema'];
        return finding['code'] == 'runtime.schema.incompatible' &&
            finding['location'] == name &&
            source is Map &&
            source['resource'] == file.uri.toString();
      }),
      'native-header-finding-$name',
    );
  }
  final invalidResponse = run.result;
  validHeaders = true;
  await keys(['Control_L+Return']);
  await waitFor(
    () =>
        run.result != null &&
        !run.busy &&
        !identical(run.result, invalidResponse),
    'native-recovered-header-result',
  );
  check(run.result!.conforming, 'native-header-recovered');
  check(run.result!.response.headers.length > 150, 'retained-header-total');
  final export = File('$directory/entity.bin');
  await run.result!.response.export(export.path);
  check(
    base64Encode(export.readAsBytesSync()) == base64Encode(responseBytes),
    'original-export',
  );
  final decoded = File('$directory/decoded.json');
  await run.result!.response.export(decoded.path, decoded: true);
  final decodedBytes = utf8.encode(
    '{"id":9007199254740993,"message":"native response"}',
  );
  check(
    base64Encode(await run.result!.response.decodedBytes()) ==
            base64Encode(decodedBytes) &&
        base64Encode(decoded.readAsBytesSync()) == base64Encode(decodedBytes),
    'decoded-export',
  );
  await resize(const Size(620, 820));
  await waitFor(
    () => elements((w) => w is RequestRunPanel).isNotEmpty,
    'narrow-mounted',
  );
  await click(
    (w) => w is BusyApiComboRow<String> && w.title == 'Responses',
    'response-view',
  );
  await send({'kind': 'menu-ready'});
  await keys(['Home', 'Down', 'Return']);
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
    'name': '$evidencePrefix-light-headers',
    'labels': ['Send', 'Search retained headers'],
  });
  await workspace!.widget.setTheme(ThemeMode.dark);
  await WidgetsBinding.instance.endOfFrame;
  await send({
    'kind': 'snapshot',
    'name': '$evidencePrefix-dark-headers',
    'labels': ['Send', 'Search retained headers'],
  });
  await click(
    (w) => w is BusyApiComboRow<String> && w.title == 'Responses',
    'response-body-view',
  );
  await send({'kind': 'menu-ready'});
  await keys(['Home', 'Return']);
  await waitFor(
    () =>
        elements(
          (w) =>
              w is BusyApiRawSourceView &&
              w.source.contains('9007199254740993'),
        ).length ==
        1,
    'retained-body-view',
  );
  final raw = elements(
    (w) => w is BusyApiRawSourceView && w.source.contains('9007199254740993'),
  ).single;
  await Scrollable.ensureVisible(raw, alignment: .6, duration: Duration.zero);
  await WidgetsBinding.instance.endOfFrame;
  await send({
    'kind': 'snapshot',
    'name': '$evidencePrefix-dark-body',
    'labels': ['Search retained preview'],
    'texts': ['9007199254740993'],
  });
  await endpoint.close(force: true);
  await provider?.close();
  check(discoveryConnections == 0, 'manual-token-no-discovery');
  await input.cancel();
  check(
    file.readAsStringSync() == original &&
        !File('${project.path}/busyapi.yaml').existsSync() &&
        owner!.project!.store.buffers.values.every(
          (buffer) => !buffer.text.contains('fixture-token'),
        ),
    'native-http-source-and-credential-isolation',
  );
  if (binding == 'uri') {
    check(
      fragment.readAsStringSync() == fragmentText,
      'native-uri-definition-preserved',
    );
  }
  stdout.writeln(
    'BUSYAPI_NATIVE_HTTP_HEADERS_PASS version=$version format=$format wire=separate-lines schema=exact-and-boolean retries=invalid-recovered source=unchanged',
  );
  stdout.writeln(
    'BUSYAPI_NATIVE_CREDENTIAL_PASS version=$version format=$format mode=$credentialMode source=unchanged',
  );
  stdout.writeln(
    'BUSYAPI_NATIVE_HTTP_PASS version=$version format=$format openId=$openId binding=$binding cookies=$cookies',
  );
}
