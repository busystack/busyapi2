import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late ProjectAccess access;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('busyapi-metadata-');
    access = await ProjectAccess.open(temporary.path);
  });
  tearDown(() async {
    access.close();
    await temporary.delete(recursive: true);
  });
  test('metadata captures ordinary files without changing bytes or reading directories', () async {
    final file = File('${temporary.path}/雪 file.json');
    final bytes = [239, 187, 191, ...'900719925474099312345.00\r\n'.codeUnits];
    await file.writeAsBytes(bytes);
    final one = await access.describe(file.path),
        two = await access.describe(file.path);
    expect(one.kind, 'file');
    expect(one.size, bytes.length);
    expect(one.mode! & 0xf000, 0x8000);
    expect(one.identity, two.identity);
    expect(await file.readAsBytes(), bytes);
  });
  test(
    'the held boundary, nested directories and known absence are distinct',
    () async {
      final directory = await Directory('${temporary.path}/nested').create();
      expect((await access.describe(temporary.path)).kind, 'directory');
      expect((await access.describe(directory.path)).kind, 'directory');
      expect(
        (await access.describe('${directory.path}/absent.json')).kind,
        'absent',
      );
      expect(
        (await access.describe('${temporary.path}/missing/another/file.json'))
            .kind,
        'absent',
      );
      expect(
        (await access.describe('${temporary.path}/missing/another/file.json'))
            .toJson(),
        {'kind': 'absent'},
      );
    },
  );
  test('final and parent symlinks never become metadata permission or known absence', () async {
    final outside = await Directory.systemTemp.createTemp(
      'busyapi-metadata-outside-',
    );
    addTearDown(() => outside.delete(recursive: true));
    final file = File('${outside.path}/data.json')
      ..writeAsStringSync('not a permitted resource');
    await Link('${temporary.path}/file-link').create(file.path);
    await Link('${temporary.path}/directory-link').create(outside.path);
    await expectLater(
      access.describe('${temporary.path}/file-link'),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'access.symlink',
        ),
      ),
    );
    await expectLater(
      access.describe('${temporary.path}/directory-link/missing.json'),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'access.parent',
        ),
      ),
    );
    expect(await file.readAsString(), 'not a permitted resource');
  });
  test(
    'closed and out-of-boundary capabilities do not report absent',
    () async {
      await expectLater(
        access.describe('${temporary.parent.path}/not-in-boundary'),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'access.outside',
          ),
        ),
      );
      access.close();
      await expectLater(
        access.describe('${temporary.path}/missing/child'),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'access.closed',
          ),
        ),
      );
    },
  );
  test('a replaced parent cannot supply an apparently absent observation from the old directory', () async {
    final original = temporary.path;
    final displaced = await temporary.rename('$original-displaced');
    addTearDown(() => displaced.delete(recursive: true));
    temporary = await Directory(original).create();
    await File('$original/missing/another/file.json').create(recursive: true);
    await expectLater(
      access.describe('$original/missing/another/file.json'),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'access.replaced',
        ),
      ),
    );
  });
}
