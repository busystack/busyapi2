part of 'project.dart';

class MockPlan {
  MockPlan._(
    this._owner,
    this.snapshot,
    this.analysis,
    this.configuration,
    this.saved,
    this._revision,
  );
  final BusyProject _owner;
  final AnalysisSnapshot snapshot;
  final Map<String, dynamic> analysis;
  final ExecutionConfiguration configuration;
  final bool saved;
  final int _revision;
  bool _closed = false;
  bool get outdated =>
      _owner._closed ||
      _revision != _owner._resourceRevision ||
      !saved && !snapshot.current(_owner.store);
  String get root => snapshot.root;

  void _ensureStartCurrent(RunCancellation? cancellation) {
    if (_closed || _owner._closed) {
      throw CoreFailure('mock.closed', 'The captured mock owner is closed');
    }
    cancellation?.throwIfCancelled();
    if (outdated) {
      throw CoreFailure(
        'mock.stale',
        'The contract changed. Prepare a new mock before starting it.',
      );
    }
  }

  Future<Map<String, dynamic>> _derive(
    String outputId,
    RunCancellation? cancellation,
  ) async {
    final settled = Completer<void>();
    final requestId =
        'mock-${snapshot.identity.substring(0, 16)}-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(settled)}';
    final work = _owner.engine.request('deriveBundle', {
      ...snapshot.toJson(),
      'outputId': outputId,
    }, requestId: requestId);
    try {
      return cancellation == null
          ? await work
          : await Future.any<Map<String, dynamic>>([
              work,
              cancellation.whenCancelled.then((_) async {
                if (settled.isCompleted) return work;
                await _owner.engine.cancel(requestId);
                throw CoreFailure(
                  'cancelled',
                  'Mock derivation cancelled; late results are discarded.',
                );
              }),
            ]);
    } finally {
      settled.complete();
    }
  }

  Future<MockRun> start({
    int port = 0,
    bool errors = true,
    String? nodeExecutable,
    String? helper,
    Uri? proxyTarget,
    RunCancellation? cancellation,
  }) async {
    _ensureStartCurrent(cancellation);
    if (port < 0 || port > 65535) {
      throw CoreFailure('mock.port', 'Mock port must be between 0 and 65535');
    }
    if (proxyTarget != null) _validateProxyTarget(proxyTarget);
    cancellation?.throwIfCancelled();
    final outputId = Uri.parse(snapshot.root)
        .replace(fragment: '')
        .resolve('./busyapi-mock.json')
        .toString();
    final result = await _derive(outputId, cancellation);
    _ensureStartCurrent(cancellation);
    final output = result['output'];
    if (result['version'] != 1 ||
        result['snapshot'] != snapshot.identity ||
        result['complete'] != true ||
        result['producer'] != 'busyapi-graph-bundle' ||
        result['producerVersion'] != '3' ||
        output is! Map ||
        output['id'] != outputId ||
        output['text'] is! String ||
        output['identity'] is! String ||
        output['identity'] != textIdentity(output['text'] as String)) {
      throw CoreFailure(
        'mock.bundle.incomplete',
        'A local mock requires one complete coherent derived snapshot',
      );
    }
    final directory = p.dirname(Platform.resolvedExecutable);
    final node =
        nodeExecutable ?? p.join(directory, 'libexec', 'busyapi', 'node');
    final script =
        helper ?? p.join(directory, 'libexec', 'busyapi', 'mock-server.cjs');
    if (!await File(node).exists() || !await File(script).exists()) {
      throw CoreFailure(
        'mock.assets',
        'The packaged Prism mock runtime is unavailable',
      );
    }
    _ensureStartCurrent(cancellation);
    final run = await MockRun._start(
      plan: this,
      node: node,
      helper: script,
      outputId: outputId,
      outputIdentity: output['identity'] as String,
      port: port,
      errors: errors,
      proxyTarget: proxyTarget,
      cancellation: cancellation,
    );
    try {
      _ensureStartCurrent(cancellation);
      return run;
    } on Object {
      await run.stop();
      rethrow;
    }
  }

