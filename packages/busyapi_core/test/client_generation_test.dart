import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'test_support.dart';

class _UnsafeOutput extends GeneratorRuntime {
  _UnsafeOutput(this.target, this.link);
  final String target;
  final bool link;
  @override
  Future<List<GeneratorOption>> options(
    String generator, {
    bool Function()? cancelled,
  }) async => const [];
  @override
  Future<GeneratorProcessResult> run(
    String stage,
    List<String> arguments, {
    bool Function()? cancelled,
    Duration timeout = const Duration(minutes: 2),
    void Function(int pid)? onStarted,
  }) async {
    final output = await Directory('$stage/output').create();
    if (link) {
      await Link('${output.path}/escaping').create(target);
    } else {
      await File('${output.path}/busyapi-output.json')
          .writeAsString('foreign ownership marker');
    }
    final packet = jsonEncode([
      {
        'operations': {
          'operation': [
            {'httpMethod': 'GET', 'path': '/things'},
          ],
        },
      },
    ]);
    return GeneratorProcessResult(
      0,
      'BUSYAPI_OPERATION_JSON_START\n$packet\nBUSYAPI_OPERATION_JSON_END\n',
      '',
    );
  }
}

class _ExecutableOutput extends _UnsafeOutput {
  _ExecutableOutput() : super('', false);
  @override
  Future<GeneratorProcessResult> run(
    String stage,
    List<String> arguments, {
    bool Function()? cancelled,
    Duration timeout = const Duration(minutes: 2),
    void Function(int pid)? onStarted,
  }) async {
    final output = await Directory('$stage/output').create();
    final script = File('${output.path}/script.sh');
    await script.writeAsString('#!/bin/sh\nprintf fixture\n');
    privatePermissions(script.path, 493);
    final packet = jsonEncode([
      {
        'operations': {
          'operation': [
            {'httpMethod': 'GET', 'path': '/things'},
          ],
        },
      },
    ]);
    return GeneratorProcessResult(
      0,
      'BUSYAPI_OPERATION_JSON_START\n$packet\nBUSYAPI_OPERATION_JSON_END\n',
      '',
    );
  }

  @override
  Future<Map<String, dynamic>> verify() async => {
    'files': {'generator-launcher': 'controlled fixture'},
  };
}

