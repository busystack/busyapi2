import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart'
    show contentIdentity, RunCancellation;
import 'package:flutter/services.dart';

enum SecretPersistence { persistent, sessionOnly }

class SecretStoreFailure implements Exception {
  const SecretStoreFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}

abstract interface class BusyApiSecretStore {
  Future<String?> read(String reference);
  Future<void> write(String reference, String value);
  Future<void> delete(String reference);
}

abstract interface class BusyApiSecretAvailability {
  Future<SecretAvailability> availability(String reference);
}

class LibsecretBusyApiSecretStore
    implements BusyApiSecretStore, BusyApiSecretAvailability {
  const LibsecretBusyApiSecretStore({
    this.channel = const MethodChannel('com.busyapi.app/secure_credentials'),
  });
  final MethodChannel channel;

  static final _reference = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static bool validValue(String value) =>
      value.isNotEmpty &&
      utf8.encode(value).length <= 64 * 1024 &&
      !value.contains('\u0000');
  static String key(String reference) {
    if (!_reference.hasMatch(reference)) {
      throw const SecretStoreFailure(
        'secret.reference',
        'Use a canonical BusyAPI v4 secret reference',
      );
    }
    return 'busyapi.request.secret.$reference';
  }

  @override
  Future<SecretAvailability> availability(String reference) async {
    try {
      final result = await channel.invokeMethod<String>('availability', {
        'key': key(reference),
      });
      return switch (result) {
        'persistent' => SecretAvailability.persistent,
        'missing' => SecretAvailability.missing,
        'locked' => SecretAvailability.locked,
        _ => SecretAvailability.unknown,
      };
    } on PlatformException {
      return SecretAvailability.unavailable;
    } on MissingPluginException {
      return SecretAvailability.unknown;
    }
  }

  @override
  Future<String?> read(String reference) async {
    try {
      final result = await channel.invokeMethod<String>('read', {
        'key': key(reference),
      });
      if (result != null &&
          (result.isEmpty ||
              utf8.encode(result).length > 64 * 1024 ||
              result.contains('\u0000'))) {
        throw const SecretStoreFailure(
          'secret.value',
          'Stored credential is empty or too large',
        );
      }
      return result;
    } on SecretStoreFailure {
      rethrow;
    } on PlatformException catch (error) {
      throw SecretStoreFailure(
        'secret.persistence.unavailable',
        error.message ?? 'Secret Service is unavailable',
      );
    } on MissingPluginException {
      throw const SecretStoreFailure(
        'secret.persistence.unavailable',
        'Secret Service integration is unavailable',
      );
    }
  }

  @override
  Future<void> write(String reference, String value) async {
    if (value.isEmpty ||
        utf8.encode(value).length > 64 * 1024 ||
        value.contains('\u0000')) {
      throw const SecretStoreFailure(
        'secret.value',
        'Credential is empty or too large',
      );
    }
    try {
      await channel.invokeMethod<void>('write', {
        'key': key(reference),
        'value': value,
      });
    } on PlatformException catch (error) {
      throw SecretStoreFailure(
        'secret.persistence.unavailable',
        error.message ?? 'Secret Service is unavailable',
      );
    } on MissingPluginException {
      throw const SecretStoreFailure(
        'secret.persistence.unavailable',
        'Secret Service integration is unavailable',
      );
    }
  }

  @override
  Future<void> delete(String reference) async {
    try {
      await channel.invokeMethod<void>('delete', {'key': key(reference)});
    } on PlatformException catch (error) {
      throw SecretStoreFailure(
        'secret.persistence.unavailable',
        error.message ?? 'Secret Service is unavailable',
      );
    } on MissingPluginException {
      throw const SecretStoreFailure(
        'secret.persistence.unavailable',
        'Secret Service integration is unavailable',
      );
    }
  }
}

