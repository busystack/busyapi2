import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _ObservedEngine extends EngineProcess {
  _ObservedEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  final methods = <String>[];
  String? discoveryFault;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) {
    methods.add(method);
    if (method == 'discoverPolicy' && discoveryFault != null) {
      if (discoveryFault == 'crash')
        throw CoreFailure('engine.exit', 'Injected discovery failure');
      return Future.value({
        'version': 1,
        if (discoveryFault != 'missing-completeness')
          'complete': discoveryFault != 'empty-incomplete',
        'requests': discoveryFault == 'false-complete'
            ? ['https://must-not-load.invalid/rules.yaml']
            : <String>[],
        if (discoveryFault != 'missing-issues')
          'issues': discoveryFault == 'unlocated-issue'
              ? [
                  {
                    'resource': 'file:///outside/rules.yaml',
                    'pointer': '',
                    'code': 'policy.dependencies.syntax',
                  },
                ]
              : <Object>[],
      });
    }
    return super.request(method, params, requestId: requestId);
  }
}

void main() {
  late Directory temp;
  late EngineProcess engine;
  late BusyProject project;
  late File root, fragment;
  late String text;
  Future<void> open(String version, bool json) async {
    root = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
    fragment = File('${temp.path}/fragment 雪.${json ? 'json' : 'yaml'}');
    await root.writeAsString(
      json
          ? '{"openapi":"$version","info":{"title":"Presence 雪😀","version":"1"},"paths":{},"x-data":{"\$ref":"literal"}}'
          : '\ufeff# root 雪😀\r\nopenapi: $version\r\ninfo: {title: "Presence 雪😀", version: "1"}\r\npaths: {}\r\nx-data: {\$ref: literal}',
    );
    text = json
        ? '{"Value":{"type":"integer","const":9007199254740993,"description":"Original 雪😀"}}\r\n'
        : '# fragment 雪😀\r\nValue:\r\n  type: integer\r\n  const: 9007199254740993\n  description: \'Original 雪😀\'';
    engine = _ObservedEngine();
    project = await BusyProject.open(root.path, engine);
    await project.buffer(root.uri.toString());
  }

  setUp(
    () async =>
        temp = await Directory.systemTemp.createTemp('busyapi-file-presence-'),
  );
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });

  for (final problem in [
    'syntax',
    'cycle',
    'functions',
    'executable',
    'alias-cycle',
  ]) {
    test(
      'unknown $problem policy dependencies cannot prove an unrelated file deletable or execute code',
      () async {
        await open('3.2.1', true);
        await fragment.writeAsString(text);
        final rules = File(
              '${temp.path}/.spectral.${problem == 'executable' ? 'cjs' : 'yaml'}',
            ),
            marker = File('${temp.path}/must-not-execute');
        await rules.writeAsString(switch (problem) {
          'syntax' => 'rules: [\n',
          'cycle' => 'extends: [./.spectral.yaml]\nrules: {}\n',
          'functions' => 'functionsDir: ./unapproved-functions\nrules: {}\n',
          'alias-cycle' => '&self\noverrides: [*self]\nrules: {}\n',
          _ =>
            'require("node:fs").writeFileSync(${jsonEncode(marker.path)}, "must not execute"); module.exports={};',
        });
        final before = await fragment.readAsBytes(),
            plan = await project.planFileDeletion(fragment.uri.toString());
        expect(
          (plan.result['blockers'] as List).any(
            (entry) => entry['code'] == 'file.delete.policy-analysis',
          ),
          true,
        );
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(isA<CoreFailure>()),
        );
        expect(await fragment.readAsBytes(), before);
        expect(project.store.get(fragment.uri.toString()).present, true);
        expect(await marker.exists(), false);
        expect((engine as _ObservedEngine).methods, isNot(contains('govern')));
      },
    );
  }
  for (final fault in [
    'missing-completeness',
    'missing-issues',
    'empty-incomplete',
    'false-complete',
    'unlocated-issue',
    'crash',
  ]) {
    test(
      'failed or inconsistent $fault dependency discovery blocks the entire deletion',
      () async {
        await open('3.2.1', true);
        await fragment.writeAsString(text);
        (engine as _ObservedEngine).discoveryFault = fault;
        final before = await fragment.readAsBytes(),
            plan = await project.planFileDeletion(fragment.uri.toString());
        expect(
          (plan.result['blockers'] as List).any(
            (entry) =>
                entry['code'] == 'file.delete.policy-analysis' &&
                entry['reasonCode'] ==
                    (fault == 'crash' ? 'engine.exit' : 'policy.protocol'),
          ),
          true,
        );
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(isA<CoreFailure>()),
        );
        expect(await fragment.readAsBytes(), before);
        expect(project.store.get(fragment.uri.toString()).present, true);
        expect(
          (engine as _ObservedEngine).methods.where(
            (method) => method == 'govern',
          ),
          isEmpty,
        );
      },
    );
  }

  for (final configured in [false, true]) {
    test(
      'deletion protects an unused approved resource mapping configured=$configured',
      () async {
        await open('3.2.1', false);
        await fragment.writeAsString(text);
        if (configured) {
          await File('${temp.path}/busyapi.yaml').writeAsString(
            'version: 1\nroots: [{name: Main, path: root.yaml}]\n'
            'resourceMappings: {"https://contracts.example/unused": "fragment 雪.yaml"}\n',
          );
          project.close();
          project = await BusyProject.open(root.path, engine);
        } else {
          await project.approveResource(
            'https://contracts.example/unused',
            fragment.uri.toString(),
          );
        }
        final bytes = await fragment.readAsBytes(),
            plan = await project.planFileDeletion(fragment.uri.toString());
        expect(
          (plan.result['blockers'] as List).any(
            (entry) => entry['code'] == 'file.delete.mapping-consumer',
          ),
          true,
        );
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(isA<CoreFailure>()),
        );
        expect(project.store.get(fragment.uri.toString()).present, true);
        expect(await fragment.readAsBytes(), bytes);
      },
    );
  }

  for (final change in ['publication', 'undo', 'move']) {
    test('expected-absence refresh cannot overwrite later $change ownership', () async {
      await open('3.2.1', false);
      await project.applyRefactoring(
        await project.planFileCreation(fragment.path, text: text, hasBom: true),
      );
      final b = project.store.get(fragment.uri.toString());
      var observed = false;
      await project.refreshDisk(
        b,
        beforeReload: () async {
          observed = true;
          switch (change) {
            case 'publication':
              final publications = PublicationStore(
                '${temp.path}/publications',
              );
              expect((await publications.save(project, [b])).complete, true);
            case 'undo':
              project.store.undo();
            case 'move':
              final destination = '${temp.path}/later.yaml';
              project.store.apply(
                [],
                paths: [
                  BufferPathEdit(
                    buffer: b.id,
                    generation: b.generation,
                    expectedPath: b.path,
                    expectedText: b.text,
                    expectedBom: b.hasBom,
                    destination: Uri.file(destination).toString(),
                    path: destination,
                  ),
                ],
              );
          }
          // A later observer owns this flag. The earlier expected-absence read
          // must not clear it after its source/presence/disk owner has changed.
          b.externalConflict = true;
        },
      );
      expect(observed, true);
      expect(b.externalConflict, true);
      expect(b.text, text);
      expect(b.hasBom, true);
      expect(
        await root.readAsBytes(),
        utf8.encode(
          '\ufeff# root 雪😀\r\nopenapi: 3.2.1\r\ninfo: {title: "Presence 雪😀", version: "1"}\r\npaths: {}\r\nx-data: {\$ref: literal}',
        ),
      );
    });
  }

  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'create/delete $version $json stays virtual through history and preserves every saved/deleted version',
        () async {
          await open(version, json);
          final originalRoot = await root.readAsBytes();
          final plan = await project.planFileCreation(
            fragment.path,
            text: text,
            hasBom: true,
          );
          expect(await fragment.exists(), false);
          expect(
            project.store.buffers.containsKey(fragment.uri.toString()),
            false,
          );
          final changed = await project.applyRefactoring(plan);
          final b = project.store.get(fragment.uri.toString()),
              bytes = b.bytes();
          expect(changed, {b.id});
          expect(b.publishedPresent, false);
          expect(b.dirty, true);
          expect(project.files, contains(fragment.path));
          expect(await fragment.exists(), false);
          final publications = PublicationStore('${temp.path}/publications');
          final saved = await publications.save(project, [b]);
          expect(saved.complete, true, reason: '${saved.failed}');
          expect(await fragment.readAsBytes(), bytes);
          expect(b.dirty, false);
          expect(b.publishedPresent, true);
          project.store.undo();
          expect(project.store.buffers.containsKey(b.id), false);
          expect(
            await fragment.exists(),
            true,
            reason: 'Undo stages inverse presence, not disk deletion',
          );
          expect(b.hasFileIntent, true);
          final removed = await publications.save(project, [b]);
          expect(removed.complete, true, reason: '${removed.failed}');
          expect(await fragment.exists(), false);
          expect(b.publishedPresent, false);
          expect(b.dirty, false);
          project.store.redo();
          expect(project.store.get(b.id), same(b));
          expect(b.dirty, true);
          expect((await publications.save(project, [b])).complete, true);
          expect(await fragment.readAsBytes(), bytes);
          project.store.replace(
            b.id,
            b.text.replaceFirst('Original', 'Unsaved'),
          );
          final working = b.text;
          final deletion = await project.planFileDeletion(b.id);
          expect(deletion.result['blockers'], isEmpty);
          expect(deletion.result['usages'], isEmpty);
          expect(await fragment.readAsBytes(), bytes);
          await project.applyRefactoring(deletion);
          expect(project.store.buffers.containsKey(b.id), false);
          expect(project.files, isNot(contains(fragment.path)));
          await expectLater(project.buffer(b.id), throwsA(isA<CoreFailure>()));
          expect((await project.check(root.uri.toString()))['complete'], true);
          project.store.undo();
          expect(project.store.get(b.id), same(b));
          expect(b.text, working);
          project.store.redo();
          expect((await publications.save(project, [b])).complete, true);
          expect(await fragment.exists(), false);
          final receipts = await Directory('${temp.path}/publications/archives')
              .list()
              .where((entry) => entry is File)
              .cast<File>()
              .toList();
          final archives = <Map>[];
          for (final receipt in receipts) {
            final value = jsonDecode(await receipt.readAsString()) as Map;
            archives.addAll((value['archives'] as List).cast<Map>());
          }
          final retained = archives
              .where((entry) => entry['deletedWorkingCopy'] is Map)
              .toList();
          expect(retained, hasLength(2));
          final latest = retained.singleWhere(
            (entry) => entry['deletedWorkingCopy']['text'] == working,
          );
          expect(latest['deletedWorkingCopy']['hasBom'], true);
          expect(await File(latest['archive'] as String).readAsBytes(), bytes);
          expect(
            latest['deletedWorkingCopy']['identity'],
            textIdentity('\ufeff$working'),
          );
          expect(await root.readAsBytes(), originalRoot);
          project.close();
          project = await BusyProject.open(root.path, engine);
          expect((await project.check(root.uri.toString()))['complete'], true);
          expect(await fragment.exists(), false);
          expect(await root.readAsBytes(), originalRoot);
        },
      );
    }
  }

  test('Undo during creation publication retains the coupled inverse reference repair and deletion', () async {
    await open('3.2.1', true);
    final rootBuffer = project.store.get(root.uri.toString()),
        rootBytes = await root.readAsBytes(),
        original = rootBuffer.text;
    final creation = await project.planFileCreation(
      fragment.path,
      text: text,
      hasBom: true,
    );
    final offset = rootBuffer.text.indexOf('"paths"');
    project.store.apply(
      [
        TextEdit(
          buffer: rootBuffer.id,
          generation: rootBuffer.generation,
          start: offset,
          end: offset,
          expected: '',
          replacement:
              '"components":{"schemas":{"Shared":{"\$ref":"${fragment.uri}#/Value"}}},',
        ),
      ],
      creations: [creation.creation],
      label: 'Create referenced fragment',
    );
    final b = project.store.get(fragment.uri.toString()), created = b.bytes();
    final checked = await project.check(rootBuffer.id);
    expect(checked['complete'], true, reason: jsonEncode(checked));
    final export = await project.prepareBundle(
      rootBuffer.id,
      '${temp.path}/working export',
    );
    addTearDown(export.close);
    expect(export.unsaved, true);
    expect(export.result['output']['text'], contains('9007199254740993'));
    expect(await root.readAsBytes(), rootBytes);
    expect(await fragment.exists(), false);
    var undone = false;
    final publications = PublicationStore(
      '${temp.path}/publications',
      afterPublish: (id) async {
        if (!undone && id == b.id) {
          undone = true;
          project.store.undo();
        }
      },
    );
    final first = await publications.save(project, [rootBuffer]);
    expect(first.complete, true, reason: '${first.failed}');
    expect(undone, true);
    expect(b.present, false);
    expect(b.publishedPresent, true);
    expect(rootBuffer.text, original);
    expect(rootBuffer.dirty, true);
    expect(b.dirty, true);
    expect(await fragment.readAsBytes(), created);
    expect(await root.readAsBytes(), isNot(rootBytes));
    expect(export.outdated, true);
    final inverse = await publications.save(project, [rootBuffer]);
    expect(inverse.complete, true, reason: '${inverse.failed}');
    expect(await fragment.exists(), false);
    expect(await root.readAsBytes(), rootBytes);
    expect(rootBuffer.dirty, false);
    expect(b.dirty, false);
    project.store.redo();
    expect(rootBuffer.dirty, true);
    expect(b.present, true);
    expect(b.publishedPresent, false);
    final repeated = await publications.save(project, [rootBuffer]);
    expect(repeated.complete, true, reason: '${repeated.failed}');
    expect(await fragment.readAsBytes(), created);
    expect((await project.check(rootBuffer.id))['complete'], true);
  });

  for (final foreign in [false, true]) {
    test(
      'deletion after a virtual move archives the proved original and preserves a distinct destination foreign=$foreign',
      () async {
        await open('3.2.1', true);
        await fragment.writeAsString(text);
        final b = await project.buffer(fragment.uri.toString()),
            original = await fragment.readAsBytes();
        final destination = File('${temp.path}/moved.json');
        project.store.apply(
          const [],
          paths: [
            BufferPathEdit(
              buffer: b.id,
              generation: b.generation,
              expectedPath: b.path,
              expectedText: b.text,
              expectedBom: b.hasBom,
              destination: destination.uri.toString(),
              path: destination.path,
            ),
          ],
        );
        final deletion = await project.planFileDeletion(b.id);
        expect(
          deletion.result['file']['publishedResource'],
          fragment.uri.toString(),
        );
        expect(deletion.result['file']['source'], destination.uri.toString());
        await project.applyRefactoring(deletion);
        await expectLater(
          project.buffer(fragment.uri.toString()),
          throwsA(isA<CoreFailure>()),
        );
        if (foreign)
          await destination.writeAsString('another physical version 雪😀');
        final publications = PublicationStore('${temp.path}/publications');
        final result = await publications.save(project, [b]);
        expect(result.complete, true, reason: '${result.failed}');
        expect(await fragment.exists(), false);
        expect(b.publishedPath, fragment.path);
        expect(b.publishedPresent, false);
        final receipt = jsonDecode(
          await (await Directory('${temp.path}/publications/archives')
                  .list()
                  .where((entry) => entry is File)
                  .cast<File>()
                  .toList())
              .single
              .readAsString(),
        );
        expect(
          await File((receipt['archives'] as List).single['archive'] as String)
              .readAsBytes(),
          original,
        );
        if (foreign) {
          expect(
            await destination.readAsString(),
            'another physical version 雪😀',
          );
          expect(project.files, contains(destination.path));
          final other = await project.buffer(destination.uri.toString());
          expect(other, isNot(same(b)));
          expect(project.store.undo, throwsA(isA<CoreFailure>()));
          expect(
            await destination.readAsString(),
            'another physical version 雪😀',
          );
        } else {
          expect(await destination.exists(), false);
          project.store.undo();
          expect(b.present, true);
          expect(b.path, destination.path);
          expect(b.hasFileIntent, true);
        }
      },
    );
  }

  test('policy inputs are protected before lint runs and discovery never executes custom code', () async {
    await open('3.2.1', true);
    project.close();
    final rules = File('${temp.path}/rules.yaml'),
        base = File('${temp.path}/base.yaml'),
        code = File('${temp.path}/custom.cjs'),
        marker = File('${temp.path}/executed');
    await rules.writeAsString(
      'extends: [./base.yaml, ./custom.cjs]\nrules: {}\n',
    );
    await base.writeAsString('rules: {}\n');
    await code.writeAsString(
      'require("node:fs").writeFileSync(${jsonEncode(marker.path)}, "must not execute"); module.exports={rules:{}};',
    );
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots: [{name: Main, path: root.json}]\npolicy: {rulesets: [rules.yaml]}\n',
    );
    project = await BusyProject.open(root.path, engine);
    for (final file in [rules, base]) {
      final before = await file.readAsBytes(),
          plan = await project.planFileDeletion(file.uri.toString());
      expect(
        (plan.result['blockers'] as List).any(
          (entry) => entry['code'] == 'file.delete.policy-consumer',
        ),
        true,
      );
      expect(
        (plan.result['usages'] as List).any(
          (entry) => entry['connection'] == 'policy-input',
        ),
        true,
      );
      await expectLater(
        project.applyRefactoring(plan),
        throwsA(isA<CoreFailure>()),
      );
      expect(await file.readAsBytes(), before);
    }
    expect((engine as _ObservedEngine).methods, isNot(contains('govern')));
    expect(await marker.exists(), false);
  });

  for (final newDefault in [false, true]) {
    test(
      'changed governance footprint rejects deletion without mutation new-default=$newDefault',
      () async {
        await open('3.2.1', true);
        await fragment.writeAsString(text);
        if (!newDefault) {
          await File('${temp.path}/.spectral.yaml')
              .writeAsString('rules: {}\n');
        }
        final before = await fragment.readAsBytes(),
            plan = await project.planFileDeletion(fragment.uri.toString());
        expect(plan.result['blockers'], isEmpty);
        await File('${temp.path}/.spectral.yaml')
            .writeAsString('rules: {}\n# later configuration\n');
        await expectLater(
          project.applyRefactoring(plan),
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'code',
              'refactor.stale',
            ),
          ),
        );
        expect(project.store.get(fragment.uri.toString()).present, true);
        expect(await fragment.readAsBytes(), before);
        expect((engine as _ObservedEngine).methods, isNot(contains('govern')));
      },
    );
  }

  test('governance cannot read a virtually removed input from disk as a current working resource', () async {
    await open('3.2.1', true);
    project.close();
    final rules = File('${temp.path}/rules.yaml');
    await rules.writeAsString('rules: {}\n');
    await File('${temp.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots: [{name: Main, path: root.json}]\npolicy: {rulesets: [rules.yaml]}\n',
    );
    project = await BusyProject.open(root.path, engine);
    expect((await project.lint(root.uri.toString()))['complete'], true);
    final b = await project.buffer(rules.uri.toString());
    project.store.apply(
      const [],
      presences: [
        BufferPresenceEdit(
          buffer: b.id,
          generation: b.generation,
          expectedPath: b.path,
          expectedText: b.text,
          expectedBom: b.hasBom,
          expectedPresent: true,
          present: false,
        ),
      ],
    );
    final working = await project.lint(root.uri.toString());
    expect(working['complete'], false);
    expect(working['categories']['policy']['complete'], false);
    expect(
      (await project.lint(root.uri.toString(), saved: true))['complete'],
      true,
    );
    expect(await rules.readAsString(), 'rules: {}\n');
  });

  test('destination races and stale source reject a whole creation before any virtual or disk mutation', () async {
    await open('3.2.1', true);
    final b = await project.buffer(root.uri.toString()), original = b.text;
    final stale = await project.planFileCreation(fragment.path, text: text);
    project.store.replace(b.id, b.text.replaceFirst('Presence', 'Later'));
    await expectLater(
      project.applyRefactoring(stale),
      throwsA(isA<CoreFailure>()),
    );
    expect(project.store.buffers.containsKey(fragment.uri.toString()), false);
    expect(await fragment.exists(), false);
    project.store.undo();
    final collision = await project.planFileCreation(fragment.path, text: text);
    await fragment.writeAsString('external newer version');
    await expectLater(
      project.applyRefactoring(collision),
      throwsA(isA<CoreFailure>()),
    );
    expect(await fragment.readAsString(), 'external newer version');
    expect(project.store.buffers.containsKey(fragment.uri.toString()), false);
    expect(b.text, original);
  });

  test('reviewed deletion refuses every established consumer and a configured root, without editing either file', () async {
    await open('3.2.1', true);
    await fragment.writeAsString(text);
    final b = await project.buffer(root.uri.toString());
    project.store.replace(
      b.id,
      b.text.replaceFirst(
        '"paths":{}',
        '"paths":{},"components":{"schemas":{"Use":{"\$ref":"${fragment.uri}#/Value"}}}',
      ),
    );
    final before = b.text, disk = await fragment.readAsBytes();
    final plan = await project.planFileDeletion(fragment.uri.toString());
    expect(plan.result['blockers'], isNotEmpty);
    expect(plan.result['usages'], hasLength(1));
    await expectLater(
      project.applyRefactoring(plan),
      throwsA(
        isA<CoreFailure>().having(
          (failure) => failure.code,
          'code',
          'refactor.blocked',
        ),
      ),
    );
    expect(b.text, before);
    expect(await fragment.readAsBytes(), disk);
    final rootPlan = await project.planFileDeletion(b.id);
    expect(
      (rootPlan.result['blockers'] as List).any(
        (entry) => entry['code'] == 'file.delete.root',
      ),
      true,
    );
    await expectLater(
      project.applyRefactoring(rootPlan),
      throwsA(isA<CoreFailure>()),
    );
    expect(await root.exists(), true);
  });

  for (final deletion in [false, true]) {
    test(
      'discard ${deletion ? 'deletion' : 'creation'} preserves disk and retires the whole unsaved presence intent',
      () async {
        await open('3.1.2', false);
        if (deletion) await fragment.writeAsString(text);
        if (deletion) {
          await project.applyRefactoring(
            await project.planFileDeletion(fragment.uri.toString()),
          );
        } else {
          await project.applyRefactoring(
            await project.planFileCreation(fragment.path, text: text),
          );
        }
        final b = project.store.fileBuffer(fragment.uri.toString());
        project.discardFileChanges();
        expect(b.present, deletion);
        expect(b.dirty, false);
        expect(await fragment.exists(), deletion);
        expect(project.store.canUndo, false);
        if (deletion) expect(project.store.get(b.id).text, text);
      },
    );
  }

  for (final deletion in [false, true]) {
    for (final newer in [false, true]) {
      test(
        'reopen after injected ${deletion ? 'delete archive' : 'create output'} receipt gap preserves ${newer ? 'external' : 'owned'} versions',
        () async {
          await open('3.2.1', true);
          if (deletion) await fragment.writeAsString(text);
          final sourceBytes = await root.readAsBytes();
          await project.applyRefactoring(
            deletion
                ? await project.planFileDeletion(fragment.uri.toString())
                : await project.planFileCreation(
                    fragment.path,
                    text: text,
                    hasBom: true,
                  ),
          );
          final b = project.store.fileBuffer(fragment.uri.toString());
          final recovery = RecoveryStore('${temp.path}/drafts');
          await recovery.persistFileMoves(project.recoveryOwner);
          var interrupted = false;
          final publications = PublicationStore(
            '${temp.path}/publications',
            afterPublish: (id) async {
              if (id == (deletion ? 'archive:${b.id}' : b.id)) {
                interrupted = true;
                throw StateError('Injected termination boundary');
              }
            },
            beforeCheckpoint: () async {
              if (interrupted) throw StateError('Injected missing receipt');
            },
          );
          final result = await publications.save(project, [b]);
          expect(result.complete, false);
          expect(result.journal, isNotNull);
          expect(interrupted, true);
          publications.releaseProject(project);
          project.close();
          if (newer) await fragment.writeAsString('newer external 雪😀');
          project = await BusyProject.open(root.path, engine);
          final restarted = PublicationStore('${temp.path}/publications');
          expect(
            await restarted.inspect(project),
            isEmpty,
            reason: 'A live different owner cannot claim this intent',
          );
          final record = (await publications.inspect(project)).single;
          expect(
            (record['outcomes'] as List).single['outcome'],
            newer ? 'conflict' : 'published',
          );
          await restarted.recoverFileMoves(project, record);
          final restored = project.store.fileBuffer(b.id);
          expect(restored.text, text);
          expect(restored.present, !deletion);
          expect(restored.externalConflict, newer);
          if (!newer) {
            expect(
              await RecoveryStore('${temp.path}/drafts').available(),
              isEmpty,
              reason: 'The injected case has not killed its process owner',
            );
            final checkpoint =
                (await Directory('${temp.path}/drafts')
                        .list()
                        .where(
                          (entry) =>
                              entry is File && entry.path.endsWith('.json'),
                        )
                        .cast<File>()
                        .toList())
                    .single;
            final draft = Map<String, dynamic>.from(
              jsonDecode(await checkpoint.readAsString()) as Map,
            )..['recordPath'] = checkpoint.path;
            await recovery.adoptFileMoves(draft, project.recoveryOwner);
          }
          final resumed = await restarted.save(project, [restored]);
          expect(resumed.complete, !newer, reason: '${resumed.failed}');
          if (newer) {
            expect(await fragment.readAsString(), 'newer external 雪😀');
            expect(restored.text, text);
          } else if (deletion) {
            expect(await fragment.exists(), false);
          } else {
            expect(await fragment.readAsBytes(), [
              239,
              187,
              191,
              ...utf8.encode(text),
            ]);
          }
          expect(await root.readAsBytes(), sourceBytes);
          restarted.releaseProject(project);
        },
      );
    }
  }
}
