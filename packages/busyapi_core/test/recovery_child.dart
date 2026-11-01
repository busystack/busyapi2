import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';

Future<void> main(List<String> args) async {
  final bytes = await File(args[0]).readAsBytes();
  final buffer = DocumentBuffer.decode(args[0], bytes);
  buffer.update(buffer.text.replaceFirst('original', 'draft'));
  final form = FormSession(
    kind: 'example',
    contentIdentity: textIdentity(buffer.text),
    target: PropertySession(
      root: buffer.id,
      buffer: buffer.id,
      generation: buffer.generation,
      pointer: '/info',
      range: [0, buffer.text.length],
      expected: buffer.text,
    ),
    arguments: {'status': '200', 'media': 'application/json'},
    initial: {'example': '{}'},
  );
  form.edit('example', '{invalid unfinished example');
  await RecoveryStore(args[1]).persist(buffer, form: form);
  stdout.writeln('ready');
  await stdin.first;
}
