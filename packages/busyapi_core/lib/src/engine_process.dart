import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'model.dart';

Future<Map<String, dynamic>> _decodeFrame(Uint8List bytes) async {
  Map<String, dynamic> decode() =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  return bytes.length < 262144 ? decode() : Isolate.run(decode);
}

Future<Uint8List> _encodeRequest(Map<String, Object?> value, bool large) async {
  Uint8List encode() => utf8.encode(jsonEncode(value));
  return large ? Isolate.run(encode) : encode();
}

class _EngineRequest {
  _EngineRequest(this.id, this.method, this.params, this.cost);
  final String id, method;
  final Map<String, Object?> params;
  final int cost;
  final result = Completer<Map<String, dynamic>>();
  final released = Completer<void>();
  Timer? deadline;
  bool started = false, sent = false, cancelled = false;
  bool get control => const ['hello', 'cancel', 'shutdown'].contains(method);
  int get priority => control
      ? -1
      : const ['analyse', 'propose', 'assistSource'].contains(method)
      ? 0
      : const [
          'evaluateSchemas',
          'govern',
          'inspectPolicyCode',
          'resolvePolicyCode',
          'reviewPolicyCode',
          'referenceDisplay',
        ].contains(method)
      ? 3
      : const [
          'inspect',
          'readDataValue',
          'schemaTree',
          'referenceChoices',
          'referencePage',
          'semanticSearch',
        ].contains(method)
      ? 2
      : 1;
}

class EngineProcess {
  /// Desktop bundles and compiled CLI use the same relocatable asset layout.
  /// Neither the current directory nor a globally installed Node is consulted.
  factory EngineProcess.bundled({String? applicationExecutable}) {
    final directory = p.dirname(
      applicationExecutable ?? Platform.resolvedExecutable,
    );
    return EngineProcess(
      executable: p.join(directory, 'libexec', 'busyapi', 'node'),
      helper: p.join(directory, 'libexec', 'busyapi', 'engine.cjs'),
    );
  }

  EngineProcess({
    required String executable,
    required String helper,
    this.timeout = const Duration(seconds: 20),
  }) : executable = File(executable).absolute.path,
       helper = File(helper).absolute.path;
  final String executable, helper;
  final Duration timeout;
  Process? _process;
  Future<void>? _starting;
  bool _closed = false;
  int _serial = 0;
  String? assetIdentity;
  final _pending = <String, _EngineRequest>{};
  final _waiting = <_EngineRequest>[];
  final _cancelling = <String, Future<void>>{};
  int _retainedRequestBytes = 0;
  final _header = <int>[];
  final _body = BytesBuilder(copy: false);
  int? _frameSize;
  Future<void>? _decoding;
  int _queuedFrames = 0, _processEpoch = 0;
  int logBytes = 0;
  final _cancelled = <String>{};
  Future<void> start() async {
    if (_closed) {
      throw CoreFailure('engine.closed', 'Engine has been shut down');
    }
    if (_process != null) return;
    if (_starting != null) return _starting;
    _starting = _launch();
    try {
      await _starting;
    } finally {
      _starting = null;
    }
  }

