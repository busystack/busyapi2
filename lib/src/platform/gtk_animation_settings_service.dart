// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// Modified for BusyAPI namespaces and contract authoring.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bridges GTK's `gtk-enable-animations` setting into Flutter.
class GtkAnimationSettingsService {
  const GtkAnimationSettingsService({
    this._channel = _settingsChannel,
    this._events = _eventsChannel,
  });

  static const _settingsChannel = MethodChannel('com.busyapi.app/linux_chrome');
  static const _eventsChannel = EventChannel(
    'com.busyapi.app/gtk_animation_settings',
  );

  final MethodChannel _channel;
  final EventChannel _events;

  Future<bool?> getAnimationsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('getGtkAnimationsEnabled');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Stream<bool?> watchAnimationsEnabled() async* {
    try {
      await for (final value in _events.receiveBroadcastStream()) {
        yield value is bool ? value : null;
      }
    } on MissingPluginException {
      yield null;
    } on PlatformException {
      yield null;
    }
  }
}

final initialGtkAnimationsEnabledProvider = Provider<bool?>((ref) => null);

final gtkAnimationsEnabledProvider = StreamProvider<bool?>((ref) async* {
  var previous = ref.watch(initialGtkAnimationsEnabledProvider);
  yield previous;
  // Linux bootstrap supplies a concrete initial value only when the native
  // bridge exists. Avoid activating an EventChannel on widget-test and
  // non-Linux engines where no plugin is registered.
  if (previous == null) return;
  await for (final value
      in const GtkAnimationSettingsService().watchAnimationsEnabled()) {
    if (value == previous) continue;
    previous = value;
    yield value;
  }
});
