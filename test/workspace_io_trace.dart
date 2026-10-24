import 'dart:io';

import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:path/path.dart' as p;

import '../packages/busyapi_core/test/test_support.dart';

/// Failure-only observation of production IO, not a fake writer or a changed
/// deadline. Fixed phase/method names contain no authored text or private paths.
class WorkspaceIoTrace {
  final watch = Stopwatch()..start(),
      events = <String>[],
      active = <int, String>{};
  int serial = 0;
  void note(String phase) {
    events.add('${watch.elapsedMilliseconds}:$phase');
    if (events.length > 96) events.removeAt(0);
  }

  Future<T> run<T>(String phase, Future<T> Function() action) async {
    final id = ++serial;
    active[id] = phase;
    note('$id:$phase:start');
    try {
      return await action();
    } on Object catch (error) {
      final code = error is CoreFailure
          ? error.code
          : error is FileSystemException
          ? 'filesystem:${error.osError?.errorCode}'
          : '${error.runtimeType}';
      note('$id:$phase:error:$code');
      rethrow;
    } finally {
      active.remove(id);
      note('$id:$phase:end');
    }
  }

  String describe(WorkspaceController controller) =>
      'active=$active; checking=${controller.checking}/${controller.checkingSemantics}; buffers=${controller.store?.buffers.length}; pending=${controller.hasPendingFields}; phases=$events';
}

class TracedEngineProcess extends EngineProcess {
  TracedEngineProcess(this.trace)
    : super(executable: runtimeNode, helper: runtimeHelper);
  final WorkspaceIoTrace trace;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) => trace.run(
    'engine:$method',
    () => super.request(method, params, requestId: requestId),
  );
}

class TracedWorkspaceController extends WorkspaceController {
  TracedWorkspaceController(super.engine, super.locations, this.trace)
    : super(
        recovery: RecoveryStore(
          p.join(locations.state, 'recovery'),
          onCheckpointPhase: trace.note,
        ),
      );
  final WorkspaceIoTrace trace;
  @override
  Future<void> persist() => trace.run('persist', super.persist);
  @override
  Future<void> initialize() => trace.run('initialize', super.initialize);
  @override
  Future<void> open(
    String path, {
    bool Function()? cancelled,
    Map<String, dynamic>? recovering,
  }) => trace.run(
    'open',
    () => super.open(path, cancelled: cancelled, recovering: recovering),
  );
  @override
  Future<void> persistView() => trace.run('persistView', super.persistView);
  @override
  Future<void> remember() => trace.run('remember', super.remember);
  @override
  Future<void> shutdown() => trace.run('shutdown', super.shutdown);
}