class SessionBusyApiSecretStore implements BusyApiSecretStore {
  final Map<String, String> _values = {};
  @override
  Future<String?> read(String reference) async => _values[reference];
  @override
  Future<void> write(String reference, String value) async {
    LibsecretBusyApiSecretStore.key(reference);
    if (value.isEmpty ||
        utf8.encode(value).length > 64 * 1024 ||
        value.contains('\u0000')) {
      throw const SecretStoreFailure(
        'secret.value',
        'Credential is empty or too large',
      );
    }
    _values[reference] = value;
  }

  @override
  Future<void> delete(String reference) async {
    _values.remove(reference);
  }

  void clear() => _values.clear();
}

enum SecretAvailability {
  unknown,
  loading,
  persistent,
  session,
  missing,
  locked,
  unavailable,
}

class OAuthCredentialMetadata {
  const OAuthCredentialMetadata({
    required this.valueIdentity,
    required this.scopes,
    this.expiresAt,
  });
  final String valueIdentity;
  final List<String> scopes;
  final DateTime? expiresAt;
  bool get expired =>
      expiresAt != null && !DateTime.now().toUtc().isBefore(expiresAt!);
}

class EnvironmentSecretStore {
  EnvironmentSecretStore({
    BusyApiSecretStore? persistent,
    SessionBusyApiSecretStore? session,
  }) : persistent = persistent ?? const LibsecretBusyApiSecretStore(),
       session = session ?? SessionBusyApiSecretStore();
  final BusyApiSecretStore persistent;
  final SessionBusyApiSecretStore session;
  final Map<String, SecretPersistence> _locations = {};
  final Map<String, SecretAvailability> _availability = {};
  final Map<(String, SecretPersistence), OAuthCredentialMetadata> _oauth = {};
  final Map<String, int> _versions = {};
  int _epoch = 0;
  final Map<String, Future<void>> _mutations = {};
  Future<void> _serial(String reference, Future<void> Function() action) {
    final previous = _mutations[reference] ?? Future<void>.value();
    final pending = previous.then<void>(
      (_) => action(),
      onError: (Object _, StackTrace _) => action(),
    );
    _mutations[reference] = pending;
    void completed() {
      if (identical(_mutations[reference], pending)) {
        _mutations.remove(reference);
      }
    }

    pending.then<void>(
      (_) => completed(),
      onError: (Object _, StackTrace _) => completed(),
    );
    return pending;
  }

  SecretAvailability availability(String reference) =>
      _locations[reference] == SecretPersistence.sessionOnly
      ? SecretAvailability.session
      : _availability[reference] ?? SecretAvailability.unknown;
  OAuthCredentialMetadata? metadata(String reference) =>
      _oauth[(
        reference,
        _locations[reference] ?? SecretPersistence.persistent,
      )];
  void rememberOAuth(
    String reference,
    String value,
    List<String> scopes,
    DateTime? expiresAt,
  ) {
    _oauth[(
      reference,
      _locations[reference] ?? SecretPersistence.sessionOnly,
    )] = OAuthCredentialMetadata(
      valueIdentity: contentIdentity(utf8.encode(value)),
      scopes: List.unmodifiable(scopes),
      expiresAt: expiresAt,
    );
  }

  Future<void> checkAvailability(String reference) async {
    if (_locations[reference] == SecretPersistence.sessionOnly) return;
    final backend = persistent;
    if (backend is! BusyApiSecretAvailability) return;
    final epoch = _epoch, version = _versions[reference];
    _availability[reference] = SecretAvailability.loading;
    final result = await (backend as BusyApiSecretAvailability).availability(
      reference,
    );
    if (_epoch == epoch &&
        _versions[reference] == version &&
        _locations[reference] != SecretPersistence.sessionOnly) {
      _availability[reference] = result;
    }
  }

  Future<void> deletePersistent(String reference) {
    LibsecretBusyApiSecretStore.key(reference);
    final epoch = _epoch, version = (_versions[reference] ?? 0) + 1;
    _versions[reference] = version;
    return _serial(reference, () async {
      await persistent.delete(reference);
      if (epoch != _epoch || version != _versions[reference]) return;
      _oauth.remove((reference, SecretPersistence.persistent));
      if (_locations[reference] != SecretPersistence.sessionOnly) {
        _locations.remove(reference);
        _availability[reference] = SecretAvailability.missing;
      }
    });
  }

