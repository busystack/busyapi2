// BusyMark-derived platform-channel ownership pattern, Copyright 2026 BusyStack.
// Apache-2.0. Immutable BusyAPI documentation; no renderer/project code loading.
import 'dart:async';
import 'dart:math';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum DocumentationWindowState {
  loading,
  ready,
  outdated,
  failed,
  closing,
  closed,
}

/// One native connection owns all of its windows. Replacing/restarting the
/// Dart owner revokes the old connection; window IDs alone are not authority.
class DocumentationWindowService {
  DocumentationWindowService({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 35),
  }) : _channel =
           channel ?? const MethodChannel('io.busystack.busyapi/documentation'),
       _token = _newToken() {
    final previous = _owners[_key];
    _owners[_key] = this;
    previous?._retire();
    _channel.setMethodCallHandler(_event);
  }
  static final _owners =
      <(BinaryMessenger, String), DocumentationWindowService>{};
  static String _newToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  final MethodChannel _channel;
  final String _token;
  final Duration timeout;
  final _sessions = <int, DocumentationWindowSession>{};
  Future<void>? _attachment;
  int _nextId = 0;
  bool _disposed = false;
  (BinaryMessenger, String) get _key =>
      (_channel.binaryMessenger, _channel.name);
  bool get _current => !_disposed && identical(_owners[_key], this);
  Map<String, Object?> get _connection => {'version': 1, 'owner': _token};

  /// Attachment creates no WebKit context and executes no renderer work.
  Future<void> attach() {
    _active();
    return _attachment ??= _attach();
  }

  Future<void> _attach() async {
    try {
      final result = await _call('attach', _connection);
      _active();
      if (!_exact(result, _connection)) throw _failure('protocol');
    } on Object {
      _attachment = null;
      rethrow;
    }
  }

  Future<DocumentationWindowSession> open({
    required DocumentationPresentation presentation,
    required Map<String, Uint8List> resources,
    required String title,
    required String loadingLabel,
    required String failureLabel,
    required String outdatedLabel,
    required FutureOr<void> Function(DocumentationSourceAction) onSource,
    bool Function()? cancelled,
  }) async {
    void active() {
      _active();
      if (cancelled?.call() == true) throw _failure('cancelled');
    }

    active();
    if (_sessions.length >= 3 || _nextId == 0x7fffffff) {
      throw _failure('capacity');
    }
    for (final label in [title, loadingLabel, failureLabel, outdatedLabel]) {
      if (label.isEmpty || label.contains('\u0000') || label.length > 1024) {
        throw _failure('protocol');
      }
    }
    if (resources.isEmpty ||
        resources.length > 64 ||
        resources['index.html']?.isNotEmpty != true) {
      throw _failure('resources');
    }
    var total = 0;
    final frozen = <String, Uint8List>{};
    for (final entry in resources.entries) {
      if (!RegExp(r'^[A-Za-z0-9_-]+\.(html|mjs|js|json|css|svg|woff2?)$')
              .hasMatch(entry.key) ||
          entry.key.length > 128 ||
          entry.value.length >
              (entry.key == 'index.html' ? 32 : 16) * 1024 * 1024 ||
          (total += entry.value.length) > 128 * 1024 * 1024) {
        throw _failure('resources');
      }
      frozen[entry.key] = Uint8List.fromList(entry.value).asUnmodifiableView();
    }
    await attach();
    active();
    if (_sessions.length >= 3) throw _failure('capacity');
    final session = DocumentationWindowSession._(
      this,
      ++_nextId,
      presentation,
      outdatedLabel,
      onSource,
    );
    _sessions[session.id] = session;
    try {
      final result = await _call('open', {
        ...session._identity,
        'title': title,
        'loading': loadingLabel,
        'failure': failureLabel,
        'resources': frozen,
        'sourceCount': presentation.sourceActions.length,
      });
      active();
      if (!_exact(result, session._identity)) throw _failure('protocol');
      session._acknowledged = true;
      session._updateReady();
      if (presentation.outdated) await session.markOutdated();
      return session;
    } on Object catch (error) {
      session._fail(error is CoreFailure ? error : _failure('failure'));
      try {
        await session.close();
      } on Object {
        throw _failure('cleanup');
      }
      rethrow;
    }
  }

  /// Call from the native workspace's existing change notification, not from
  /// a hidden renderer timer or a second document/dependency monitor.
  Future<void> synchronize() async {
    if (!_current) return;
    await Future.wait([
      for (final session in _sessions.values.toList())
        if (session.presentation.outdated) session.markOutdated(),
    ]);
  }

  Future<Object?> _call(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel
          .invokeMethod<Object?>(method, arguments)
          .timeout(timeout);
    } on MissingPluginException {
      throw _failure('unavailable');
    } on TimeoutException {
      throw _failure('timeout');
    } on PlatformException catch (error) {
      const known = {
        'documentation.host.protocol',
        'documentation.host.capacity',
        'documentation.host.owner',
        'documentation.host.resources',
        'documentation.host.closed',
        'documentation.host.module',
        'documentation.host.runtime',
      };
      throw known.contains(error.code)
          ? CoreFailure(
              error.code,
              'Documentation window request did not complete',
            )
          : _failure('failure');
    } on Object {
      throw _failure('failure');
    }
  }

  Future<Object?> _event(MethodCall call) async {
    if (!_current || call.method != 'event') return null;
    final value = call.arguments;
    if (value is! Map || value['owner'] != _token || value['id'] is! int) {
      return null;
    }
    final session = _sessions[value['id']];
    if (session == null ||
        value['snapshot'] != session.presentation.snapshot.identity) {
      return null;
    }
    final kind = value['kind'];
    final keys = {
      ...session._identity.keys,
      'kind',
      if (kind == 'source') 'index',
      if (kind == 'failed' || kind == 'blocked') 'code',
    };
    if (value['version'] is! int ||
        value['version'] != 1 ||
        value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key))) {
      session._fail(_failure('protocol'));
      unawaited(session.close().catchError((Object _) {}));
      return null;
    }
    switch (kind) {
      case 'ready':
        session._reportedReady = true;
        session._updateReady();
      case 'closed':
        session._finishClose();
      case 'failed':
        const codes = {
          'busyapi.documentation.process-terminated',
          'busyapi.documentation.renderer-failed',
          'busyapi.documentation.timeout',
          'busyapi.documentation.load-failed',
          'busyapi.documentation.isolation-unavailable',
        };
        session._fail(
          codes.contains(value['code'])
              ? CoreFailure(
                  value['code'] as String,
                  'Documentation rendering did not complete',
                )
              : _failure('protocol'),
        );
      case 'blocked':
        const codes = {
          'resource',
          'navigation',
          'permission',
          'popup',
          'download',
          'context-menu',
          'message',
        };
        if (!codes.contains(value['code'])) {
          session._fail(_failure('protocol'));
          unawaited(session.close().catchError((Object _) {}));
        }
      case 'source':
        if (value['index'] is! int ||
            (value['index'] as int) < 0 ||
            (value['index'] as int) >=
                session.presentation.sourceActions.length ||
            ![
              DocumentationWindowState.ready,
              DocumentationWindowState.outdated,
            ].contains(session.state)) {
          session._fail(_failure('protocol'));
          unawaited(session.close().catchError((Object _) {}));
          return null;
        }
        if (session.state == DocumentationWindowState.outdated ||
            session.presentation.outdated) {
          await session.markOutdated();
          return null;
        }
        try {
          final action = session.presentation.resolveSourceAction(
            value['index'] as int,
          );
          if (!_current || session.state != DocumentationWindowState.ready) {
            return null;
          }
          await session._onSource(action);
        } on Object {
          session._error = CoreFailure(
            'documentation.source.navigation',
            'The captured source is unavailable or navigation was declined',
          );
          if (session.presentation.outdated) await session.markOutdated();
          session._notify();
        }
      default:
        session._fail(_failure('protocol'));
        unawaited(session.close().catchError((Object _) {}));
    }
    return null;
  }

  static bool _exact(Object? result, Map<String, Object?> expected) =>
      result is Map &&
      result.length == expected.length &&
      expected.entries.every(
        (entry) =>
            result[entry.key].runtimeType == entry.value.runtimeType &&
            result[entry.key] == entry.value,
      );
  static CoreFailure _failure(String code) => CoreFailure(
    'documentation.host.$code',
    'Documentation window request did not complete',
  );
  void _active() {
    if (!_current) throw _failure('closed');
  }

  void _retire() {
    _disposed = true;
    for (final session in _sessions.values.toList()) {
      session._finishClose();
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    final owned = _current, attachment = _attachment;
    _retire();
    if (owned) {
      _owners.remove(_key);
      _channel.setMethodCallHandler(null);
      try {
        await attachment;
      } on Object {
        /* Attachment may have lost its Dart owner while in flight. */
      }
      if (await _call('detach', _connection) != null) {
        throw _failure('protocol');
      }
    }
  }
}

