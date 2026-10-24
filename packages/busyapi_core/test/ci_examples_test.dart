import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'test_support.dart';

void main() {
  test('CI examples parse locally and preserve failing command status', () {
    final github = loadYaml(
      File('$repositoryRoot/examples/ci/github-actions.yml').readAsStringSync(),
    ) as YamlMap;
    final job = github['jobs']['contract'];
    final steps = job['steps'] as YamlList;
    final commands = steps
        .where((step) => step['run'] is String)
        .map((step) => step['run'] as String)
        .join('\n');
    expect(commands, contains('check contracts --root public --sarif'));
    expect(commands, contains('lint contracts --root public --sarif'));
    expect(commands, contains(r'--base "$API_BASELINE"'));
    expect(
      commands,
      contains('--case controlled-health --environment local --junit'),
    );
    expect(commands, isNot(contains('|| true')));
    expect(steps.last['if'], 'always()');
    expect(steps.last['uses'], startsWith('actions/upload-artifact@'));
    final gitlab = loadYaml(
      File('$repositoryRoot/examples/ci/gitlab-ci.yml').readAsStringSync(),
    ) as YamlMap;
    final script = (gitlab['api-contract']['script'] as YamlList).join('\n');
    expect(script, contains(r'--base "$CI_MERGE_REQUEST_DIFF_BASE_SHA"'));
    expect(script, isNot(contains('|| true')));
    expect(gitlab['api-contract']['artifacts']['when'], 'always');
    expect(
      gitlab['api-contract']['artifacts']['reports']['junit'],
      'contract-tests.xml',
    );
    expect(gitlab['api-contract']['allow_failure'], isNull);
  });
}
