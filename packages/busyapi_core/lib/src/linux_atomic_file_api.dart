// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// BusyAPI uses content-checked publication.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _RenameAt2Native = Int32 Function(
  Int32 oldDirectory,
  Pointer<Utf8> oldPath,
  Int32 newDirectory,
  Pointer<Utf8> newPath,
  Uint32 flags,
);
typedef _RenameAt2Dart = int Function(
  int oldDirectory,
  Pointer<Utf8> oldPath,
  int newDirectory,
  Pointer<Utf8> newPath,
  int flags,
);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();
typedef _LinkNative = Int32 Function(
  Pointer<Utf8> oldPath,
  Pointer<Utf8> newPath,
);
typedef _LinkDart = int Function(Pointer<Utf8> oldPath, Pointer<Utf8> newPath);
typedef _OpenAtNative = Int32 Function(Int32, Pointer<Utf8>, Int32);
typedef _OpenAtDart = int Function(int, Pointer<Utf8>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _DuplicateNative = Int32 Function(Int32, Int32, VarArgs<(Int32,)>);
typedef _DuplicateDart = int Function(int, int, int);

// Send only a descriptor number and an optional deterministic test boundary.
// A closure here could accidentally capture the caller's FFI library, source
// buffers, open handles or widget ownership when Isolate.run serializes it.
class _DirectorySynchronization {
  const _DirectorySynchronization(this.descriptor, this.beforeSync);
  final int descriptor;
  final FutureOr<void> Function(int descriptor)? beforeSync;
  Future<void> run() async {
    await beforeSync?.call(descriptor);
    LinuxAtomicFileApi.instance._syncDirectoryFd(descriptor);
  }
}

/// Small Linux-only wrapper around atomic `renameat2` file exchanges.
///
/// Exchanging a staged file with its destination lets callers verify the exact
/// inode that was replaced. Callers must retain disputed displaced bytes;
/// exchanging back can overwrite a concurrent writer and is not a rollback.
final class LinuxAtomicFileApi {
  LinuxAtomicFileApi._() {
    if (!Platform.isLinux) {
      return;
    }
    final library = DynamicLibrary.open('libc.so.6');
    _library = library;
    try {
      _renameAt2 = _library!.lookupFunction<_RenameAt2Native, _RenameAt2Dart>(
        'renameat2',
      );
    } on ArgumentError {
      _renameAt2 = null;
    }
    _errnoLocation = _library!
        .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
          '__errno_location',
        );
    _link = _library!.lookupFunction<_LinkNative, _LinkDart>('link');
    _openAt = _library!.lookupFunction<_OpenAtNative, _OpenAtDart>('openat');
    _fsync = _library!.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'fsync',
    );
    _close = _library!.lookupFunction<_CloseNative, _CloseDart>('close');
    _duplicate = _library!.lookupFunction<_DuplicateNative, _DuplicateDart>(
      'fcntl',
    );
  }

  static const fileExistsError = 17;
  static const _invalidArgumentError = 22;
  static const _functionNotImplementedError = 38;
  static const _operationNotSupportedError = 95;
  static const _atCurrentWorkingDirectory = -100;
  static const _renameNoReplace = 1;
  static const _renameExchange = 2;
  static final instance = LinuxAtomicFileApi._();

  _RenameAt2Dart? _renameAt2;
  _ErrnoLocationDart? _errnoLocation;
  _LinkDart? _link;
  _OpenAtDart? _openAt;
  _CloseDart? _close;
  _DuplicateDart? _duplicate;
  int Function(int)? _fsync;
  DynamicLibrary? _library;

  bool get isAvailable => _renameAt2 != null && _errnoLocation != null;
  int openDirectory(String path) {
    final ptr = path.toNativeUtf8();
    try {
      final fd = _openAt?.call(-100, ptr, 0x10000 | 0x20000 | 0x80000) ?? -1;
      if (fd < 0) {
        throw FileSystemException('Cannot anchor staging directory', path);
      }
      return fd;
    } finally {
      malloc.free(ptr);
    }
  }

  void _syncDirectoryFd(int fd) {
    if (_fsync?.call(fd) != 0) {
      throw FileSystemException('Cannot synchronize publication directory');
    }
  }

  /// Await real durability without blocking the calling (possibly UI) isolate.
  /// Duplicate with F_DUPFD_CLOEXEC *before* yielding: closing/reusing the
  /// caller's descriptor cannot retarget synchronization, and a spawned
  /// executable cannot inherit this private capability. No pathname is reopened
  /// by the worker. Only this owner closes the duplicate after actual completion.
  Future<void> syncDirectoryFd(
    int fd, {
    FutureOr<void> Function(int descriptor)? beforeSync,
  }) {
    final held = _duplicate?.call(fd, 1030, 0) ?? -1;
    if (held < 0)
      throw FileSystemException(
        'Cannot pin publication directory synchronization',
      );
    try {
      return Isolate.run(
        _DirectorySynchronization(held, beforeSync).run,
        debugName: 'busyapi-directory-sync',
      ).whenComplete(() => closeDirectory(held));
    } on Object {
      closeDirectory(held);
      rethrow;
    }
  }

  Future<void> syncParent(
    String parent, {
    FutureOr<void> Function(int descriptor)? beforeSync,
  }) async {
    final anchor = RegExp(r'^/proc/self/fd/(\d+)$').firstMatch(parent);
    if (anchor != null) {
      await syncDirectoryFd(
        int.parse(anchor.group(1)!),
        beforeSync: beforeSync,
      );
      return;
    }
    final fd = openDirectory(parent);
    try {
      await syncDirectoryFd(fd, beforeSync: beforeSync);
    } finally {
      closeDirectory(fd);
    }
  }

  void closeDirectory(int fd) => _close?.call(fd);

  /// Returns `null` on success, otherwise the Linux errno value.
  int? exchange(String firstPath, String secondPath) {
    final renameAt2 = _renameAt2;
    final errnoLocation = _errnoLocation;
    if (renameAt2 == null || errnoLocation == null) {
      return null;
    }
    final nativeFirstPath = firstPath.toNativeUtf8();
    final nativeSecondPath = secondPath.toNativeUtf8();
    try {
      final result = renameAt2(
        _atCurrentWorkingDirectory,
        nativeFirstPath,
        _atCurrentWorkingDirectory,
        nativeSecondPath,
        _renameExchange,
      );
      return result == 0 ? null : errnoLocation().value;
    } finally {
      malloc.free(nativeFirstPath);
      malloc.free(nativeSecondPath);
    }
  }

  /// Publishes [oldPath] at [newPath] without replacing an existing entity.
  ///
  /// Returns `null` on success, otherwise the Linux errno value.
  int? publishNoReplace(
    String oldPath,
    String newPath, {
    bool directory = false,
    bool renameOnly = false,
  }) {
    final errnoLocation = _errnoLocation;
    final link = _link;
    if (errnoLocation == null || link == null) {
      return _operationNotSupportedError;
    }
    final nativeOldPath = oldPath.toNativeUtf8();
    final nativeNewPath = newPath.toNativeUtf8();
    try {
      final renameAt2 = _renameAt2;
      if (renameAt2 != null) {
        final result = renameAt2(
          _atCurrentWorkingDirectory,
          nativeOldPath,
          _atCurrentWorkingDirectory,
          nativeNewPath,
          _renameNoReplace,
        );
        if (result == 0) {
          return null;
        }
        final errorNumber = errnoLocation().value;
        if (errorNumber != _invalidArgumentError &&
            errorNumber != _functionNotImplementedError &&
            errorNumber != _operationNotSupportedError) {
          return errorNumber;
        }
      }
      if (directory || renameOnly) return _operationNotSupportedError;
      final result = link(nativeOldPath, nativeNewPath);
      return result == 0 ? null : errnoLocation().value;
    } finally {
      malloc.free(nativeOldPath);
      malloc.free(nativeNewPath);
    }
  }
}
