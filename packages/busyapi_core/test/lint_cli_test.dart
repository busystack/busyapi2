import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('packaged headless lint uses configured URI mappings offline with original-source parity', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-cli-policy-map-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(
        '\ufeff{"openapi":"3.2.1","info":{"title":"Policy 雪😀","version":"1"},"paths":{},"x-data":9007199254740993.00}',
      );
    File('${temp.path}/rules.yaml')
        .writeAsStringSync('extends: ["./%62ase rules.yaml"]\n');
    File('${temp.path}/base.yaml').writeAsStringSync(
      'rules:\n  description:\n    given: \$.info\n    then: {field: description, function: truthy}\n',
    );
    File('${temp.path}/busyapi.yaml').writeAsStringSync(
      'version: 1\nroots: [{name: Main, path: root.json}]\n'
      'policy: {rulesets: ["https://rules.example/policy.yaml"]}\n'
      'resourceMappings: {"https://rules.example/policy.yaml": rules.yaml, "https://rules.example/base%20rules.yaml": base.yaml}\n',
    );
    final before = file.readAsBytesSync(),
        engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final core = await project.lint(file.uri.toString(), saved: true);
    expect(core['complete'], true);
    final result = await Process.run(
      '/usr/bin/python3',
      [
        '$repositoryRoot/tools/offline_exec.py',
        '$testBundle/busyapi',
        'lint',
        file.path,
        '--json',
      ],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final output = jsonDecode(result.stdout as String);
    expect(output['complete'], true);
    expect(output['findings'], core['findings']);
    expect(output['snapshots'], [core['snapshot']]);
    expect(output['configurations'], [core['configuration']]);
    expect(output['checkedRoots'], [
      {'name': 'root.json', 'resource': file.uri.toString()},
    ]);
    expect(file.readAsBytesSync(), before);
  });
  test('headless lint shares saved-snapshot findings, thresholds and original sources with core governance', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-cli-lint-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        '# retain 雪😀\nopenapi: 3.2.1\ninfo: {title: Policy, version: "1"}\npaths: {/p: {get: {responses: {204: {description: No body}}}}}\nx-number: 9007199254740993.00\n',
      );
    final before = file.readAsBytesSync();
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final core = await project.lint(file.uri.toString(), saved: true);
    final result = await Process.run(
      '$testBundle/busyapi',
      ['lint', file.path, '--json'],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final output = jsonDecode(result.stdout as String);
    expect(output['complete'], true);
    expect(output['findings'], core['findings']);
    expect(output['snapshots'], [core['snapshot']]);
    expect(output['configurations'], [core['configuration']]);
    expect(output['sourceSnapshots'], [core['sourceSnapshot']]);
    expect(output['categories'][0]['results']['policy']['complete'], true);
    final relaxed = await Process.run(
      '$testBundle/busyapi',
      ['lint', file.path, '--fail-severity', 'error', '--json'],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(relaxed.exitCode, 0, reason: '${relaxed.stdout}\n${relaxed.stderr}');
    expect(jsonDecode(relaxed.stdout as String)['findings'], isNotEmpty);
    expect(file.readAsBytesSync(), before);
    expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
  });
  test('lint configured-root aggregation, denied code and invalid threshold retain non-success exit categories', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-cli-policy-');
    addTearDown(() => temp.delete(recursive: true));
    for (final name in ['a', 'b']) {
      File('${temp.path}/$name.json').writeAsStringSync(
        '{"openapi":"3.1.2","info":{"title":"Policy","version":"1"},"paths":{"/p":{"get":{"responses":{"204":{"description":"None"}}}}}}',
      );
    }
    File('${temp.path}/busyapi.yaml').writeAsStringSync(
      'version: 1\nroots: [{name: A, path: a.json}, {name: B, path: b.json}]\npolicy: {rulesets: [busyapi:recommended], failSeverity: warning}\n',
    );
    Future<ProcessResult> run(List<String> options) => Process.run(
      '$testBundle/busyapi',
      ['lint', temp.path, ...options, '--json'],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    final all = await run([]);
    expect(all.exitCode, 1);
    final data = jsonDecode(all.stdout as String);
    expect(data['checkedRoots'], hasLength(2));
    expect(data['categories'], hasLength(2));
    expect(
      (data['findings'] as List).map((f) => f['root']).toSet(),
      hasLength(2),
    );
    final selected = await run(['--root', 'B']);
    expect(selected.exitCode, 1);
    expect(jsonDecode(selected.stdout as String)['checkedRoots'], hasLength(1));
    final code = File('${temp.path}/custom.js')
      ..writeAsStringSync(
        'require("fs").writeFileSync(${jsonEncode('${temp.path}/must-not-exist')}, "unsafe");',
      );
    final denied = await run(['--ruleset', code.path]);
    expect(denied.exitCode, 2, reason: denied.stdout as String);
    expect(jsonDecode(denied.stdout as String)['complete'], false);
    expect(File('${temp.path}/must-not-exist').existsSync(), false);
    final invalid = await run(['--fail-severity', 'unknown']);
    expect(invalid.exitCode, 3);
    expect(
      jsonDecode(invalid.stdout as String)['error']['code'],
      'policy.threshold',
    );
  });
}
