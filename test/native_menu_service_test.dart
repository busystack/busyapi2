// Ported BusyMark assertions, Copyright 2026 BusyStack, Apache-2.0.
import 'dart:io';

import 'package:busyapi/src/app/app_settings.dart';
import 'package:busyapi/src/app/command_registry.dart';
import 'package:busyapi/src/app/shortcut_binding.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'show serializes native menu presentation and returns its selection',
    () async {
      const channel = MethodChannel('busyapi/test/native-menu');
      MethodCall? call;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (value) async {
            call = value;
            return 2;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final session = NativeMenuSession();
      final result = await const NativeMenuService(channel: channel).show(
        session: session,
        anchor: const Rect.fromLTWH(12, 34, 56, 78),
        entries: const [
          NativeMenuEntry.command(
            label: 'Open',
            iconName: 'document-open-symbolic',
            iconColorArgb: 0xff3584e4,
            shortcut: 'Localized display',
            gtkAccelerator: '<Primary>o',
            checkable: true,
            selected: true,
            mutuallyExclusive: true,
          ),
          NativeMenuEntry.separator(),
          NativeMenuEntry.command(label: 'Disabled', enabled: false),
          NativeMenuEntry.command(
            label: 'Full Screen',
            checkable: true,
            selected: true,
          ),
        ],
        focusFirst: true,
        preferAbove: true,
      );

      expect(result.available, isTrue);
      expect(result.selectedIndex, 2);
      expect(call?.method, 'show');
      expect(call?.arguments, {
        'sessionId': session.id,
        'anchor': {'x': 12.0, 'y': 34.0, 'width': 56.0, 'height': 78.0},
        'entries': [
          {
            'label': 'Open',
            'icon': 'document-open-symbolic',
            'iconColor': 0xff3584e4,
            'shortcut': 'Localized display',
            'gtkAccelerator': '<Primary>o',
            'enabled': true,
            'checkable': true,
            'selected': true,
            'mutuallyExclusive': true,
            'separator': false,
          },
          {
            'label': '',
            'enabled': false,
            'checkable': false,
            'selected': false,
            'mutuallyExclusive': false,
            'separator': true,
          },
          {
            'label': 'Disabled',
            'enabled': false,
            'checkable': false,
            'selected': false,
            'mutuallyExclusive': false,
            'separator': false,
          },
          {
            'label': 'Full Screen',
            'enabled': true,
            'checkable': true,
            'selected': true,
            'mutuallyExclusive': false,
            'separator': false,
          },
        ],
        'focusFirst': true,
        'preferredPosition': 'top',
      });
    },
  );

  test('dismiss is scoped to the native menu session', () async {
    const channel = MethodChannel('busyapi/test/native-menu-dismiss');
    MethodCall? call;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (value) async {
          call = value;
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final session = NativeMenuSession();
    final dismissed = await const NativeMenuService(channel: channel)
        .dismiss(session);

    expect(dismissed, isTrue);
    expect(call?.method, 'dismiss');
    expect(call?.arguments, {'sessionId': session.id});
  });

  test(
    'missing native host reports unavailable for a themed fallback',
    () async {
      const channel = MethodChannel('busyapi/test/native-menu-missing');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw MissingPluginException(),
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final result = await const NativeMenuService(channel: channel).show(
        session: NativeMenuSession(),
        anchor: Rect.zero,
        entries: const [NativeMenuEntry.command(label: 'Fallback')],
      );

      expect(result.available, isFalse);
      expect(result.selectedIndex, isNull);
    },
  );
  test('U5 Send binding persistence retains modifiers and refuses unmodified Enter', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-send-binding-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final locations = StateLocations(
      config: directory.path,
      state: directory.path,
      cache: directory.path,
    );
    expect(busyApiDefaultKeyBindings['request-send']!.label, 'Ctrl+Enter');
    for (final binding in [
      const BusyApiKeyBinding(
        LogicalKeyboardKey.enter,
        control: true,
        shift: true,
      ),
      const BusyApiKeyBinding(LogicalKeyboardKey.enter, alt: true),
    ]) {
      await BusyApiRequestShortcut.save(locations, binding);
      final loaded = await BusyApiRequestShortcut.load(locations);
      expect(loaded!.toJson(), binding.toJson());
    }
    await BusyApiRequestShortcut.save(
      locations,
      const BusyApiKeyBinding(LogicalKeyboardKey.enter),
    );
    expect(await BusyApiRequestShortcut.load(locations), isNull);
  });
}
