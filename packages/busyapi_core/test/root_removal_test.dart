import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _RootPlanEngine extends EngineProcess {
  _RootPlanEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  String? corrupt;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'planRootRemoval')
      switch (corrupt) {
        case 'range':
          (result['edits'] as List).single['end'] = -1;
        case 'other-buffer':
          (result['edits'] as List).single['buffer'] = 'file:///unrelated.yaml';
        case 'identity':
          result['removed']['name'] = 'Not the selected declaration';
      }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true])
      test(
        'reviewed root removal $version $json is one configuration-only transaction with safe publication',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-root-plan 雪 ',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final first = File('${temp.path}/first.${json ? 'json' : 'yaml'}'),
              second = File('${temp.path}/second.${json ? 'json' : 'yaml'}');
          final api = json
              ? '\ufeff{"openapi":"$version","info":{"title":"Exact 😀","version":"1"},"paths":{},"x-data":{"n":900719925474099312345,"\$ref":"literal"}}'
              : '\ufeff# kept 😀\r\nopenapi: $version\ninfo: {title: "Exact 😀", version: "1"}\r\npaths: {}\nx-data: {n: 900719925474099312345, \$ref: literal}';
          await first.writeAsString(api);
          await second.writeAsString(api);
          final config = File('${temp.path}/busyapi.yaml');
          final text =
              '# metadata 😀\r\nversion: 1\nroots:\n  - {name: First, path: ${first.uri.pathSegments.last}} # declaration\r\n  - {name: Second, path: ${second.uri.pathSegments.last}} # kept\nunknown: {n: 900719925474099312345, \$ref: "payload data"}';
          await config.writeAsString('\ufeff$text');
          final original = {
            for (final file in [first, second, config])
              file.path: await file.readAsBytes(),
          };
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final source = await project.buffer(first.uri.toString());
          project.store.replace(
            source.id,
            source.text.replaceFirst('Exact 😀', 'Unsaved 😀'),
          );
          final working = source.text;
          final plan = await project.planRootRemoval('First', source.id);
          expect(plan.checkedRoots, [
            first.uri.toString(),
            second.uri.toString(),
          ], reason: 'Every configured context contributes to consumer impact');
          expect(plan.result['blockers'], isEmpty);
          expect(plan.result['configuredRoots'], [
            first.uri.toString(),
            second.uri.toString(),
          ]);
          expect(plan.result['changes'], hasLength(1));
          expect(
            plan.edits.every((edit) => edit.buffer == config.uri.toString()),
            true,
          );
          expect(project.roots.map((root) => root.name), ['First', 'Second']);
          expect(project.store.get(config.uri.toString()).dirty, false);
          // Preparing/cancelling a review is not a history entry.
          project.store.undo();
          expect(source.text, contains('Exact 😀'));
          project.store.redo();
          expect(source.text, working);
          await expectLater(
            project.applyRefactoring(plan),
            throwsA(isA<CoreFailure>()),
            reason:
                'All captured API generations participate in impact freshness',
          );
          final current = await project.planRootRemoval('First', source.id);
          await project.applyRefactoring(current);
          expect(project.roots.map((root) => root.name), ['Second']);
          expect(source.text, working);
          for (final entry in original.entries)
            expect(await File(entry.key).readAsBytes(), entry.value);
          project.store.undo();
          expect(project.roots.map((root) => root.name), ['First', 'Second']);
          expect(source.text, working);
          project.store.redo();
          expect(project.roots.map((root) => root.name), ['Second']);
          final manifest = project.store.get(config.uri.toString()),
              after = manifest.bytes();
          expect(manifest.text, contains('900719925474099312345'));
          expect(manifest.text, contains('# kept'));
          final publication = PublicationStore(
            '${temp.path}/state/publications',
          );
          expect((await publication.save(project, [manifest])).complete, true);
          expect(await config.readAsBytes(), after);
          expect(source.dirty, true);
          for (final file in [first, second])
            expect(await file.readAsBytes(), original[file.path]);
          final reopened = await BusyProject.open(temp.path, engine);
          addTearDown(reopened.close);
          expect(reopened.roots.map((root) => root.name), ['Second']);
          expect(first.existsSync(), true);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', temp.path, '--root', 'Second', '--json'],
            environment: {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect(jsonDecode(cli.stdout as String)['complete'], true);
        },
      );
  test('root removal captures dual-use schemas, external examples and every affected input', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-root-consumers-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final first = File('${temp.path}/first.yaml'),
        second = File('${temp.path}/second.yaml'),
        config = File('${temp.path}/busyapi.yaml');
    const api =
        'openapi: 3.2.1\ninfo: {title: Root, version: "1"}\npaths: {}\n';
    await first.writeAsString(api);
    await second.writeAsString(api);
    const manifest =
        'version: 1\nroots: [{name: First, path: first.yaml, type: string}, {name: Second, path: second.yaml, type: integer}]\nresourceMappings: {"https://example.invalid/configuration": busyapi.yaml}\n\$defs: {Stable: {type: string}}\nunknown: {\$ref: "#/roots/0"}\n';
    await config.writeAsString(manifest);
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final consumer = await project.buffer(second.uri.toString());
    for (final declaration in [
      'schemas: {Use: {\$ref: "busyapi.yaml#/roots/0"}}',
      'schemas: {Use: {\$ref: "busyapi.yaml#/roots/1"}}',
      'examples: {Use: {externalValue: "https://example.invalid/configuration"}}',
      'schemas: {Use: {\$ref: "unapproved.yaml#/Missing"}}',
    ]) {
      project.store.replace(consumer.id, '${api}components: {$declaration}\n');
      final plan = await project.planRootRemoval('First', first.uri.toString());
      expect(plan.result['blockers'], isNotEmpty);
      expect(plan.result['usages'], isNotEmpty);
      final before = {
        for (final buffer in project.store.buffers.values)
          buffer.id: buffer.text,
      };
      await expectLater(
        project.applyRefactoring(plan),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'refactor.blocked',
          ),
        ),
      );
      expect({
        for (final buffer in project.store.buffers.values)
          buffer.id: buffer.text,
      }, before);
      expect(project.roots.map((root) => root.name), ['First', 'Second']);
      expect(await config.readAsString(), manifest);
    }
    // Unknown/example payload spellings are not graph edges. A genuinely used
    // independent definition in the same physical file is not blanket-blocked.
    project.store.replace(
      consumer.id,
      '${api}components: {schemas: {Use: {\$ref: "busyapi.yaml#/\$defs/Stable"}}, examples: {Data: {value: {\$ref: "busyapi.yaml#/roots/0", n: 900719925474099312345}}}}\n',
    );
    final safe = await project.planRootRemoval('First', first.uri.toString());
    expect(safe.result['blockers'], isEmpty);
    project.store.replace(
      consumer.id,
      '${consumer.text}# later affected input\n',
    );
    await expectLater(
      project.applyRefactoring(safe),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'refactor.stale',
        ),
      ),
    );
    expect(project.store.get(config.uri.toString()).text, manifest);
    final current = await project.planRootRemoval(
      'First',
      first.uri.toString(),
    );
    await project.applyRefactoring(current);
    expect(project.roots.single.name, 'Second');
    expect(consumer.text, contains('900719925474099312345'));
    expect(await first.readAsString(), api);
    expect(await second.readAsString(), api);
  });
  test('stale or malformed root removal changes no buffer and retains every external version', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-stale-root-plan-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Root, version: "1"}\npaths: {}\n',
      );
    final config = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Root, path: root.yaml}]\n',
      );
    final before = await config.readAsString(), api = await root.readAsBytes();
    final engine = _RootPlanEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    for (final corruption in ['range', 'other-buffer', 'identity']) {
      engine.corrupt = corruption;
      await expectLater(
        project.planRootRemoval('Root', root.uri.toString()),
        throwsA(
          isA<CoreFailure>().having(
            (failure) => failure.code,
            'code',
            'root.protocol',
          ),
        ),
      );
      expect(project.store.get(config.uri.toString()).text, before);
      expect(project.store.canUndo, false);
    }
    engine.corrupt = null;
    final stale = await project.planRootRemoval('Root', root.uri.toString());
    await config.writeAsString('$before# newer external metadata\n');
    await expectLater(
      project.applyRefactoring(stale),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'refactor.stale',
        ),
      ),
    );
    expect(await config.readAsString(), '$before# newer external metadata\n');
    expect(await root.readAsBytes(), api);
    final latest = await project.planRootRemoval('Root', root.uri.toString());
    project.store.replace(
      config.uri.toString(),
      '$before# unsaved newer metadata\n',
    );
    await expectLater(
      project.applyRefactoring(latest),
      throwsA(isA<CoreFailure>()),
    );
    expect(
      project.store.get(config.uri.toString()).text,
      '$before# unsaved newer metadata\n',
    );
    expect(project.roots.single.name, 'Root');
  });
}
