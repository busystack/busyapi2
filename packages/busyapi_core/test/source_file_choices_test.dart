import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    for (final kind in ['direct', 'fragment', 'chained']) {
      test(
        'Swagger $format $kind file completion preserves captured source ownership',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-file-choice-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final rootFile = File('${directory.path}/api.$format');
          final part = File('${directory.path}/types.$format');
          final last = File('${directory.path}/last.$format');
          final operation = {
            'responses': {
              '200': {
                'description': 'Keep response',
                'schema': kind == 'direct'
                    ? {'type': 'string'}
                    : {r'$ref': './types.$format#/File'},
              },
            },
          };
          final root = {
            'swagger': '2.0',
            'info': {'title': 'Keep 雪', 'version': 'unrelated'},
            'paths': {
              '/value': {'get': operation},
            },
          };
          String render(Map<String, Object?> value) => format == 'json'
              ? const JsonEncoder.withIndent('  ').convert(value)
              : '# Keep comment\r\n${value.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\r\n')}\r\nx-payload: &keep {literal: false}\r\nx-mirror: *keep\r\n';
          Future<void> write(File file, Map<String, Object?> value) => file
              .writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode(render(value))]);
          await write(rootFile, root);
          if (kind != 'direct') {
            await write(part, {
              'File': kind == 'chained'
                  ? {r'$ref': './last.$format#/Final'}
                  : {'type': 'string'},
            });
          }
          if (kind == 'chained')
            await write(last, {
              'Final': {'type': 'string'},
            });
          final files = [
            rootFile,
            if (kind != 'direct') part,
            if (kind == 'chained') last,
          ];
          final originals = {
            for (final file in files) file.path: await file.readAsBytes(),
          };
          final project = await BusyProject.open(rootFile.path, engine);
          addTearDown(project.close);
          final selected = kind == 'direct'
              ? rootFile
              : kind == 'fragment'
              ? part
              : last;
          final buffer = await project.buffer(selected.uri.toString());
          final rootBuffer = await project.buffer(rootFile.uri.toString());
          final caret = buffer.text.indexOf('string') + 2;
          expect(caret, greaterThan(1));
          buffer.selection = SourceSelection(caret, caret);
          Future<SourceAssistance> capture() => project.assistSource(
            rootFile.uri.toString(),
            buffer.id,
            buffer.selection,
          );
          final before = buffer.bytes(), assistance = await capture();
          final choice = assistance.completions.indexWhere(
            (value) => value['label'] == 'file',
          );
          expect(choice, greaterThanOrEqualTo(0));
          expect(buffer.bytes(), before);
          final bodyReference = kind == 'direct'
              ? '#/paths/~1value/get/responses/200/schema'
              : './types.$format#/File';
          final parameter = jsonEncode([
            {
              'name': 'body',
              'in': 'body',
              'schema': {r'$ref': bodyReference},
            },
          ]);
          final withBody = rootBuffer.text.replaceFirst(
            '"responses":',
            '"parameters":$parameter,"responses":',
          );
          expect(withBody, isNot(rootBuffer.text));
          project.store.replace(rootBuffer.id, withBody);
          expect(
            () => assistance.completion(choice, buffer),
            throwsA(
              isA<CoreFailure>().having(
                (value) => value.code,
                'code',
                'assist.stale',
              ),
            ),
          );
          buffer.selection = SourceSelection(caret, caret);
          expect(
            (await capture()).completions.any(
              (value) => value['label'] == 'file',
            ),
            isFalse,
          );
          project.store.undo();
          buffer.selection = SourceSelection(caret, caret);
          final refreshed = await capture();
          final edit = refreshed.completion(
            refreshed.completions.indexWhere(
              (value) => value['label'] == 'file',
            ),
            buffer,
          );
          project.store.apply([edit], label: 'File type completion');
          expect(
            buffer.text,
            beforeText(before).replaceFirst('"string"', '"file"'),
          );
          final accepted = buffer.bytes();
          project.store.undo();
          expect(buffer.bytes(), before);
          project.store.redo();
          expect(buffer.bytes(), accepted);
          final checked = await project.check(rootFile.uri.toString());
          expect(checked['complete'], isTrue, reason: '$checked');
          expect(checked['findings'], isEmpty, reason: '$checked');
          for (final file in files)
            expect(await file.readAsBytes(), originals[file.path]);
          await project.save(buffer);
          expect(await selected.readAsBytes(), accepted);
          for (final file in files.where(
            (file) => file.path != selected.path,
          )) {
            expect(await file.readAsBytes(), originals[file.path]);
          }
          final reopened = await BusyProject.open(rootFile.path, engine);
          try {
            final checked = await reopened.check(rootFile.uri.toString());
            expect(checked['complete'], isTrue);
            expect(checked['findings'], isEmpty);
          } finally {
            reopened.close();
          }
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', rootFile.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['complete'], isTrue);
          expect(report['findings'], isEmpty);
          expect(await selected.readAsBytes(), accepted);
        },
      );
    }
  }
}

String beforeText(List<int> bytes) => utf8.decode(bytes.skip(3).toList());