  Future<void> _launch() async {
    final missing = <String>[
      if (!await File(executable).exists()) 'Node 24.15.0 runtime: $executable',
      if (!await File(helper).exists()) 'contract helper: $helper',
    ];
    if (missing.isNotEmpty) {
      throw CoreFailure(
        'engine.assets',
        'Required contract assets are missing:\n${missing.join('\n')}\n'
            'Rebuild the Linux bundle with its contract assets, or reinstall '
            'the complete application. Project files have not been removed.',
      );
    }
    assetIdentity = contentIdentity(await File(helper).readAsBytes());
    final env = Map<String, String>.from(Platform.environment)
      ..removeWhere(
        (key, _) =>
            key.startsWith('NODE_') ||
            key.startsWith('NPM_') ||
            key.startsWith('npm_') ||
            key.startsWith('LD_') ||
            key.startsWith('DYLD_') ||
            key == 'LD_LIBRARY_PATH' ||
            key == 'DYLD_INSERT_LIBRARIES' ||
            key == 'OPENSSL_CONF' ||
            key == 'OPENSSL_MODULES' ||
            key == 'OPENSSL_ENGINES',
      );
    final process = await Process.start(
      executable,
      ['--disable-proto=throw', helper],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: File(helper).parent.path,
      runInShell: false,
    );
    if (_closed) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw CoreFailure('engine.closed', 'Engine has been shut down');
    }
    _process = process;
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object error) {
          if (identical(_process, process)) {
            _fail('engine.input', 'Helper input closed unexpectedly');
          }
        },
      ),
    );
    _processEpoch++;
    _decoding = null;
    _header.clear();
    _body.clear();
    _frameSize = null;
    process.stdout.listen(
      (data) {
        if (identical(_process, process)) _receive(data);
      },
      onError: (_) {
        if (identical(_process, process)) {
          _fail('engine.output', 'Cannot read helper output');
        }
      },
      onDone: () {
        if (identical(_process, process) &&
            (_header.isNotEmpty || _frameSize != null)) {
          _fail('engine.truncated', 'Helper output was truncated');
        }
      },
    );
    process.stderr.listen((data) {
      logBytes = (logBytes + data.length).clamp(0, 8192);
    }); // Never retain user data from helper logs.
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          _fail('engine.exit', 'Contract engine exited ($code)');
        }
      }),
    );
    late Map<String, dynamic> hello;
    try {
      hello = await _send('hello', {});
    } on Object {
      await _kill();
      rethrow;
    }
    if (hello['protocol'] != 1 ||
        hello['engineVersion'] != '0.1.0' ||
        hello['nodeVersion'] != '24.15.0' ||
        hello['range'] != 'half-open' ||
        hello['lineBase'] != 1 ||
        hello['columnBase'] != 1 ||
        hello['bom'] != 'excluded' ||
        hello['offsetUnit'] != 'utf16' ||
        hello['lineEndings'] != 'raw') {
      await _kill();
      throw CoreFailure(
        'engine.handshake',
        'Incompatible contract engine protocol',
      );
    }
  }

  void _receive(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var offset = 0;
    while (offset < bytes.length) {
      if (_frameSize == null) {
        while (_header.length < 4 && offset < bytes.length) {
          _header.add(bytes[offset++]);
        }
        if (_header.length < 4) return;
        final size = ByteData.sublistView(Uint8List.fromList(_header))
            .getUint32(0);
        _header.clear();
        if (size > 64 * 1024 * 1024 || size < 2) {
          _fail('engine.frame', 'Malformed helper frame');
          unawaited(_kill());
          return;
        }
        _frameSize = size;
      }
      final count = (_frameSize! - _body.length).clamp(
        0,
        bytes.length - offset,
      );
      _body.add(Uint8List.sublistView(bytes, offset, offset + count));
      offset += count;
      if (_body.length < _frameSize!) return;
      final frame = _body.takeBytes();
      _frameSize = null;
      if (_queuedFrames >= 8) {
        _fail('engine.queue', 'Helper exceeded the bounded response queue');
        unawaited(_kill());
        return;
      }
      _queuedFrames++;
      final epoch = _processEpoch;
      _decoding = (_decoding ?? Future<void>.value()).then(
        (_) => _acceptFrame(frame, epoch),
      );
    }
  }

  Future<void> _acceptFrame(Uint8List frame, int epoch) async {
    try {
      if (epoch != _processEpoch || _process == null) return;
      try {
        final value = await _decodeFrame(frame);
        if (epoch != _processEpoch || _process == null) return;
        if (value['protocol'] != 1 || value['id'] is! String) {
          throw const FormatException();
        }
        final request = _pending[value['id']];
        if (request == null) return;
        if (!request.sent) throw const FormatException();
        if (value['ok'] == true && value['result'] is Map) {
          if (!request.result.isCompleted) {
            request.result.complete(
              Map<String, dynamic>.from(value['result'] as Map),
            );
          }
        } else {
          if (!request.result.isCompleted) {
            final error = value['error'];
            if (error is! Map ||
                error['kind'] != null && error['kind'] != 'unsupported')
              throw const FormatException();
            final source = error['source'];
            CoreFailureSource? location;
            if (source != null) {
              if (source is! Map ||
                  source['resource'] is! String ||
                  source['pointer'] is! String ||
                  source['range'] is! List)
                throw const FormatException();
              final range = source['range'] as List;
              if (range.length != 2 ||
                  range.any((value) => value is! int) ||
                  (range[0] as int) < 0 ||
                  (range[1] as int) < (range[0] as int))
                throw const FormatException();
              location = CoreFailureSource(
                source['resource'] as String,
                source['pointer'] as String,
                SourceRange(range[0] as int, range[1] as int),
              );
            }
            request.result.completeError(
              CoreFailure(
                (error['code'] as String?) ?? 'engine.error',
                (error['message'] as String?) ?? 'Engine rejected the request',
                kind: error['kind'] == 'unsupported'
                    ? CoreFailureKind.unsupported
                    : null,
                source: location,
              ),
            );
          }
        }
        _release(request);
      } on Object {
        if (epoch != _processEpoch || _process == null) return;
        _fail('engine.json', 'Malformed helper response');
        unawaited(_kill());
      }
    } finally {
      _queuedFrames--;
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (_process == null) {
      throw CoreFailure('engine.stopped', 'Contract engine is not running');
    }
    var id = requestId ?? '${++_serial}';
    if (requestId == null) {
      while (_pending.containsKey(id) ||
          _cancelled.contains(id) ||
          _cancelling.containsKey(id)) {
        id = '${++_serial}';
      }
    } else if (_pending.containsKey(id) || _cancelling.containsKey(id)) {
      throw CoreFailure(
        'engine.identity',
        'A pending request already owns that identity',
      );
    }
    // Capture mutable containers before waiting. Strings are immutable/shared;
    // callers cannot retarget a queued snapshot by changing a list or map.
    final control = const ['hello', 'cancel', 'shutdown'].contains(method);
    var cost = 0, nodes = 0;
    Object? capture(Object? value, int depth) {
      if (++nodes > 400000 || depth > 256) {
        throw CoreFailure(
          'engine.limit',
          'Request structure exceeds its limit',
        );
      }
      cost += value is String ? value.length * 2 : 32;
      if ((control ? cost : _retainedRequestBytes + cost) >
          (control ? 65536 : 128 * 1024 * 1024)) {
        throw CoreFailure('engine.limit', 'Captured request memory is full');
      }
      if (value is List) {
        return List<Object?>.unmodifiable([
          for (final item in value) capture(item, depth + 1),
        ]);
      }
      if (value is Map<String, Object?>) {
        return Map<String, Object?>.unmodifiable({
          for (final entry in value.entries)
            capture(entry.key, depth + 1) as String: capture(
              entry.value,
              depth + 1,
            ),
        });
      }
      if (value == null || value is String || value is bool || value is num) {
        return value;
      }
      throw CoreFailure(
        'engine.input',
        'Request contains an unsupported value',
      );
    }

    if (_pending.values.where((r) => r.control == control).length >= 8) {
      throw CoreFailure(
        'engine.queue',
        'Bounded request waiting queue is full',
      );
    }
    final frozen = capture(params, 0) as Map<String, Object?>;
    final request = _EngineRequest(id, method, frozen, cost);
    if (!control) _retainedRequestBytes += cost;
    _pending[id] = request;
    // The deadline includes waiting and encoding, not just helper execution.
    request.result.future.ignore();
    request.deadline = Timer(timeout, () {
      if (!_pending.containsKey(id)) return;
      request.cancelled = true;
      if (!request.result.isCompleted) {
        request.result.completeError(
          CoreFailure('engine.timeout', 'Analysis exceeded the time limit'),
        );
      }
      if (!request.started) {
        _release(request);
      } else if (request.sent) {
        if (request.control) {
          unawaited(_kill());
        } else {
          // Keep its data capacity until actual termination acknowledgement.
          unawaited(cancel(id));
        }
      }
    });
    _waiting.add(request);
    _drainRequests();
    return request.result.future;
  }

  void _drainRequests() {
    if (_process == null) return;
    while (true) {
      _EngineRequest? next;
      for (final request in _waiting) {
        if (_closed && !request.control) continue;
        if (_pending.values
                .where((r) => r.started && r.control == request.control)
                .length >=
            4) {
          continue;
        }
        if (next == null || request.priority < next.priority) next = request;
      }
      if (next == null) return;
      _waiting.remove(next);
      next.started = true;
      unawaited(_dispatch(next));
    }
  }

  void _release(_EngineRequest request) {
    if (!identical(_pending[request.id], request)) return;
    _pending.remove(request.id);
    _waiting.remove(request);
    if (!request.control) _retainedRequestBytes -= request.cost;
    request.deadline?.cancel();
    if (!request.released.isCompleted) request.released.complete();
    _drainRequests();
  }

  Future<void> _dispatch(_EngineRequest request) async {
    final process = _process, epoch = _processEpoch, params = request.params;
    final large =
        (params['resources'] as List? ?? []).fold<int>(
          0,
          (n, r) => n + ((r as Map)['text'] as String? ?? '').length,
        ) >=
        262144;
    late Uint8List payload;
    try {
      payload = await _encodeRequest({
        'protocol': 1,
        'id': request.id,
        'method': request.method,
        'params': params,
      }, large);
    } on Object {
      if (!request.result.isCompleted) {
        request.result.completeError(
          CoreFailure('engine.input', 'Cannot encode helper request'),
        );
      }
      _release(request);
      return;
    }
    if (request.cancelled) {
      _release(request);
      return;
    }
    if (epoch != _processEpoch ||
        !identical(process, _process) ||
        !identical(_pending[request.id], request)) {
      return;
    }
    if (payload.length > 64 * 1024 * 1024) {
      request.result.completeError(
        CoreFailure('engine.limit', 'Encoded request exceeds its frame limit'),
      );
      _release(request);
      return;
    }
    final header = ByteData(4)..setUint32(0, payload.length);
    try {
      request.sent = true;
      process!.stdin.add(header.buffer.asUint8List());
      process.stdin.add(payload);
    } on Object {
      _fail('engine.input', 'Cannot write helper request');
      unawaited(_kill());
    }
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    await start();
    if (requestId != null && _cancelled.remove(requestId)) {
      throw CoreFailure('cancelled', 'Request cancelled before dispatch');
    }
    return _send(method, params, requestId: requestId);
  }

  Future<void> cancelPrefix(String prefix) async {
    // Mark every captured owner before any termination releases a slot. A
    // queued sibling must not start while sequential cancellation awaits I/O.
    await Future.wait([
      for (final id
          in _pending.keys.where((id) => id.startsWith(prefix)).toList())
        cancel(id),
    ]);
  }

  Future<void> cancel(String id) {
    final existing = _cancelling[id];
    if (existing != null) return existing;
    final request = _pending[id];
    if (request == null) {
      _cancelled.add(id);
      if (_cancelled.length > 128) _cancelled.remove(_cancelled.first);
      return Future.value();
    }
    request.cancelled = true;
    if (!request.started || !request.sent) {
      if (!request.result.isCompleted) {
        request.result.completeError(
          CoreFailure('cancelled', 'Request cancelled before dispatch'),
        );
      }
      if (!request.started) _release(request);
      return request.released.future;
    }
    final stopped = _cancelSent(request);
    _cancelling[id] = stopped;
    unawaited(stopped.whenComplete(() => _cancelling.remove(id)));
    return stopped;
  }

  Future<void> _cancelSent(_EngineRequest request) async {
    try {
      await _send('cancel', {'id': request.id});
      if (!request.result.isCompleted) {
        request.result.completeError(
          CoreFailure('cancelled', 'Request cancelled'),
        );
      }
      _release(request);
    } on Object {
      await _kill();
    }
  }

  void _fail(String code, String message) {
    final all = _pending.values.toList();
    _pending.clear();
    _waiting.clear();
    _retainedRequestBytes = 0;
    for (final request in all) {
      request.deadline?.cancel();
      if (!request.result.isCompleted) {
        request.result.completeError(CoreFailure(code, message));
      }
      if (!request.released.isCompleted) request.released.complete();
    }
  }

  Future<void> _kill() async {
    final process = _process;
    _process = null;
    _processEpoch++;
    if (process == null) return;
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    _fail('engine.stopped', 'Contract engine stopped');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // The launch checks closure before owning the newly started process.
      }
    }
    if (_process != null) {
      try {
        await _send('shutdown', {});
        await _process?.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        await _kill();
      }
    }
    _fail('engine.closed', 'Contract engine closed');
  }
}
