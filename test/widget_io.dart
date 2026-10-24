import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Real IO can depend on callbacks/timers already scheduled in the widget
/// binding's fake frame zone. Awaiting it entirely inside runAsync prevents
/// that zone from progressing. Start the real operation there, then drive
/// frames until its actual completion, preserving errors and a bounded deadline.
Future<T> runWidgetIo<T>(
  WidgetTester tester,
  Future<T> Function() operation, {
  Duration timeout = const Duration(seconds: 8),
  String Function()? describeState,
}) async {
  var finished = false;
  T? value;
  Object? failure;
  StackTrace? failureStack;
  final watch = Stopwatch()..start();
  await tester.runAsync(() async {
    unawaited(
      Future<T>.sync(operation).then<void>(
        (result) {
          value = result;
          finished = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          finished = true;
        },
      ),
    );
  });
  while (!finished && watch.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!finished) {
    throw TestFailure(
      'The actual IO operation did not finish within $timeout; no success was inferred'
      '${describeState == null ? '' : '\n${describeState()}'}',
    );
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return value as T;
}
