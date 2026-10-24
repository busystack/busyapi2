import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';

// A deliberately small, read-only entry point for independently relocated
// exports. It reuses the core IO/graph/check path, not a package-specific parser.
Future<void> main(List<String> arguments) async {
  if (arguments.length > 1 ||
      arguments.any((arg) => !['--json', '--help'].contains(arg))) {
    stderr.writeln('Use busyapi-resource [--json | --help]');
    exitCode = 3;
    return;
  }
  if (arguments.contains('--help')) {
    stdout.writeln(
      'BusyAPI resource-package loader v1\nRun beside resource-package.json: busyapi-resource [--json]\nRead-only original-URI graph and dialect checks; no network retrieval, project code or display.\nExit: 0 complete clean; 1 invalid; 2 incomplete; 3 operational/configuration failure.',
    );
    return;
  }
  final engine = EngineProcess.bundled();
  try {
    final package = await ResourcePackage.open(
      File(Platform.resolvedExecutable).parent.path,
      engine,
    );
    final checked = await package.check(engine);
    exitCode = checked['complete'] != true
        ? 2
        : checked['status'] == 'invalid'
        ? 1
        : 0;
    if (arguments.contains('--json')) {
      stdout.writeln(jsonEncode(checked));
    } else {
      stdout.writeln('${checked['status']}: ${package.snapshot.root}');
      for (final finding in checked['findings'] as List) {
        stdout.writeln(
          '${finding['severity']} ${finding['code']} ${finding['resource']} ${finding['pointer']}: ${finding['message']}',
        );
      }
    }
  } on Object catch (error) {
    final failure = error is CoreFailure
        ? error
        : CoreFailure(
            'io.failure',
            'The resource package could not be checked',
          );
    exitCode =
        [
          'engine.assets',
          'bundle.package.assets',
          'bundle.package.invalid',
          'bundle.package.changed',
          'bundle.package.identity',
        ].contains(failure.code)
        ? 3
        : 2;
    if (arguments.contains('--json')) {
      stdout.writeln(
        jsonEncode({
          'version': 1,
          'status': exitCode == 3 ? 'operational-failure' : 'incomplete',
          'complete': false,
          'checkedRoots': [],
          'findings': [],
          'error': {'code': failure.code, 'message': failure.message},
        }),
      );
    } else {
      stderr.writeln('${failure.code}: ${failure.message}');
    }
  } finally {
    await engine.close();
  }
}
