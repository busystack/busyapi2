import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Build-only review of the actual SDK runtime embedded in standalone AOT
/// executables. No source checkout, resolver, downloader or package script is
/// needed. The Flutter engine and copied native libraries have separate scope.
class DartRuntimeNotices {
  DartRuntimeNotices(this.inventory, this.files);
  final Map<String, Object?> inventory;
  final Map<String, List<int>> files;
}

Future<DartRuntimeNotices> collectDartRuntimeNotices(
  Directory repository,
  Directory sdk,
) async {
  Future<List<int>> ordinary(String path, {int limit = 1024 * 1024}) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError(
        'Non-ordinary Dart runtime review input: ${p.basename(path)}',
      );
    }
    final file = File(path);
    if (await file.length() > limit) {
      throw StateError('Oversized Dart runtime review input');
    }
    final data = await file.readAsBytes();
    if (data.isEmpty || data.length > limit) {
      throw StateError('Invalid Dart runtime review input');
    }
    return data;
  }

  final reviewBytes = await ordinary(
    p.join(repository.path, 'tools/dart_runtime.review.json'),
  );
  final value = jsonDecode(utf8.decode(reviewBytes));
  if (value is! Map<String, dynamic> ||
      value['version'] != 1 ||
      value['components'] is! List ||
      (value['components'] as List).isEmpty ||
      (value['components'] as List).length > 32 ||
      value['scope'] is! String ||
      value['source'] is! String ||
      value['network'] is! String) {
    throw StateError('Invalid Dart runtime licence review');
  }
  final revision = utf8
      .decode(await ordinary(p.join(sdk.path, 'revision')))
      .trim();
  final rootLicense = await ordinary(p.join(sdk.path, 'LICENSE'));
  final runtime = await ordinary(
    p.join(sdk.path, 'bin/dartaotruntime'),
    limit: 32 * 1024 * 1024,
  );
  if (value['sdk'] != Platform.version.split(' ').first ||
      value['sdkRevision'] != revision ||
      value['sdkLicenseSha256'] != sha256.convert(rootLicense).toString() ||
      value['aotRuntimeSha256'] != sha256.convert(runtime).toString()) {
    throw StateError(
      'The actual Dart SDK/runtime changed; review its embedded components and original notices before redistribution',
    );
  }

  final files = <String, List<int>>{}, names = <String>{};
  final index = StringBuffer(
    'BusyAPI distribution notice index: Dart AOT runtime\n\n'
    'SDK ${value['sdk']} / $revision\n'
    '${value['scope']}\n'
    'The compiler, DevTools, browser tooling and upstream test suites are not distributed by this directory. '
    'The entries include conservative configured-header/runtime-builtins coverage, not an assertion that every upstream feature is linked. '
    'Original wording is retained in the named files. Source comment excerpts are labelled as such in dependencies.json; they are not fabricated upstream LICENSE files.\n'
    '${value['network']}\n\n',
  );
  for (final component in value['components'] as List) {
    if (component is! Map ||
        ![
          'name',
          'version',
          'source',
          'license',
          'purpose',
          'distribution',
          'obligations',
        ].every(
          (key) =>
              component[key] is String && (component[key] as String).isNotEmpty,
        ) ||
        !names.add(component['name'] as String) ||
        component['notices'] is! List ||
        (component['notices'] as List).isEmpty) {
      throw StateError('Incomplete Dart runtime component review');
    }
    index.writeln('${component['name']} — ${component['version']}');
    for (final key in [
      'license',
      'purpose',
      'distribution',
      'source',
      'obligations',
    ]) {
      index.writeln('$key: ${component[key]}');
    }
    for (final record in component['notices'] as List) {
      if (record is! Map ||
          record['file'] is! String ||
          !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(record['file'] as String) ||
          ['.', '..'].contains(record['file']) ||
          record['source'] is! String ||
          record['form'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch('${record['sha256']}') ||
          record['sourceFileSha256'] != null &&
              !RegExp(r'^[0-9a-f]{64}$')
                  .hasMatch('${record['sourceFileSha256']}') ||
          files.length >= 128) {
        throw StateError('Invalid Dart runtime notice identity');
      }
      final name = record['file'] as String;
      final data = await ordinary(
        p.join(repository.path, 'tools/licenses/dart-runtime', name),
      );
      if (sha256.convert(data).toString() != record['sha256']) {
        throw StateError('Changed/unreviewed Dart runtime notice: $name');
      }
      final previous = files['runtime/$name'];
      if (previous != null &&
          sha256.convert(previous).toString() != record['sha256']) {
        throw StateError('Conflicting Dart runtime notice: $name');
      }
      files['runtime/$name'] = data;
      index.writeln('notice: $name (${record['form']})');
    }
    index.writeln();
  }
  index.writeln(
    'DART-LICENSE is the original SDK root BSD licence, installed beside the headless package inventory. '
    'DART-PATENT_GRANT is an independent original grant with its own conditions. '
    'This index does not replace the controlling original texts, grant trademark/endorsement rights, '
    'or clear the modified Flutter engine, copied native libraries or a confined distribution.\n',
  );
  final inventory = <String, Object?>{
    ...value,
    'reviewSha256': sha256.convert(reviewBytes).toString(),
  };
  files['runtime/NOTICE.txt'] = utf8.encode(index.toString());
  files['runtime/dependencies.json'] = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
  );
  return DartRuntimeNotices(inventory, files);
}
