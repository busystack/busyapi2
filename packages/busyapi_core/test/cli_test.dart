import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('CLI secret input failures are bounded and never echo supplied values', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-cli-secret-');
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Secrets, version: "1"}\npaths: {}\n',
      );
    final original = root.readAsBytesSync();
    const canary = 'synthetic-stdin-secret-canary';
    final inputs = <(List<int>, String)>[
      (utf8.encode('{"reference":"$canary",}'), 'secret.input'),
      (utf8.encode('["$canary"]'), 'secret.input'),
      ([...utf8.encode('{"reference":"$canary'), 0xff], 'secret.input'),
      (
        utf8.encode('{"reference":"$canary${'x' * (1024 * 1024)}"}'),
        'secret.input.limit',
      ),
    ];
    for (final machine in [false, true]) {
      for (final (input, code) in inputs) {
        final process = await Process.start(
          '$testBundle/busyapi',
          [
            'test',
            root.path,
            '--case',
            'selected',
            '--secrets-stdin',
            if (machine) '--json',
          ],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        try {
          try {
            process.stdin.add(input);
            await process.stdin.close();
          } on FileSystemException {
            // A bounded reader may close an oversized pipe before its producer.
          }
          expect(
            await process.exitCode.timeout(const Duration(seconds: 15)),
            3,
          );
          final stdout = await output, stderr = await errors;
          expect('$stdout$stderr', isNot(contains(canary)));
          if (machine) {
            final result = jsonDecode(stdout) as Map;
            expect(result['version'], 1);
            expect(result['complete'], false);
            expect(result['error']['code'], code);
            expect(stderr, isEmpty);
          } else {
            expect(stdout, isEmpty);
            expect(stderr, contains(code));
          }
          expect(root.readAsBytesSync(), original);
          expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
        } finally {
          process.kill();
          await process.exitCode;
        }
      }
    }
  });
  test('CLI explicit URI mappings resolve from original base without a display or writes', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-cli-map-');
    addTearDown(() => temp.delete(recursive: true));
    final root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: T, version: "1"}\npaths: {}\ncomponents: {schemas: {X: {\$ref: "https://contracts.example/schemas/item"}}}\n',
      );
    final item = File('${temp.path}/cache.yaml')
      ..writeAsStringSync('\$ref: child\n');
    final child = File('${temp.path}/child.json')..writeAsStringSync('false');
    final before = {
      for (final file in [root, item, child]) file.path: file.readAsBytesSync(),
    };
    final result = await Process.run(
      '$testBundle/busyapi',
      [
        'check',
        root.path,
        '--map-resource',
        'https://contracts.example/schemas/item',
        item.path,
        '--map-resource',
        'https://contracts.example/schemas/child',
        child.path,
        '--json',
      ],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final output = jsonDecode(result.stdout as String);
    expect(output['status'], 'complete');
    expect(output['complete'], true);
    expect(output['findings'], isEmpty);
    expect(result.stderr, isEmpty);
    for (final entry in before.entries)
      expect(File(entry.key).readAsBytesSync(), entry.value);
    expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
  });
  test('CLI initializer reports actual partial publication and retains concurrent bytes', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-cli-partial-');
    addTearDown(() => temp.delete(recursive: true));
    // Controlled failure injection is a separately compiled development entry,
    // never an installed application asset. A relocated production bundle must
    // still exercise its own CLI below, without shipping this fault helper.
    final result = await Process.run(
      '$repositoryRoot/build/test-runtime/cli-fault-child',
      ['init', '${temp.path}/api', '--title', 'test', '--api-version', '1.0.0'],
    );
    expect(result.exitCode, 3);
    expect(result.stderr, contains('init.partial'));
    expect(result.stderr, contains('${temp.path}/api/openapi.yaml'));
    final contract = File('${temp.path}/api/openapi.yaml');
    expect(contract.readAsStringSync(), contains('paths: {}'));
    final before = contract.readAsBytesSync();
    expect(
      File('${temp.path}/api/busyapi.yaml').readAsStringSync(),
      'concurrent manifest\n',
    );
    final retry = await Process.run('$testBundle/busyapi', [
      'init',
      '${temp.path}/api',
      '--title',
      'retry',
      '--api-version',
      '2',
    ]);
    expect(retry.exitCode, 3);
    expect(retry.stderr, contains('init.collision'));
    expect(contract.readAsBytesSync(), before);
  });
  test(
    'compiled CLI and workspace checks normalize identically for saved source',
    () async {
      final cli = File('$testBundle/busyapi');
      expect(
        cli.existsSync(),
        true,
        reason: 'Compile the independent CLI into the injected test bundle',
      );
      final temp = await Directory.systemTemp.createTemp('busyapi-parity-');
      addTearDown(() => temp.delete(recursive: true));
      final path = await Initializer.create(
        destination: temp.path,
        title: 'Parity',
        apiVersion: '1',
        openapi: '3.2.1',
      );
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(path, engine);
      addTearDown(project.close);
      final buffer = await project.buffer(project.roots.single.id);
      project.store.replace(
        buffer.id,
        buffer.text.replaceFirst('Parity', 'Authored'),
      );
      await project.save(buffer);
      final live = await project.check(project.roots.single.id);
      final core = await project.check(project.roots.single.id, saved: true);
      expect(live['snapshot'], core['snapshot']);
      expect(live['findings'], core['findings']);
      expect(live['contextSnapshot'], isNot(core['contextSnapshot']));
      final env = Map<String, String>.from(Platform.environment)
        ..remove('DISPLAY')
        ..remove('WAYLAND_DISPLAY');
      final checked = await Process.run(
        cli.path,
        ['check', path, '--json'],
        environment: env,
        includeParentEnvironment: false,
      );
      expect(checked.exitCode, 0);
      final json = jsonDecode(checked.stdout as String) as Map<String, dynamic>;
      expect(json['findings'], core['findings']);
      expect(json['versions'], core['versions']);
      expect(json['snapshots'], [core['snapshot']]);
      expect(json['status'], core['status']);
      expect(json['complete'], core['complete']);
      final help = await Process.run(
        cli.path,
        ['--help'],
        environment: env,
        includeParentEnvironment: false,
      );
      expect(help.exitCode, 0);
      expect(help.stdout, contains('Exit codes:'));
      final version = await Process.run(
        cli.path,
        ['--version'],
        environment: env,
        includeParentEnvironment: false,
      );
      expect(version.exitCode, 0);
      expect(version.stdout, 'BusyAPI 0.1.0\n');
      await File(path).writeAsString('openapi: [broken\n');
      final invalid = await Process.run(
        cli.path,
        ['check', path, '--json'],
        environment: env,
        includeParentEnvironment: false,
      );
      expect(invalid.exitCode, 1);
      expect(
        (jsonDecode(invalid.stdout as String) as Map)['status'],
        'invalid',
      );
    },
  );
}
