import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/dart_runtime_notices.dart';
import 'test_support.dart';

void main() {
  final repository = Directory(repositoryRoot),
      sdk = Directory(p.dirname(p.dirname(Platform.resolvedExecutable)));

  test(
    'actual pinned AOT runtime retains all original and nested notices offline',
    () async {
      final result = await collectDartRuntimeNotices(repository, sdk);
      expect(result.inventory['sdk'], '3.13.4');
      expect((result.inventory['components'] as List).length, 10);
      final review = jsonDecode(
        await File(p.join(repository.path, 'tools/dart_runtime.review.json'))
            .readAsString(),
      ) as Map;
      for (final component in review['components'] as List) {
        for (final notice in component['notices'] as List) {
          final bytes = result.files['runtime/${notice['file']}']!;
          expect(sha256.convert(bytes).toString(), notice['sha256']);
          expect(
            bytes,
            await File(
              p.join(
                repository.path,
                'tools/licenses/dart-runtime',
                notice['file'] as String,
              ),
            ).readAsBytes(),
          );
        }
      }
      expect(
        utf8.decode(result.files['runtime/libcxx-ryu-header']!),
        contains('Boost Software License - Version 1.0'),
      );
      expect(
        utf8.decode(result.files['runtime/libcxx-unicode-header']!),
        contains('Copyright (c) 1991-2022 Unicode'),
      );
      expect(
        utf8.decode(result.files['runtime/zlib-zlib.h-header']!),
        contains('1995-2024 Jean-loup Gailly and Mark Adler'),
      );
      expect(
        utf8.decode(result.files['runtime/boringssl-LICENSE']!),
        contains('Apache License'),
      );
      expect(
        utf8.decode(result.files['runtime/DART-PATENT_GRANT']!),
        contains('patent'),
      );
      expect(
        utf8.decode(result.files['runtime/NOTICE.txt']!),
        isNot(contains(repository.path)),
      );
      expect(
        utf8.decode(result.files['runtime/NOTICE.txt']!),
        isNot(contains(sdk.path)),
      );
    },
  );

  for (final fault in ['sdk', 'notice', 'symlink', 'traversal', 'missing']) {
    test('runtime review fails before publication for $fault', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'busyapi-dart-runtime-notices-',
      );
      try {
        final fakeRepository = Directory(p.join(temporary.path, 'repository')),
            fakeSdk = Directory(p.join(temporary.path, 'sdk'));
        await Directory(
          p.join(fakeRepository.path, 'tools/licenses/dart-runtime'),
        ).create(recursive: true);
        final reviewFile = File(
          p.join(fakeRepository.path, 'tools/dart_runtime.review.json'),
        );
        final review = jsonDecode(
          await File(p.join(repository.path, 'tools/dart_runtime.review.json'))
              .readAsString(),
        ) as Map;
        for (final source in Directory(
          p.join(repository.path, 'tools/licenses/dart-runtime'),
        ).listSync()) {
          await File(source.path).copy(
            p.join(
              fakeRepository.path,
              'tools/licenses/dart-runtime',
              p.basename(source.path),
            ),
          );
        }
        if (fault == 'traversal') {
          review['components'][0]['notices'][0]['file'] = '../outside';
        }
        await reviewFile.writeAsString(jsonEncode(review));
        await Directory(p.join(fakeSdk.path, 'bin')).create(recursive: true);
        for (final name in ['revision', 'LICENSE', 'bin/dartaotruntime']) {
          await File(p.join(sdk.path, name)).copy(p.join(fakeSdk.path, name));
        }
        final notice = File(
          p.join(
            fakeRepository.path,
            'tools/licenses/dart-runtime/libcxx-ryu-header',
          ),
        );
        if (fault == 'sdk') {
          await File(p.join(fakeSdk.path, 'bin/dartaotruntime'))
              .writeAsBytes([1, 2, 3]);
        } else if (fault == 'notice') {
          await notice.writeAsString(
            'Changed terms, not the reviewed original\n',
          );
        } else if (fault == 'missing') {
          await notice.delete();
        } else if (fault == 'symlink') {
          await notice.delete();
          await Link(notice.path).create(
            p.join(
              repository.path,
              'tools/licenses/dart-runtime/libcxx-ryu-header',
            ),
          );
        }
        await expectLater(
          collectDartRuntimeNotices(fakeRepository, fakeSdk),
          throwsStateError,
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    });
  }
}
