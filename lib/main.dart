import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yaru/yaru.dart';
import 'package:busyapi_core/busyapi_core.dart';

import 'src/app/busyapi_app.dart';
import 'src/app/app_settings.dart';
import 'src/app/system_accent.dart';
import 'src/platform/gtk_animation_settings_service.dart';
import 'src/platform/gtk_window_preferences_service.dart';
import 'src/platform/gtk_header_icon_service.dart';
import 'src/platform/linux_gtk_accent_service.dart';
import 'src/workspace/workspace_controller.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await YaruWindow.ensureInitialized();
  final accent = LinuxAccentCoordinator(
    sources: [const LinuxGtkAccentService(), const LinuxPortalAppearance()],
  );
  await accent.initialize();
  final chrome = await Future.wait<Object?>([
    const GtkAnimationSettingsService().getAnimationsEnabled(),
    const GtkWindowPreferencesService().load(),
  ]);
  final icons = GtkHeaderIconService();
  await icons.initialize();
  final core = WorkspaceController(
    EngineProcess.bundled(),
    StateLocations.xdg(),
  );
  await core.initialize();
  final appearance = await BusyApiAppearance.load(core.locations);
  runApp(
    ProviderScope(
      overrides: [
        initialGtkAnimationsEnabledProvider.overrideWithValue(
          chrome[0] as bool?,
        ),
        initialGtkWindowPreferencesProvider.overrideWithValue(
          chrome[1] as GtkWindowPreferences?,
        ),
        gtkHeaderIconServiceProvider.overrideWith((ref) {
          ref.onDispose(icons.dispose);
          return icons;
        }),
        initialSystemAccentColorProvider.overrideWithValue(accent.color),
        linuxAccentCoordinatorProvider.overrideWith((ref) {
          ref.onDispose(() => unawaited(accent.dispose()));
          return accent;
        }),
      ],
      child: BusyApiApp(
        controller: core,
        initialAppearance: appearance,
        startupPath: args.isEmpty ? null : args.first,
      ),
    ),
  );
}
