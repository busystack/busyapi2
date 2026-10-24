import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-migration-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    await engine.close();
    await temp.delete(recursive: true);
  });
  Future<(BusyProject, File)> open([
    String text =
        'openapi: 3.0.4\ninfo: {title: Original, version: "1"}\npaths: {}\n',
  ]) async {
    final file = File('${temp.path}/source.yaml');
    await file.writeAsString(text);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    return (project, file);
  }

  for (final conversion in [
    ('2.0', '3.0.4'),
    ('3.0.4', '3.1.2'),
    ('3.1.2', '3.0.4'),
  ]) {
    test(
      'multipart migration ${conversion.$1} to ${conversion.$2} preserves actual HTTP values',
      () async {
        final seen = <List<Object?>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          final boundary = request.headers.contentType!.parameters['boundary']!;
          final text = await utf8.decoder.bind(request).join();
          final parts = <List<String>>[];
          for (final part in text.split('--$boundary').skip(1)) {
            if (part.startsWith('--')) continue;
            final at = part.indexOf('\r\n\r\n');
            final headers = part.substring(0, at);
            final name = RegExp('name="([^"]+)"')
                .firstMatch(headers)!
                .group(1)!;
            final type =
                RegExp(r'Content-Type: ([^\r\n]+)')
                    .firstMatch(headers)
                    ?.group(1) ??
                'text/plain';
            parts.add([name, type, part.substring(at + 4, part.length - 2)]);
          }
          seen.add([request.method, request.uri.toString(), parts]);
          request.response.statusCode = 204;
          await request.response.close();
        });
        final (project, file) = await open(
          conversion.$1 == '2.0'
              ? '''swagger: '2.0'
info: {title: Wire, version: '1'}
host: 127.0.0.1:${server.port}
schemes: [http]
basePath: /v1
consumes: [multipart/form-data]
paths:
  /form:
    post:
      parameters:
        - {name: tags, in: formData, type: array, collectionFormat: multi, items: {type: integer}}
      responses: {'204': {description: ok}}
'''
              : '''openapi: ${conversion.$1}
info: {title: Wire, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}/v1'}]
paths:
  /form:
    post:
      requestBody:
        content:
          multipart/form-data:
            schema: {type: object, properties: {tags: {type: array, items: {type: integer}}}}
            encoding: {tags: {contentType: application/json, style: form, explode: ${conversion.$1 == '3.1.2'}}}
      responses: {'204': {description: ok}}
''',
        );
        final original = await file.readAsBytes(), root = file.uri.toString();
        final buffer = await project.buffer(root);
        project.store.replace(
          root,
          buffer.text.replaceFirst('Wire', 'Unsaved wire'),
        );
        Future<void> send(BusyProject owner, String root) async {
          final analysis = await owner.check(root);
          expect(analysis['complete'], isTrue, reason: '$analysis');
          final operation =
              (analysis['projection']['operations'] as List).single as Map;
          final plan = await owner.prepareRequest(
            root,
            resource: operation['resource'] as String,
            pointer: operation['pointer'] as String,
            occurrence: operation['occurrence'] as String,
          );
          addTearDown(plan.close);
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              body: const RequestBodyDraft.multipart([
                RequestFormField('tags', '9007199254740993'),
                RequestFormField('tags', '0'),
              ], []),
            ),
            resolveSecret: (_) async => null,
          );
          expect(
            result.outgoing.complete,
            isTrue,
            reason: '${result.outgoing.findings}',
          );
          expect(
            result.outgoing.valid,
            isTrue,
            reason: '${result.outgoing.findings}',
          );
          expect(result.received.complete, isTrue);
          await result.close();
        }

        await send(project, root);
        final review = await project.prepareMigration(
          root,
          '${temp.path}/migrated',
          targetVersion: conversion.$2,
        );
        addTearDown(review.close);
        expect(
          review.status,
          MigrationStatus.faithfullyConvertible,
          reason: '${review.result}',
        );
        expect(review.unsaved, isTrue);
        await review.publish();
        final copy = await BusyProject.open(review.destination, engine);
        addTearDown(copy.close);
        await send(copy, copy.roots.single.id);
        expect(seen, hasLength(2));
        expect(seen[0], seen[1]);
        expect(seen[0][0], 'POST');
        expect(seen[0][1], '/v1/form');
        expect((seen[0][2] as List).map((part) => (part as List).last), [
          '9007199254740993',
          '0',
        ]);
        expect(await file.readAsBytes(), original);
        expect(buffer.dirty, isTrue);
      },
    );
  }

  for (final family in ['2.0', '3.0', '3.1', '3.2'])
    for (final format in ['yaml', 'json'])
      test(
        '$family $format migrated copies preserve original bytes, unsaved buffers and reopen with target rules',
        () async {
          final source = File(
                '$repositoryRoot/tools/contract_engine/fixtures/native-families/$family-valid.$format',
              ),
              file = File('${temp.path}/source.$format');
          final bytes = [239, 187, 191, ...await source.readAsBytes()];
          await file.writeAsBytes(bytes);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(file.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Native', 'Unsaved'),
          );
          final destination = '${temp.path}/migrated',
              review = await project.prepareMigration(
                buffer.id,
                destination,
                targetVersion: '3.2.1',
              );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.unsaved, true);
          expect(await Directory(destination).exists(), false);
          expect(await file.readAsBytes(), bytes);
          await review.publish();
          expect(await file.readAsBytes(), bytes);
          expect(buffer.dirty, true);
          final copy = await BusyProject.open(destination, engine);
          addTearDown(copy.close);
          final checked = await copy.check(copy.roots.single.id);
          expect(
            checked['status'],
            'complete',
            reason: '${checked['findings']}',
          );
          expect(
            checked['projection']['specification']['declaredVersion'],
            '3.2.1',
          );
          final migrated = File('$destination/${review.result['entry']}');
          expect((await migrated.readAsBytes()).take(3), [239, 187, 191]);
          expect(await migrated.readAsString(), contains('Unsaved'));
        },
      );
  test('cross-file migration reopens from only its published files and identity mappings', () async {
    final model = File('${temp.path}/model.yaml');
    const modelText =
        'a/b: {type: object, properties: {next: {\$ref: "#/a~1b"}}}\n';
    await model.writeAsString(modelText);
    final (project, file) = await open(
      'openapi: 3.0.4\ninfo: {title: External, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: {\$ref: "model.yaml#/a~1b"}}}\n',
    );
    final original = await file.readAsBytes(),
        review = await project.prepareMigration(
          file.uri.toString(),
          '${temp.path}/copy',
          targetVersion: '3.2.1',
        );
    addTearDown(review.close);
    expect(review.publishable, true, reason: '${review.result}');
    await review.publish();
    await model.rename('${temp.path}/source-only.yaml');
    final copy = await BusyProject.open(review.destination, engine);
    addTearDown(copy.close);
    expect((await copy.check(copy.roots.single.id))['status'], 'complete');
    expect(await file.readAsBytes(), original);
  });
  test('static schema resources and anchors downgrade to independently reopenable native Swagger copies', () async {
    final model = File('${temp.path}/models.json');
    const modelText =
        r'{"$id":"https://schemas.invalid/tree","type":"object","properties":{"value":{"$ref":"#needle"}},"$defs":{"a/b":{"$anchor":"needle","type":"integer","enum":[9007199254740992,9007199254740993],"const":9007199254740993}}}';
    await model.writeAsString(modelText);
    final (project, file) = await open(
      'openapi: 3.2.1\ninfo: {title: Static, version: "1"}\npaths: {}\ncomponents: {schemas: {Model: {\$ref: "models.json"}}}\n',
    );
    final original = await file.readAsBytes();
    final review = await project.prepareMigration(
      file.uri.toString(),
      '${temp.path}/copy',
      targetVersion: '2.0',
    );
    addTearDown(review.close);
    expect(review.publishable, true, reason: '${review.result}');
    await review.publish();
    await model.rename('${temp.path}/source-only.json');
    final copy = await BusyProject.open(review.destination, engine);
    addTearDown(copy.close);
    final result = await copy.check(copy.roots.single.id);
    expect(result['status'], 'complete', reason: '$result');
    expect(result['projection']['specification']['family'], '2.0');
    expect(await file.readAsBytes(), original);
    expect(
      await File('${temp.path}/source-only.json').readAsString(),
      modelText,
    );
    expect(
      await File('${review.destination}/${review.result['entry']}')
          .readAsString(),
      contains('9007199254740993'),
    );
  });
  test(
    'Source edits and declaration changes reject stale migration reviews',
    () async {
      final (project, file) = await open();
      final root = file.uri.toString(),
          review = await project.prepareMigration(
            root,
            '${temp.path}/copy',
            targetVersion: '3.1.2',
          );
      addTearDown(review.close);
      final buffer = await project.buffer(root);
      project.store.replace(root, buffer.text.replaceFirst('3.0.4', '3.2.1'));
      await expectLater(
        review.publish(),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'migration.stale',
          ),
        ),
      );
      expect(await Directory(review.destination).exists(), false);
      expect(await file.readAsString(), contains('3.0.4'));
      expect(buffer.text, contains('3.2.1'));
    },
  );
  test('external source changes at the last publication boundary leave the destination absent', () async {
    final (project, file) = await open();
    final review = await project.prepareMigration(
      file.uri.toString(),
      '${temp.path}/copy',
      targetVersion: '3.1.2',
    );
    addTearDown(review.close);
    await expectLater(
      review.publish(
        beforePublish: () => file.writeAsString(
          '# external\n${File(file.path).readAsStringSync()}',
        ),
      ),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'migration.stale',
        ),
      ),
    );
    expect(await Directory(review.destination).exists(), false);
    expect(await file.readAsString(), startsWith('# external'));
  });
  test('destination races, cancellation and staged failures preserve all original files', () async {
    final (project, file) = await open();
    final original = await file.readAsBytes();
    for (final failure in ['race', 'cancel', 'failure']) {
      final path = '${temp.path}/$failure',
          review = await project.prepareMigration(
            file.uri.toString(),
            path,
            targetVersion: '3.1.2',
          );
      addTearDown(review.close);
      var cancel = false;
      await expectLater(
        review.publish(
          cancelled: () => cancel,
          beforePublish: () async {
            if (failure == 'race') {
              await Directory(path).create();
              await File('$path/foreign').writeAsString('Keep');
            }
            if (failure == 'cancel') cancel = true;
            if (failure == 'failure')
              throw const FileSystemException('Controlled publication failure');
          },
        ),
        throwsA(anything),
      );
      expect(await file.readAsBytes(), original);
      if (failure == 'race') {
        expect(await File('$path/foreign').readAsString(), 'Keep');
        expect(await File('$path/openapi.yaml').exists(), false);
      } else {
        expect(await Directory(path).exists(), false);
      }
    }
  });
  test(
    'blocked conversion never publishes an apparently complete copy',
    () async {
      final (project, file) = await open(
        'openapi: 3.2.1\ninfo: {title: Newer, version: "1"}\npaths: {/x: {query: {responses: {204: {description: Empty}}}}}\n',
      );
      final original = await file.readAsBytes(),
          review = await project.prepareMigration(
            file.uri.toString(),
            '${temp.path}/copy',
            targetVersion: '3.1.2',
          );
      addTearDown(review.close);
      expect(review.status, MigrationStatus.blocked);
      expect(review.problems.single.resource, file.uri.toString());
      expect(review.problems.single.pointer, contains('/query'));
      await expectLater(
        review.publish(),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'migration.blocked',
          ),
        ),
      );
      expect(await Directory(review.destination).exists(), false);
      expect(await file.readAsBytes(), original);
    },
  );
  test('installed CLI requires an exact reviewed identity and publishes a separately reopenable copy', () async {
    final (project, file) = await open();
    final original = await file.readAsBytes(),
        destination = '${temp.path}/cli-copy';
    Future<ProcessResult> run(List<String> options) =>
        Process.run('$testBundle/busyapi', [
          'migrate',
          file.path,
          '--target',
          '3.2.1',
          '--output',
          destination,
          '--json',
          ...options,
        ]);
    final first = await run([]);
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    final report = jsonDecode(first.stdout as String) as Map;
    expect(report['published'], false);
    expect(await Directory(destination).exists(), false);
    final stale = await run(['--apply', List.filled(64, '0').join()]);
    expect(stale.exitCode, 3);
    expect(await Directory(destination).exists(), false);
    final applied = await run(['--apply', report['reviewIdentity'] as String]);
    expect(applied.exitCode, 0, reason: '${applied.stdout}\n${applied.stderr}');
    expect((jsonDecode(applied.stdout as String) as Map)['published'], true);
    expect(await file.readAsBytes(), original);
    final checked = await Process.run('$testBundle/busyapi', [
      'check',
      destination,
      '--json',
    ]);
    expect(checked.exitCode, 0, reason: '${checked.stdout}\n${checked.stderr}');
  });
}
