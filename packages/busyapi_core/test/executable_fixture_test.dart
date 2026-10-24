import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('separate executable fixture copier preserves bytes, mode and immediate execution in a Unicode path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-exec-fixture-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('/usr/bin/true');
    final digest = await sha256.bind(source.openRead()).first;
    final target = await copyExecutableFixture(
      source.path,
      '${directory.path}/fixture 雪',
    );
    expect(await sha256.bind(target.openRead()).first, digest);
    expect(
      (await target.stat()).mode & 0x1ff,
      (await source.stat()).mode & 0x1ff,
    );
    expect(await FileSystemEntity.identical(source.path, target.path), false);
    for (var index = 0; index < 20; index++) {
      final result = await Process.run(
        target.path,
        const [],
        environment: const {'PATH': ''},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0);
    }
    await expectLater(
      copyExecutableFixture(source.path, target.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await sha256.bind(target.openRead()).first, digest);
  });

  test('compiled CLI fixture construction and immediate startup withstand concurrent process creation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-exec-traffic-',
    );
    addTearDown(() => directory.delete(recursive: true));
    for (var iteration = 0; iteration < 5; iteration++) {
      final copying = copyExecutableFixture(
        '$testBundle/busyapi',
        '${directory.path}/cli $iteration 雪',
      );
      final traffic = Future.wait(
        List.generate(
          12,
          (_) => Process.run(
            '/usr/bin/true',
            const [],
            environment: const {'PATH': ''},
            includeParentEnvironment: false,
          ),
        ),
      );
      final executable = await copying;
      final result = await Process.run(
        executable.path,
        const ['--version'],
        environment: const {'PATH': ''},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, 'BusyAPI 0.1.0\n');
      for (final child in await traffic) {
        expect(child.exitCode, 0);
      }
    }
  });

  test('executable fixture setup refuses linked and non-executable sources without publishing a destination', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-exec-invalid-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final linked = Link('${directory.path}/linked');
    await linked.create('/usr/bin/true');
    final text = File('${directory.path}/text');
    await text.writeAsString('Not an executable');
    for (final source in [linked.path, text.path]) {
      final destination = '${directory.path}/must-not-exist';
      await expectLater(
        copyExecutableFixture(source, destination),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await FileSystemEntity.type(destination, followLinks: false),
        FileSystemEntityType.notFound,
      );
    }
  });
}
