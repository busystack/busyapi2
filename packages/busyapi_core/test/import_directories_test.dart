import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ProjectAccess access;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-owned-import-dirs-');
    access = await ProjectAccess.open(temp.path);
  });
  tearDown(() async {
    access.close();
    await temp.delete(recursive: true);
  });
  test('owned publication retains empty Unicode/Git directories and detects their removal', () async {
    final target = '${temp.path}/output';
    await access.publishOutput(
      target,
      {
        'api.yaml': [1, 2, 3],
      },
      {'operation': 'import'},
      emptyDirectories: {'.git/refs/heads', 'empty 雪'},
    );
    expect(await Directory('$target/.git/refs/heads').exists(), true);
    expect(await Directory('$target/empty 雪').exists(), true);
    final receipt = await access.inspectOutput(target);
    expect(receipt.files, {
      'api.yaml': contentIdentity([1, 2, 3]),
    });
    await Directory('$target/empty 雪').delete();
    await expectLater(
      access.inspectOutput(target),
      throwsA(isA<CoreFailure>()),
    );
  });
  test('unchanged replacement retains previous empty directories; foreign content blocks it', () async {
    final target = '${temp.path}/output';
    await access.publishOutput(
      target,
      {
        'api.yaml': [1],
      },
      {},
      emptyDirectories: {'empty'},
    );
    final receipt = await access.inspectOutput(target);
    final result = await access.publishOutput(
      target,
      {
        'api.yaml': [2],
      },
      {},
      replaceIdentity: receipt.identity,
      emptyDirectories: {'next'},
    );
    expect(await Directory('${result.previous}/empty').exists(), true);
    expect(await Directory('$target/next').exists(), true);
    await File('$target/next/foreign').writeAsString('owner bytes');
    await expectLater(
      access.inspectOutput(target),
      throwsA(isA<CoreFailure>()),
    );
    expect(await File('$target/next/foreign').readAsString(), 'owner bytes');
  });
  test('escaping directory names and cancellation publish nothing', () async {
    final target = '${temp.path}/refused';
    await expectLater(
      access.publishOutput(
        target,
        {
          'api': [1],
        },
        {},
        emptyDirectories: {'../outside'},
      ),
      throwsA(isA<CoreFailure>()),
    );
    await expectLater(
      access.publishOutput(
        target,
        {
          'api': [1],
        },
        {},
        emptyDirectories: {'empty'},
        cancelled: () => true,
      ),
      throwsA(isA<CoreFailure>()),
    );
    expect(await Directory(target).exists(), false);
    expect((await temp.list().toList()), isEmpty);
  });
  test(
    'an imported project cannot become a replaceable derived output',
    () async {
      final target = '${temp.path}/source';
      await access.publishOutput(
        target,
        {
          'api.yaml': [1, 2, 3],
        },
        {'operation': 'import'},
        emptyDirectories: {'empty'},
      );
      final receipt = await access.inspectOutput(target);
      await expectLater(
        access.publishOutput(
          target,
          {
            'generated.ts': [4],
          },
          {'operation': 'generate'},
          replaceIdentity: receipt.identity,
        ),
        throwsA(
          isA<CoreFailure>().having((f) => f.code, 'code', 'output.source'),
        ),
      );
      expect(await File('$target/api.yaml').readAsBytes(), [1, 2, 3]);
      expect(await Directory('$target/empty').exists(), true);
    },
  );
}
