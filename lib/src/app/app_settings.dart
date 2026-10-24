// Startup settings pattern adapted from BusyMark's app_settings.dart.
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'shortcut_binding.dart';

class BusyApiAppearance {
  const BusyApiAppearance({this.mode = ThemeMode.system, this.failure});
  final ThemeMode mode;
  final Object? failure;

  static Future<BusyApiAppearance> load(StateLocations locations) async {
    try {
      final file = File(p.join(locations.config, 'appearance.json'));
      if (!await file.exists()) return const BusyApiAppearance();
      final value = jsonDecode(await file.readAsString());
      return BusyApiAppearance(mode: ThemeMode.values.byName(value['theme']));
    } on Object catch (error) {
      return BusyApiAppearance(failure: error);
    }
  }

  static Future<void> save(StateLocations locations, ThemeMode mode) =>
      writePrivateJson(p.join(locations.config, 'appearance.json'), {
        'theme': mode.name,
      });
}

class BusyApiRequestShortcut {
  static Future<BusyApiKeyBinding?> load(StateLocations locations) async {
    final file = File(p.join(locations.config, 'request-shortcut.json'));
    if (!await file.exists()) return null;
    if (await file.length() > 4096) {
      throw CoreFailure(
        'settings.shortcut',
        'The request shortcut setting exceeds its bound.',
      );
    }
    final binding = BusyApiKeyBinding.fromJson(
      jsonDecode(await file.readAsString()),
    );
    return binding?.key == LogicalKeyboardKey.enter &&
            (binding!.control || binding.alt || binding.meta)
        ? binding
        : null;
  }

  static Future<void> save(
    StateLocations locations,
    BusyApiKeyBinding binding,
  ) => writePrivateJson(
    p.join(locations.config, 'request-shortcut.json'),
    binding.toJson(),
  );
}
