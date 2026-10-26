import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

Future<({BusyProject project, File root, File data, File manifest})> fixture(
  Directory temp,
  EngineProcess engine, {
  String version = '3.0.4',
  bool json = false,
  bool configured = true,
}) async {
  final ext = json ? 'json' : 'yaml';
  final root = File('${temp.path}/api.$ext');
  final data = File('${temp.path}/payload.$ext');
  final manifest = File('${temp.path}/busyapi.yaml');
  final value = {
    version == '2.0' ? 'swagger' : 'openapi': version,
    'info': {'title': 'Case files 雪', 'version': 'unrelated'},
    'paths': <String, Object?>{},
  };
  await root.writeAsString(
    json
        ? jsonEncode(value)
        : '# Keep API\r\n${value.entries.map((e) => '${e.key}: ${jsonEncode(e.value)}').join('\r\n')}\r\n',
  );
  await data.writeAsString(
    '\ufeff{"\$ref":"opaque", "n":9007199254740993.00}\r\n',
  );
  if (configured) await manifest.writeAsString(configuration(ext));
  final project = await BusyProject.open(
    configured ? temp.path : root.path,
    engine,
  );
  return (project: project, root: root, data: data, manifest: manifest);
}

String configuration(String ext, {String? file}) =>
    '# Keep configuration\r\nversion: 1\r\nroots: [{name: Main, path: api.$ext}]\r\n'
    'tests:\r\n  - name: upload\r\n    operation: {method: post, path: /items}\r\n'
    '    body:\r\n      value: {literal: "payload.$ext"}\r\n      files:\r\n'
    '        - {name: asset, path: "${file ?? './payload.$ext'}"} # Keep path comment\r\n'
    'x-data: {path: "payload.$ext", n: 9007199254740993.00}\r\n';