  Uri configuredProxyTarget() {
    final value = configuration.mock['proxyTarget'];
    if (value is! String || value.isEmpty) {
      throw CoreFailure(
        'mock.proxy.configuration',
        'Configure mock.proxyTarget before explicitly starting validation proxy mode',
      );
    }
    final target = Uri.tryParse(value);
    if (target == null) {
      throw CoreFailure(
        'mock.proxy.target',
        'Validation proxy target is invalid',
      );
    }
    _validateProxyTarget(target);
    return target;
  }

  static void _validateProxyTarget(Uri target) {
    if (!target.isAbsolute ||
        !const ['http', 'https'].contains(target.scheme) ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        target.hasQuery ||
        target.hasFragment) {
      throw CoreFailure(
        'mock.proxy.target',
        'Validation proxy target must be an HTTP(S) base URL without credentials, query or fragment',
      );
    }
  }

  void close() => _closed = true;
}

class MockValidationIdentity {
  const MockValidationIdentity._(this.name, this.version, this.configuration);
  final String name, version, configuration;
  static MockValidationIdentity? _read(
    Object? value, {
    required String expectedName,
  }) {
    if (value
        case {
          'name': String name,
          'version': String version,
          'configuration': String configuration,
        }
        when name == expectedName &&
            version.isNotEmpty &&
            version.length <= 128 &&
            configuration.isNotEmpty &&
            configuration.length <= 16384) {
      return MockValidationIdentity._(name, version, configuration);
    }
    return null;
  }

  Map<String, String> toJson() => {
    'name': name,
    'version': version,
    'configuration': configuration,
  };
}

CoreFailure? _mockStartupFailure(Object? value, MockPlan plan) {
  if (value is! Map ||
      value['code'] is! String ||
      value['message'] is! String ||
      value['kind'] != null && value['kind'] != 'unsupported')
    return null;
  CoreFailureSource? location;
  if (value['source'] != null) {
    final source = value['source'];
    if (source is! Map ||
        source['resource'] is! String ||
        source['pointer'] is! String)
      return null;
    final range = source['range'];
    if (range is! List ||
        range.length != 2 ||
        range[0] is! int ||
        range[1] is! int ||
        (range[0] as int) < 0 ||
        (range[1] as int) < (range[0] as int))
      return null;
    final resources = plan.snapshot.resources.where(
      (resource) => resource['id'] == source['resource'],
    );
    if (resources.length != 1 ||
        resources.single['text'] is! String ||
        (range[1] as int) > (resources.single['text'] as String).length)
      return null;
    location = CoreFailureSource(
      source['resource'] as String,
      source['pointer'] as String,
      SourceRange(range[0] as int, range[1] as int),
    );
  }
  return CoreFailure(
    value['code'] as String,
    _sanitizeMockText(
      utf8.encode(value['message'] as String),
      plan._owner.access.boundary,
    ),
    kind: value['kind'] == 'unsupported' ? CoreFailureKind.unsupported : null,
    source: location,
  );
}