  Future<void> clearOverride(String reference) {
    LibsecretBusyApiSecretStore.key(reference);
    final epoch = _epoch, version = (_versions[reference] ?? 0) + 1;
    _versions[reference] = version;
    return _serial(reference, () async {
      await session.delete(reference);
      if (epoch != _epoch || version != _versions[reference]) return;
      _oauth.remove((reference, SecretPersistence.sessionOnly));
      _locations.remove(reference);
      _availability.remove(reference);
    });
  }

  SecretPersistence? status(String reference) => _locations[reference];
  Future<void> write(
    String reference,
    String value, {
    required SecretPersistence persistence,
  }) async {
    LibsecretBusyApiSecretStore.key(reference);
    if (value.isEmpty ||
        utf8.encode(value).length > 64 * 1024 ||
        value.contains('\u0000')) {
      throw const SecretStoreFailure(
        'secret.value',
        'Enter a non-empty credential of at most 64 KiB, without NUL characters.',
      );
    }
    final epoch = _epoch, version = (_versions[reference] ?? 0) + 1;
    _versions[reference] = version;
    final store = persistence == SecretPersistence.persistent
        ? persistent
        : session;
    await _serial(reference, () async {
      if (epoch != _epoch) {
        throw const SecretStoreFailure(
          'secret.stale',
          'Credential ownership changed; enter the value again deliberately.',
        );
      }
      await store.write(reference, value);
      if (epoch != _epoch || version != _versions[reference]) return;
      _oauth.remove((reference, persistence));
      _locations[reference] = persistence;
      _availability[reference] = persistence == SecretPersistence.persistent
          ? SecretAvailability.persistent
          : SecretAvailability.session;
    });
  }

  Future<String?> read(
    String reference, {
    RunCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final epoch = _epoch, version = _versions[reference];
    final selected = _locations[reference] ?? SecretPersistence.persistent;
    try {
      final value =
          await (selected == SecretPersistence.sessionOnly
                  ? session
                  : persistent)
              .read(reference);
      cancellation?.throwIfCancelled();
      if (epoch != _epoch || version != _versions[reference]) {
        throw const SecretStoreFailure(
          'secret.stale',
          'Credential ownership changed; send again deliberately.',
        );
      }
      _availability[reference] = value == null
          ? SecretAvailability.missing
          : selected == SecretPersistence.sessionOnly
          ? SecretAvailability.session
          : SecretAvailability.persistent;
      final metadata = _oauth[(reference, selected)];
      if (metadata != null) {
        if (value == null ||
            metadata.valueIdentity != contentIdentity(utf8.encode(value))) {
          _oauth.remove((reference, selected));
        } else if (metadata.expired) {
          throw const SecretStoreFailure(
            'oauth.expired',
            'This credential has expired. Authorize again, then explicitly Send.',
          );
        }
      }
      return value;
    } on SecretStoreFailure catch (error) {
      // A detached cancelled read no longer owns availability, including errors.
      if (cancellation?.cancelled != true &&
          epoch == _epoch &&
          version == _versions[reference] &&
          error.code.startsWith('secret.persistence')) {
        _availability[reference] = SecretAvailability.unavailable;
      }
      rethrow;
    }
  }

  Future<void> delete(String reference) async {
    final selected = _locations[reference];
    await clearOverride(reference);
    try {
      await deletePersistent(reference);
    } on SecretStoreFailure {
      if (selected == SecretPersistence.persistent) rethrow;
    }
  }

  void clearSession() {
    ++_epoch;
    _oauth.removeWhere((key, _) => key.$2 == SecretPersistence.sessionOnly);
    _availability.removeWhere(
      (_, value) =>
          value == SecretAvailability.session ||
          value == SecretAvailability.loading,
    );
    session.clear();
    _locations.removeWhere(
      (_, value) => value == SecretPersistence.sessionOnly,
    );
  }
}
