import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _PolicyEngine extends EngineProcess {
  _PolicyEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  String? fault;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'govern') {
      entered?.complete();
      final gate = release;
      release = null;
      if (gate != null) await gate.future;
      if (fault == 'crash')
        throw CoreFailure('engine.exit', 'Synthetic policy failure');
      if (fault == 'malformed') return {'complete': true, 'findings': []};
    }
    return super.request(method, params, requestId: requestId);
  }
}

String _contract(String version, bool json) => json
    ? '{"openapi":"$version","info":{"title":"Policy","version":"1"},"paths":{"/p":{"get":{"responses":{"204":{"description":"No body"}}}}},"x-number":9007199254740993.00}'
    : '# retained 😀\r\nopenapi: "$version"\r\ninfo: {title: Policy, version: "1"}\npaths:\n  /p:\n    get:\n      responses:\n        "204": {description: No body}\nx-number: 9007199254740993.00';

void main() {
  test('configured rule URI uses the same saved and working mappings as the canonical snapshot', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-policy-map-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(_contract('3.2.1', true));
    final before = file.readAsBytesSync();
    for (final name in ['first', 'second']) {
      File('${temp.path}/$name.yaml').writeAsStringSync(
        'extends: ["./%62ase rules.yaml"]\nrules:\n  $name:\n    given: \$.info\n    then: {field: description, function: truthy}\n',
      );
    }
    File('${temp.path}/parent.yaml')
        .writeAsStringSync('# mapped parent 雪😀\nrules: {}\n');
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Main, path: root.json}]\n'
        'policy: {rulesets: ["https://contracts.example/policy"]}\n'
        'resourceMappings: {"https://contracts.example/policy": first.yaml, "https://contracts.example/base%20rules.yaml": parent.yaml}\n',
      );
    final engine = _PolicyEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final config = await project.buffer(manifest.uri.toString());
    for (final (working, expected) in [
      (false, 'first'),
      (true, 'second'),
      (false, 'first'),
      (true, 'second'),
    ]) {
      if (working && !config.dirty) {
        project.store.replace(
          config.id,
          config.text.replaceFirst('first.yaml', 'second.yaml'),
        );
      }
      final result = await project.lint(file.uri.toString(), saved: !working);
      expect(result['complete'], true);
      final policy = (result['findings'] as List)
          .where((f) => f['category'] == 'policy')
          .toList();
      expect(policy.map((f) => f['code']), ['policy.rule.$expected']);
      expect(policy.single['resource'], file.uri.toString());
      expect(policy.single['pointer'], '/info');
      if (config.dirty) expect(config.text, contains('second.yaml'));
    }
    expect(manifest.readAsStringSync(), contains('first.yaml'));
    expect(file.readAsBytesSync(), before);
  });
  for (final version in ['3.1.2', '3.2.1'])
    for (final json in [false, true]) {
      test(
        'shared source-located governance and thresholds preserve exact source $version $json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-governance-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}')
            ..writeAsStringSync('\ufeff${_contract(version, json)}');
          final before = file.readAsBytesSync(), engine = _PolicyEngine();
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final stages = <Map<String, dynamic>>[];
          final result = await project.lint(
            file.uri.toString(),
            onProgress: stages.add,
          );
          expect(result['complete'], true, reason: jsonEncode(result));
          expect(lintExitCode(result), 1);
          expect(
            (result['findings'] as List).where(
              (f) => f['category'] == 'policy',
            ),
            hasLength(1),
          );
          final finding = (result['findings'] as List).singleWhere(
            (f) => f['category'] == 'policy',
          );
          expect(finding['resource'], file.uri.toString());
          expect(finding['pointer'], '/paths/~1p/get');
          expect(finding['snapshot'], result['snapshot']);
          expect(result['categories']['policy']['complete'], true);
          expect(result['categories']['runtime']['status'], 'not-implemented');
          expect(
            stages.any(
              (r) => r['categories']['policy']['status'] == 'checking',
            ),
            true,
          );
          final relaxed = await project.lint(
            file.uri.toString(),
            failSeverity: 'error',
          );
          expect(lintExitCode(relaxed), 0);
          expect(relaxed['sourceSnapshot'], result['sourceSnapshot']);
          expect(relaxed['configuration'], isNot(result['configuration']));
          final saved = await project.lint(file.uri.toString(), saved: true);
          expect(saved['findings'], result['findings']);
          expect(saved['configuration'], result['configuration']);
          expect(saved['snapshot'], result['snapshot']);
          expect(file.readAsBytesSync(), before);
          expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
        },
      );
    }
  test('ordered project rules and local mapped rulesets use unsaved overlays and invalidate monitoring', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-policy-config-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(_contract('3.2.1', true));
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        '# config\nversion: 1\nroots: [{name: Main, path: root.json}]\npolicy:\n  rulesets: [./rules.yaml]\n  failSeverity: error\nx-future: kept\n',
      );
    final rules = File('${temp.path}/rules.yaml')
      ..writeAsStringSync(
        'extends: ["https://rules.example/base.yaml"]\nrules: {operation-summary: error}\n',
      );
    final parent = File('${temp.path}/mapped.yaml')
      ..writeAsStringSync('extends: [busyapi:recommended]\n');
    final engine = _PolicyEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(temp.path, engine);
    addTearDown(project.close);
    await project.approveResource(
      'https://rules.example/base.yaml',
      parent.uri.toString(),
    );
    final original = {
      for (final item in [file, manifest, rules, parent])
        item.path: item.readAsBytesSync(),
    };
    final result = await project.lint(file.uri.toString());
    expect(result['complete'], true, reason: jsonEncode(result));
    expect(lintExitCode(result), 1);
    final buffer = await project.buffer(rules.uri.toString());
    final offset = buffer.text.indexOf('error');
    project.store.apply([
      TextEdit(
        buffer: buffer.id,
        generation: buffer.generation,
        start: offset,
        end: offset + 5,
        expected: 'error',
        replacement: 'off',
      ),
    ], label: 'Policy edit');
    final unsaved = await project.lint(file.uri.toString());
    expect(unsaved['complete'], true, reason: jsonEncode(unsaved));
    expect(lintExitCode(unsaved), 0);
    expect(unsaved['unsaved'], true);
    expect(unsaved['configuration'], isNot(result['configuration']));
    final saved = await project.lint(file.uri.toString(), saved: true);
    expect(saved['snapshot'], result['snapshot']);
    parent.writeAsStringSync(
      'extends: [busyapi:recommended]\nrules: {operation-summary: off}\n',
    );
    final changed = await project.refreshResources();
    expect(changed.resources, contains(parent.uri.toString()));
    expect(changed.roots, contains(file.uri.toString()));
    for (final entry in original.entries.where(
      (entry) => entry.key != parent.path,
    ))
      expect(File(entry.key).readAsBytesSync(), entry.value);
  });
  test('inherited declarative overrides use captured source ownership through the shared core', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-policy-overrides-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(_contract('3.2.1', true));
    final directory = Directory('${temp.path}/policy')..createSync();
    final parent = File('${directory.path}/base.yaml')
      ..writeAsStringSync(
        'extends: busyapi:recommended\nrules: {operation-summary: off}\noverrides:\n  - files: ["../root.json#/paths/~1p/get"]\n    rules: {operation-summary: error}\n',
      );
    final rules = File('${temp.path}/.spectral.yaml')
      ..writeAsStringSync('extends: ./policy/base.yaml\n');
    final engine = _PolicyEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final original = [
      file.readAsBytesSync(),
      parent.readAsBytesSync(),
      rules.readAsBytesSync(),
    ];
    final result = await project.lint(file.uri.toString());
    expect(result['complete'], true, reason: jsonEncode(result));
    final findings = (result['findings'] as List)
        .where((finding) => finding['category'] == 'policy')
        .toList();
    expect(findings, hasLength(1));
    expect(findings.single['severity'], 'error');
    expect(findings.single['resource'], file.uri.toString());
    expect(
      findings.single['ruleProvenance'],
      contains(
        isA<Map>().having(
          (entry) => entry['resource'],
          'source',
          parent.uri.toString(),
        ),
      ),
    );
    expect([
      file.readAsBytesSync(),
      parent.readAsBytesSync(),
      rules.readAsBytesSync(),
    ], original);
  });
  test('unapproved remote rules and default executable rules cannot be green or run code', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-policy-denied-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(_contract('3.1.2', true));
    final code = File('${temp.path}/.spectral.js')
      ..writeAsStringSync(
        'require("fs").writeFileSync(${jsonEncode('${temp.path}/must-not-exist')}, "unsafe"); throw Error("must not run");',
      );
    final engine = _PolicyEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final denied = await project.lint(file.uri.toString());
    expect(lintExitCode(denied), 2);
    expect(denied['categories']['policy']['complete'], false);
    expect(
      (denied['findings'] as List).any(
        (f) => f['code'] == 'policy.code.approval-required',
      ),
      true,
    );
    expect(File('${temp.path}/must-not-exist').existsSync(), false);
    final remote = await project.lint(
      file.uri.toString(),
      rulesets: ['https://denied.example/rules.yaml'],
    );
    expect(lintExitCode(remote), 2);
    expect(code.readAsStringSync(), contains('must not run'));
  });
  for (final fault in ['crash', 'malformed'])
    test(
      'failed $fault governance retains useful validity and explicitly incomplete policy',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-policy-failure-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/root.json')
          ..writeAsStringSync(_contract('3.2.1', true));
        final before = file.readAsBytesSync();
        final engine = _PolicyEngine()..fault = fault;
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final result = await project.lint(file.uri.toString());
        expect(lintExitCode(result), 2);
        expect(result['categories']['openapi']['complete'], true);
        expect(result['categories']['policy']['complete'], false);
        expect(
          (result['findings'] as List).any(
            (f) => f['code'] == 'policy.execution.incomplete',
          ),
          true,
        );
        expect(file.readAsBytesSync(), before);
      },
    );
  for (final target in ['source', 'rules'])
    test(
      'a later $target change rejects the entire captured governance result',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-policy-stale-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/root.json')
          ..writeAsStringSync(_contract('3.2.1', true));
        final rules = File('${temp.path}/.spectral.yaml')
          ..writeAsStringSync('extends: [busyapi:recommended]\n');
        final engine = _PolicyEngine()
          ..entered = Completer<void>()
          ..release = Completer<void>();
        final release = engine.release!;
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final pending = project.lint(file.uri.toString());
        final expectation = expectLater(
          pending,
          throwsA(
            isA<CoreFailure>().having((e) => e.code, 'code', 'policy.stale'),
          ),
        );
        await engine.entered!.future;
        final changed = target == 'source' ? file : rules;
        changed.writeAsStringSync('${changed.readAsStringSync()}\n');
        release.complete();
        await expectation;
        expect(changed.readAsStringSync(), endsWith('\n'));
      },
    );
}
