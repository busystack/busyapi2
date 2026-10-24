import 'package:busyapi/src/platform/secret_store.dart';
import 'package:busyapi_core/busyapi_core.dart' show RunCancellation;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('busyapi/test/secure_credentials');
  const reference = '123e4567-e89b-42d3-a456-426614174000';

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('bridge accepts only BusyAPI-owned canonical key identities', () {
    expect(
      LibsecretBusyApiSecretStore.key(reference),
      'busyapi.request.secret.$reference',
    );
    for (final invalid in [
      'contract-auth-token',
      '../arbitrary-keyring-entry',
      '123e4567-e89b-12d3-a456-426614174000',
      '123E4567-E89B-42D3-A456-426614174000',
    ]) {
      expect(
        () => LibsecretBusyApiSecretStore.key(invalid),
        throwsA(
          isA<SecretStoreFailure>().having(
            (error) => error.code,
            'code',
            'secret.reference',
          ),
        ),
      );
    }
  });

  test('disconnected Secret Service stays explicit while session-only secrets work and clear', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'locked', message: 'locked');
        });
    final persistent = LibsecretBusyApiSecretStore(channel: channel);
    final store = EnvironmentSecretStore(persistent: persistent);
    await expectLater(
      store.write(
        reference,
        'never-plaintext',
        persistence: SecretPersistence.persistent,
      ),
      throwsA(
        isA<SecretStoreFailure>().having(
          (error) => error.code,
          'code',
          'secret.persistence.unavailable',
        ),
      ),
    );
    expect(store.status(reference), isNull);
    await store.write(
      reference,
      'synthetic-session-value',
      persistence: SecretPersistence.sessionOnly,
    );
    expect(store.status(reference), SecretPersistence.sessionOnly);
    expect(await store.read(reference), 'synthetic-session-value');
    store.clearSession();
    expect(store.status(reference), isNull);
    await expectLater(
      store.read(reference),
      throwsA(isA<SecretStoreFailure>()),
    );
  });

  test('persistent operations send only scoped keys and never expose a fallback value', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'read') return 'synthetic-persistent-value';
          return null;
        });
    const store = LibsecretBusyApiSecretStore(channel: channel);
    await store.write(reference, 'synthetic-persistent-value');
    expect(await store.read(reference), 'synthetic-persistent-value');
    await store.delete(reference);
    expect(calls.map((call) => call.method), ['write', 'read', 'delete']);
    for (final call in calls) {
      final arguments = call.arguments as Map;
      expect(arguments['key'], 'busyapi.request.secret.$reference');
      if (call.method != 'write') expect(arguments.containsKey('value'), false);
    }
  });
  test('H18 metadata-only availability discovers a stored credential without reading it', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'availability') return 'persistent';
          if (call.method == 'read') return 'stored-token';
          return null;
        });
    final store = EnvironmentSecretStore(
      persistent: const LibsecretBusyApiSecretStore(channel: channel),
    );
    expect(store.availability(reference), SecretAvailability.unknown);
    await store.checkAvailability(reference);
    expect(store.availability(reference), SecretAvailability.persistent);
    expect(calls, ['availability']);
    await store.write(
      reference,
      'session-token',
      persistence: SecretPersistence.sessionOnly,
    );
    expect(await store.read(reference), 'session-token');
    await store.clearOverride(reference);
    expect(await store.read(reference), 'stored-token');
    expect(calls, isNot(contains('delete')));
  });

  test('F06 cancelled persistent-read errors preserve newer availability', () async {
    for (final cancelRead in [true, false]) {
      final entered = Completer<void>(), release = Completer<String?>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'availability') return 'persistent';
            if (call.method == 'read') {
              entered.complete();
              return release.future;
            }
            return null;
          });
      final store = EnvironmentSecretStore(
        persistent: const LibsecretBusyApiSecretStore(channel: channel),
      );
      final cancellation = RunCancellation();
      final read = store.read(reference, cancellation: cancellation);
      await entered.future;
      if (cancelRead) cancellation.cancel();
      await store.checkAvailability(reference);
      expect(store.availability(reference), SecretAvailability.persistent);
      final settled = expectLater(
        read,
        throwsA(
          isA<SecretStoreFailure>().having(
            (error) => error.code,
            'code',
            'secret.persistence.unavailable',
          ),
        ),
      );
      // Exercise the production bridge conversion, not an unrelated StateError.
      release.completeError(
        PlatformException(
          code: 'unavailable',
          message: 'Synthetic backend failure',
        ),
      );
      await settled;
      expect(
        store.availability(reference),
        cancelRead
            ? SecretAvailability.persistent
            : SecretAvailability.unavailable,
      );
      expect(calls, ['read', 'availability']);
    }
  });

  test(
    'H16 credential metadata follows value and persistence version',
    () async {
      final persistent = SessionBusyApiSecretStore();
      final store = EnvironmentSecretStore(persistent: persistent);
      await store.write(
        reference,
        'stored-token',
        persistence: SecretPersistence.persistent,
      );
      store.rememberOAuth(reference, 'stored-token', [
        'read',
      ], DateTime.now().toUtc().add(const Duration(hours: 1)));
      await store.write(
        reference,
        'session-token',
        persistence: SecretPersistence.sessionOnly,
      );
      expect(store.metadata(reference), isNull);
      store.rememberOAuth(reference, 'session-token', [
        'write',
      ], DateTime.now().toUtc().subtract(const Duration(seconds: 1)));
      await expectLater(
        store.read(reference),
        throwsA(
          isA<SecretStoreFailure>().having(
            (e) => e.code,
            'code',
            'oauth.expired',
          ),
        ),
      );
      await store.clearOverride(reference);
      expect(await store.read(reference), 'stored-token');
      expect(store.metadata(reference)!.scopes, ['read']);
      await store.write(
        reference,
        'replacement',
        persistence: SecretPersistence.persistent,
      );
      expect(store.metadata(reference), isNull);
      expect(await store.read(reference), 'replacement');
      await expectLater(
        store.write(reference, '', persistence: SecretPersistence.sessionOnly),
        throwsA(
          isA<SecretStoreFailure>().having(
            (e) => e.code,
            'code',
            'secret.value',
          ),
        ),
      );
      expect(await store.read(reference), 'replacement');
    },
  );

  test(
    'H18 delayed availability cannot replace a newer session override',
    () async {
      final pending = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async =>
                call.method == 'availability' ? pending.future : null,
          );
      final store = EnvironmentSecretStore(
        persistent: const LibsecretBusyApiSecretStore(channel: channel),
      );
      final lookup = store.checkAvailability(reference);
      await store.write(
        reference,
        ' newer value ',
        persistence: SecretPersistence.sessionOnly,
      );
      pending.complete('missing');
      await lookup;
      expect(store.availability(reference), SecretAvailability.session);
      expect(await store.read(reference), ' newer value ');
    },
  );
  test(
    'H18 delayed writes are serialized and cannot overwrite a newer credential',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final writes = <String>[];
      String? stored;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'write') {
              final value = (call.arguments as Map)['value'] as String;
              writes.add(value);
              if (writes.length == 1) {
                entered.complete();
                await release.future;
              }
              stored = value;
            }
            if (call.method == 'read') return stored;
            return null;
          });
      final store = EnvironmentSecretStore(
        persistent: const LibsecretBusyApiSecretStore(channel: channel),
      );
      final first = store.write(
        reference,
        'older',
        persistence: SecretPersistence.persistent,
      );
      await entered.future;
      final second = store.write(
        reference,
        'newer',
        persistence: SecretPersistence.persistent,
      );
      expect(writes, ['older']);
      release.complete();
      await Future.wait([first, second]);
      expect(writes, ['older', 'newer']);
      expect(await store.read(reference), 'newer');
      expect(store.status(reference), SecretPersistence.persistent);
    },
  );
}
