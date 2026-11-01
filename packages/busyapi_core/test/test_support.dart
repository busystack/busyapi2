import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String get repositoryRoot =>
    p.basename(Directory.current.path) == 'busyapi_core'
    ? p.normalize(p.join(Directory.current.path, '../..'))
    : Directory.current.path;
String get testBundle =>
    Platform.environment['BUSYAPI_TEST_BUNDLE'] ??
    p.join(repositoryRoot, 'build/test-runtime');
String get runtimeNode => p.join(testBundle, 'libexec/busyapi/node');
String get runtimeHelper => p.join(testBundle, 'libexec/busyapi/engine.cjs');
Future<({int code, String output, String error})> runCliWithSecrets(
  List<String> arguments,
  Map<String, String> secrets,
) async {
  final process = await Process.start(
    '$testBundle/busyapi',
    [...arguments, '--secrets-stdin'],
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  var exited = false;
  final completion = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  try {
    process.stdin.write(jsonEncode(secrets));
    await process.stdin.close();
    final code = await completion.timeout(const Duration(seconds: 30));
    return (code: code, output: await output, error: await error);
  } finally {
    if (!exited) {
      process.kill();
      await completion.timeout(const Duration(seconds: 5));
    }
  }
}

String coreTestPath(String name) =>
    p.join(repositoryRoot, 'packages/busyapi_core/test', name);

/// Test setup only: never put a fresh executable's writable descriptor in the
/// shared test VM. Another isolate's fork can inherit it until exec/close,
/// causing ETXTBSY even after File.copy has completed in the parent.
/// A separate, awaited coreutils copier cannot expose its descriptor to those
/// forks. This is not a product writer, launch retry or SDK modification.
Future<File> copyExecutableFixture(String source, String destination) async {
  final input = File(source), output = File(destination);
  if (await FileSystemEntity.type(source, followLinks: false) !=
          FileSystemEntityType.file ||
      (await input.stat()).mode & 0x49 == 0 ||
      await FileSystemEntity.type(destination, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Expected an ordinary executable and a new fixture destination',
      destination,
    );
  }
  final before = await sha256.bind(input.openRead()).first;
  final copied = await Process.run(
    '/usr/bin/cp',
    ['--update=none', '--preserve=mode', '--', source, destination],
    environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
    includeParentEnvironment: false,
  );
  if (copied.exitCode != 0 ||
      await FileSystemEntity.type(destination, followLinks: false) !=
          FileSystemEntityType.file ||
      (await output.stat()).mode & 0x1ff != (await input.stat()).mode & 0x1ff ||
      await sha256.bind(output.openRead()).first != before ||
      await sha256.bind(input.openRead()).first != before) {
    throw FileSystemException(
      'Executable fixture copy failed its byte/mode identity check',
      destination,
    );
  }
  return output;
}
