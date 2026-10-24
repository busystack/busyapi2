import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ProjectAccess access;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-output-boundary-');
    access = await ProjectAccess.open(temp.path);
  });
  tearDown(() async {
    access.close();
    await temp.delete(recursive: true);
  });
  Map<String, List<int>> files(String value) => {
    'index.html': utf8.encode('<!doctype html>$value'),
    'assets/雪 space/data.json': utf8.encode(
      '{"n":9007199254740993,"text":"😀 $value"}\n',
    ),
  };
  test('large executable replacement uses the actual verified writer and retains both versions', () async {
    final bytes = List<int>.filled(17 * 1024 * 1024, 42),
        destination = '${temp.path}/large-owned-output';
    await access.publishOutput(
      destination,
      {'loader': bytes, 'resource.yaml': utf8.encode('original\n')},
      {},
      executableFiles: {'loader'},
    );
    final first = await access.inspectOutput(destination);
    final result = await access.publishOutput(
      destination,
      {'loader': bytes, 'resource.yaml': utf8.encode('replacement\n')},
      {},
      executableFiles: {'loader'},
      replaceIdentity: first.identity,
    );
    expect(result.previous, isNotNull);
    expect(
      await File('$destination/resource.yaml').readAsString(),
      'replacement\n',
    );
    expect(
      await File('${result.previous}/resource.yaml').readAsString(),
      'original\n',
    );
    expect(
      (await access.inspectOutput(result.previous!)).identity,
      first.identity,
    );
    expect(
      await access.mode('$destination/loader', maxBytes: 128 * 1024 * 1024),
      493,
    );
  });
  test('digest-bound runtime reads do not expand ordinary contract or output limits', () async {
    final bytes = List<int>.filled(16 * 1024 * 1024 + 1, 42),
        file = File('${temp.path}/large-artifact');
    await file.writeAsBytes(bytes);
    final identity = contentIdentity(bytes);
    await expectLater(
      access.read(file.path),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'limit.bytes')),
    );
    expect(await access.readVerifiedArtifact(file.path, identity), bytes);
    await expectLater(
      access.readVerifiedArtifact(file.path, '0' * 64),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'access.artifact.changed',
        ),
      ),
    );
    await expectLater(
      access.publishOutput('${temp.path}/not-a-binary', {
        'source.json': bytes,
      }, {}),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'output.limit')),
    );
    expect(await Directory('${temp.path}/not-a-binary').exists(), false);
  });
  test('explicit executable publication is bounded, recorded and verified without making source data executable', () async {
    final destination = '${temp.path}/loader';
    await access.publishOutput(
      destination,
      {
        'loader': utf8.encode('immutable executable bytes'),
        'resource.yaml': utf8.encode('x: data\n'),
      },
      {},
      executableFiles: {'loader'},
    );
    expect(await access.mode('$destination/loader'), 493);
    expect(await access.mode('$destination/resource.yaml'), 420);
    final receipt = await access.inspectOutput(destination);
    expect(receipt.files.keys, containsAll(['loader', 'resource.yaml']));
    privatePermissions('$destination/loader', 420);
    await expectLater(
      access.inspectOutput(destination),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'output.ownership'),
      ),
    );
    await expectLater(
      access.publishOutput(
        '${temp.path}/bad',
        files('data'),
        {},
        executableFiles: {'absent'},
      ),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'output.limit')),
    );
    expect(await Directory('${temp.path}/bad').exists(), false);
  });
  test('staged owned output is complete, inspectable, relocatable and collision-safe', () async {
    final destination = '${temp.path}/site 雪';
    final expected = files('first');
    await access.publishOutput(destination, expected, {
      'snapshot': 'frozen',
      'unsaved': true,
    });
    final receipt = await access.inspectOutput(destination);
    expect(receipt.metadata, {'snapshot': 'frozen', 'unsaved': true});
    for (final entry in expected.entries)
      expect(
        await File('$destination/${entry.key}').readAsBytes(),
        entry.value,
      );
    await expectLater(
      access.publishOutput(destination, files('second'), {}),
      throwsA(isA<Object>()),
    );
    expect(
      (await access.inspectOutput(destination)).identity,
      receipt.identity,
    );
    await Directory(destination).rename('${temp.path}/relocated');
    expect(
      (await access.inspectOutput('${temp.path}/relocated')).identity,
      receipt.identity,
    );
    expect(
      temp.listSync().length,
      1,
      reason:
          'An unpublished collision stage is cleaned, not the existing output',
    );
  });
  test('reviewed replacement retains the displaced output at a usable recovery path', () async {
    final destination = '${temp.path}/site';
    await access.publishOutput(destination, files('old'), {'snapshot': 'old'});
    final old = await access.inspectOutput(destination);
    final result = await access.publishOutput(destination, files('new'), {
      'snapshot': 'new',
    }, replaceIdentity: old.identity);
    expect(result.previous, isNotNull);
    expect(
      (await access.inspectOutput(result.previous!)).identity,
      old.identity,
    );
    expect(
      (await access.inspectOutput(destination)).metadata['snapshot'],
      'new',
    );
    access.close();
    expect(
      await File('${result.previous}/index.html').readAsString(),
      '<!doctype html>old',
    );
  });
  test('modified, additional, missing or symlinked output content is not owned replacement', () async {
    final destination = '${temp.path}/site';
    await access.publishOutput(destination, files('old'), {});
    final old = await access.inspectOutput(destination);
    final original = await File('$destination/index.html').readAsBytes();
    for (final fault in ['modified', 'additional', 'missing', 'symlink']) {
      final file = File('$destination/index.html');
      if (fault == 'modified') await file.writeAsString('external version');
      if (fault == 'additional')
        await File('$destination/working-api.yaml')
            .writeAsString('openapi: 3.2.1\n');
      if (fault == 'missing') await file.delete();
      if (fault == 'symlink') {
        await file.delete();
        await Link(file.path).create('${temp.path}/outside');
      }
      await expectLater(
        access.publishOutput(
          destination,
          files('new'),
          {},
          replaceIdentity: old.identity,
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'output.ownership'),
        ),
      );
      if (fault == 'symlink') await Link(file.path).delete();
      if (fault == 'additional')
        await File('$destination/working-api.yaml').delete();
      await file.writeAsBytes(original);
    }
    expect((await access.inspectOutput(destination)).identity, old.identity);
  });
  test('cancel and a pre-publication failure never publish empty or partial output', () async {
    final destination = '${temp.path}/site';
    await expectLater(
      access.publishOutput(
        destination,
        files('cancelled'),
        {},
        cancelled: () => true,
      ),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    await expectLater(
      access.publishOutput(
        destination,
        files('failed'),
        {},
        beforePublish: () => throw StateError('boundary fault'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await Directory(destination).exists(), false);
    expect(temp.listSync(), isEmpty);
    for (final name in [
      '../source.yaml',
      '/outside',
      'x/../source',
      'x\\escape',
      'a//b',
      'busyapi-output.json',
    ]) {
      await expectLater(
        access.publishOutput(destination, {
          name: [1],
        }, {}),
        throwsA(isA<CoreFailure>()),
      );
    }
  });
  test(
    'external edits after review and at publication reject every replacement',
    () async {
      final destination = '${temp.path}/site';
      await access.publishOutput(destination, files('old'), {});
      final old = await access.inspectOutput(destination);
      await expectLater(
        access.publishOutput(
          destination,
          files('new'),
          {},
          replaceIdentity: old.identity,
          beforePublish: () =>
              File('$destination/index.html').writeAsString('external version'),
        ),
        throwsA(isA<CoreFailure>()),
      );
      expect(
        await File('$destination/index.html').readAsString(),
        'external version',
      );
      expect(temp.listSync().length, 1);
    },
  );
  test('failure after exchange preserves both actual versions and reports publication truthfully', () async {
    final destination = '${temp.path}/site';
    await access.publishOutput(destination, files('old'), {'snapshot': 'old'});
    final old = await access.inspectOutput(destination);
    OutputDirectoryChanged? caught;
    try {
      await access.publishOutput(
        destination,
        files('new'),
        {'snapshot': 'new'},
        replaceIdentity: old.identity,
        afterPublish: () => throw StateError('after real exchange'),
      );
    } on OutputDirectoryChanged catch (error) {
      caught = error;
    }
    expect(caught, isNotNull);
    expect(caught!.published, true);
    expect(caught.recoveryPath, isNotNull);
    expect(
      (await access.inspectOutput(caught.recoveryPath!)).identity,
      old.identity,
    );
    expect(
      (await access.inspectOutput(destination)).metadata['snapshot'],
      'new',
    );
  });
  test(
    'a moved output parent cannot redirect publication to its replacement',
    () async {
      final parent = await Directory('${temp.path}/parent').create();
      final destination = '${parent.path}/site';
      await expectLater(
        access.publishOutput(
          destination,
          files('new'),
          {},
          beforePublish: () async {
            await parent.rename('${temp.path}/moved');
            await Directory(parent.path).create();
            await File('${parent.path}/unrelated.txt')
                .writeAsString('preserve');
          },
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'access.replaced'),
        ),
      );
      expect(await Directory(destination).exists(), false);
      expect(
        await File('${parent.path}/unrelated.txt').readAsString(),
        'preserve',
      );
      expect(Directory('${temp.path}/moved').listSync(), isEmpty);
    },
  );
}
