import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _HeldConfigurationEngine extends EngineProcess {
  _HeldConfigurationEngine()
    : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'normalizeResourceUris' && entered != null) {
      final gate = release!;
      entered!.complete();
      entered = null;
      await gate.future;
    }
    return result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'working roots follow exact unsaved configuration without retargeting saved source $version $json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-root-config 雪 ',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final first = File('${temp.path}/first.${json ? 'json' : 'yaml'}');
          final second = File('${temp.path}/second.${json ? 'yaml' : 'json'}');
          final yaml =
              'openapi: $version\ninfo: {title: "Exact 😀", version: "1"}\npaths: {}';
          final object =
              '{"openapi":"$version","info":{"title":"Exact 😀","version":"1"},"paths":{}}';
          await first.writeAsBytes([
            239,
            187,
            191,
            ...utf8.encode(json ? object : yaml),
          ]);
          await second.writeAsString(json ? yaml : object);
          final manifest = File('${temp.path}/busyapi.yaml');
          final before =
              '# root owners 😀\r\nversion: 1\nroots:\r\n  - {name: First, path: ${first.uri.pathSegments.last}} # keep\n  - {name: Second, path: ${second.uri.pathSegments.last}} # remove declaration only\r\nunknown: {number: 900719925474099312345, value: "kept"}';
          await manifest.writeAsBytes([239, 187, 191, ...utf8.encode(before)]);
          final original = {
            for (final file in [first, second, manifest])
              file.path: await file.readAsBytes(),
          };
          final project = await BusyProject.open(temp.path, engine);
          addTearDown(project.close);
          final config = await project.buffer(manifest.uri.toString());
          final after = before.replaceFirst(
            '  - {name: Second, path: ${second.uri.pathSegments.last}} # remove declaration only\r\n',
            '',
          );
          project.store.replace(config.id, after);
          expect(project.roots.map((root) => root.name), ['First']);
          await project.check(first.uri.toString());
          expect(project.roots.map((root) => (root.name, root.id)), [
            ('First', first.uri.toString()),
          ]);
          await project.check(second.uri.toString(), saved: true);
          expect(project.roots.map((root) => root.name), [
            'First',
          ], reason: 'Saved checks do not replace the working root projection');
          project.store.undo();
          expect(project.roots.map((root) => root.name), ['First', 'Second']);
          await project.check(first.uri.toString());
          expect(project.roots.map((root) => root.name), ['First', 'Second']);
          project.store.redo();
          expect(project.roots.map((root) => root.name), ['First']);
          await project.check(first.uri.toString());
          expect(project.roots.map((root) => root.name), ['First']);
          for (final entry in original.entries)
            expect(await File(entry.key).readAsBytes(), entry.value);
          final publication = PublicationStore(
            '${temp.path}/state/publications',
          );
          expect((await publication.save(project, [config])).complete, true);
          expect(await manifest.readAsBytes(), [
            239,
            187,
            191,
            ...utf8.encode(after),
          ]);
          for (final file in [first, second])
            expect(await file.readAsBytes(), original[file.path]);
          final reopened = await BusyProject.open(temp.path, engine);
          addTearDown(reopened.close);
          expect(reopened.roots.map((root) => root.name), ['First']);
          expect(
            second.existsSync(),
            true,
            reason: 'Removing a declaration is not a filesystem deletion',
          );
        },
      );
    }
  }
  test('standalone source retains its explicit scope when neighbouring root declarations change', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-standalone-roots-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.1.2\ninfo: {title: Root, version: "1"}\npaths: {}\n',
      );
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Unrelated, path: other.yaml}]\n',
      );
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(root.path, engine);
    addTearDown(project.close);
    final config = await project.buffer(manifest.uri.toString());
    project.store.replace(config.id, 'version: 1\nroots: []\n');
    project.reconcileRootConfiguration();
    await project.check(root.uri.toString());
    expect(project.roots.map((value) => value.id), [root.uri.toString()]);
  });
  test('a missing configured manifest is incomplete rather than silently using stale roots and defaults', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-missing-root-config-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Root, version: "1"}\npaths: {}\n',
      );
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Root, path: root.yaml}]\n',
      );
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    await manifest.delete();
    await expectLater(
      project.check(root.uri.toString()),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'manifest.missing',
        ),
      ),
    );
    expect(project.roots.single.id, root.uri.toString());
    expect(root.existsSync(), true);
  });
  test('a later manifest edit during canonical URI work cannot adopt a stale named-root list', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-root-config-race-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Root, version: "1"}\npaths: {}\n',
      );
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Original, path: root.yaml}]\n',
      );
    final engine = _HeldConfigurationEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final config = await project.buffer(manifest.uri.toString());
    project.store.replace(
      config.id,
      'version: 1\nroots: [{name: Obsolete, path: root.yaml}]\nresourceMappings: {"https://resource.invalid/unused": unused.json}\n',
    );
    final entered = engine.entered = Completer<void>();
    final release = engine.release = Completer<void>();
    final pending = project.check(root.uri.toString());
    final rejected = expectLater(
      pending,
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'manifest.changed',
        ),
      ),
    );
    await entered.future;
    project.store.replace(
      config.id,
      'version: 1\nroots: [{name: Current, path: root.yaml}]\n',
    );
    release.complete();
    await rejected;
    expect(project.roots.single.name, 'Current');
    await project.check(root.uri.toString());
    expect(project.roots.single.name, 'Current');
    expect(
      await manifest.readAsString(),
      'version: 1\nroots: [{name: Original, path: root.yaml}]\n',
    );
  });
  test('invalid working roots cannot mutate the last coherent root set or prevent source repair', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-invalid-roots-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Root, version: "1"}\npaths: {}\n',
      );
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Root, path: root.yaml}]\n',
      );
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final config = await project.buffer(manifest.uri.toString());
    for (final text in [
      'version: 1\nroots: [{name: Broken}]\n',
      'version: 1\nroots: [{name: Duplicate, path: root.yaml}, {name: Duplicate, path: root.yaml}]\n',
      'version: 1\nroots: [{name: Outside, path: ../outside.yaml}]\n',
    ]) {
      project.store.replace(config.id, text);
      await expectLater(
        project.check(root.uri.toString()),
        throwsA(isA<CoreFailure>()),
      );
      expect(project.roots.map((root) => root.name), ['Root']);
      expect(config.text, text);
    }
    project.store.replace(
      config.id,
      'version: 1\nroots: []\nunknown: retained\n',
    );
    await project.check(root.uri.toString());
    expect(project.roots, isEmpty);
    expect(root.existsSync(), true);
    expect(
      await manifest.readAsString(),
      'version: 1\nroots: [{name: Root, path: root.yaml}]\n',
    );
  });
}
