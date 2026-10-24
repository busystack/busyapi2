import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'retained-URI move preserves exact source, all roots and saved/working identity $version $json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-retained-core-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final ext = json ? 'json' : 'yaml',
              root = File('${temp.path}/root.$ext'),
              other = File('${temp.path}/other.$ext'),
              manifest = File('${temp.path}/busyapi.yaml');
          final text = json
              ? '{\r\n"openapi":"$version",${version.startsWith('3.2') ? '"\$self":"./root.$ext",' : ''}"info":{"title":"Retained 🐾","version":"1","description":"[Guide](../guide/file.md)"},"paths":{},"components":{"schemas":{"Node":{"\$id":"node","\$dynamicAnchor":"node","type":"object","properties":{"value":{"type":"integer"},"children":{"type":"array","items":{"\$dynamicRef":"#node"}}},"example":{"value":900719925474099312345,"children":[]}}}}}'
              : 'openapi: $version\r\n${version.startsWith('3.2') ? '\$self: ./root.$ext\n' : ''}info: {title: "Retained 🐾", version: "1", description: "[Guide](../guide/file.md)"}\npaths: {}\ncomponents:\n  schemas:\n    Node:\n      \$id: node\n      \$dynamicAnchor: node\n      type: object\n      properties:\n        value: {type: integer}\n        children: {type: array, items: {\$dynamicRef: "#node"}}\n      example: {value: 900719925474099312345, children: []} # exact';
          await root.writeAsBytes([239, 187, 191, ...utf8.encode(text)]);
          // Source representation may differ between resources; neither is reserialized.
          final otherText =
              '{"openapi":"$version","info":{"title":"Other","version":"1"},"paths":{},"components":{"schemas":{"Use":{"\$ref":"root.$ext#/components/schemas/Node"}}}}';
          await other.writeAsString(otherText);
          final config =
              'version: 1\nroots:\n  - name: Main\n    path: root.$ext # owner\n  - name: Other\n    path: other.$ext\nunknown: {number: 900719925474099312345, \$ref: payload}\n';
          await manifest.writeAsString(config);
          await Directory('${temp.path}/new folder').create();
          final destination = File('${temp.path}/new folder/新しい.$ext');
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final b = await project.buffer(root.uri.toString());
          project.store.replace(
            b.id,
            b.text.replaceFirst('Retained 🐾', 'Unsaved 🐾'),
          );
          final original = b.bytes();
          final plan = await project.planFileMove(
            b.id,
            destination.path,
            retainIdentity: true,
          );
          expect(plan.result['file']['retainedIdentity'], root.uri.toString());
          await project.applyRefactoring(plan);
          expect(b.bytes(), original);
          expect(project.store.get(other.uri.toString()).text, otherText);
          expect(
            project.approvedResources[root.uri.toString()],
            destination.uri.toString(),
          );
          for (final r in project.roots) {
            final checked = await project.check(r.id);
            expect(checked['complete'], true, reason: jsonEncode(checked));
            expect(checked['unsaved'], true);
          }
          expect(destination.existsSync(), false);
          project.store.undo();
          expect(b.id, root.uri.toString());
          expect(project.approvedResources, isEmpty);
          expect(project.store.get(manifest.uri.toString()).text, config);
          project.store.redo();
          expect(b.id, destination.uri.toString());
          expect(project.approvedResources[root.uri.toString()], b.id);
          final savedBeforePublication = await project.check(
            root.uri.toString(),
            saved: true,
          );
          expect(savedBeforePublication['complete'], true);
          expect(savedBeforePublication['unsaved'], false);
          expect(project.approvedResources[root.uri.toString()], b.id);
          final publications = PublicationStore(
            '${temp.path}/state/publications',
          );
          expect((await publications.save(project, [b])).complete, true);
          expect(root.existsSync(), false);
          expect(await destination.readAsBytes(), original);
          expect(await other.readAsString(), otherText);
          expect(
            await manifest.readAsString(),
            contains(
              'unknown: {number: 900719925474099312345, \$ref: payload}',
            ),
          );
          final reopened = await BusyProject.open(temp.path, engine);
          addTearDown(reopened.close);
          expect(reopened.approvedResources[root.uri.toString()], b.id);
          for (final r in reopened.roots) {
            final check = await reopened.check(r.id);
            expect(check['complete'], true, reason: jsonEncode(check));
            expect(check['unsaved'], false);
          }
          final cli = await Process.run('$testBundle/busyapi', [
            'check',
            temp.path,
            '--json',
          ]);
          expect(cli.exitCode, 0, reason: cli.stderr as String);
          expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
          // A subsequent ordinary move must update the existing portable mapping,
          // not silently create a different retrieval base.
          final next = File('${temp.path}/again.$ext');
          final second = await reopened.planFileMove(b.id, next.path);
          await reopened.applyRefactoring(second);
          expect(
            reopened.approvedResources[root.uri.toString()],
            next.uri.toString(),
          );
          expect((await reopened.check(next.uri.toString()))['complete'], true);
        },
      );
    }
  }
  for (final version in ['3.1.2', '3.2.1'])
    test(
      'configured local resource mappings share canonical identities and survive headless reopen $version',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-resource-config-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final root = File('${temp.path}/root.json'),
            model = File('${temp.path}/model.json'),
            manifest = File('${temp.path}/busyapi.yaml');
        await root.writeAsString(
          jsonEncode({
            'openapi': version,
            'info': {'title': 'Mapped', 'version': '1'},
            'paths': {},
            'components': {
              'schemas': {
                'Model': {
                  r'$ref': r'https://xn--xample-9ua.test/a/model#/$defs/a~1b',
                },
              },
            },
          }),
        );
        await model.writeAsString(
          r'{"$id":"./model","$defs":{"a/b":{"type":"integer","examples":[900719925474099312345]}}}',
        );
        await manifest.writeAsString(
          'version: 1\nroots:\n  - name: Main\n    path: root.json\nresourceMappings:\n  "HTTPS://éxample.test:443/a/./%6dodel": model.json # retained\nunknown: {number: 900719925474099312345}\n',
        );
        final original = await manifest.readAsBytes();
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final checked = await project.check(
          project.roots.single.id,
          schemaEvaluation: false,
        );
        expect(checked['complete'], true);
        expect(checked['status'], 'complete');
        expect(
          (checked['resources'] as List).any(
            (resource) => resource['id'] == model.uri.toString(),
          ),
          true,
        );
        expect(project.approvedResources, {
          'https://xn--xample-9ua.test/a/model': model.uri.toString(),
        });
        expect(await manifest.readAsBytes(), original);
        final cli = await Process.run('$testBundle/busyapi', [
          'check',
          temp.path,
          '--json',
        ]);
        expect(cli.exitCode, 0, reason: cli.stderr as String);
        expect((jsonDecode(cli.stdout as String) as Map)['complete'], true);
        expect(await manifest.readAsBytes(), original);
      },
    );
  test('unsaved mapping configuration is captured, monitored and distinct from saved input', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-resource-overlay-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Initializer.create(
      destination: temp.path,
      title: 'Overlay',
      apiVersion: '1',
    );
    final manifest = File('${temp.path}/busyapi.yaml'),
        model = File('${temp.path}/model.yaml');
    await model.writeAsString('type: string\n');
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final initial = await project.check(
      project.roots.single.id,
      schemaEvaluation: false,
    );
    final b = await project.buffer(manifest.uri.toString());
    project.store.replace(
      b.id,
      '${b.text}resourceMappings:\n  https://example.test/model: model.yaml\n',
    );
    final working = await project.check(
      project.roots.single.id,
      schemaEvaluation: false,
    );
    expect(working['unsaved'], true);
    expect(working['snapshot'], isNot(initial['snapshot']));
    expect(project.approvedResources, isNotEmpty);
    final saved = await project.check(
      project.roots.single.id,
      saved: true,
      schemaEvaluation: false,
    );
    expect(saved['unsaved'], false);
    expect(
      project.approvedResources,
      isNotEmpty,
      reason: 'A saved check cannot retarget the working projection',
    );
    await project.save(b);
    await manifest.writeAsString('${b.text}# external\n');
    final refresh = await project.refreshResources();
    expect(refresh.resources, contains(b.id));
    expect(refresh.roots, contains(project.roots.single.id));
  });
  test('mappings never grant outside-directory access or choose a conflicting identifier', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-resource-cap-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await Directory('${temp.path}/project').create();
    final root = File('${temp.path}/project/root.json');
    await root.writeAsString(
      r'{"openapi":"3.2.1","info":{"title":"Approval","version":"1"},"paths":{},"components":{"schemas":{"Use":{"$ref":"https://example.test/model"}}}}',
    );
    await File('${temp.path}/external.json').writeAsString('{"type":"string"}');
    final manifest = File('${temp.path}/project/busyapi.yaml');
    await manifest.writeAsString(
      'version: 1\nroots: [{name: Main, path: root.json}]\nresourceMappings: {"https://example.test/model": ../external.json}\n',
    );
    final project = await BusyProject.open('${temp.path}/project', engine);
    addTearDown(project.close);
    final denied = await project.check(
      project.roots.single.id,
      schemaEvaluation: false,
    );
    expect(denied['complete'], false);
    await project.approveContext(temp.path);
    expect(
      (await project.check(
        project.roots.single.id,
        schemaEvaluation: false,
      ))['complete'],
      true,
    );
    await expectLater(
      project.approveResource(
        'https://example.test/%6dodel',
        root.uri.toString(),
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'resource.collision'),
      ),
    );
  });
  test('an explicitly opened contract named busyapi.yaml is not a project manifest', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-resource-name-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final file = File('${temp.path}/busyapi.yaml');
    await file.writeAsString(
      'openapi: 3.1.2\ninfo: {title: Named, version: "1"}\npaths: {}\n',
    );
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    expect(
      (await project.check(
        project.roots.single.id,
        schemaEvaluation: false,
      ))['complete'],
      true,
    );
    expect(project.approvedResources, isEmpty);
  });
  test('configuration-only edits stale a captured rename and frozen output without applying source edits', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-resource-freshness-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json'),
        manifest = File('${temp.path}/busyapi.yaml');
    const text =
        r'{"openapi":"3.2.1","info":{"title":"Fresh","version":"1"},"paths":{},"components":{"schemas":{"Model":{"type":"string"},"Use":{"$ref":"#/components/schemas/Model"}}}}';
    const config = 'version: 1\nroots: [{name: Main, path: root.json}]\n';
    await root.writeAsString(text);
    await manifest.writeAsString(config);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(root.uri.toString());
    final plan = await project.planComponentRename({
      'resource': b.id,
      'pointer': '/components/schemas/Model',
      'generation': b.generation,
    }, 'Renamed');
    final output = await project.prepareBundle(b.id, '${temp.path}/output');
    addTearDown(output.close);
    expect(output.outdated, false);
    await manifest.writeAsString('$config# external metadata 🐾\n');
    await expectLater(
      project.applyRefactoring(plan),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'refactor.stale'),
      ),
    );
    expect(b.text, text);
    expect(await root.readAsString(), text);
    expect(output.outdated, true);
    expect(File('${temp.path}/output/openapi.json').existsSync(), false);
    final latest = await project.prepareBundle(b.id, '${temp.path}/latest');
    addTearDown(latest.close);
    final m = await project.buffer(manifest.uri.toString());
    project.store.replace(m.id, '${m.text}# working metadata 雪\n');
    expect(latest.outdated, true);
    expect(
      latest.snapshot.configuration.single['text'],
      '$config# external metadata 🐾\n',
    );
    expect(await manifest.readAsString(), '$config# external metadata 🐾\n');
  });
  test('normalization rejects unsafe identities and configuration plus session mappings share one limit', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-resource-bounds-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final root = File('${temp.path}/root.json');
    await root.writeAsString(
      '{"openapi":"3.1.2","info":{"title":"Bounds","version":"1"},"paths":{}}',
    );
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots: [{name: Main, path: root.json}]\nresourceMappings:\n${List.generate(256, (i) => '  https://example.test/$i: cache-$i.json\n').join()}',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    expect(project.approvedResources, hasLength(256));
    for (final value in [
      'https://user:secret@example.test/x',
      'https://example.test/x#',
      'https://example.test/%xx',
      'relative',
    ]) {
      await expectLater(
        project.approveResource(value, root.uri.toString()),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'resource.identity'),
        ),
      );
    }
    await expectLater(
      project.approveResource('https://example.test/new', root.uri.toString()),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'resource.limit'),
      ),
    );
    expect(project.approvedResources, hasLength(256));
    expect(await root.readAsString(), contains('"title":"Bounds"'));
  });
}
