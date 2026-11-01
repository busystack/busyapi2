import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-cli-generate-');
  });
  tearDown(() => temp.delete(recursive: true));
  Future<ProcessResult> cli(List<String> arguments) => Process.run(
    '$testBundle/busyapi',
    arguments,
    environment: const {
      'PATH': '',
      'LANG': 'C.UTF-8',
      'JAVA_HOME': '/not/a/runtime',
      'JAVA_TOOL_OPTIONS': '-javaagent:/missing/agent.jar',
    },
    includeParentEnvironment: false,
  );

  test('packaged catalog/options work without global Java or Node and expose untested clients', () async {
    final result = await cli(['generate', '--list-generators', '--json']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final catalog = jsonDecode(result.stdout as String) as Map;
    expect(catalog['producerVersion'], '7.26.0');
    expect(
      (catalog['generators'] as List).map((item) => item['name']),
      containsAll(['go', 'rust', 'lua', 'dart', 'typescript-fetch', 'python']),
    );
    final options = await cli([
      'generate',
      '--generator',
      'go',
      '--generator-options',
      '--json',
    ]);
    expect(options.exitCode, 0, reason: '${options.stdout}\n${options.stderr}');
    final entries = jsonDecode(options.stdout as String)['options'] as List;
    expect(
      entries.firstWhere(
        (option) => option['name'] == 'packageName',
      )['documentation'],
      isNotEmpty,
    );
    expect(entries.any((option) => option['name'] == 'Description'), false);
  });

  test('packaged generate publishes saved input and requires an unchanged receipt for regeneration', () async {
    final source = await Directory('${temp.path}/source').create();
    final file = File('${source.path}/api.json');
    const content =
        '{"openapi":"3.1.2","info":{"title":"Client","version":"1.0.0"},"paths":{"/things":{"get":{"operationId":"listThings","responses":{"200":{"description":"ok"}}}}}}';
    await file.writeAsString(content);
    final target = '${temp.path}/client';
    final arguments = [
      'generate',
      file.path,
      '--generator',
      'typescript-fetch',
      '--option',
      'npmName=controlled-client',
      '--output',
      target,
      '--json',
    ];
    final first = await cli(arguments);
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    final json = jsonDecode(first.stdout as String) as Map;
    expect(json['version'], 1);
    expect(json['complete'], true);
    expect(json['input'], 'saved-source');
    expect(json['generator'], 'typescript-fetch');
    expect(json['output']['directory'], target);
    final receipt = File('$target/busyapi-output.json');
    final original = await receipt.readAsBytes();
    final denied = await cli(arguments);
    expect(denied.exitCode, 3, reason: '${denied.stdout}\n${denied.stderr}');
    expect(await receipt.readAsBytes(), original);
    final repeated = await cli([
      ...arguments,
      '--replace-output',
      json['output']['receiptIdentity'] as String,
    ]);
    expect(
      repeated.exitCode,
      0,
      reason: '${repeated.stdout}\n${repeated.stderr}',
    );
    final previous =
        jsonDecode(repeated.stdout as String)['output']['previous'] as String;
    expect(await File('$previous/busyapi-output.json').readAsBytes(), original);
    expect(await file.readAsString(), content);
    expect(await File('${source.path}/busyapi.yaml').exists(), false);
  });

  test('unsupported generation is incomplete, keeps source intact and publishes nothing', () async {
    final source = await Directory('${temp.path}/source').create();
    final file = File('${source.path}/api.json');
    const text =
        '{"openapi":"3.2.1","info":{"title":"Still authored as 3.2","version":"1"},"paths":{}}';
    await file.writeAsString(text);
    final target = '${temp.path}/rejected';
    final result = await cli([
      'generate',
      file.path,
      '--generator',
      'typescript-fetch',
      '--output',
      target,
      '--json',
    ]);
    expect(result.exitCode, 2, reason: '${result.stdout}\n${result.stderr}');
    final json = jsonDecode(result.stdout as String) as Map;
    expect(json['status'], 'incomplete');
    expect(json['complete'], false);
    expect(json['tool']['version'], '7.26.0');
    expect(json['error']['detail'], isNotEmpty);
    expect(await Directory(target).exists(), false);
    expect(await file.readAsString(), text);
  });
}