void main() {
  late Directory temp;
  late EngineProcess engine;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'busyapi-case-file-maintenance-',
    );
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    await engine.close();
    await temp.delete(recursive: true);
  });
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        '$version json=$json saved file move keeps exact source and grouped history/publication',
        () async {
          final f = await fixture(temp, engine, version: version, json: json);
          final project = f.project;
          addTearDown(project.close);
          final data = await project.buffer(f.data.uri.toString());
          final config = await project.buffer(f.manifest.uri.toString());
          final originalConfig = config.text,
              originalData = data.bytes(),
              originalRoot = await f.root.readAsBytes();
          project.store.replace(data.id, '${data.text}unsaved 雪😀\r\n');
          final working = data.bytes();
          final destination = File(
            '${temp.path}/new 雪.${json ? 'json' : 'yaml'}',
          );
          final plan = await project.planFileMove(
            data.id,
            destination.path,
            retainIdentity: true,
          );
          expect(plan.result['blockers'], isEmpty);
          expect(
            (plan.result['usages'] as List).any(
              (u) => u['connection'] == 'case-file',
            ),
            true,
          );
          expect(await f.manifest.readAsString(), originalConfig);
          expect(await f.data.readAsBytes(), originalData);
          await project.applyRefactoring(plan);
          final afterConfig = config.text;
          expect(
            afterConfig,
            contains(
              'path: "./new 雪.${json ? 'json' : 'yaml'}"} # Keep path comment\r\n',
            ),
          );
          expect(
            afterConfig,
            contains('value: {literal: "payload.${json ? 'json' : 'yaml'}"}'),
          );
          expect(afterConfig, contains('n: 9007199254740993.00'));
          expect(data.id, destination.uri.toString());
          expect(data.bytes(), working);
          project.store.undo();
          expect(config.text, originalConfig);
          expect(data.id, f.data.uri.toString());
          expect(data.bytes(), working);
          project.store.redo();
          expect(config.text, afterConfig);
          expect(data.id, destination.uri.toString());
          final publication = PublicationStore('${temp.path}/state');
          expect((await publication.save(project, [data])).complete, true);
          expect(await f.data.exists(), false);
          expect(await destination.readAsBytes(), working);
          expect(await f.manifest.readAsString(), afterConfig);
          expect(await f.root.readAsBytes(), originalRoot);
          final reopened = await BusyProject.open(temp.path, engine);
          addTearDown(reopened.close);
          expect(
            (await reopened.buffer(destination.uri.toString())).bytes(),
            working,
          );
          final deletion = await reopened.planFileDeletion(
            destination.uri.toString(),
          );
          expect(
            (deletion.result['blockers'] as List).any(
              (b) => b['code'] == 'file.delete.case-file',
            ),
            true,
          );
          await expectLater(
            reopened.applyRefactoring(deletion),
            throwsA(isA<CoreFailure>()),
          );
          expect(await destination.readAsBytes(), working);
        },
      );
    }
  }
  for (final operation in ['move', 'delete']) {
    test(
      '$operation observes unsaved case configuration instead of disk',
      () async {
        final f = await fixture(temp, engine);
        final project = f.project;
        addTearDown(project.close);
        final config = await project.buffer(f.manifest.uri.toString());
        final disk = config.text;
        project.store.replace(
          config.id,
          configuration('yaml', file: './unrelated.yaml'),
        );
        if (operation == 'move') {
          final plan = await project.planFileMove(
            f.data.uri.toString(),
            '${temp.path}/new.yaml',
          );
          expect(
            (plan.result['usages'] as List).where(
              (u) => u['connection'] == 'case-file',
            ),
            isEmpty,
          );
          await project.applyRefactoring(plan);
        } else {
          final plan = await project.planFileDeletion(f.data.uri.toString());
          expect(plan.result['blockers'], isEmpty);
          await project.applyRefactoring(plan);
        }
        expect(config.text, configuration('yaml', file: './unrelated.yaml'));
        expect(await f.manifest.readAsString(), disk);
      },
    );
    for (final change in ['buffer', 'disk', 'new-configuration']) {
      test(
        '$operation rejects $change after case path review without partial mutations',
        () async {
          final f = await fixture(
            temp,
            engine,
            configured: change != 'new-configuration',
          );
          final project = f.project;
          addTearDown(project.close);
          if (change != 'new-configuration') {
            await f.manifest.writeAsString(
              configuration('yaml', file: './unrelated.yaml'),
            );
          }
          final destination = File('${temp.path}/new.yaml');
          final plan = operation == 'move'
              ? await project.planFileMove(
                  f.data.uri.toString(),
                  destination.path,
                )
              : await project.planFileDeletion(f.data.uri.toString());
          if (change == 'buffer') {
            final config = await project.buffer(f.manifest.uri.toString());
            project.store.replace(config.id, configuration('yaml'));
          } else {
            await f.manifest.writeAsString(configuration('yaml'));
          }
          final before = await f.data.readAsBytes();
          await expectLater(
            project.applyRefactoring(plan),
            throwsA(isA<CoreFailure>()),
          );
          expect(await destination.exists(), false);
          expect(await f.data.readAsBytes(), before);
          final buffer = await project.buffer(f.data.uri.toString());
          expect(buffer.id, f.data.uri.toString());
          expect(buffer.present, true);
        },
      );
    }
  }
  test('a dirty conflicting case configuration blocks planning and keeps user text', () async {
    final f = await fixture(temp, engine);
    final project = f.project;
    addTearDown(project.close);
    final config = await project.buffer(f.manifest.uri.toString());
    final working = '${config.text}# unsaved\r\n';
    project.store.replace(config.id, working);
    await f.manifest.writeAsString('${config.text}# external\r\n');
    await project.refreshDisk(config);
    expect(config.externalConflict, true);
    await expectLater(
      project.planFileDeletion(f.data.uri.toString()),
      throwsA(isA<CoreFailure>()),
    );
    await expectLater(
      project.planFileMove(f.data.uri.toString(), '${temp.path}/new.yaml'),
      throwsA(isA<CoreFailure>()),
    );
    expect(config.text, working);
    expect(await f.data.exists(), true);
  });

  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        '$version json=$json dual contract/upload bytes require retained URI identity',
        () async {
          final f = await fixture(temp, engine, version: version, json: json);
          final project = f.project;
          addTearDown(project.close);
          final ext = json ? 'json' : 'yaml';
          final reference = {r'$ref': './payload.$ext#/Value'};
          final document = {
            version == '2.0' ? 'swagger' : 'openapi': version,
            'info': {'title': 'Dual use', 'version': '1'},
            'paths': <String, Object?>{},
            if (version == '2.0')
              'definitions': {'Value': reference}
            else
              'components': {
                'schemas': {'Value': reference},
              },
          };
          await f.root.writeAsString(
            json
                ? jsonEncode(document)
                : document.entries
                      .map((e) => '${e.key}: ${jsonEncode(e.value)}')
                      .join('\n'),
          );
          final upload = json
              ? '{"Value":{"\$ref":"./model.json"}}'
              : '# Keep uploaded source\r\nValue: {\$ref: "./model.yaml"}\r\n';
          await f.data.writeAsString(upload);
          await File('${temp.path}/model.$ext')
              .writeAsString(json ? '{"type":"string"}' : 'type: string\n');
          await Directory('${temp.path}/new').create();
          final destination = File('${temp.path}/new/payload.$ext');
          final originalConfig = await f.manifest.readAsString();
          await expectLater(
            project.planFileMove(f.data.uri.toString(), destination.path),
            throwsA(
              isA<CoreFailure>()
                  .having((e) => e.code, 'code', 'file.move.case-file.content')
                  .having(
                    (e) => e.source?.resource,
                    'resource',
                    f.manifest.uri.toString(),
                  )
                  .having(
                    (e) => e.source?.pointer,
                    'pointer',
                    '/tests/0/body/files/0/path',
                  ),
            ),
          );
          expect(await f.data.readAsString(), upload);
          expect(await f.manifest.readAsString(), originalConfig);
          expect(await destination.exists(), false);
          final plan = await project.planFileMove(
            f.data.uri.toString(),
            destination.path,
            retainIdentity: true,
          );
          expect(plan.result['blockers'], isEmpty);
          await project.applyRefactoring(plan);
          final data = project.store.get(destination.uri.toString());
          expect(data.text, upload);
          final config = project.store.get(f.manifest.uri.toString());
          expect(config.text, contains('"./new/payload.$ext"'));
          project.store.undo();
          expect(data.id, f.data.uri.toString());
          expect(data.text, upload);
          expect(config.text, originalConfig);
          project.store.redo();
          final publication = PublicationStore('${temp.path}/state');
          expect((await publication.save(project, [data])).complete, true);
          expect(await destination.readAsString(), upload);
          expect(await f.data.exists(), false);
          final reopened = await BusyProject.open(temp.path, engine);
          addTearDown(reopened.close);
          expect(
            (await reopened.check(f.root.uri.toString()))['complete'],
            true,
          );
          expect(
            (await reopened.buffer(destination.uri.toString())).text,
            upload,
          );
        },
      );
    }
  }

  test('shared YAML case paths retain their configuration source on refusal', () async {
    final f = await fixture(temp, engine);
    final project = f.project;
    addTearDown(project.close);
    final text =
        'version: 1\nroots: [{name: Main, path: api.yaml}]\nx-file: &file {name: asset, path: "./payload.yaml"}\ntests: [{name: Upload, operation: {method: post, path: /items}, body: {files: [*file]}}]\n';
    final config = await project.buffer(f.manifest.uri.toString());
    project.store.replace(config.id, text);
    final before = await f.data.readAsBytes();
    await expectLater(
      project.planFileMove(f.data.uri.toString(), '${temp.path}/new.yaml'),
      throwsA(
        isA<CoreFailure>()
            .having((e) => e.code, 'code', 'edit.shared')
            .having(
              (e) => e.source?.resource,
              'resource',
              f.manifest.uri.toString(),
            )
            .having(
              (e) => e.source?.pointer,
              'pointer',
              '/tests/0/body/files/0/path',
            ),
      ),
    );
    expect(config.text, text);
    expect(await f.data.readAsBytes(), before);
    expect(await File('${temp.path}/new.yaml').exists(), false);
  });
}
