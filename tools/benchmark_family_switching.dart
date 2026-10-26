// Measures captured root changes in the shared core, independently of native paint.
import 'dart:convert';
import 'dart:io';

import '../packages/busyapi_core/lib/busyapi_core.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: benchmark_family_switching.dart NODE ENGINE PROJECT',
    );
    exitCode = 64;
    return;
  }
  final engine = EngineProcess(executable: args[0], helper: args[1]);
  BusyProject? project;
  var samples = 0;
  try {
    project = await BusyProject.open(args[2], engine);
    if (project.roots.length < 2) {
      throw StateError(
        'Choose a project with multiple roots named by declared version',
      );
    }
    for (var cycle = 0; cycle < 5; cycle++) {
      for (var offset = 0; offset < project.roots.length; offset++) {
        final root = project.roots[(cycle + offset) % project.roots.length];
        final elapsed = Stopwatch()..start();
        final result = await project.check(root.id, measure: true);
        elapsed.stop();
        final projection = result['projection'];
        final specification = projection is Map
            ? projection['specification']
            : null;
        if (result['status'] != 'complete' ||
            specification is! Map ||
            specification['declaredVersion'] != root.name) {
          throw StateError(
            'The captured root is incomplete or differs from its expected version: ${root.id}',
          );
        }
        stdout.writeln(
          jsonEncode({
            'kind': 'headless-root-switch-not-native-paint',
            'cycle': cycle,
            'root': root.id,
            'specification': specification,
            'status': result['status'],
            'wallUs': elapsed.elapsedMicroseconds,
            'metrics': project.lastTimings,
            'machine': Platform.operatingSystemVersion,
            'dart': Platform.version,
          }),
        );
        samples++;
      }
    }
  } finally {
    project?.close();
    await engine.close();
  }
  stdout.writeln(jsonEncode({'complete': true, 'samples': samples}));
}
