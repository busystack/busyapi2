import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test('explicit clone resolves a relative local source before entering its private stage', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-relative-clone-',
    );
    try {
      final source = await Directory('${temp.path}/source 雪::local').create();
      await File('${source.path}/api.yaml').writeAsString('openapi: 3.2.1\n');
      for (final args in [
        ['init'],
        ['add', '.'],
        [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'commit',
          '-m',
          'fixture',
        ],
      ]) {
        final result = await Process.run(
          '/usr/bin/git',
          args,
          workingDirectory: source.path,
          environment: const {
            'PATH': '/usr/bin:/bin',
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': '/dev/null',
          },
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      final parent = await Directory('${temp.path}/private').create();
      final stage = '${parent.path}/checkout';
      final identity = await GitRepository.cloneIntoStage(
        './source 雪::local',
        stage,
        sourceDirectory: temp.path,
      );
      expect(identity.commit, isNotNull);
      expect(identity.version, startsWith('git version '));
      expect(await File('$stage/api.yaml').readAsString(), 'openapi: 3.2.1\n');
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