class DocumentationWindowSession extends ChangeNotifier {
  DocumentationWindowSession._(
    this._owner,
    this.id,
    this.presentation,
    this._outdatedLabel,
    this._onSource,
  ) {
    _ready.future.ignore();
    _deadline = Timer(_owner.timeout, () {
      _fail(DocumentationWindowService._failure('timeout'));
      unawaited(close().catchError((Object _) {}));
    });
  }
  final DocumentationWindowService _owner;
  final int id;
  final DocumentationPresentation presentation;
  final String _outdatedLabel;
  final FutureOr<void> Function(DocumentationSourceAction) _onSource;
  final _ready = Completer<void>();
  late final Timer _deadline;
  DocumentationWindowState _state = DocumentationWindowState.loading;
  CoreFailure? _error;
  bool _acknowledged = false, _reportedReady = false, _disposed = false;
  Future<void>? _closing, _outdating;
  DocumentationWindowState get state => _state;
  CoreFailure? get error => _error;
  Future<void> get ready => _ready.future;
  Map<String, Object?> get _identity => {
    ..._owner._connection,
    'id': id,
    'snapshot': presentation.snapshot.identity,
  };
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _updateReady() {
    if (!_acknowledged ||
        !_reportedReady ||
        ![
          DocumentationWindowState.loading,
          DocumentationWindowState.outdated,
        ].contains(_state)) {
      return;
    }
    _state =
        presentation.outdated || _state == DocumentationWindowState.outdated
        ? DocumentationWindowState.outdated
        : DocumentationWindowState.ready;
    if (!_ready.isCompleted) _ready.complete();
    _deadline.cancel();
    _notify();
  }

