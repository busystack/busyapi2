// Process-termination oracle only; not part of the distributed application.
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final bundle = p.dirname(Platform.resolvedExecutable);
  final engine = EngineProcess(
    executable: p.join(bundle, 'libexec/busyapi/node'),
    helper: p.join(bundle, 'libexec/busyapi/engine.cjs'),
  );
  final project = await BusyProject.open(args[0], engine);
  final root = project.roots.singleWhere((r) => r.name == 'working');
  final destination = project.roots.singleWhere((r) => r.name == 'models');
  final source = await project.buffer(root.id);
  final plan = await project.planComponentDefinitionMove(
    {
      'root': root.id,
      'resource': root.id,
      'generation': source.generation,
      'pointer': '/components/schemas/Public',
    },
    'Stored',
    destinationResource: destination.id,
  );
  await project.applyRefactoring(plan);
  final publications = PublicationStore(
    args[1],
    afterPublish: (id) async {
      if (id == source.id) {
        stdout.writeln('definition-published-before-receipt');
        await stdin.first;
      }
    },
  );
  await publications.save(project, [
    source,
    for (final buffer in project.store.buffers.values)
      if (buffer.id != source.id) buffer,
  ]);
  project.close();
  await engine.close();
}
