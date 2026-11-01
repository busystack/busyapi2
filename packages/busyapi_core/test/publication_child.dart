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
  if (args.length > 2 && args[2].startsWith('security-')) {
    final root = project.roots.single.id;
    final buffer = await project.buffer(root);
    final swagger = buffer.text.contains('"swagger"');
    await project.applyRefactoring(
      await project.planComponentRename({
        'resource': root,
        'generation': buffer.generation,
        'pointer':
            '${swagger ? '/securityDefinitions' : '/components/securitySchemes'}/Old',
      }, 'Renamed'),
    );
    if (args[2] == 'security-draft') {
      await RecoveryStore(args[1]).persistFileMoves(project.recoveryOwner);
      stdout.writeln('draft-durable');
      await stdin.first;
    } else {
      await PublicationStore(
        args[1],
        afterPublish: (id) async {
          if (id == root) {
            stdout.writeln('first-published');
            await stdin.first;
          }
        },
      ).save(project, [buffer]);
    }
    project.close();
    await engine.close();
    return;
  }
  final a = await project.buffer(project.roots.single.id);
  final b = await project.buffer(
    Uri.file(p.join(args[0], 'part.yaml')).toString(),
  );
  project.store.replace(a.id, a.text.replaceFirst('original', 'published'));
  project.store.replace(b.id, 'part draft\n');
  final publications = PublicationStore(
    args[1],
    afterPublish: (id) async {
      if (id == a.id) {
        stdout.writeln('first-published');
        await stdin.first;
      }
    },
  );
  await publications.save(project, [a, b]);
  project.close();
  await engine.close();
}
