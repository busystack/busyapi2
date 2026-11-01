import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late File source;
  late ProjectAccess access;
  late List<int> original;
  late int mode;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-owned-file-archive-');
    source = File('${temp.path}/source.yaml');
    original = [
      239,
      187,
      191,
      ...utf8.encode(
        '# retained\r\ntitle: "雪😀"\nvalue: 900719925474099312345',
      ),
    ];
    await source.writeAsBytes(original);
    access = await ProjectAccess.open(temp.path);
    mode = await access.mode(source.path);
  });
  tearDown(() async {
    access.close();
    await temp.delete(recursive: true);
  });
  test(
    'old-name removal retains exact bytes in a private preallocated archive',
    () async {
      final archive = await access.prepareFileArchive(source.path);
      expect(p.basename(p.dirname(archive)), startsWith('busyapi-file-move-'));
      expect(await File(archive).exists(), false);
      expect(
        (await Directory(File(archive).parent.path).stat()).mode & 511,
        448,
      );
      await access.archiveFile(
        source.path,
        archive,
        expected: contentIdentity(original),
        mode: mode,
      );
      expect(await source.exists(), false);
      expect(await File(archive).readAsBytes(), original);
      expect(await access.mode(archive), mode);
    },
  );
  test('retained hidden archive slots keep their existing source-preservation contract', () async {
    final prepared = await access.prepareFileArchive(source.path);
    final retained = await Directory(p.dirname(prepared))
        .rename(p.join(temp.path, '.${p.basename(p.dirname(prepared))}'));
    final archive = p.join(retained.path, 'source');
    expect((await retained.stat()).mode & 511, 448);
    await access.archiveFile(
      source.path,
      archive,
      expected: contentIdentity(original),
      mode: mode,
    );
    expect(await source.exists(), false);
    expect(await File(archive).readAsBytes(), original);
    expect(await access.mode(archive), mode);
  });
  test('preflight changes and an occupied archive cannot remove or overwrite either version', () async {
    final archive = await access.prepareFileArchive(source.path);
    await source.writeAsString('new external\n');
    await expectLater(
      access.archiveFile(
        source.path,
        archive,
        expected: contentIdentity(original),
        mode: mode,
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'file.archive.stale'),
      ),
    );
    expect(await source.readAsString(), 'new external\n');
    expect(await File(archive).exists(), false);
    await source.writeAsBytes(original);
    await File(archive).writeAsString('foreign archive\n');
    await expectLater(
      access.archiveFile(
        source.path,
        archive,
        expected: contentIdentity(original),
        mode: mode,
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'file.archive.rename'),
      ),
    );
    expect(await source.readAsBytes(), original);
    expect(await File(archive).readAsString(), 'foreign archive\n');
  });
  test('a race after source verification retains the newer original and never rolls back', () async {
    final archive = await access.prepareFileArchive(source.path);
    await expectLater(
      access.archiveFile(
        source.path,
        archive,
        expected: contentIdentity(original),
        mode: mode,
        beforeArchive: () => source.writeAsString('newer during archival\n'),
      ),
      throwsA(
        isA<FileArchiveChanged>().having(
          (e) => e.archivePath,
          'archive',
          archive,
        ),
      ),
    );
    expect(await source.exists(), false);
    expect(await File(archive).readAsString(), 'newer during archival\n');
  });
  test(
    'a recreated source name is preserved beside the archived original',
    () async {
      final archive = await access.prepareFileArchive(source.path);
      await expectLater(
        access.archiveFile(
          source.path,
          archive,
          expected: contentIdentity(original),
          mode: mode,
          afterArchive: () => source.writeAsString('new filename owner\n'),
        ),
        throwsA(
          isA<FileArchiveChanged>().having(
            (e) => e.code,
            'code',
            'file.archive.reappeared',
          ),
        ),
      );
      expect(await source.readAsString(), 'new filename owner\n');
      expect(await File(archive).readAsBytes(), original);
    },
  );
  test('a replaced archive parent is not followed and foreign content stays untouched', () async {
    final archive = await access.prepareFileArchive(source.path);
    final parent = File(archive).parent;
    await parent.rename('${temp.path}/retained-stage');
    final foreign = await Directory('${temp.path}/foreign').create();
    final value = File('${foreign.path}/source');
    await value.writeAsString('foreign\n');
    await Link(parent.path).create(foreign.path);
    await expectLater(
      access.archiveFile(
        source.path,
        archive,
        expected: contentIdentity(original),
        mode: mode,
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(await source.readAsBytes(), original);
    expect(await value.readAsString(), 'foreign\n');
  });
  test('archive destinations cannot name an arbitrary selected file', () async {
    final foreign = File('${temp.path}/foreign.txt');
    await foreign.writeAsString('foreign');
    await expectLater(
      access.archiveFile(
        source.path,
        foreign.path,
        expected: contentIdentity(original),
        mode: mode,
      ),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'file.archive.path'),
      ),
    );
    expect(await source.readAsBytes(), original);
    expect(await foreign.readAsString(), 'foreign');
  });
}
