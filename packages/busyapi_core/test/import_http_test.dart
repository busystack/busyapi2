import 'dart:async';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late StreamSubscription<HttpRequest> subscription;
  final seen = <String>[];
  final reached = <String, Completer<void>>{};
  void observe(String path) =>
      reached.putIfAbsent(path, Completer<void>.new).complete();
  Future<void> waitFor(String path) =>
      reached.putIfAbsent(path, Completer<void>.new).future;
  setUp(() async {
    seen.clear();
    reached.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    subscription = server.listen((request) async {
      seen.add(request.uri.path);
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      observe(request.uri.path);
      // Intentional client aborts are not an unhandled server test failure.
      unawaited(
        request.response.done.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
      );
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          base.resolve('/雪.yaml').toString(),
        );
      } else if (request.uri.path == '/stalled') {
        request.response.write('partial');
        await request.response.flush();
        return;
      } else if (request.uri.path == '/headers') {
        return;
      } else if (request.uri.path == '/large') {
        request.response.add(List.filled(1024, 42));
      } else {
        request.response.write('openapi: 3.2.1\n# 雪\n');
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await subscription.cancel();
    await server.close(force: true);
  });
  test(
    'explicit redirect approves each actual target and preserves Unicode bytes',
    () async {
      final initial = base.resolve('/redirect'),
          target = base.resolve('/雪.yaml');
      final result = await const ContractHttpTransport().acquireResource(
        initial,
        approved: {initial, target}.contains,
      );
      expect(result.$1, target);
      expect(result.$2, [
        111,
        112,
        101,
        110,
        97,
        112,
        105,
        58,
        32,
        51,
        46,
        50,
        46,
        49,
        10,
        35,
        32,
        233,
        155,
        170,
        10,
      ]);
      expect(seen, ['/redirect', '/%E9%9B%AA.yaml']);
    },
  );
  test('unapproved redirect never connects to its destination', () async {
    final initial = base.resolve('/redirect');
    await expectLater(
      const ContractHttpTransport().acquireResource(
        initial,
        approved: (uri) => uri == initial,
      ),
      throwsA(
        isA<CoreFailure>().having((f) => f.code, 'code', 'import.approval'),
      ),
    );
    expect(seen, ['/redirect']);
  });
  for (final stage in ['headers', 'stalled']) {
    test('overall deadline aborts owned import at $stage', () async {
      final clock = Stopwatch()..start();
      await expectLater(
        const ContractHttpTransport().acquireResource(
          base.resolve('/$stage'),
          approved: (_) => true,
          timeout: const Duration(milliseconds: 400),
        ),
        throwsA(
          isA<CoreFailure>().having((f) => f.code, 'code', 'import.timeout'),
        ),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    });
    test('explicit cancellation aborts import at $stage', () async {
      final cancel = RunCancellation();
      final run = const ContractHttpTransport().acquireResource(
        base.resolve('/$stage'),
        approved: (_) => true,
        cancellation: cancel,
      );
      final failed = expectLater(
        run,
        throwsA(isA<CoreFailure>().having((f) => f.code, 'code', 'cancelled')),
      );
      await waitFor('/$stage');
      cancel.cancel();
      await failed;
      expect(seen, ['/$stage']);
    });
  }
  test(
    'bounded acquisition refuses oversized data without a partial success',
    () async {
      await expectLater(
        const ContractHttpTransport().acquireResource(
          base.resolve('/large'),
          approved: (_) => true,
          maximumBytes: 100,
        ),
        throwsA(
          isA<CoreFailure>().having((f) => f.code, 'code', 'limit.import'),
        ),
      );
      expect(seen, ['/large']);
    },
  );
}
