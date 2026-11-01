import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:busyapi_core/src/linux_atomic_file_api.dart';
import 'package:test/test.dart';

// Sendable instance methods deliberately avoid closures over test/native state.
class _Gate {
  const _Gate(this.owner);
  final SendPort owner;

  Future<void> enter(int descriptor) async {
    final release = ReceivePort();
    try {
      owner.send([descriptor, release.sendPort]);
      await release.first;
    } finally {
      release.close();
    }
  }
}

class _SlowBoundary {
  const _SlowBoundary(this.owner);
  final SendPort owner;

  void enter(int descriptor) {
    owner.send(descriptor);
    sleep(const Duration(milliseconds: 250));
  }
}

class _UnsendableBoundary {
  _UnsendableBoundary(this.port);
  final ReceivePort port;
  void enter(int descriptor) => port.sendPort.send(descriptor);
}

void _failBeforeSync(int descriptor) => throw const FileSystemException(
  'Injected directory synchronization failure',
);

String _target(int descriptor) =>
    Link('/proc/self/fd/$descriptor').targetSync();

Set<String> _descriptorsFor(String path) => Directory('/proc/self/fd')
    // Other test isolates share this process and can close unrelated FDs
    // during enumeration. Do not stat/follow their transient proc links;
    // readlink below already tolerates disappearance. The exact set of
    // descriptors pointing at this test's pinned directory is still
    // compared before/after every injected failure.
    .listSync(followLinks: false)
    .whereType<Link>()
    .where((link) {
      try {
        return link.targetSync() == path;
      } on FileSystemException {
        return false;
      }
    })
    .map((link) => link.path)
    .toSet();

void main() {
  final api = LinuxAtomicFileApi.instance;
  for (final kind in ['descriptor', 'anchored parent', 'path parent']) {
    test(
      '$kind sync pins its original directory until actual completion',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'busyapi-sync-',
        );
        final original = await Directory('${temporary.path}/source').create();
        final retained = '${temporary.path}/retained';
        final started = ReceivePort();
        var caller = api.openDirectory(original.path);
        int? replacement;
        SendPort? release;
        Future<void>? pending;
        try {
          final gate = _Gate(started.sendPort);
          pending = switch (kind) {
            'descriptor' => api.syncDirectoryFd(caller, beforeSync: gate.enter),
            'anchored parent' => api.syncParent(
              '/proc/self/fd/$caller',
              beforeSync: gate.enter,
            ),
            _ => api.syncParent(original.path, beforeSync: gate.enter),
          };
          var completed = false;
          final observed = pending.then((_) => completed = true);
          final message = await started.first as List;
          final held = message[0] as int;
          release = message[1] as SendPort;
          expect(held, isNot(caller));
          final flags = RegExp(
            r'^flags:\s+([0-7]+)$',
            multiLine: true,
          ).firstMatch(File('/proc/self/fdinfo/$held').readAsStringSync())!;
          expect(int.parse(flags[1]!, radix: 8) & 0x80000, isNot(0));

          api.closeDirectory(caller);
          caller = -1;
          await original.rename(retained);
          await Directory(original.path).create();
          replacement = api.openDirectory(original.path);
          expect(_target(held), retained);
          expect(_target(replacement), original.path);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(completed, isFalse, reason: 'Durability has not happened yet');

          release.send(null);
          release = null;
          await observed;
          expect(completed, isTrue);
          // A different isolate may already have reused the numeric FD. What
          // must be gone is every capability to our original pinned inode,
          // not an unrelated process-wide descriptor slot.
          expect(_descriptorsFor(retained), isEmpty);
          expect(_target(replacement), original.path);
        } finally {
          release?.send(null);
          if (pending != null) await pending;
          started.close();
          if (caller >= 0) api.closeDirectory(caller);
          if (replacement != null) api.closeDirectory(replacement);
          await temporary.delete(recursive: true);
        }
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'blocking synchronization work does not block the calling isolate',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'busyapi-sync-loop-',
      );
      final descriptor = api.openDirectory(temporary.path);
      final started = ReceivePort();
      try {
        final slow = _SlowBoundary(started.sendPort);
        var completed = false;
        final pending = api
            .syncDirectoryFd(descriptor, beforeSync: slow.enter)
            .then((_) => completed = true);
        await started.first;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(completed, isFalse);
        await pending;
        expect(completed, isTrue);
      } finally {
        started.close();
        api.closeDirectory(descriptor);
        await temporary.delete();
      }
    },
    skip: !Platform.isLinux,
  );

  test('worker and spawn failures close only the pinned descriptor', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'busyapi-sync-fail-',
    );
    final descriptor = api.openDirectory(temporary.path);
    final unsendable = ReceivePort();
    try {
      final before = _descriptorsFor(temporary.path);
      for (final sync in [
        () => api.syncDirectoryFd(descriptor, beforeSync: _failBeforeSync),
        () => api.syncParent(
          '/proc/self/fd/$descriptor',
          beforeSync: _failBeforeSync,
        ),
        () => api.syncParent(temporary.path, beforeSync: _failBeforeSync),
      ]) {
        await expectLater(sync(), throwsA(isA<FileSystemException>()));
        expect(_descriptorsFor(temporary.path), before);
      }
      final boundary = _UnsendableBoundary(unsendable);
      await expectLater(
        Future.sync(
          () => api.syncDirectoryFd(descriptor, beforeSync: boundary.enter),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(_descriptorsFor(temporary.path), before);
      expect(_target(descriptor), temporary.path);
    } finally {
      unsendable.close();
      api.closeDirectory(descriptor);
      await temporary.delete();
    }
  }, skip: !Platform.isLinux);

  test(
    'invalid descriptors and missing or symlink parents fail closed',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'busyapi-sync-path-',
      );
      try {
        expect(
          () => api.syncDirectoryFd(-1),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          api.syncParent('${temporary.path}/missing'),
          throwsA(isA<FileSystemException>()),
        );
        final directory = await Directory('${temporary.path}/real').create();
        final link = await Link('${temporary.path}/link')
            .create(directory.path);
        await expectLater(
          api.syncParent(link.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isLinux,
  );
}
