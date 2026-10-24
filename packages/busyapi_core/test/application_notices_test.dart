import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/application_inputs.dart';
import '../tool/application_notices.dart';
import '../tool/prepare_notices.dart' as publication;

class _Sources {
  _Sources(this.directory) {
    repository = Directory('${directory.path}/repository')..createSync();
    sdk = Directory('${directory.path}/sdk')..createSync();
    packages = {
      'flutter': Directory('${sdk.path}/packages/flutter'),
      'sample': Directory('${directory.path}/sample'),
      'native': Directory('${directory.path}/native'),
    };
    void write(String path, String text) {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    final version = {
      'frameworkVersion': '3.47.5',
      'frameworkRevision': 'framework',
      'engineRevision': 'engine',
      'engineContentHash': 'content',
    };
    write('${sdk.path}/bin/cache/flutter.version.json', jsonEncode(version));
    write(
      '${sdk.path}/bin/cache/pkg/sky_engine/LICENSE',
      'original aggregate\r\n',
    );
    write(
      '${repository.path}/tools/flutter_engine/engine.lock.json',
      jsonEncode({...version, 'flutterVersion': '3.47.5'}),
    );
    write('${repository.path}/LICENSE', 'original application licence\n');
    write('${repository.path}/NOTICE', 'original adapted-source attribution\n');
    write(
      '${repository.path}/pubspec.lock',
      'packages:\n  sample: {source: hosted, version: "1.0.0", description: {url: "https://pub.dev", sha256: "${'b' * 64}"}}\n  native: {source: hosted, version: "2.0.0", description: {url: "https://pub.dev", sha256: "${'c' * 64}"}}\n',
    );
    for (final name in ['sample', 'native']) {
      final version = name == 'sample' ? '1.0.0' : '2.0.0';
      write(
        '${packages[name]!.path}/pubspec.yaml',
        'name: $name\nversion: $version\n',
      );
      // Deliberately synthetic permission data: these fixtures exercise exact
      // inspection/publication, not adoption of a real package or legal advice.
      write(
        '${packages[name]!.path}/LICENSE',
        'original fixture notice for $name\r\n',
      );
      write(
        '${packages[name]!.path}/lib/$name.dart',
        '\ufeff// unchanged 雪😀\r\nconst value = "original";',
      );
    }
    write(
      '${packages['native']!.path}/linux/plugin.cc',
      '// original native source\r\n',
    );
    build = ApplicationInputs(
      artifactIdentity: 'a' * 64,
      mode: 'Debug',
      entry: 'lib/main.dart',
      packages: {
        'sample': ['lib/sample.dart'],
        'native': [],
      },
      nativePlugins: {'native'},
    );
  }
  final Directory directory;
  late Directory repository, sdk;
  late Map<String, Directory> packages;
  late ApplicationInputs build;
  Future<ApplicationNoticeInputs> inspect() => inspectApplicationNotices(
    repository: repository,
    packages: packages,
    build: build,
  );
  Map<String, dynamic> review(ApplicationNoticeInputs input) => {
    'version': 1,
    'sdk': input.sdk,
    'packages': [
      for (final record in input.records)
        {
          ...record,
          'license': 'MPL-2.0',
          'purpose': 'Source-copy boundary fixture',
          'distribution': 'Synthetic test only',
          'obligations': 'Retain original fixture notices and source',
        },
    ],
  };
  Future<({Map<String, List<int>> files, Map<String, Object?> inventory})>
  assemble(ApplicationNoticeInputs inputs, Map<String, dynamic> review) =>
      assembleApplicationNotices(
        repository: repository,
        packages: packages,
        inputs: inputs,
        review: review,
      );
}

void main() {
  test('dataset and codec supplements retain exact declarations, source provenance and independent terms', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-app-dataset-');
    addTearDown(() => temp.delete(recursive: true));
    final source = _Sources(temp), inspected = await source.inspect();
    final notice = File('${source.repository.path}/dataset-LICENSE')
      ..writeAsStringSync('original dataset copyright\r\npermission\r\n');
    final bytes = await notice.readAsBytes();
    final review = source.review(inspected);
    review['supplements'] = [
      {
        'name': 'unicode-original',
        'packages': ['sample'],
        'notice': 'dataset-LICENSE',
        'noticeSha256': sha256.convert(bytes).toString(),
        'license': 'Unicode-3.0',
        'source': 'https://example.invalid/exact-release/LICENSE',
        'purpose': 'Synthetic dataset fixture',
        'obligations': 'Retain notice',
      },
    ];
    review['datasets'] = [
      {
        'package': 'sample',
        'file': 'lib/sample.dart',
        'sha256': inspected.sourceFiles['sample']!['lib/sample.dart'],
        'supplement': 'unicode-original',
        'license': 'Unicode-3.0',
        'source': 'https://example.invalid/exact-release/data',
        'purpose': 'Synthetic data fixture',
        'modifications': 'Original fixture bytes',
      },
    ];
    final assembled = await source.assemble(inspected, review);
    expect(assembled.files['supplements/unicode-original'], bytes);
    expect(assembled.inventory['datasets'], review['datasets']);
    expect(
      utf8.decode(assembled.files['THIRD_PARTY_NOTICES.txt']!),
      contains('Original fixture bytes'),
    );
    (review['datasets'] as List).first['sha256'] = '0' * 64;
    await expectLater(source.assemble(inspected, review), throwsStateError);
    (review['datasets'] as List).first['sha256'] =
        inspected.sourceFiles['sample']!['lib/sample.dart'];
    (review['supplements'] as List).first['license'] = 'Unreviewed';
    await expectLater(source.assemble(inspected, review), throwsStateError);
    (review['supplements'] as List).first['license'] = 'Unicode-3.0';
    await notice.writeAsString('conflicting replacement');
    await expectLater(source.assemble(inspected, review), throwsStateError);
  });
  test('reviewed application inputs preserve original notices and exact library/native source through safe publication', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-app-notice-source-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final source = _Sources(temp), inspected = await source.inspect();
    expect(inspected.records.map((record) => record['name']), [
      'native',
      'sample',
    ]);
    expect(inspected.records.first['linuxNativePlugin'], true);
    final review = source.review(inspected);
    // JSON object-key order is presentation, not a different source grant.
    review['sdk'] = {
      for (final entry in inspected.sdk.entries.toList().reversed)
        entry.key: entry.value,
    };
    final assembled = await source.assemble(inspected, review);
    expect(
      assembled.files['BusyAPI-NOTICE'],
      await File('${source.repository.path}/NOTICE').readAsBytes(),
    );
    for (final name in ['sample', 'native']) {
      final version = name == 'sample' ? '1.0.0' : '2.0.0',
          key =
              'sources/$name-${name == 'sample' ? '1.0.0' : '2.0.0'}/lib/$name.dart';
      expect(
        assembled.files[key],
        await File('${source.packages[name]!.path}/lib/$name.dart')
            .readAsBytes(),
      );
      expect(
        utf8.decode(assembled.files['SOURCE-AVAILABILITY.txt']!),
        contains('https://pub.dev/api/archives/$name-$version.tar.gz'),
      );
    }
    expect(
      assembled.files['sources/native-2.0.0/linux/plugin.cc'],
      await File('${source.packages['native']!.path}/linux/plugin.cc')
          .readAsBytes(),
    );
    final output = '${temp.path}/installed licences 雪';
    await publication.publishNoticeFiles(
      assembled.files,
      source.repository,
      Directory('${source.repository.path}/packages/busyapi_core'),
      '--output=$output',
      operation: 'application-notices',
      defaultDirectory: 'application-notices',
      identity: {'sha256': inspected.build.artifactIdentity},
    );
    for (final entry in assembled.files.entries)
      expect(await File('$output/${entry.key}').readAsBytes(), entry.value);
    final repeated = await source.assemble(inspected, review);
    expect(repeated.files, assembled.files);
  });
  test('unknown/conflicting licence decisions, changed source and missing declarations cannot produce publishable contents', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-app-notice-denied-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final source = _Sources(temp), inspected = await source.inspect();
    final denied = source.review(inspected);
    (denied['packages'] as List).first['license'] =
        'Unreviewed-or-incompatible';
    await expectLater(source.assemble(inspected, denied), throwsStateError);
    final duplicate = source.review(inspected);
    (duplicate['packages'] as List).add((duplicate['packages'] as List).first);
    await expectLater(source.assemble(inspected, duplicate), throwsStateError);
    final changed = File('${source.packages['sample']!.path}/lib/sample.dart');
    final before = await changed.readAsBytes();
    await changed.writeAsString('// newer unrelated version\n');
    await expectLater(
      source.assemble(inspected, source.review(inspected)),
      throwsStateError,
    );
    expect(await changed.readAsString(), '// newer unrelated version\n');
    await changed.writeAsBytes(before);
    final manifest = File('${source.packages['sample']!.path}/pubspec.yaml');
    await manifest.writeAsString('name: sample\nversion: "9.0.0"\n');
    await expectLater(source.inspect(), throwsStateError);
  });
  test('inspection snapshots cannot be rewritten by a pending notice/source consumer', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-app-notice-immutable-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final source = _Sources(temp), inspected = await source.inspect();
    expect(() => inspected.sdk.clear(), throwsUnsupportedError);
    expect(
      () => inspected.records.first['name'] = 'someone else',
      throwsUnsupportedError,
    );
    expect(
      () => (inspected.records.first['notices'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(() => inspected.notices.values.first[0] = 0, throwsUnsupportedError);
    expect(
      () => inspected.sourceFiles['sample']!.clear(),
      throwsUnsupportedError,
    );
    expect(
      (await source.assemble(inspected, source.review(inspected))).files,
      isNotEmpty,
    );
  });
}
