import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../lib/src/atomic_directory_writer.dart';
import 'application_inputs.dart';

bool _sameReviewValue(Object? first, Object? second) {
  if (first is Map && second is Map)
    return first.length == second.length &&
        first.keys.every(
          (key) =>
              second.containsKey(key) &&
              _sameReviewValue(first[key], second[key]),
        );
  if (first is List && second is List)
    return first.length == second.length &&
        List.generate(
          first.length,
          (index) => index,
        ).every((index) => _sameReviewValue(first[index], second[index]));
  return first == second;
}

/// Exact installed-source inspection for the selected compiler/native inputs.
/// Licence decisions belong to the committed review, not header heuristics.
/// This never invokes a dependency, fetches resources or initializes Flutter.
class ApplicationNoticeInputs {
  ApplicationNoticeInputs(
    this.build,
    Map<String, Object?> sdk,
    List<Map<String, Object?>> records,
    Map<String, List<int>> notices,
    Map<String, Map<String, String>> sourceFiles,
  ) : sdk = _freeze(sdk) as Map<String, Object?>,
      records = List.unmodifiable(
        records.map((record) => _freeze(record) as Map<String, Object?>),
      ),
      notices = Map.unmodifiable({
        for (final notice in notices.entries)
          notice.key: List<int>.unmodifiable(notice.value),
      }),
      sourceFiles = Map.unmodifiable({
        for (final tree in sourceFiles.entries)
          tree.key: Map<String, String>.unmodifiable(tree.value),
      });
  static Object? _freeze(Object? value) {
    if (value is Map)
      return Map<String, Object?>.unmodifiable({
        for (final item in value.entries)
          item.key as String: _freeze(item.value),
      });
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }

  final ApplicationInputs build;
  final Map<String, Object?> sdk;
  final List<Map<String, Object?>> records;
  final Map<String, List<int>> notices;
  final Map<String, Map<String, String>> sourceFiles;
  Map<String, Object?> toJson() => {
    'version': 1,
    'scope': 'flutter-linux-compiler-inputs',
    'sdk': sdk,
    'packages': records,
  };
}