void main() {
  final runtime = GeneratorRuntime(
    directory: '$repositoryRoot/build/generator',
  );
  late Directory temp;
  late EngineProcess engine;
  BusyProject? project;
  final outputs = <ClientOutput>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-generation-test-');
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    for (final output in outputs) {
      output.close();
    }
    outputs.clear();
    project?.close();
    project = null;
    await engine.close();
    await temp.delete(recursive: true);
  });
  Future<File> fixture({String version = '3.1.2', bool boolean = false}) async {
    final directory = await Directory('${temp.path}/source').create();
    final root = File('${directory.path}/api.json');
    await root.writeAsString(
      jsonEncode({
        'openapi': version,
        'info': {'title': 'Fixture', 'version': '1.0.0'},
        'paths': {
          '/things': {
            'get': {
              'operationId': 'listThings',
              'responses': {
                '200': {
                  'description': 'ok',
                  'content': {
                    'application/json': {
                      'schema': {
                        'type': 'array',
                        'items': {r'$ref': './model.json'},
                      },
                    },
                  },
                },
              },
            },
          },
        },
        if (boolean)
          'components': {
            'schemas': {'BooleanSchema': true},
          },
      }),
    );
    await File('${directory.path}/model.json').writeAsString(
      '{"type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string"}}}',
    );
    project = await BusyProject.open(root.path, engine);
    return root;
  }

  test(
    'official catalog and documented options are not a test-language whitelist',
    () async {
      final clients = await runtime.clients();
      expect(clients.length, greaterThan(50));
      expect(
        clients.map((g) => g.name),
        containsAll([
          'dart',
          'typescript-fetch',
          'go',
          'rust',
          'lua',
          'csharp',
        ]),
      );
      expect(clients.map((g) => g.name), isNot(contains('spring')));
      final options = await runtime.options('typescript-fetch');
      expect(options.map((o) => o.name), contains('npmName'));
      expect(options.map((o) => o.name), isNot(contains('Description')));
      expect(
        options.firstWhere((o) => o.name == 'npmName').documentation,
        contains('npm package'),
      );
      await expectLater(runtime.options('spring'), throwsA(isA<CoreFailure>()));
    },
  );

  for (final generator in ['typescript-fetch', 'dart', 'python']) {
    test('$generator uses the actual snapshot and produces operation/model source', () async {
      final source = await fixture(),
          original = await File('${temp.path}/source/model.json').readAsBytes();
      final model = await project!.buffer(
        Uri.file('${temp.path}/source/model.json').toString(),
      );
      project!.store.replace(
        model.id,
        model.text.replaceFirst('"name"', '"draftName"'),
      );
      final output = await project!.prepareClient(
        source.uri.toString(),
        '${temp.path}/$generator',
        generator: generator,
        runtime: runtime,
      );
      outputs.add(output);
      expect(output.unsaved, true);
      expect(output.outdated, false);
      expect(output.metadata['operations'], ['GET /things']);
      final text = output.files
          .where(
            (name) => name.endsWith(
              generator == 'dart'
                  ? '.dart'
                  : generator == 'python'
                  ? '.py'
                  : '.ts',
            ),
          )
          .map((name) => utf8.decode(output.bytes(name)))
          .join('\n');
      expect(
        text.toLowerCase(),
        contains(generator == 'python' ? 'list_things' : 'listthings'),
      );
      expect(
        text.toLowerCase(),
        contains(generator == 'python' ? 'draft_name' : 'draftname'),
      );
      expect(await File(model.path).readAsBytes(), original);
      await output.publish();
      expect(await output.existing(), isNotNull);
      expect(output.files, contains('busyapi-generation.json'));
      // Only trusted fixture output is compiled in tests, never during the
      // application workflow. No generated code is executed or installed.
      if (generator == 'typescript-fetch') {
        final compiled = await Process.run(
          '/usr/bin/timeout',
          [
            '--signal=KILL',
            '15',
            runtimeNode,
            '$repositoryRoot/tools/contract_engine/node_modules/typescript/bin/tsc',
            '--strict',
            '--noEmit',
            '--target',
            'ES2020',
            '--module',
            'ES2020',
            '--moduleResolution',
            'node',
            '--lib',
            'ES2020,DOM',
            ...output.files
                .where((name) => name.endsWith('.ts'))
                .map((name) => '${output.destination}/$name'),
          ],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(
          compiled.exitCode,
          0,
          reason: '${compiled.stdout}\n${compiled.stderr}',
        );
      } else if (generator == 'python') {
        final compiled = await Process.run('/usr/bin/python3', [
          '-c',
          'import pathlib,sys; files=list(pathlib.Path(sys.argv[1]).rglob("*.py")); assert files; [compile(p.read_text(),str(p),"exec") for p in files]',
          output.destination,
        ]);
        expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      } else {
        final package =
            loadYaml(utf8.decode(output.bytes('pubspec.yaml')))['name']
                as String;
        final harness = await Directory('${temp.path}/compile-harness/bin')
            .create(recursive: true);
        await File('${harness.parent.path}/pubspec.yaml').writeAsString(
          'name: trusted_client_compile\nenvironment: {sdk: ">=3.13.0 <4.0.0"}\ndependencies:\n  ${jsonEncode(package)}: {path: ${jsonEncode(output.destination)}}\n',
        );
        await File('${harness.path}/main.dart').writeAsString(
          'import "package:$package/api.dart"; void main() { print(ApiClient); }\n',
        );
        for (final args in [
          ['pub', 'get', '--offline'],
          ['compile', 'kernel', 'bin/main.dart', '-o', 'compiled.dill'],
        ]) {
          final compiled = await Process.run(
            '/usr/bin/timeout',
            ['--signal=KILL', '15', Platform.resolvedExecutable, ...args],
            workingDirectory: harness.parent.path,
            environment: {
              'PATH': '',
              'LANG': 'C.UTF-8',
              'PUB_CACHE':
                  Platform.environment['PUB_CACHE'] ??
                  '${Platform.environment['HOME']}/.pub-cache',
            },
            includeParentEnvironment: false,
          );
          expect(
            compiled.exitCode,
            0,
            reason: '${compiled.stdout}\n${compiled.stderr}',
          );
        }
      }
      project!.store.replace(model.id, model.text + '\n');
      expect(output.outdated, true);
    });
  }

  test('repeatability, reviewed replacement, hand edits and destination races preserve bytes', () async {
    final source = await fixture();
    final first = await project!.prepareClient(
      source.uri.toString(),
      '${temp.path}/output',
      generator: 'typescript-fetch',
      runtime: runtime,
    );
    outputs.add(first);
    await first.publish();
    final receipt = (await first.existing())!;
    final next = await project!.prepareClient(
      source.uri.toString(),
      first.destination,
      generator: 'typescript-fetch',
      runtime: runtime,
    );
    outputs.add(next);
    expect(next.identity, first.identity);
    expect(
      (await next.changes(receipt))
          .every((change) => change.kind == 'unchanged'),
      true,
    );
    final name = next.files.firstWhere((name) => name.endsWith('.ts'));
    expect(await next.previousBytes(name, receipt.identity), next.bytes(name));
    final published = await next.publish(replaceIdentity: receipt.identity);
    expect(published.previous, isNotNull);
    final edited = File('${next.destination}/$name');
    await edited.writeAsString('hand edited');
    await expectLater(next.existing(), throwsA(anything));
    await expectLater(
      next.publish(replaceIdentity: receipt.identity),
      throwsA(anything),
    );
    expect(await edited.readAsString(), 'hand edited');
    final race = await project!.prepareClient(
      source.uri.toString(),
      '${temp.path}/raced',
      generator: 'typescript-fetch',
      runtime: runtime,
    );
    outputs.add(race);
    await expectLater(
      race.publish(
        beforePublish: () async {
          await Directory(race.destination).create();
          await File('${race.destination}/foreign')
              .writeAsString('competing bytes');
        },
      ),
      throwsA(anything),
    );
    expect(
      await File('${race.destination}/foreign').readAsString(),
      'competing bytes',
    );
  });

  for (final scenario in ['version', 'boolean']) {
    test(
      'upstream $scenario rejection is reported without publishing partial output',
      () async {
        final source = await fixture(
          version: scenario == 'version' ? '3.2.1' : '3.1.2',
          boolean: scenario == 'boolean',
        );
        final original = await source.readAsBytes();
        await expectLater(
          project!.prepareClient(
            source.uri.toString(),
            '${temp.path}/rejected',
            generator: 'typescript-fetch',
            runtime: runtime,
          ),
          throwsA(
            isA<OutputAnalysisFailure>().having(
              (e) => e.cause,
              'cause',
              isA<GeneratorFailure>().having(
                (e) => e.detail,
                'detail',
                isNotEmpty,
              ),
            ),
          ),
        );
        expect(await Directory('${temp.path}/rejected').exists(), false);
        expect(await source.readAsBytes(), original);
      },
    );
  }

  test(
    'missing assets, option injection and explicit cancellation fail closed',
    () async {
      await expectLater(
        GeneratorRuntime(directory: temp.path).clients(),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'generate.assets'),
        ),
      );
      final source = await fixture();
      await expectLater(
        project!.prepareClient(
          source.uri.toString(),
          '${temp.path}/invalid',
          generator: 'typescript-fetch',
          runtime: runtime,
          options: {'skipValidateSpec': true},
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'generate.options'),
        ),
      );
      await expectLater(
        runtime.run(temp.path, ['list'], cancelled: () => true),
        throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      expect(await Directory('${temp.path}/invalid').exists(), false);
    },
  );

  test('actual owned process cancellation and expired deadline do not leave children', () async {
    var cancelled = false;
    int? pid;
    await expectLater(
      runtime.run(
        temp.path,
        ['list'],
        cancelled: () => cancelled,
        onStarted: (value) {
          pid = value;
          cancelled = true;
        },
      ),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(pid, isNotNull);
    expect(await Directory('/proc/$pid').exists(), false);
    await expectLater(
      runtime.run(
        temp.path,
        ['version'],
        timeout: Duration.zero,
        onStarted: (_) => fail('expired execution must not start'),
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'generate.timeout'),
      ),
    );
  });

  test('official coverage packet extraction retains warnings but not debug payloads', () {
    final packet = jsonEncode([
      {
        'operations': {
          'operation': [
            {'httpMethod': 'GET', 'path': '/snow/雪'},
          ],
        },
        'example': 'synthetic private payload',
      },
    ]);
    final value = generatorOperationCoverage(
      'WARN upstream limitation\nBUSYAPI_OPERATION_JSON_START\n$packet\nBUSYAPI_OPERATION_JSON_END\nBUSYAPI_OPERATION_JSON_START\n[]\nBUSYAPI_OPERATION_JSON_END\n',
    );
    expect(value.operations, {'GET /snow/雪'});
    expect(value.log, contains('upstream limitation'));
    expect(value.log, isNot(contains('private payload')));
    expect(
      () => generatorOperationCoverage('no packet'),
      throwsA(isA<GeneratorFailure>()),
    );
  });

  test(
    'authored callback coverage is explicit and never silently dropped',
    () async {
      final source = await fixture();
      final buffer = await project!.buffer(source.uri.toString());
      final document = jsonDecode(buffer.text) as Map;
      document['paths']['/things']['get']['callbacks'] = {
        'event': {
          r'{$request.query.callbackUrl}': {
            'post': {
              'responses': {
                '200': {'description': 'received'},
              },
            },
          },
        },
      };
      project!.store.replace(buffer.id, jsonEncode(document));
      await expectLater(
        project!.prepareClient(
          source.uri.toString(),
          '${temp.path}/callbacks',
          generator: 'typescript-fetch',
          runtime: runtime,
        ),
        throwsA(
          isA<OutputAnalysisFailure>().having(
            (error) => error.code,
            'code',
            'generate.coverage',
          ),
        ),
      );
      expect(await Directory('${temp.path}/callbacks').exists(), false);
    },
  );

  test('captured executable modes use the real ownership receipt and detect hand changes', () async {
    final source = await fixture();
    final output = await project!.prepareClient(
      source.uri.toString(),
      '${temp.path}/executable',
      generator: 'controlled-child-fixture',
      runtime: _ExecutableOutput(),
    );
    outputs.add(output);
    expect(
      (await output.changes(null))
          .firstWhere((change) => change.path == 'script.sh')
          .executable,
      true,
    );
    await output.publish();
    expect(
      (await File('${output.destination}/script.sh').stat()).mode & 0x49,
      isNot(0),
    );
    final receipt = (await output.existing())!;
    expect(receipt.metadata['executables'], ['script.sh']);
    privatePermissions('${output.destination}/script.sh', 420);
    await expectLater(output.existing(), throwsA(anything));
    expect(
      await File('${output.destination}/script.sh').readAsString(),
      '#!/bin/sh\nprintf fixture\n',
    );
  });

  for (final link in [false, true]) {
    test(
      'untrusted child output ${link ? 'links' : 'receipt collisions'} cannot enter publication',
      () async {
        final source = await fixture(),
            original = await File('${temp.path}/source/api.json').readAsBytes();
        final destination = await Directory('${temp.path}/preserved').create();
        await File('${destination.path}/foreign')
            .writeAsString('previous bytes');
        await expectLater(
          project!.prepareClient(
            source.uri.toString(),
            destination.path,
            generator: 'fault-injected-official-child',
            runtime: _UnsafeOutput(source.path, link),
          ),
          throwsA(
            isA<OutputAnalysisFailure>().having(
              (error) => error.code,
              'code',
              'generate.path',
            ),
          ),
        );
        expect(await source.readAsBytes(), original);
        expect(
          await File('${destination.path}/foreign').readAsString(),
          'previous bytes',
        );
      },
    );
  }
}