class MockRun {
  MockRun._(
    this.plan,
    this.process,
    this.grouped,
    this.host,
    this.port,
    this.toolVersion,
    this.operations,
    this.upstreamForwarding,
    this.nativeValidation,
    this.nativeResponseValidation,
    this.nativeParameterValidation,
    this.nativeSecurityValidation,
    this._stderr,
  );
  final MockPlan plan;
  final Process process;
  final bool grouped;
  final String host, toolVersion;
  final int port, operations;
  final bool upstreamForwarding;
  final MockValidationIdentity nativeValidation;
  final MockValidationIdentity nativeResponseValidation;
  final MockValidationIdentity nativeParameterValidation;
  final MockValidationIdentity nativeSecurityValidation;
  final List<int> _stderr;
  bool _stopping = false;
  bool get outdated => plan.outdated;
  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);
  Future<int> get exitCode => process.exitCode;
  String get errors => _sanitizeMockText(_stderr, plan._owner.access.boundary);

  static Future<MockRun> _start({
    required MockPlan plan,
    required String node,
    required String helper,
    required String outputId,
    required String outputIdentity,
    required int port,
    required bool errors,
    required Uri? proxyTarget,
    RunCancellation? cancellation,
  }) async {
    final snap = Platform.environment['SNAP'];
    final setsid = snap == null ? '/usr/bin/setsid' : '$snap/usr/bin/setsid';
    final grouped = Platform.isLinux && await File(setsid).exists();
    plan._ensureStartCurrent(cancellation);
    final process = await Process.start(
      grouped ? setsid : node,
      grouped ? ['--wait', '--', node, helper] : [helper],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'},
      includeParentEnvironment: false,
      runInShell: false,
    );
    final stderrBytes = <int>[], ready = Completer<Map<String, dynamic>>();
    var stdoutSize = 0, stderrSize = 0;
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stdoutSize += utf8.encode(line).length + 1;
          if (stdoutSize > 1024 * 1024) {
            _terminateMock(process, grouped);
            if (!ready.isCompleted) {
              ready.complete({
                'version': 1,
                'event': 'failed',
                'error': 'mock protocol output exceeded 1 MiB',
              });
            }
            return;
          }
          if (ready.isCompleted) return;
          try {
            final value = jsonDecode(line);
            if (value is Map && value['version'] == 1) {
              ready.complete(Map<String, dynamic>.from(value));
            }
          } on FormatException {
            // The protocol check below reports non-JSON startup output.
          }
        });
    final errorsSubscription = process.stderr.listen((chunk) {
      if (stderrSize >= 1024 * 1024) return;
      final retained = chunk.take(1024 * 1024 - stderrSize).toList();
      stderrBytes.addAll(retained);
      stderrSize += retained.length;
    });
    process.stdin.add(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'snapshot': plan.snapshot.identity,
          'capture': plan.snapshot.toJson(),
          'derived': {'id': outputId, 'identity': outputIdentity},
          'port': port,
          'errors': errors,
          if (proxyTarget != null) 'upstream': proxyTarget.toString(),
        }),
      ),
    );
    await process.stdin.close();
    unawaited(
      cancellation?.whenCancelled.then(
            (_) => _terminateMock(process, grouped),
          ) ??
          Future.value(),
    );
    Map<String, dynamic> message;
    try {
      message = await Future.any([
        ready.future,
        process.exitCode.then<Map<String, dynamic>>(
          (code) => {'version': 1, 'event': 'exited', 'exitCode': code},
        ),
      ]).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _terminateMock(process, grouped);
      throw CoreFailure(
        'mock.readiness',
        'Prism did not report readiness within 30 seconds',
      );
    }
    if (cancellation?.cancelled == true) {
      _terminateMock(process, grouped);
      throw CoreFailure('cancelled', 'Mock startup was cancelled');
    }
    final nativeValidation = MockValidationIdentity._read(
      message['nativeValidation'],
      expectedName: 'hyperjump+busyapi-exact',
    );
    final nativeResponseValidation = MockValidationIdentity._read(
      message['nativeResponseValidation'],
      expectedName: 'busyapi-native-response',
    );
    final nativeParameterValidation = MockValidationIdentity._read(
      message['nativeParameterValidation'],
      expectedName: 'busyapi-native-parameters',
    );
    final nativeSecurityValidation = MockValidationIdentity._read(
      message['nativeSecurityValidation'],
      expectedName: 'busyapi-native-security',
    );
    if (message['event'] != 'ready' ||
        message['snapshot'] != plan.snapshot.identity ||
        message['tool'] != 'Prism' ||
        message['toolVersion'] != '5.15.11' ||
        message['host'] != '127.0.0.1' ||
        message['port'] is! int ||
        message['operations'] is! int ||
        nativeValidation == null ||
        nativeResponseValidation == null ||
        nativeParameterValidation == null ||
        nativeSecurityValidation == null ||
        nativeValidation.version != _schemaProducerVersion ||
        nativeResponseValidation.version != '3' ||
        nativeResponseValidation.configuration !=
            'response-wire-v3:${nativeValidation.configuration}' ||
        nativeParameterValidation.version != '2' ||
        nativeParameterValidation.configuration !=
            'parameter-wire-v2:${nativeValidation.configuration}' ||
        nativeSecurityValidation.version != '1' ||
        nativeSecurityValidation.configuration !=
            'security-wire-v1:${nativeValidation.configuration}' ||
        message['upstreamForwarding'] != (proxyTarget != null)) {
      _terminateMock(process, grouped);
      await lines.cancel();
      await errorsSubscription.cancel();
      if (message['event'] == 'failed') {
        final failure = _mockStartupFailure(message['failure'], plan);
        if (failure != null) throw failure;
      }
      final detail = _sanitizeMockText(
        stderrBytes,
        plan._owner.access.boundary,
      );
      throw CoreFailure(
        'mock.readiness',
        'Prism failed before readiness${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    return MockRun._(
      plan,
      process,
      grouped,
      message['host'] as String,
      message['port'] as int,
      message['toolVersion'] as String,
      message['operations'] as int,
      message['upstreamForwarding'] as bool,
      nativeValidation,
      nativeResponseValidation,
      nativeParameterValidation,
      nativeSecurityValidation,
      stderrBytes,
    );
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _terminateMock(process, grouped, forceLater: false);
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (grouped) {
        Process.killPid(-process.pid, ProcessSignal.sigkill);
      } else {
        process.kill(ProcessSignal.sigkill);
      }
      await process.exitCode;
    }
  }
}

