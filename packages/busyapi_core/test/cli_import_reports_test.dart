import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-cli-import-reports-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<ProcessResult> cli(List<String> arguments) => Process.run(
    '$testBundle/busyapi',
    arguments,
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  test('packaged CLI advertises import and separate report options', () async {
    final result = await cli(['--help']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('busyapi import SOURCE --kind'));
    expect(result.stdout, contains('--sarif FILE'));
    expect(result.stdout, contains('--junit FILE'));
  });
  test('failed source acquisition retains unsuccessful SARIF and unchanged JSON stdout', () async {
    final report = '${temp.path}/check.sarif';
    final result = await cli([
      'check',
      '${temp.path}/missing.yaml',
      '--sarif',
      report,
      '--json',
    ]);
    expect(result.exitCode, 3);
    final json = jsonDecode(result.stdout as String) as Map;
    expect(json['version'], 1);
    expect(json['complete'], false);
    expect(json['status'], 'operational-failure');
    final sarif = jsonDecode(await File(report).readAsString()) as Map;
    expect(sarif['version'], '2.1.0');
    expect(sarif['runs'][0]['invocations'][0]['executionSuccessful'], false);
    expect(result.stderr, isEmpty);
  });
  test(
    'test setup failure emits an incomplete JUnit run error before any case',
    () async {
      final report = '${temp.path}/tests.xml';
      final result = await cli([
        'test',
        '${temp.path}/missing.yaml',
        '--case',
        'selected',
        '--junit',
        report,
        '--json',
      ]);
      expect(result.exitCode, 3);
      final xml = await File(report).readAsString();
      expect(xml, contains('tests="1"'));
      expect(xml, contains('errors="1"'));
      expect(xml, contains('<error type="incomplete"'));
      expect(xml, contains('name="complete" value="false"'));
      expect(RegExp('<testcase ').allMatches(xml).length, 1);
      expect(xml, contains('classname="busyapi.execution"'));
      expect(xml, isNot(contains('name="selected"')));
      final parsed = await Process.run('/usr/bin/python3', [
        '-c',
        'import sys,xml.etree.ElementTree as E; assert E.parse(sys.argv[1]).getroot().tag == "testsuites"',
        report,
      ]);
      expect(parsed.exitCode, 0, reason: '${parsed.stderr}');
      expect(jsonDecode(result.stdout as String)['version'], 1);
    },
  );
  test(
    'occupied report bytes are preserved even when a command fails',
    () async {
      final report = File('${temp.path}/owned.sarif');
      await report.writeAsString('previous owner bytes');
      final result = await cli([
        'check',
        '${temp.path}/missing.yaml',
        '--sarif',
        report.path,
        '--json',
      ]);
      expect(result.exitCode, 3);
      expect(await report.readAsString(), 'previous owner bytes');
    },
  );
  test('invalid import configuration never acquires or publishes', () async {
    final result = await cli([
      'import',
      '${temp.path}/source',
      '--kind',
      'unsupported',
      '--output',
      '${temp.path}/new',
      '--json',
    ]);
    expect(result.exitCode, 3);
    expect(jsonDecode(result.stdout as String)['error']['code'], 'cli.import');
    expect(await Directory('${temp.path}/new').exists(), false);
  });
  test(
    'saved local import uses packaged core assets without ambient Node or Git',
    () async {
      final source = await Directory('${temp.path}/source').create();
      final file = File('${source.path}/api.yaml');
      const text =
          'openapi: 3.2.1\ninfo: {title: 雪, version: "1"}\npaths: {}\n';
      await file.writeAsString(text);
      final result = await cli([
        'import',
        file.path,
        '--kind',
        'file',
        '--output',
        '${temp.path}/acquired',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final json = jsonDecode(result.stdout as String) as Map;
      expect(json['complete'], true);
      expect(json['opened'], false);
      expect(json['provenance']['snapshot'], isA<String>());
      expect(await File(json['root'] as String).readAsString(), text);
      expect(await file.readAsString(), text);
    },
  );
}
