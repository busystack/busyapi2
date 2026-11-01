import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../lib/src/atomic_directory_writer.dart';
import 'application_inputs.dart';
import 'application_notices.dart';
import 'dart_runtime_notices.dart';
import 'font_notices.dart';

/// Build-time only. Uses the selected package configuration and committed lock;
/// it never downloads packages, executes dependency scripts or inspects a home
/// directory by convention. Normal installation includes human-readable texts,
/// not just Flutter's compressed application-license asset.
Future<void> main(List<String> arguments) async {
  final core = File.fromUri(Platform.script).parent.parent.absolute;
  final repository = core.parent.parent;
  final inspect = arguments.contains('--inspect');
  final outputArgument = arguments
      .where((argument) => argument.startsWith('--output='))
      .singleOrNull;
  final fontAssetsArgument = arguments
      .where((argument) => argument.startsWith('--font-assets='))
      .singleOrNull;
  final applicationArgument = arguments
      .where((argument) => argument.startsWith('--application='))
      .singleOrNull;
  String? option(String prefix) => arguments
      .where((argument) => argument.startsWith(prefix))
      .singleOrNull
      ?.substring(prefix.length);
  final mode = option('--mode='), entry = option('--entry=');
  if (arguments.any(
    (argument) =>
        argument != '--inspect' &&
        !argument.startsWith('--output=') &&
        !argument.startsWith('--font-assets=') &&
        !argument.startsWith('--application=') &&
        !argument.startsWith('--mode=') &&
        !argument.startsWith('--entry='),
  ))
    throw ArgumentError(
      'Use --inspect, --output=PATH, --font-assets=PATH, or --application=PATH --mode=Debug|Profile|Release --entry=PATH',
    );
  if ((applicationArgument != null &&
          (mode == null || entry == null || fontAssetsArgument != null)) ||
      (applicationArgument == null && (mode != null || entry != null)))
    throw ArgumentError(
      'Application notices require the actual artifact, mode and entry; font and application inspection are separate',
    );
  final configurationUri = await Isolate.packageConfig;
  if (configurationUri == null)
    throw StateError('Run locked pub get before preparing Dart notices');
  final configuration =
      jsonDecode(await File.fromUri(configurationUri).readAsString()) as Map;
  final packages = <String, Directory>{
    for (final package in configuration['packages'] as List)
      package['name'] as String: Directory.fromUri(
        configurationUri.resolve(package['rootUri'] as String),
      ),
  };
  if (applicationArgument != null) {
    final build = await applicationInputs(
      repository: repository,
      packages: packages,
      artifact: applicationArgument.substring('--application='.length),
      mode: mode!,
      entry: entry!,
    );
    final inputs = await inspectApplicationNotices(
      repository: repository,
      packages: packages,
      build: build,
    );
    if (inspect) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(inputs.toJson()),
      );
      return;
    }
    final review = jsonDecode(
      await File(
        p.join(repository.path, 'tools/flutter_dependencies.review.json'),
      ).readAsString(),
    ) as Map<String, dynamic>;
    final result = await assembleApplicationNotices(
      repository: repository,
      packages: packages,
      inputs: inputs,
      review: review,
    );
    await publishNoticeFiles(
      result.files,
      repository,
      core,
      outputArgument,
      operation: 'application-notices',
      defaultDirectory: 'application-notices',
      identity: {
        'sha256': build.artifactIdentity,
        'mode': build.mode,
        'entry': build.entry,
      },
    );
    return;
  }
  if (fontAssetsArgument != null) {
    final result = await collectFontNotices(
      repository,
      packages,
      fontAssetsArgument.substring('--font-assets='.length),
    );
    if (inspect) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(result.inventory),
      );
    } else {
      await publishNoticeFiles(
        result.files,
        repository,
        core,
        outputArgument,
        operation: 'font-notices',
        defaultDirectory: 'font-notices',
        identity: {'frameworkRevision': result.inventory['frameworkRevision']},
      );
    }
    return;
  }
  final lock = loadYaml(
    await File(p.join(core.path, 'pubspec.lock')).readAsString(),
  ) as YamlMap;
  final root = loadYaml(
    await File(p.join(core.path, 'pubspec.yaml')).readAsString(),
  ) as YamlMap;
  final pending = (root['dependencies'] as YamlMap).keys
      .cast<String>()
      .toList();
  final records = <String, Map<String, Object?>>{},
      files = <String, List<int>>{};
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (records.containsKey(name)) continue;
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name))
      throw StateError('Invalid dependency name');
    final directory = packages[name],
        entry = (lock['packages'] as YamlMap)[name];
    if (directory == null || entry is! YamlMap || entry['source'] != 'hosted')
      throw StateError('Unresolved/non-hosted core dependency: $name');
    final specification = loadYaml(
      await File(p.join(directory.path, 'pubspec.yaml')).readAsString(),
    ) as YamlMap;
    if (specification['name'] != name ||
        specification['version'] != entry['version'])
      throw StateError('Dependency version differs from the lock: $name');
    final notices = <Map<String, Object?>>[];
    for (final filename in ['LICENSE', 'NOTICE', 'COPYRIGHT']) {
      final source = File(p.join(directory.path, filename));
      if (!await source.exists()) continue;
      final bytes = await source.readAsBytes();
      final relative = '$name/$filename';
      files[relative] = bytes;
      notices.add({
        'file': relative,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
    if (notices.isEmpty) throw StateError('No original license text for $name');
    final sourceFiles = <String, String>{};
    final library = Directory(p.join(directory.path, 'lib'));
    var sourceBytes = 0;
    if (await library.exists()) {
      await for (final entity in library.list(
        recursive: true,
        followLinks: false,
      )) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) continue;
        if (type != FileSystemEntityType.file) {
          throw StateError('Non-ordinary dependency source: $name');
        }
        final bytes = await File(entity.path).readAsBytes();
        sourceBytes += bytes.length;
        if (sourceFiles.length >= 4096 || sourceBytes > 16 * 1024 * 1024) {
          throw StateError(
            'Dependency source exceeds its inspection limit: $name',
          );
        }
        final relative = p.posix.joinAll(
          p.split(p.relative(entity.path, from: directory.path)),
        );
        sourceFiles[relative] = sha256.convert(bytes).toString();
      }
    }
    final sourceIdentity = StringBuffer();
    for (final relative in sourceFiles.keys.toList()..sort()) {
      sourceIdentity.write('$relative\u0000${sourceFiles[relative]}\n');
    }
    records[name] = {
      'name': name,
      'version': entry['version'],
      'source':
          '${entry['description']['url']}/packages/$name/versions/${entry['version']}',
      'archiveSha256': entry['description']['sha256'],
      'notices': notices,
      'sourceSha256': sha256
          .convert(utf8.encode(sourceIdentity.toString()))
          .toString(),
      'sourceFiles': sourceFiles.length,
    };
    final dependencies = specification['dependencies'];
    if (dependencies is Map) pending.addAll(dependencies.keys.cast<String>());
  }
  final sorted = records.keys.toList()..sort();
  if (inspect) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'packages': [for (final name in sorted) records[name]],
      }),
    );
    return;
  }
  final review = jsonDecode(
    await File(p.join(repository.path, 'tools/dart_dependencies.review.json'))
        .readAsString(),
  ) as Map;
  if (review['version'] != 1 || review['packages'] is! List)
    throw StateError('Invalid Dart dependency review inventory');
  final approved = <String, Map>{
    for (final entry in review['packages'] as List)
      entry['name'] as String: entry as Map,
  };
  if (approved.length != records.length ||
      approved.keys.any((name) => !records.containsKey(name)))
    throw StateError(
      'The production Dart closure changed; review exact licenses before building',
    );
  for (final name in sorted) {
    final actual = records[name]!, reviewed = approved[name]!;
    for (final key in [
      'name',
      'version',
      'source',
      'archiveSha256',
      'notices',
      'sourceSha256',
      'sourceFiles',
    ]) {
      if (jsonEncode(actual[key]) != jsonEncode(reviewed[key]))
        throw StateError(
          'Unreviewed Dart dependency identity/notice: $name ($key)',
        );
    }
    if (!{
          'BSD-3-Clause',
          'MIT',
          'ISC',
          'Apache-2.0',
        }.contains(reviewed['license']) ||
        reviewed['purpose'] is! String ||
        reviewed['distribution'] is! String)
      throw StateError('Missing/unknown redistribution review: $name');
    actual.addAll({
      'license': reviewed['license'],
      'purpose': reviewed['purpose'],
      'distribution': reviewed['distribution'],
      'obligations': reviewed['obligations'],
    });
  }
  for (final dataset in review['datasets'] as List? ?? const []) {
    final name = dataset['package'] as String,
        source = dataset['file'] as String;
    if (!records.containsKey(name) || !AtomicDirectoryWriter.safeName(source))
      throw StateError('Invalid reviewed dataset');
    final bytes = await File(p.join(packages[name]!.path, source))
        .readAsBytes();
    if (sha256.convert(bytes).toString() != dataset['sha256'])
      throw StateError('Unreviewed embedded dataset: $name/$source');
    final notice = dataset['notice'] as String;
    if (!AtomicDirectoryWriter.safeName(notice))
      throw StateError('Invalid dataset notice');
    final license = await File(p.join(repository.path, notice)).readAsBytes();
    if (sha256.convert(license).toString() != dataset['noticeSha256'])
      throw StateError('Unreviewed dataset notice');
    files['datasets/${p.basename(notice)}'] = license;
  }
  final sdk = Directory(p.dirname(p.dirname(Platform.resolvedExecutable)));
  final sdkLicense = await File(p.join(sdk.path, 'LICENSE')).readAsBytes();
  files['DART-LICENSE'] = sdkLicense;
  final runtimeNotices = await collectDartRuntimeNotices(repository, sdk);
  files.addAll(runtimeNotices.files);
  final inventory = {
    'version': 1,
    'scope': 'headless-core-production-closure',
    'sdk': Platform.version.split(' ').first,
    'sdkNoticeSha256': sha256.convert(sdkLicense).toString(),
    'runtime': runtimeNotices.inventory,
    'packages': [for (final name in sorted) records[name]],
    'datasets': review['datasets'] ?? [],
  };
  files['dependencies.json'] = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
  );
  await publishNoticeFiles(
    files,
    repository,
    core,
    outputArgument,
    operation: 'dart-notices',
    defaultDirectory: 'dart-notices',
    identity: {'sdk': inventory['sdk']},
  );
}

Future<void> publishNoticeFiles(
  Map<String, List<int>> files,
  Directory repository,
  Directory core,
  String? outputArgument, {
  required String operation,
  required String defaultDirectory,
  required Map<String, Object?> identity,
}) async {
  final target = p.normalize(
    p.absolute(
      outputArgument == null
          ? p.join(repository.path, 'build', defaultDirectory)
          : outputArgument.substring('--output='.length),
    ),
  );
  if (target == p.dirname(target) ||
      target == repository.path ||
      target == core.path)
    throw ArgumentError('Choose a dedicated generated notice directory');
  await Directory(p.dirname(target)).create(recursive: true);
  String? replacement;
  if (await FileSystemEntity.type(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    final previous = await AtomicDirectoryWriter.inspect(target);
    if (previous.metadata['operation'] != operation)
      throw StateError('The destination is not an owned Dart notice directory');
    if (jsonEncode(previous.files) ==
        jsonEncode({
          for (final name in files.keys.toList()..sort())
            name: sha256.convert(files[name]!).toString(),
        }))
      return;
    replacement = previous.identity;
  }
  await AtomicDirectoryWriter().publish(target, files, {
    'operation': operation,
    ...identity,
  }, replaceIdentity: replacement);
}