Future<ApplicationNoticeInputs> inspectApplicationNotices({
  required Directory repository,
  required Map<String, Directory> packages,
  required ApplicationInputs build,
}) async {
  final sdkRoot = packages['flutter']!.parent.parent;
  final records = <Map<String, Object?>>[],
      notices = <String, List<int>>{},
      trees = <String, Map<String, String>>{};
  var total = 0;
  Future<List<int>> read(String path, {int limit = 64 * 1024 * 1024}) async {
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file)
      throw StateError('Dependency inputs must be ordinary files');
    final size = await file.length();
    if (size > limit || (total += size) > 256 * 1024 * 1024)
      throw StateError(
        'The application source/notice inspection exceeds its bounded byte budget',
      );
    final bytes = await file
        .openRead(0, size)
        .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    if (await file.length() != size)
      throw StateError('A dependency input changed during inspection');
    return bytes;
  }

  String digest(List<int> bytes) => sha256.convert(bytes).toString();
  final sdk = jsonDecode(
    utf8.decode(
      await read(
        p.join(sdkRoot.path, 'bin/cache/flutter.version.json'),
        limit: 65536,
      ),
    ),
  ) as Map;
  final engine = jsonDecode(
    utf8.decode(
      await read(
        p.join(repository.path, 'tools/flutter_sdk.lock.json'),
        limit: 65536,
      ),
    ),
  ) as Map;
  if (sdk['frameworkRevision'] != engine['frameworkRevision'] ||
      sdk['engineRevision'] != engine['engineRevision'] ||
      sdk['frameworkVersion'] != engine['frameworkVersion'])
    throw StateError(
      'Application notices require the selected framework and upstream SDK source identity',
    );
  final lock = loadYaml(
    utf8.decode(
      await read(p.join(repository.path, 'pubspec.lock'), limit: 256 * 1024),
    ),
  ) as YamlMap;
  final selected = build.packages.keys.toList()..sort();
  for (final name in selected) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name))
      throw StateError('Invalid compiled dependency name');
    final directory = packages[name]!,
        entry = (lock['packages'] as YamlMap)[name];
    if (entry is! YamlMap || !{'sdk', 'hosted'}.contains(entry['source']))
      throw StateError('Unreviewed application dependency source: $name');
    final specificationBytes = await read(
      p.join(directory.path, 'pubspec.yaml'),
      limit: 65536,
    );
    final specification = loadYaml(utf8.decode(specificationBytes)) as YamlMap;
    if (specification['name'] != name ||
        entry['source'] == 'hosted' &&
            specification['version'] != entry['version'])
      throw StateError('Application dependency differs from its lock: $name');
    final originalNotices = <Map<String, Object?>>[];
    final filenames = <String>[];
    await for (final file in directory.list(followLinks: false)) {
      if (RegExp(
        r'^(license|licence|notice|copying|copyright)([._-]|$)',
        caseSensitive: false,
      ).hasMatch(p.basename(file.path)))
        filenames.add(p.basename(file.path));
    }
    filenames.sort();
    for (final filename in filenames) {
      final bytes = await read(
            p.join(directory.path, filename),
            limit: 4 * 1024 * 1024,
          ),
          target = '$name/$filename';
      notices[target] = bytes;
      originalNotices.add({'file': target, 'sha256': digest(bytes)});
    }
    if (originalNotices.isEmpty && entry['source'] == 'sdk') {
      // SDK packages such as flutter_localizations/flutter_test inherit the
      // enclosing Flutter distribution's original notice, not a guessed MIT.
      final bytes = await read(
            p.join(sdkRoot.path, 'LICENSE'),
            limit: 4 * 1024 * 1024,
          ),
          target = '$name/FLUTTER-LICENSE';
      notices[target] = bytes;
      originalNotices.add({
        'file': target,
        'sha256': digest(bytes),
        'inheritedFrom': 'Flutter SDK LICENSE',
      });
    }
    if (originalNotices.isEmpty)
      throw StateError(
        'Review the exact published licence declaration and original notices before distributing $name',
      );
    final sources = <String, String>{};
    for (final folder in [
      'lib',
      if (build.nativePlugins.contains(name)) 'linux',
    ]) {
      final tree = Directory(p.join(directory.path, folder));
      if (!await tree.exists()) continue;
      await for (final file in tree.list(recursive: true, followLinks: false)) {
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.directory) continue;
        if (type != FileSystemEntityType.file || sources.length >= 10000)
          throw StateError(
            'Non-ordinary or excessive dependency source: $name',
          );
        final relative = p.posix.joinAll(
          p.split(p.relative(file.path, from: directory.path)),
        );
        sources[relative] = digest(await read(file.path));
      }
    }
    for (final relative in build.packages[name]!) {
      if (!AtomicDirectoryWriter.safeName(relative))
        throw StateError('Invalid compiled dependency source path');
      if (!sources.containsKey(relative))
        sources[relative] = digest(
          await read(p.join(directory.path, relative)),
        );
    }
    final sourceIdentity = StringBuffer();
    for (final file in sources.keys.toList()..sort())
      sourceIdentity.write('$file\u0000${sources[file]}\n');
    trees[name] = Map.unmodifiable(sources);
    records.add({
      'name': name,
      'version': entry['source'] == 'sdk'
          ? sdk['frameworkVersion']
          : entry['version'],
      'source': entry['source'] == 'sdk'
          ? 'https://github.com/flutter/flutter/tree/${sdk['frameworkRevision']}/packages/$name'
          : '${entry['description']['url']}/packages/$name/versions/${entry['version']}',
      if (entry['source'] == 'hosted')
        'archiveSha256': entry['description']['sha256'],
      'pubspecSha256': digest(specificationBytes),
      'notices': originalNotices,
      'sourceSha256': digest(utf8.encode(sourceIdentity.toString())),
      'sourceFiles': sources.length,
      'compilerFiles': build.packages[name]!.length,
      'linuxNativePlugin': build.nativePlugins.contains(name),
    });
  }
  // Preserve the selected SDK's original engine/third-party aggregate as an
  // aggregate. It is not a claim that every listed platform component ships.
  final aggregate = await read(
    p.join(sdkRoot.path, 'bin/cache/pkg/sky_engine/LICENSE'),
    limit: 4 * 1024 * 1024,
  );
  notices['flutter-sdk/ENGINE-THIRD-PARTY-NOTICES'] = aggregate;
  final sdkRecord = <String, Object?>{
    'frameworkVersion': sdk['frameworkVersion'],
    'frameworkRevision': sdk['frameworkRevision'],
    'engineRevision': sdk['engineRevision'],
    'engineContentHash': sdk['engineContentHash'],
    'engineNoticeSha256': digest(aggregate),
    'engineNotice': 'flutter-sdk/ENGINE-THIRD-PARTY-NOTICES',
    'engineNoticeScope': 'Original selected SDK aggregate; actual upstream-engine/native-library licence choices require their separate distribution review.',
  };
  return ApplicationNoticeInputs(
    build,
    sdkRecord,
    List.unmodifiable(records),
    Map.unmodifiable(notices),
    Map.unmodifiable(trees),
  );
}

