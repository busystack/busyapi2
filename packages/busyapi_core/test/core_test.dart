import 'test_support.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('worker snapshots retain captured text, BOM and generation', () async {
    final original = '${'field: 😀\r\n' * 50000}tail';
    final b = DocumentBuffer.decode(
      '/tmp/snapshot.yaml',
      utf8.encode('\ufeff$original'),
    );
    final pending = b.snapshotAsync();
    b.update('$original\nnewer');
    final captured = await pending;
    expect(captured['text'], original);
    expect(captured['generation'], 1);
    expect(captured['hasBom'], true);
    expect(captured['identity'], textIdentity('\ufeff$original'));
    final current = await b.snapshotAsync();
    expect(current['identity'], b.sourceIdentity);
    expect(current['generation'], b.generation);
    expect(current['identity'], isNot(captured['identity']));
  });
  late Directory temp;
  late EngineProcess engine;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-test-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    await engine.close();
    await temp.delete(recursive: true);
  });

  test('concurrent callers share one physical buffer and clean saves validate disk', () async {
    await Initializer.create(
      destination: temp.path,
      title: 'Original',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final buffers = await Future.wait([
      project.buffer(project.roots.single.id),
      project.buffer(project.roots.single.id),
    ]);
    expect(buffers[0], same(buffers[1]));
    final b = buffers[0];
    File(b.path).writeAsStringSync(b.text.replaceFirst('Original', 'External'));
    final result = await PublicationStore('${temp.path}/state')
        .save(project, [b]);
    expect(result.complete, true);
    expect(b.text, contains('External'));
    expect(b.dirty, false);
    expect(File(b.path).readAsStringSync(), b.text);
  });
  test('analysis validates clean open buffers and refresh cannot replace concurrent typing', () async {
    await Initializer.create(
      destination: temp.path,
      title: 'A',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id);
    File(b.path).writeAsStringSync(b.text.replaceFirst('"A"', '"C"'));
    final checked = await project.check(b.id);
    expect(checked['info']['value']['title'], 'C');
    expect(b.text, contains('"C"'));
    File(b.path).writeAsStringSync(b.text.replaceFirst('"C"', '"External"'));
    final entered = Completer<void>(), release = Completer<void>();
    final refresh = project.refreshDisk(
      b,
      beforeReload: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    project.store.replace(b.id, b.text.replaceFirst('"C"', '"Typing"'));
    release.complete();
    await refresh;
    expect(b.text, contains('"Typing"'));
    expect(b.externalConflict, true);
    expect(b.baseline, contains('"C"'));
    expect(File(b.path).readAsStringSync(), contains('"External"'));
  });
  test('concurrent Source typing is not a disk-resource change', () async {
    await Initializer.create(
      destination: temp.path,
      title: 'A',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id);
    await project.check(b.id);
    final saved = File(b.path).readAsBytesSync();
    final poll = project.refreshResources();
    project.store.replace(b.id, b.text.replaceFirst('"A"', '"Typing"'));
    final result = await poll;
    expect(result.resources, isEmpty);
    expect(result.roots, isEmpty);
    expect(b.text, contains('"Typing"'));
    expect(b.externalConflict, false);
    expect(File(b.path).readAsBytesSync(), saved);
    File(b.path)
        .writeAsStringSync(b.baseline.replaceFirst('"A"', '"External"'));
    final external = await project.refreshResources();
    expect(external.resources, {b.id});
    expect(external.roots, {b.id});
    expect(b.externalConflict, true);
    expect(b.text, contains('"Typing"'));
  });

  test('unopened shared dependencies invalidate both roots and missing resources can return', () async {
    File('${temp.path}/busyapi.yaml').writeAsStringSync(
      'version: 1\nroots:\n  - name: a\n    path: a.yaml\n  - name: b\n    path: b.yaml\n',
    );
    for (final name in ['a', 'b']) {
      File('${temp.path}/$name.yaml').writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: $name, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Shared: {\$ref: shared.yaml}\n',
      );
    }
    final shared = File('${temp.path}/shared.yaml')
      ..writeAsStringSync('type: string\n');
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    for (final root in project.roots) {
      await project.check(root.id);
    }
    expect(project.store.buffers, isEmpty);
    File('${temp.path}/unrelated.yaml').writeAsStringSync('unrelated: true');
    expect((await project.refreshResources()).roots, isEmpty);
    shared.writeAsStringSync('type: boolean\n');
    expect(
      (await project.refreshResources()).roots,
      project.roots.map((r) => r.id).toSet(),
    );
    final active = await project.check(project.roots.first.id);
    expect(active['complete'], true);
    final b = await project.buffer(shared.uri.toString());
    project.store.replace(b.id, 'type: integer\n');
    shared.writeAsStringSync('type: number\n');
    await project.refreshResources();
    expect(b.text, 'type: integer\n');
    expect(b.externalConflict, true);
    shared.deleteSync();
    await project.refreshResources();
    shared.writeAsStringSync('type: string\n');
    expect(
      (await project.refreshResources()).roots,
      project.roots.map((r) => r.id).toSet(),
    );
    expect(b.text, 'type: integer\n');
  });
  test(
    'analysis of a dirty conflict retains the observed disk identity',
    () async {
      await Initializer.create(
        destination: temp.path,
        title: 'Original',
        apiVersion: '1',
      );
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      final b = await project.buffer(project.roots.single.id);
      await project.check(b.id);
      project.store.replace(b.id, b.text.replaceFirst('Original', 'Draft'));
      final external = b.baseline.replaceFirst('Original', 'External');
      File(b.path).writeAsStringSync(external);
      expect((await project.refreshResources()).roots, {b.id});
      expect(b.externalConflict, true);
      await project.check(b.id);
      final unchanged = await project.refreshResources();
      expect(unchanged.roots, isEmpty);
      expect(unchanged.resources, isEmpty);
      expect(b.text, contains('Draft'));
      expect(File(b.path).readAsStringSync(), external);
    },
  );
  test(
    'batched collection preserves the complete graph and saved snapshot parity',
    () async {
      final rootFile = File('${temp.path}/openapi.json');
      rootFile.writeAsStringSync(
        jsonEncode({
          'openapi': '3.2.1',
          'info': {'title': 'Batched', 'version': '1'},
          'paths': {},
          'components': {
            'schemas': {
              for (var i = 0; i < 40; i++)
                'Schema$i': {r'$ref': 'Schema$i.json'},
            },
          },
        }),
      );
      const fragment =
          '{"type":"object","properties":{"name":{"type":"string"}}}';
      for (var i = 0; i < 40; i++) {
        File('${temp.path}/Schema$i.json').writeAsStringSync(fragment);
      }
      final project = await BusyProject.open(rootFile.path, engine);
      addTearDown(project.close);
      final root = project.roots.single.id;
      await project.buffer(root);
      final initial = await project.check(root);
      expect(initial['status'], 'complete');
      expect(initial['resources'], hasLength(41));
      expect(project.dependencies[root], hasLength(41));
      final saved = await project.check(root, saved: true);
      expect(saved['snapshot'], initial['snapshot']);
      expect(saved['findings'], initial['findings']);
      final missing = File('${temp.path}/Schema7.json');
      missing.deleteSync();
      expect((await project.refreshResources()).roots, {root});
      final incomplete = await project.check(root);
      expect(incomplete['complete'], false);
      expect(incomplete['findings'], isNotEmpty);
      expect(incomplete['resources'], hasLength(40));
      missing.writeAsStringSync(fragment);
      expect((await project.refreshResources()).roots, {root});
      final restored = await project.check(root);
      expect(restored['status'], 'complete');
      expect(restored['resources'], hasLength(41));
      expect(restored['snapshot'], initial['snapshot']);
      expect(rootFile.readAsStringSync(), contains('"paths":{}'));
    },
  );
  test('clean external reload retires only touching history and cannot undo a newer disk version', () async {
    await Initializer.create(
      destination: '${temp.path}/api',
      title: 'A',
      apiVersion: '1',
    );
    final project = await BusyProject.open('${temp.path}/api', engine);
    try {
      final b = await project.buffer(project.roots.single.id);
      final independent = DocumentBuffer.decode(
        '${temp.path}/independent.yaml',
        utf8.encode('original'),
      );
      project.store.buffers[independent.id] = independent;
      project.store.replace(independent.id, 'independent edit');
      project.store.replace(b.id, b.text.replaceFirst('"A"', '"B"'));
      await project.save(b);
      File(b.path).writeAsStringSync(b.text.replaceFirst('"B"', '"C"'));
      final generation = b.generation;
      await project.refreshDisk(b);
      final current = b.text;
      expect(b.generation, greaterThan(generation));
      project.store.undo();
      expect(b.text, current);
      expect(independent.text, 'original');
      project.store.redo();
      expect(b.text, current);
    } finally {
      project.close();
    }
  });
  test(
    'history replay checks every expected value before touching any buffer',
    () {
      final store = BufferStore();
      final a = DocumentBuffer.decode('/tmp/a.yaml', utf8.encode('A'));
      final b = DocumentBuffer.decode('/tmp/b.yaml', utf8.encode('B'));
      store.buffers.addAll({a.id: a, b.id: b});
      store.apply([
        for (final item in [a, b])
          TextEdit(
            buffer: item.id,
            generation: item.generation,
            start: 0,
            end: 1,
            expected: item.text,
            replacement: 'edited',
          ),
      ]);
      b.update('external');
      expect(() => store.undo(), throwsA(isA<CoreFailure>()));
      expect(a.text, 'edited');
      expect(b.text, 'external');
    },
  );
  test('existing incident project opens and checks without reinitialization or byte changes', () async {
    final dir = Directory('${temp.path}/testapiproject/api')
      ..createSync(recursive: true);
    final contract = File('${dir.path}/openapi.yaml');
    final manifest = File('${dir.path}/busyapi.yaml');
    const source =
        'openapi: "3.1.2"\ninfo:\n  title: "test"\n  version: "1.0.0"\npaths: {}\n';
    const configuration =
        'version: 1\nroots:\n  - name: main\n    path: openapi.yaml\n';
    contract.writeAsStringSync(source);
    manifest.writeAsStringSync(configuration);
    final before = contract.statSync();
    final project = await BusyProject.open(dir.path, engine);
    try {
      expect(project.roots.single.name, 'main');
      final result = await project.check(project.roots.single.id);
      expect(result['status'], 'complete');
      expect(result['operations'], isEmpty);
      final buffer = await project.buffer(project.roots.single.id);
      await project.save(buffer);
      expect(contract.readAsStringSync(), source);
      expect(manifest.readAsStringSync(), configuration);
      expect(contract.statSync().modified, before.modified);
    } finally {
      project.close();
    }
  });
  test(
    'UTF8 raw decode retains BOM, mixed endings, final newline and Unicode',
    () {
      final raw = [239, 187, 191, ...utf8.encode('a: 😀\r\nb: 1\nc: 2\r')];
      final b = DocumentBuffer.decode('/tmp/a.yaml', raw);
      expect(b.bytes(), raw);
      expect(b.lines.lineCount, 4);
      expect(b.lines.lineAt(2).startOffset, 7);
      expect(
        () => DocumentBuffer.decode('/tmp/b.yaml', [255]),
        throwsFormatException,
      );
    },
  );
  test(
    'multi-buffer plans are all-or-nothing and generations never rewind',
    () {
      final store = BufferStore();
      for (final name in ['a', 'b']) {
        final b = DocumentBuffer.decode('/tmp/$name.yaml', utf8.encode('same'));
        store.buffers[b.id] = b;
      }
      final a = store.buffers.values.first, b = store.buffers.values.last;
      expect(
        () => store.apply([
          TextEdit(
            buffer: a.id,
            generation: 1,
            start: 0,
            end: 4,
            expected: 'same',
            replacement: 'new',
          ),
          TextEdit(
            buffer: b.id,
            generation: 0,
            start: 0,
            end: 4,
            expected: 'same',
            replacement: 'bad',
          ),
        ]),
        throwsA(isA<CoreFailure>()),
      );
      expect(a.text, 'same');
      store.replace(a.id, 'source');
      store.apply([
        TextEdit(
          buffer: a.id,
          generation: 2,
          start: 0,
          end: 6,
          expected: 'source',
          replacement: 'design',
        ),
      ]);
      store.undo();
      expect(a.text, 'source');
      store.undo();
      expect(a.text, 'same');
      store.redo();
      store.redo();
      expect(a.text, 'design');
      expect(a.generation, 7);
    },
  );
  for (final version in ['3.1.2', '3.2.1'])
    for (final format in ['yaml', 'json']) {
      test('initializer and source/design history $version $format', () async {
        final path = await Initializer.create(
          destination: temp.path,
          title: 'API',
          apiVersion: '1',
          openapi: version,
          format: format,
        );
        final original = await File(path).readAsBytes();
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id, b = await project.buffer(root);
        await project.save(b);
        expect(await File(path).readAsBytes(), original);
        final result = await project.check(root);
        expect(result['status'], 'complete');
        final info = result['info'];
        final session = PropertySession(
          root: root,
          buffer: b.id,
          generation: b.generation,
          pointer: '/info',
          range: List<int>.from(info['range'] as List),
          expected: b.text.substring(
            info['range'][0] as int,
            info['range'][1] as int,
          ),
        );
        session.bind('title', 'API');
        session.bind('version', '1');
        session.edit('title', 'Edited');
        session.edit('version', '2');
        await project.proposeAndApply(root, session, session.actions());
        expect(b.text, contains('Edited'));
        project.store.replace(root, b.text.replaceFirst('Edited', 'Source'));
        project.store.undo();
        expect(b.text, contains('Edited'));
        project.store.undo();
        expect(b.bytes(), original);
        project.store.redo();
        project.store.redo();
        await project.save(b);
        expect((await project.check(root, saved: true))['status'], 'complete');
        await expectLater(
          Initializer.create(
            destination: temp.path,
            title: 'Other',
            apiVersion: '2',
          ),
          throwsA(isA<CoreFailure>()),
        );
        expect(await File(path).readAsBytes(), b.bytes());
      });
    }
  test(
    'discovery ambiguity fragments and opening never creates manifest',
    () async {
      for (final name in ['a', 'b']) {
        await File(p.join(temp.path, '$name.yaml')).writeAsString(
          'openapi: 3.1.2\ninfo: {title: A, version: "1"}\npaths: {}\n',
        );
      }
      await File(p.join(temp.path, 'fragment.yaml'))
          .writeAsString('type: string\n');
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      expect(project.roots.length, 2);
      expect(File(p.join(temp.path, 'busyapi.yaml')).existsSync(), false);
      final fragment = await project.buffer(
        Uri.file(p.join(temp.path, 'fragment.yaml')).toString(),
      );
      expect(fragment.text, 'type: string\n');
    },
  );
  test('same-size dirty disk conflict and clean reload', () async {
    final path = await Initializer.create(
      destination: temp.path,
      title: 'AAA',
      apiVersion: '1',
    );
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final b = await project.buffer(project.roots.single.id);
    final original = b.text;
    await File(path).writeAsString(original.replaceFirst('AAA', 'BBB'));
    await project.refreshDisk(b);
    expect(b.text, contains('BBB'));
    project.store.replace(b.id, b.text.replaceFirst('BBB', 'CCC'));
    await File(path).writeAsString(original.replaceFirst('AAA', 'DDD'));
    await expectLater(project.save(b), throwsA(isA<CoreFailure>()));
    expect(b.text, contains('CCC'));
    expect(await File(path).readAsString(), contains('DDD'));
  });
  test('approved boundary rejects traversal and symlinks', () async {
    final access = await ProjectAccess.open(temp.path);
    addTearDown(access.close);
    await Link(p.join(temp.path, 'escape.yaml')).create('/etc/passwd');
    await expectLater(
      access.read(p.join(temp.path, 'escape.yaml')),
      throwsA(isA<CoreFailure>()),
    );
    await expectLater(access.read('/etc/passwd'), throwsA(isA<CoreFailure>()));
  });
  test('unsaved shared fragment snapshots have one physical buffer', () async {
    await File(p.join(temp.path, 'shared.yaml')).writeAsString(
      'Thing: {type: object, properties: {name: {type: string}}}\n',
    );
    for (final name in ['a', 'b']) {
      await File(p.join(temp.path, '$name.yaml')).writeAsString(
        'openapi: 3.2.1\ninfo: {title: $name, version: "1"}\npaths: {}\ncomponents: {schemas: {Thing: {\$ref: "shared.yaml#/Thing"}}}\n',
      );
    }
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final fragment = await project.buffer(
      Uri.file(p.join(temp.path, 'shared.yaml')).toString(),
    );
    project.store.replace(
      fragment.id,
      fragment.text.replaceFirst('string', 'integer'),
    );
    for (final root in project.roots) {
      final check = await project.check(root.id);
      expect(check['status'], 'complete');
      expect(check['unsaved'], true);
      expect(
        (check['resources'] as List).singleWhere(
          (r) => r['id'] == fragment.id,
        )['generation'],
        fragment.generation,
      );
    }
    expect(project.store.buffers.length, 1);
  });
  test(
    'recovery against changed disk cannot publish over new content',
    () async {
      final path = await Initializer.create(
        destination: temp.path,
        title: 'A',
        apiVersion: '1',
      );
      final project = await BusyProject.open(temp.path, engine);
      addTearDown(project.close);
      final b = await project.buffer(project.roots.single.id);
      project.store.replace(b.id, b.text.replaceFirst('"A"', '"Draft"'));
      final store = RecoveryStore(p.join(temp.path, 'recovery'));
      await store.persist(b);
      final recordFile = Directory(store.directory)
          .listSync()
          .whereType<File>()
          .single;
      final record =
          jsonDecode(await recordFile.readAsString()) as Map<String, dynamic>;
      record['recordPath'] = recordFile.path;
      await File(path).writeAsString(b.baseline.replaceFirst('"A"', '"Disk"'));
      await project.reload(b);
      await store.adopt(record, b);
      expect(b.text, contains('Draft'));
      expect(b.externalConflict, true);
      await expectLater(project.save(b), throwsA(isA<CoreFailure>()));
      expect(await File(path).readAsString(), contains('Disk'));
    },
  );
  test(
    'helper missing and runtime injection do not return check success',
    () async {
      final missing = EngineProcess(
        executable: p.join(temp.path, 'missing'),
        helper: 'missing',
      );
      await expectLater(missing.start(), throwsA(isA<CoreFailure>()));
      await missing.close();
      await engine.start();
      expect((await engine.request('hello', {}))['offsetUnit'], 'utf16');
    },
  );
  test('outside dependencies require an explicit context and share stable buffers after approval', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-approval-');
    addTearDown(() => temp.delete(recursive: true));
    final projectDir = Directory('${temp.path}/project')..createSync();
    final outside = Directory('${temp.path}/outside')..createSync();
    final file = File('${projectDir.path}/api.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {}\ncomponents: {schemas: {Thing: {\$ref: "../outside/schema.yaml#/Thing"}}}',
      );
    final schema = File('${outside.path}/schema.yaml')
      ..writeAsStringSync('Thing: {type: string}');
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(projectDir.path, engine);
    addTearDown(project.close);
    final root = Uri.file(file.path).toString(),
        fragment = Uri.file(schema.path).toString();
    final denied = await project.check(root);
    expect(denied['status'], 'incomplete');
    await expectLater(project.buffer(fragment), throwsA(isA<CoreFailure>()));
    await project.approveContext(outside.path);
    final approved = await project.check(root);
    expect(approved['status'], 'complete');
    expect(approved['snapshot'], isNot(denied['snapshot']));
    final buffer = await project.buffer(fragment);
    expect(identical(await project.buffer(fragment), buffer), true);
    project.store.replace(fragment, 'Thing: {type: integer}');
    expect((await project.check(root))['unsaved'], true);
    expect(await schema.readAsString(), 'Thing: {type: string}');
  });
  test(
    'missing helper does not prevent opening existing unconfigured source',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-source-only-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/fragment.yaml')
        ..writeAsStringSync('authored: unchanged\n');
      final engine = EngineProcess(
        executable: '/missing/node',
        helper: '/missing/engine',
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      expect(project.discoveryFailure, isNotNull);
      final b = await project.buffer(Uri.file(file.path).toString());
      expect(b.text, 'authored: unchanged\n');
      expect(b.dirty, false);
      await expectLater(project.check(b.id), throwsA(isA<CoreFailure>()));
    },
  );
  test('late field input and IME state stay with the rebased occurrence after an accepted edit', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-late-fields-');
    addTearDown(() => temp.delete(recursive: true));
    final path = await Initializer.create(
      destination: temp.path,
      title: 'Original',
      apiVersion: '1',
    );
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    final id = Uri.file(path).toString(),
        b = await project.buffer(Uri.file(path).toString());
    final info = (await project.check(id))['info'] as Map;
    final range = List<int>.from(info['range'] as List);
    final fields = PropertySession(
      root: id,
      buffer: id,
      generation: b.generation,
      pointer: '/info',
      range: range,
      expected: b.text.substring(range[0], range[1]),
    );
    fields.bind('title', 'Original');
    fields.bind('version', '1');
    fields.edit('title', 'Accepted title');
    final captured = Map<String, Object?>.from(fields.values);
    final applying = project.proposeAndApply(
      id,
      fields,
      fields.actions(),
      acceptedValues: captured,
    );
    fields.edit('version', '2');
    final next = (await applying)!;
    expect(next.pending, true);
    expect(b.text, contains('Accepted title'));
    expect(next.values['version'], '2');
    expect(next.committed['version'], '1');
    expect(next.generation, b.generation);
    fields.edit('description', 'Input through the earlier field adapter');
    fields.composing = true;
    expect(
      next.values['description'],
      'Input through the earlier field adapter',
    );
    expect(next.composing, true);
    await expectLater(
      project.proposeAndApply(id, next, next.actions()),
      throwsA(isA<CoreFailure>()),
    );
    fields.composing = false;
    await project.proposeAndApply(
      id,
      next,
      next.actions(),
      acceptedValues: Map.of(next.values),
    );
    expect(b.text, contains('Input through the earlier field adapter'));
    expect((await project.check(id))['info']['value']['version'], '2');
  });
  test(
    'aggregate snapshot limits never become silent partial success',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-snapshot-bound-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final root = File('${temp.path}/api.yaml')
        ..writeAsStringSync(
          'openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {}\ncomponents: {schemas: {Thing: {\$ref: "large.yaml#/Thing"}}}',
        );
      final dependency = File('${temp.path}/large.yaml');
      await dependency.writeAsString(
        '#' +
            List.filled(9 * 1024 * 1024, 'x').join() +
            '\nThing: {type: string}',
      );
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(root.path, engine);
      addTearDown(project.close);
      await expectLater(
        project.check(Uri.file(root.path).toString()),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'limit.snapshot'),
        ),
      );
      expect(await dependency.length(), greaterThan(9 * 1024 * 1024));
    },
  );
}
