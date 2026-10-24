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
  if (args[2].startsWith('extract-file-')) {
    final root = project.roots.single.id;
    final source = await project.buffer(root);
    final destination = p.join(project.access.boundary, 'definition 雪.json');
    await project.applyRefactoring(
      await project.planComponentExtractionToFile(
        {
          'root': root,
          'resource': root,
          'generation': source.generation,
          'pointer': '/components/schemas/Owner/properties/child',
        },
        'Stored',
        destination,
      ),
    );
    await RecoveryStore(p.join(args[1], 'drafts'))
        .persistFileMoves(project.recoveryOwner);
    if (args[2] == 'extract-file-draft') {
      stdout.writeln('${args[2]}-durable');
      await stdin.first;
    } else {
      final selected = args[2] == 'extract-file-root'
          ? source.id
          : Uri.file(destination).toString();
      await PublicationStore(
        args[1],
        afterPublish: (id) async {
          if (id == selected) {
            stdout.writeln('${args[2]}-before-receipt');
            await stdin.first;
          }
        },
      ).save(project, [project.store.get(Uri.file(destination).toString())]);
    }
    project.close();
    await engine.close();
    return;
  }
  if (args[2].startsWith('presence-')) {
    final deletion = args[2].startsWith('presence-delete');
    final path = p.join(args[0], deletion ? 'fragment.json' : 'created.json');
    await project.applyRefactoring(
      deletion
          ? await project.planFileDeletion(Uri.file(path).toString())
          : await project.planFileCreation(
              path,
              text:
                  '{"Value":{"type":"integer","example":9007199254740993}}\r\n',
              hasBom: true,
            ),
    );
    final affected = project.store.fileBuffer(Uri.file(path).toString());
    await RecoveryStore(p.join(args[1], 'drafts'))
        .persistFileMoves(project.recoveryOwner);
    if (args[2].endsWith('-draft')) {
      stdout.writeln('${args[2]}-durable');
      await stdin.first;
    } else {
      final publication = PublicationStore(
        args[1],
        afterPublish: (id) async {
          if (id == (deletion ? 'archive:${affected.id}' : affected.id)) {
            stdout.writeln('${args[2]}-before-receipt');
            await stdin.first;
          }
        },
      );
      await publication.save(project, [affected]);
    }
    project.close();
    await engine.close();
    return;
  }
  final source = await project.buffer(project.roots.single.id);
  project.store.replace(
    source.id,
    source.text.replaceFirst('Process', 'Unsaved 🐾'),
  );
  await project.applyRefactoring(
    await project.planFileMove(source.id, p.join(args[0], 'moved.json')),
  );
  if (args[2] == 'draft') {
    final item = await project.inspectObject(
      source.id,
      source.id,
      '/components/schemas/Exact',
    );
    final range = List<int>.from(item['range'] as List);
    final form = FormSession(
      kind: 'object.value',
      target: PropertySession(
        root: source.id,
        buffer: source.id,
        generation: source.generation,
        pointer: '/components/schemas/Exact',
        range: range,
        expected: source.text.substring(range[0], range[1]),
      ),
      contentIdentity: source.sourceIdentity,
      arguments: {
        'field': {'name': 'example', 'type': 'any', 'nativeString': false},
      },
      initial: {'value': '900719925474099312345'},
    );
    form.edit('value', '{"unfinished": "雪 🐾\n');
    await RecoveryStore(args[1])
        .persistFileMoves(project.recoveryOwner, form: form);
    stdout.writeln('draft-durable');
    await stdin.first;
  } else {
    await RecoveryStore(p.join(args[1], 'drafts'))
        .persistFileMoves(project.recoveryOwner);
    final publications = PublicationStore(
      args[1],
      afterPublish: (id) async {
        if (args[2].startsWith('destination') && id == source.id ||
            args[2] == 'archive' && id == 'archive:${source.id}') {
          stdout.writeln('${args[2]}-before-receipt');
          await stdin.first;
        }
      },
    );
    await publications.save(project, [source]);
  }
  project.close();
  await engine.close();
}