/// Publishable contents only after exact source/notice review. The caller uses
/// the existing notice publisher/atomic core boundary; this function writes no
/// files. Whole original package URLs/digests identify preferred upstream source
/// distributions; MPL-covered installed library/native sources are also copied
/// verbatim for offline inspection, without executing generation scripts.
Future<({Map<String, List<int>> files, Map<String, Object?> inventory})>
assembleApplicationNotices({
  required Directory repository,
  required Map<String, Directory> packages,
  required ApplicationNoticeInputs inputs,
  required Map<String, dynamic> review,
}) async {
  if (review['version'] != 1 ||
      review['sdk'] is! Map ||
      review['packages'] is! List ||
      !_sameReviewValue(review['sdk'], inputs.sdk))
    throw StateError('Unreviewed application SDK/notice identity');
  final approved = <String, Map>{};
  for (final raw in review['packages'] as List) {
    final record = raw as Map, name = record['name'] as String;
    if (approved.containsKey(name))
      throw StateError('Ambiguous application dependency review');
    approved[name] = record;
  }
  final files = <String, List<int>>{...inputs.notices},
      records = <Map<String, Object?>>[];
  final human = StringBuffer(
    'BusyAPI Flutter/Linux application inputs\n\nOriginal third-party notices and licences are retained below. Compiler inputs are a conservative source set; unused symbols may be removed by AOT. The linked Linux plugins are identified separately. Source archives/URLs identify the original distributions, not permission to execute their scripts. Application terms do not restrict recipients\' rights in the separately licensed components.\n\n',
  );
  final sourceAccess = StringBuffer(
    'MPL 2.0 source availability\n\nThe unmodified covered library/native sources below are made available under MPL 2.0. Their original notices remain attached. The complete original distributions (including preferred upstream code-generation inputs) can also be obtained without an account at the listed source archive URLs. No BusyAPI proprietary/user-contract source is included. See each package\'s original MPL text and https://www.mozilla.org/en-US/MPL/2.0/.\n\n',
  );
  const identities = [
    'name',
    'version',
    'source',
    'archiveSha256',
    'pubspecSha256',
    'notices',
    'sourceSha256',
    'sourceFiles',
    'linuxNativePlugin',
  ];
  const allowed = {
    'BSD-2-Clause',
    'BSD-3-Clause',
    'MIT',
    'Apache-2.0',
    'MPL-2.0',
    'MIT AND BSD-3-Clause AND bzip2-1.0.6',
    'MIT AND Apache-2.0 AND BSD-3-Clause',
    'BSD-3-Clause AND Apache-2.0',
  };
  var copied = 0, count = 0;
  for (final actual in inputs.records) {
    final name = actual['name'] as String, decision = approved[name];
    if (decision == null ||
        identities.any((key) => !_sameReviewValue(actual[key], decision[key])))
      throw StateError(
        'Unreviewed application dependency source/notices: $name',
      );
    final license = decision['license'];
    if (!allowed.contains(license) ||
        decision['purpose'] is! String ||
        decision['distribution'] is! String ||
        decision['obligations'] is! String)
      throw StateError('Missing application redistribution decision: $name');
    for (final notice in actual['notices'] as List) {
      if (sha256.convert(files[notice['file']]!).toString() != notice['sha256'])
        throw StateError('The captured original notice changed');
    }
    final output = <String, Object?>{
      ...actual,
      for (final key in ['license', 'purpose', 'distribution', 'obligations'])
        key: decision[key],
    };
    if (license == 'MPL-2.0') {
      final directory = packages[name]!, version = actual['version'] as String;
      final archive = 'https://pub.dev/api/archives/$name-$version.tar.gz';
      final sources = <Map<String, Object?>>[];
      final captured = {...inputs.sourceFiles[name]!};
      captured['pubspec.yaml'] = actual['pubspecSha256'] as String;
      for (final relative in captured.keys.toList()..sort()) {
        if (!AtomicDirectoryWriter.safeName(relative))
          throw StateError('Invalid source availability path');
        final original = File(p.join(directory.path, relative));
        if (await FileSystemEntity.type(original.path, followLinks: false) !=
            FileSystemEntityType.file)
          throw StateError('The reviewed source availability input changed');
        final length = await original.length();
        if (length > 16 * 1024 * 1024 ||
            (copied += length) > 64 * 1024 * 1024 ||
            ++count > 20000)
          throw StateError(
            'The source-availability copy exceeds its bounded budget',
          );
        final bytes = await original
            .openRead(0, length)
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        if (await original.length() != length ||
            sha256.convert(bytes).toString() != captured[relative])
          throw StateError(
            'The reviewed source changed before notice/source assembly',
          );
        final target = 'sources/$name-$version/$relative';
        files[target] = bytes;
        sources.add({'file': target, 'sha256': captured[relative]});
      }
      for (final raw in actual['notices'] as List) {
        final notice = raw as Map,
            filename = (notice['file'] as String).substring(name.length + 1);
        final target = 'sources/$name-$version/$filename';
        files[target] = files[notice['file']]!;
        sources.add({'file': target, 'sha256': notice['sha256']});
      }
      sourceAccess.writeln(
        '$name $version\nComplete original distribution: $archive\nArchive SHA-256: ${actual['archiveSha256']}\nIncluded unmodified library/native source: sources/$name-$version/\nOriginal MPL notice: $name/LICENSE\n',
      );
      output['sourceAvailability'] = {
        'license': 'MPL-2.0',
        'originalArchive': archive,
        'archiveSha256': actual['archiveSha256'],
        'includedScope': 'Reviewed installed library/native sources and original declaration/notices; complete original preferred-source distribution is available at the upstream archive URL.',
        'files': sources,
      };
    }
    human.writeln(
      '$name ${actual['version']} — $license\n${decision['purpose']}\nSource: ${actual['source']}\n${decision['distribution']}\n${decision['obligations']}\nOriginal notices: ${(actual['notices'] as List).map((notice) => notice['file']).join(', ')}\n',
    );
    records.add(output);
  }
  final supplements = <Map<String, Object?>>[];
  for (final raw in review['supplements'] as List? ?? const []) {
    final item = Map<String, Object?>.from(raw as Map),
        owners = (item['packages'] as List).cast<String>();
    if (!owners.any((name) => inputs.sourceFiles.containsKey(name))) continue;
    final relative = item['notice'] as String,
        name = item['name'] as String,
        owner = item['noticePackage'] as String?;
    if (!AtomicDirectoryWriter.safeName(relative) ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(name) ||
        !{
          'Apache-2.0',
          'Unicode-3.0',
          'BSD-3-Clause source-code incorporation grant',
        }.contains(item['license']) ||
        [
          'purpose',
          'obligations',
          'source',
        ].any((key) => item[key] is! String || (item[key] as String).isEmpty) ||
        owner != null && !packages.containsKey(owner))
      throw StateError('Invalid supplementary application notice');
    final source = File(
      p.join(owner == null ? repository.path : packages[owner]!.path, relative),
    );
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await source.length() > 1024 * 1024)
      throw StateError('Missing/non-ordinary supplementary application notice');
    final bytes = await source.readAsBytes();
    if (sha256.convert(bytes).toString() != item['noticeSha256'])
      throw StateError('Unreviewed supplementary application notice: $name');
    final target = 'supplements/$name';
    if (files.containsKey(target))
      throw StateError('Duplicate supplementary application notice');
    files[target] = bytes;
    supplements.add({...item, 'installedNotice': target});
    human.writeln(
      '$name — ${item['license']}\n${item['purpose']}\nSource: ${item['source']}\n${item['obligations']}\nOriginal/supplementary notice: $target\n',
    );
  }
  final datasets = <Map<String, Object?>>[];
  for (final raw in review['datasets'] as List? ?? const []) {
    final item = Map<String, Object?>.from(raw as Map),
        name = item['package'] as String,
        relative = item['file'] as String;
    if (!inputs.sourceFiles.containsKey(name)) continue;
    if (inputs.sourceFiles[name]![relative] != item['sha256'] ||
        !supplements.any((notice) => notice['name'] == item['supplement']))
      throw StateError(
        'Unreviewed application dataset/source notice: $name/$relative',
      );
    datasets.add(item);
    human.writeln(
      '$name/$relative — ${item['license']}\n${item['purpose']}\nSource: ${item['source']}\n${item['modifications']}\nNotice: supplements/${item['supplement']}\n',
    );
  }
  // The original application/adaptation notices are separate from dependency
  // grants, and never replaced by a package's licence or authored API licence.
  for (final filename in ['LICENSE', 'NOTICE']) {
    final source = File(p.join(repository.path, filename));
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await source.length() > 1024 * 1024)
      throw StateError('Missing/changed BusyAPI application/adaptation notice');
    files['BusyAPI-$filename'] = await source.readAsBytes();
  }
  files['SOURCE-AVAILABILITY.txt'] = utf8.encode(sourceAccess.toString());
  files['THIRD_PARTY_NOTICES.txt'] = utf8.encode(human.toString());
  final inventory = <String, Object?>{
    'version': 1,
    'scope': 'flutter-linux-application-inputs',
    'sdk': inputs.sdk,
    'application': {
      'sha256': inputs.build.artifactIdentity,
      'mode': inputs.build.mode,
      'entry': inputs.build.entry,
      'productionEntry': inputs.build.productionEntry,
    },
    'packages': records,
    'supplements': supplements,
    'datasets': datasets,
    'distributionScope': 'Application Dart inputs and linked Flutter Linux plugins. Original engine notice aggregate retained; copied/system native libraries and the upstream engine need their separate distribution/source review.',
  };
  files['dependencies.json'] = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
  );
  return (files: files, inventory: inventory);
}
