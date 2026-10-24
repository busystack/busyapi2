import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/src/platform/documentation_window_service.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.busystack.busyapi/documentation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late EngineProcess engine;
  late BusyProject project;
  late DocumentationPresentation presentation;
  late File source;
  late List<MethodCall> calls;
  final services = <DocumentationWindowService>[];
  Completer<void>? attachEntered, attachRelease, openEntered, openRelease;
  String? fault;
  Map<String, Object?> identity(Map args) => {
    for (final key in ['version', 'owner', 'id', 'snapshot']) key: args[key],
  };
  setUp(() async {
    calls = [];
    fault = null;
    attachEntered = null;
    attachRelease = null;
    openEntered = null;
    openRelease = null;
    temporary = await Directory.systemTemp.createTemp(
      'busyapi-documentation-channel-',
    );
    source = File('${temporary.path}/api.json');
    await source.writeAsString(
      '{"openapi":"3.2.1","info":{"title":"Captured 雪😀","version":"1"},"paths":{},"components":{"schemas":{"Boolean":false}}}',
    );
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
    project = await BusyProject.open(source.path, engine);
    presentation = await project.captureDocumentationPresentation(
      source.uri.toString(),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      if (fault == 'unavailable') {
        throw MissingPluginException('Synthetic missing component');
      }
      if (call.method == 'attach') {
        if (attachEntered?.isCompleted == false) attachEntered!.complete();
        await attachRelease?.future;
        return {'version': args['version'], 'owner': args['owner']};
      }
      if (call.method == 'open') {
        if (openEntered?.isCompleted == false) openEntered!.complete();
        await openRelease?.future;
        if (fault == 'module' || fault == 'runtime') {
          throw PlatformException(
            code: 'documentation.host.$fault',
            message: 'private loader path and source',
          );
        }
        if (fault == 'ack') {
          return {...identity(args), 'private': 'must not be logged'};
        }
        return identity(args);
      }
      if (call.method == 'close' && fault == 'cleanup') {
        throw PlatformException(
          code: 'private',
          message: 'private source value',
        );
      }
      return null;
    });
  });
  tearDown(() async {
    fault = null;
    if (attachRelease?.isCompleted == false) attachRelease!.complete();
    if (openRelease?.isCompleted == false) openRelease!.complete();
    for (final service in services) {
      await service.close();
    }
    services.clear();
    messenger.setMockMethodCallHandler(channel, null);
    project.close();
    await engine.close();
    await temporary.delete(recursive: true);
  });
  DocumentationWindowService create({Duration? timeout}) {
    final service = DocumentationWindowService(
      channel: channel,
      timeout: timeout ?? const Duration(seconds: 35),
    );
    services.add(service);
    return service;
  }

  Future<DocumentationWindowSession> open(
    DocumentationWindowService service, {
    Map<String, Uint8List>? resources,
    FutureOr<void> Function(DocumentationSourceAction)? onSource,
    bool Function()? cancelled,
  }) => service.open(
    presentation: presentation,
    resources:
        resources ??
        {'index.html': Uint8List.fromList(utf8.encode('<!doctype html>'))},
    title: 'Captured reference',
    loadingLabel: 'Loading',
    failureLabel: 'Failed',
    outdatedLabel: 'Outdated · 雪😀',
    onSource: onSource ?? (_) {},
    cancelled: cancelled,
  );
  Map<String, Object?> lastIdentity() => identity(
    calls.lastWhere((call) => call.method == 'open').arguments as Map,
  );
  Future<void> event(Map<String, Object?> value) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('event', value)),
      (reply) {
        try {
          channel.codec.decodeEnvelope(reply!);
          done.complete();
        } on Object catch (error, stack) {
          done.completeError(error, stack);
        }
      },
    );
    await done.future;
  }

  for (final component in ['module', 'runtime']) {
    test(
      'missing native $component remains source independent and retryable',
      () async {
        final service = create(),
            buffer = await project.buffer(source.uri.toString()),
            original = buffer.bytes();
        fault = component;
        await expectLater(
          open(service),
          throwsA(
            isA<CoreFailure>()
                .having(
                  (failure) => failure.code,
                  'code',
                  'documentation.host.$component',
                )
                .having(
                  (failure) => failure.message,
                  'message',
                  isNot(contains('private')),
                ),
          ),
        );
        expect(buffer.bytes(), original);
        fault = null;
        final session = await open(service);
        await event({...lastIdentity(), 'kind': 'ready'});
        await session.ready;
        expect(session.state, DocumentationWindowState.ready);
        expect(buffer.bytes(), original);
      },
    );
  }

  test('native creation acknowledgement is not renderer readiness; captured resources and opaque source actions stay owned', () async {
    final service = create(),
        bytes = Uint8List.fromList(utf8.encode('<!doctype html>')),
        navigated = <DocumentationSourceAction>[];
    attachEntered = Completer<void>();
    attachRelease = Completer<void>();
    final pending = open(
      service,
      resources: {'index.html': bytes},
      onSource: navigated.add,
    );
    await attachEntered!.future;
    bytes[0] = 0;
    attachRelease!.complete();
    final session = await pending,
        request =
            calls.lastWhere((call) => call.method == 'open').arguments as Map,
        owner = lastIdentity();
    expect(
      (request['resources'] as Map)['index.html'],
      utf8.encode('<!doctype html>'),
    );
    expect(request['sourceCount'], presentation.sourceActions.length);
    expect(session.state, DocumentationWindowState.loading);
    var ready = false;
    unawaited(
      session.ready.then((_) {
        ready = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ready, false);
    await event({...owner, 'kind': 'ready'});
    await session.ready;
    expect(session.state, DocumentationWindowState.ready);
    await event({...owner, 'snapshot': 'stale', 'kind': 'source', 'index': 0});
    await event({...owner, 'owner': '0' * 32, 'kind': 'source', 'index': 0});
    expect(navigated, isEmpty);
    await event({...owner, 'kind': 'source', 'index': 0});
    expect(navigated, [presentation.resolveSourceAction(0)]);
    await session.close();
    expect(session.state, DocumentationWindowState.closed);
    await event({...owner, 'kind': 'source', 'index': 0});
    expect(navigated.length, 1);
    expect(await source.readAsString(), contains('Captured 雪😀'));
  });
  test('a snapshot invalidated before native acknowledgement stays readable but never regains source authority', () async {
    final service = create(), navigated = <DocumentationSourceAction>[];
    openEntered = Completer<void>();
    openRelease = Completer<void>();
    final pending = open(service, onSource: navigated.add);
    await openEntered!.future;
    final owner = lastIdentity();
    final buffer = await project.buffer(source.uri.toString());
    project.store.replace(
      buffer.id,
      buffer.text.replaceFirst('Captured', 'Changed'),
    );
    await service.synchronize();
    await event({...owner, 'kind': 'ready'});
    openRelease!.complete();
    final session = await pending;
    await session.ready;
    expect(session.state, DocumentationWindowState.outdated);
    expect(calls.where((call) => call.method == 'outdated').length, 1);
    expect(
      (calls.lastWhere((call) => call.method == 'outdated').arguments
          as Map)['label'],
      'Outdated · 雪😀',
    );
    await event({...owner, 'kind': 'ready'});
    await event({...owner, 'kind': 'source', 'index': 0});
    expect(navigated, isEmpty);
    expect(session.state, DocumentationWindowState.outdated);
    expect(await source.readAsString(), contains('Captured 雪😀'));
  });
  test('replacing a Dart connection cannot inherit old window IDs, handlers or late replies', () async {
    final first = create(),
        oldNavigation = <DocumentationSourceAction>[],
        newNavigation = <DocumentationSourceAction>[];
    openEntered = Completer<void>();
    openRelease = Completer<void>();
    final oldPending = open(first, onSource: oldNavigation.add);
    final rejected = expectLater(
      oldPending,
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'documentation.host.closed',
        ),
      ),
    );
    await openEntered!.future;
    final oldIdentity = lastIdentity(), oldGate = openRelease!;
    openRelease = null;
    openEntered = null;
    final second = create(),
        current = await open(second, onSource: newNavigation.add),
        newIdentity = lastIdentity();
    expect(newIdentity['owner'], isNot(oldIdentity['owner']));
    expect(newIdentity['id'], oldIdentity['id']);
    await first.close();
    oldGate.complete();
    await rejected;
    await event({...oldIdentity, 'kind': 'ready'});
    await event({...oldIdentity, 'kind': 'source', 'index': 0});
    expect(current.state, DocumentationWindowState.loading);
    expect(oldNavigation, isEmpty);
    expect(newNavigation, isEmpty);
    await event({...newIdentity, 'kind': 'ready'});
    await current.ready;
    await event({...newIdentity, 'kind': 'source', 'index': 0});
    expect(newNavigation.length, 1);
    expect(calls.where((call) => call.method == 'close'), isEmpty);
  });
  test('malformed current native events fail closed and never forward paths, commands or invalid indexes', () async {
    final service = create(), navigated = <DocumentationSourceAction>[];
    for (final extra in [
      {'kind': 'source', 'index': 0, 'command': 'shell'},
      {'kind': 'source', 'index': 0.0},
      {'kind': 'source', 'index': presentation.sourceActions.length},
      {'kind': 'ready', 'version': 1.0},
      {'kind': 'unknown'},
    ]) {
      final session = await open(service, onSource: navigated.add),
          owner = lastIdentity();
      await event({...owner, 'kind': 'ready'});
      await session.ready;
      await event({...owner, ...extra});
      await session.close();
      expect(session.error?.code, 'documentation.host.protocol');
      expect(navigated, isEmpty);
    }
  });
  test('renderer crashes remain failed after readiness and errors contain no authored values', () async {
    final service = create(),
        session = await open(service),
        owner = lastIdentity();
    await event({...owner, 'kind': 'ready'});
    await session.ready;
    await event({
      ...owner,
      'kind': 'failed',
      'code': 'busyapi.documentation.process-terminated',
    });
    expect(session.state, DocumentationWindowState.failed);
    expect(session.error?.code, 'busyapi.documentation.process-terminated');
    await event({...owner, 'kind': 'ready'});
    expect(session.state, DocumentationWindowState.failed);
    await session.close();
  });
  test('cancelled and malformed creation is cleaned up; a failed close remains unconfirmed and retryable', () async {
    final service = create();
    fault = 'ack';
    await expectLater(
      open(service),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'documentation.host.protocol',
        ),
      ),
    );
    expect(calls.where((call) => call.method == 'close').length, 1);
    fault = null;
    openEntered = Completer<void>();
    openRelease = Completer<void>();
    var cancelled = false;
    final pending = open(service, cancelled: () => cancelled),
        rejected = expectLater(
          pending,
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              'documentation.host.cancelled',
            ),
          ),
        );
    await openEntered!.future;
    cancelled = true;
    openRelease!.complete();
    await rejected;
    openRelease = null;
    final session = await open(service);
    fault = 'cleanup';
    await expectLater(
      session.close(),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'documentation.host.cleanup',
        ),
      ),
    );
    expect(session.state, DocumentationWindowState.failed);
    expect(session.error.toString(), isNot(contains('private source value')));
    fault = null;
    await session.close();
    expect(session.state, DocumentationWindowState.closed);
  });
  test(
    'creation and readiness have independent bounded non-success paths',
    () async {
      final service = create(timeout: const Duration(milliseconds: 500));
      final session = await open(service);
      await expectLater(
        session.ready,
        throwsA(
          isA<CoreFailure>().having(
            (e) => e.code,
            'code',
            'documentation.host.timeout',
          ),
        ),
      );
      await session.close();
      expect(session.state, DocumentationWindowState.closed);
      openEntered = Completer<void>();
      openRelease = Completer<void>();
      final pending = open(service),
          failed = expectLater(
            pending,
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'documentation.host.timeout',
              ),
            ),
          );
      await openEntered!.future;
      await failed;
      openRelease!.complete();
    },
  );
  test('only the entry receives the 32-MiB located-document budget', () async {
    final session = await open(
      create(),
      resources: {
        'index.html': Uint8List(32 * 1024 * 1024),
        'vendor.js': Uint8List(16 * 1024 * 1024),
      },
    );
    final resources =
        calls
                .singleWhere((call) => call.method == 'open')
                .arguments['resources']
            as Map;
    expect((resources['index.html'] as Uint8List).length, 32 * 1024 * 1024);
    expect((resources['vendor.js'] as Uint8List).length, 16 * 1024 * 1024);
    await session.close();
  });

  test('resource bounds and unavailable components do not create native windows or prevent a later retry', () async {
    final service = create();
    for (final resources in <Map<String, Uint8List>>[
      {},
      {'../index.html': Uint8List(1)},
      {'index.html': Uint8List(0)},
      {'index.html': Uint8List(32 * 1024 * 1024 + 1)},
      {
        'index.html': Uint8List(1),
        'vendor.js': Uint8List(16 * 1024 * 1024 + 1),
      },
      {
        'index.html': Uint8List(1),
        for (var i = 0; i < 64; i++) 'extra_$i.js': Uint8List(1),
      },
    ]) {
      await expectLater(
        open(service, resources: resources),
        throwsA(isA<CoreFailure>()),
      );
    }
    expect(calls, isEmpty);
    fault = 'unavailable';
    await expectLater(
      open(service),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'documentation.host.unavailable',
        ),
      ),
    );
    fault = null;
    final session = await open(service);
    await event({...lastIdentity(), 'kind': 'ready'});
    await session.ready;
    expect(session.state, DocumentationWindowState.ready);
  });
}
