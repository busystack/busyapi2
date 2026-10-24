// Developer benchmark: warm IPC/collection/parser/check work; no native paint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../packages/busyapi_core/lib/busyapi_core.dart';

Future<void> main(List<String> args) async {
  final engine = EngineProcess(executable: args[0], helper: args[1]);
  final documentation = args.length > 2 && args[2] == '--documentation';
  try {
    for (final file in args.skip(documentation ? 3 : 2)) {
      final project = await BusyProject.open(file, engine);
      try {
        final root = project.roots.single.id;
        final b = await project.buffer(root);
        for (var i = 0; i < 5; i++) {
          // A scalar change forces real parsing while retaining the dependency graph.
          project.store.replace(
            b.id,
            b.text.replaceFirst('fixture', 'fixture$i'),
          );
          if (documentation) {
            // Diagnose real capture/collection/verification handling as well
            // as engine work. These are raw callback intervals (no assumed
            // overhead subtraction), not native input-to-visible latency.
            final elapsed = Stopwatch()..start(), intervals = <int>[];
            var previous = 0;
            void sample() {
              final now = elapsed.elapsedMicroseconds;
              intervals.add(now - previous);
              previous = now;
            }

            final timer = Timer.periodic(
              const Duration(milliseconds: 2),
              (_) => sample(),
            );
            DocumentationPresentation presentation;
            try {
              presentation = await project.captureDocumentationPresentation(
                root,
              );
            } finally {
              sample();
              timer.cancel();
              elapsed.stop();
            }
            intervals.sort();
            stdout.writeln(
              jsonEncode({
                'version': 1,
                'kind': 'headless-documentation-capture-not-native-paint',
                'fixture': file,
                'iteration': i,
                'bytes': b.bytes().length,
                'wallUs': elapsed.elapsedMicroseconds,
                'callbackIntervalUs': {
                  'count': intervals.length,
                  'p50': intervals[intervals.length ~/ 2],
                  'p95': intervals[(intervals.length * .95).ceil() - 1],
                  'max': intervals.last,
                },
                'snapshot': presentation.snapshot.sourceIdentity,
                'displayBytes': utf8.encode(presentation.text).length,
                'sections':
                    (presentation.projection['sections'] as List).length,
                'sourceActions': presentation.sourceActions.length,
                'machine': Platform.operatingSystemVersion,
                'dart': Platform.version,
              }),
            );
            continue;
          }
          final result = await project.check(root, measure: true);
          stdout.writeln(
            jsonEncode({
              'fixture': file,
              'iteration': i,
              'bytes': b.bytes().length,
              'status': result['status'],
              'metrics': project.lastTimings,
              'machine': Platform.operatingSystemVersion,
            }),
          );
        }
      } finally {
        project.close();
      }
    }
  } finally {
    await engine.close();
  }
}