void _terminateMock(Process process, bool group, {bool forceLater = true}) {
  if (group) {
    Process.killPid(-process.pid, ProcessSignal.sigterm);
  } else {
    process.kill(ProcessSignal.sigterm);
  }
  if (forceLater) {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (group) {
          Process.killPid(-process.pid, ProcessSignal.sigkill);
        } else {
          process.kill(ProcessSignal.sigkill);
        }
      }),
    );
  }
}

String _sanitizeMockText(List<int> bytes, String boundary) {
  var value = utf8
      .decode(bytes, allowMalformed: true)
      .replaceAll(boundary, '[project]');
  value = value
      .replaceAllMapped(
        RegExp(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@'),
        (match) => '${match.group(1)}[redacted]@',
      )
      .replaceAllMapped(
        RegExp(r'([?&][^=\s&]+)=([^\s&]+)'),
        (match) => '${match.group(1)}=[redacted]',
      );
  value = value.replaceAll(
    RegExp(
      r'(authorization|cookie|token|secret)[^\r\n]*',
      caseSensitive: false,
    ),
    '[redacted]',
  );
  value = value.trim();
  return value.length <= 4000 ? value : '${value.substring(0, 4000)}…';
}

extension MockPlanning on BusyProject {
  Future<MockPlan> prepareMock(
    String root, {
    bool saved = false,
    String? requestId,
    bool Function()? cancelled,
  }) async {
    if (_closed) throw CoreFailure('access.closed', 'Project is closed');
    final captured = await captureContractSnapshot(
      root,
      saved: saved,
      requestId: requestId,
      cancelled: cancelled,
    );
    final revision = _resourceRevision;
    return MockPlan._(
      this,
      captured.snapshot,
      captured.analysis,
      ExecutionConfiguration.parse(
        captured.snapshot.configuration.singleOrNull,
        access.boundary,
      ),
      saved,
      revision,
    );
  }
}
