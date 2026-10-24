import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../lib/src/atomic_directory_writer.dart';

/// Build-only asset review, not a font loader or runtime service. Original
/// Fonts must stay byte-identical to the reviewed originals. Normal Linux
/// builds retain TREE_SHAKE_ICONS=false; licence permissions do not authorize
/// a stale subset or another change to the accepted rendering baseline.
Future<({Map<String, List<int>> files, Map<String, Object?> inventory})>
collectFontNotices(
  Directory repository,
  Map<String, Directory> packages,
  String assets,
) async {
  final review = jsonDecode(
    await File(p.join(repository.path, 'tools/flutter_fonts.review.json'))
        .readAsString(),
  ) as Map;
  final framework = packages['flutter'];
  final yaru = packages['yaru'];
  if (review['version'] != 1 || framework == null || yaru == null) {
    throw StateError(
      'Prepare the locked Flutter/Yaru font inputs before building',
    );
  }
  final sdk = framework.parent.parent;
  final version = jsonDecode(
    await File(p.join(sdk.path, 'bin/cache/flutter.version.json'))
        .readAsString(),
  ) as Map;
  final engine = jsonDecode(
    await File(p.join(repository.path, 'tools/flutter_engine/engine.lock.json'))
        .readAsString(),
  ) as Map;
  if (version['frameworkRevision'] != review['frameworkRevision'] ||
      engine['frameworkRevision'] != review['frameworkRevision']) {
    throw StateError(
      'The font asset review does not match the selected Flutter framework',
    );
  }
  final lock = loadYaml(
    await File(p.join(repository.path, 'pubspec.lock')).readAsString(),
  ) as YamlMap;
  final approvedPackage = review['package'] as Map;
  final locked = (lock['packages'] as YamlMap)['yaru'] as YamlMap;
  if (approvedPackage['name'] != 'yaru' ||
      locked['source'] != 'hosted' ||
      locked['version'] != approvedPackage['version'] ||
      locked['description']['sha256'] != approvedPackage['archiveSha256']) {
    throw StateError(
      'The font asset review does not match the selected Yaru package',
    );
  }
  Future<List<int>> ordinary(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Font inputs and output assets must be ordinary files');
    }
    final file = File(path);
    if (await file.length() > 16 * 1024 * 1024)
      throw StateError('Font asset exceeds its bounded inspection limit');
    return file.readAsBytes();
  }

  String digest(List<int> bytes) => sha256.convert(bytes).toString();
  if (digest(await ordinary(p.join(yaru.path, 'pubspec.yaml'))) !=
      approvedPackage['pubspecSha256']) {
    throw StateError('Unreviewed Yaru font declaration');
  }
  final fontManifest = jsonDecode(
    utf8.decode(await ordinary(p.join(assets, 'FontManifest.json'))),
  );
  if (fontManifest is! List || fontManifest.length > 32)
    throw StateError('Expected the current bounded Flutter font manifest');
  final emitted = <String, String>{};
  for (final raw in fontManifest) {
    final family = raw['family'] as String;
    for (final font in raw['fonts'] as List) {
      final asset = font['asset'] as String;
      if (!AtomicDirectoryWriter.safeName(asset) || emitted.containsKey(asset))
        throw StateError('Ambiguous installed font identity');
      emitted[asset] = family;
    }
  }
  final files = <String, List<int>>{}, records = <Map<String, Object?>>[];
  final attribution = StringBuffer(
    'BusyAPI application font assets\n\nThese assets retain their individual licences. The application licence does not restrict the recipients\' rights in these assets. No vendor endorsement or trademark permission is asserted.\n\n',
  );
  final groups = review['groups'] as List;
  final expected = <String>{};
  for (final raw in groups) {
    final group = Map<String, Object?>.from(raw as Map);
    final owner = group['package'] as String;
    if (owner != 'yaru' && owner != 'flutter-sdk')
      throw StateError('Unreviewed font owner');
    final root = owner == 'yaru' ? yaru : sdk;
    final name = group['name'] as String;
    final family = owner == 'yaru' ? 'packages/yaru/$name' : name;
    final license = group['license'];
    if (!{'Ubuntu-font-1.0', 'CC-BY-SA-4.0', 'CC-BY-4.0'}.contains(license) ||
        group['obligations'] is! String ||
        group['distribution'] is! String)
      throw StateError('Missing font redistribution review');
    if (owner == 'flutter-sdk' &&
        (await File(
              p.join(sdk.path, 'bin/internal/material_fonts.version'),
            ).readAsString()).trim() !=
            group['version'])
      throw StateError('Unreviewed Material Icons source identity');
    final notices = <Map<String, Object?>>[], fonts = <Map<String, Object?>>[];
    for (final raw in group['notices'] as List) {
      final notice = raw as Map, relative = notice['file'] as String;
      if (!AtomicDirectoryWriter.safeName(relative))
        throw StateError('Invalid font notice path');
      final bytes = await ordinary(p.join(root.path, relative));
      if (digest(bytes) != notice['sha256'])
        throw StateError('Unreviewed font notice: $name/$relative');
      final target = '$owner/$relative';
      files[target] = bytes;
      notices.add({'file': target, 'sha256': digest(bytes)});
    }
    for (final raw in group['fonts'] as List) {
      final font = raw as Map,
          relative = font['file'] as String,
          asset = font['asset'] as String;
      if (!AtomicDirectoryWriter.safeName(relative) ||
          !AtomicDirectoryWriter.safeName(asset) ||
          !expected.add(asset) ||
          emitted[asset] != family)
        throw StateError('Unreviewed or missing font family/asset');
      final source = await ordinary(p.join(root.path, relative)),
          output = await ordinary(p.join(assets, asset));
      if (output.length < 12) {
        throw StateError('The assembled font asset is empty or truncated');
      }
      if (digest(source) != font['sha256'])
        throw StateError('Unreviewed original font: $name/$relative');
      final modified = digest(source) != digest(output);
      if (group['allowBuildModification'] != false)
        throw StateError('Unreviewed font modification policy');
      if (modified)
        throw StateError(
          'The assembled font changed; normal Linux builds require original font bytes and disable icon subsetting',
        );
      fonts.add({
        'asset': asset,
        'sourceFile': relative,
        'sourceSha256': digest(source),
        'sha256': digest(output),
        'modified': modified,
        'modifications': 'Original font bytes unchanged.',
      });
    }
    attribution.writeln(
      '$name — $license\n${group['copyright']}\nSource: ${group['source']}\n${group['obligations']}',
    );
    for (final font in fonts)
      attribution.writeln('${font['asset']}: ${font['modifications']}');
    attribution.writeln(
      'Original notices: ${notices.map((notice) => notice['file']).join(', ')}\n',
    );
    records.add({...group, 'notices': notices, 'fonts': fonts});
  }
  if (expected.length != emitted.length ||
      emitted.keys.any((asset) => !expected.contains(asset)))
    throw StateError('An unreviewed font entered the application');
  final inventory = <String, Object?>{
    'version': 1,
    'scope': 'application-font-assets',
    'frameworkRevision': version['frameworkRevision'],
    'groups': records,
  };
  files['THIRD_PARTY_NOTICES.txt'] = utf8.encode(attribution.toString());
  files['dependencies.json'] = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
  );
  return (files: files, inventory: inventory);
}