  void _fail(CoreFailure error) {
    if (_state == DocumentationWindowState.closed) return;
    _error = error;
    _state = DocumentationWindowState.failed;
    _deadline.cancel();
    if (!_ready.isCompleted) _ready.completeError(error);
    _notify();
  }

  Future<void> markOutdated() {
    if (_state == DocumentationWindowState.closed ||
        _state == DocumentationWindowState.failed ||
        _state == DocumentationWindowState.closing) {
      return Future.value();
    }
    _state = DocumentationWindowState.outdated;
    _notify();
    return !_acknowledged ? Future.value() : _outdating ??= _setOutdated();
  }

  Future<void> _setOutdated() async {
    if (!_acknowledged || !_owner._current) return;
    try {
      if (await _owner._call('outdated', {
            ..._identity,
            'label': _outdatedLabel,
          }) !=
          null) {
        throw DocumentationWindowService._failure('protocol');
      }
    } on Object {
      if (_owner._current && _state != DocumentationWindowState.closed) {
        _fail(DocumentationWindowService._failure('protocol'));
      }
    }
  }

  void _finishClose() {
    if (_state == DocumentationWindowState.closed) return;
    _state = DocumentationWindowState.closed;
    _deadline.cancel();
    _owner._sessions.remove(id);
    if (!_ready.isCompleted) {
      _ready.completeError(DocumentationWindowService._failure('closed'));
    }
    _notify();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_state == DocumentationWindowState.closed) return;
    _state = DocumentationWindowState.closing;
    _notify();
    if (!_owner._current) {
      _finishClose();
      return;
    }
    try {
      if (await _owner._call('close', _identity) != null) {
        throw DocumentationWindowService._failure('protocol');
      }
      _finishClose();
    } on Object {
      if (_state == DocumentationWindowState.closed) return;
      _closing = null;
      final failure = DocumentationWindowService._failure('cleanup');
      _fail(failure);
      throw failure;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}
