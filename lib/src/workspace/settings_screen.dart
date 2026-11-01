// Adapted from BusyMark's SettingsScreen, navigation and theme controls.
// Copyright 2026 BusyStack (Apache-2.0). BusyAPI settings only.
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/busyapi_motion_widgets.dart';
import '../app/busyapi_search_field.dart';
import '../app/linux/linux_header_style.dart';
import '../app/localization.dart';
import '../app/linux/linux_page_frame.dart';

class BusyApiSettingsScreen extends StatefulWidget {
  const BusyApiSettingsScreen({
    super.key,
    required this.mode,
    required this.onThemeChanged,
    required this.onBack,
    required this.projectSettings,
    this.appearanceFailure,
    this.appearanceEnabled = true,
    this.menu,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final VoidCallback onBack;
  final Widget projectSettings;
  final Object? appearanceFailure;
  final bool appearanceEnabled;
  final Widget? menu;
  @override
  State<BusyApiSettingsScreen> createState() => _BusyApiSettingsScreenState();
}

class _BusyApiSettingsScreenState extends State<BusyApiSettingsScreen> {
  int page = 0;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final labels = [l.appearance, l.projectSettings];
    final icons = [BusyApiGlyphs.appearance, BusyApiGlyphs.folder];
    String themeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => l.system,
      ThemeMode.light => l.light,
      ThemeMode.dark => l.dark,
    };
    final themeControl = BusyApiPopupSelector<ThemeMode>(
      value: widget.mode,
      label: themeLabel(widget.mode),
      tooltip: l.theme,
      options: [
        for (final mode in ThemeMode.values)
          BusyApiPopupSelectorOption(value: mode, label: themeLabel(mode)),
      ],
      onSelected: widget.onThemeChanged,
      enabled: widget.appearanceEnabled,
    );
    final appearance = BusyApiGroupedList(
      title: l.appearance,
      filled: true,
      children: [
        LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth < BusyApiSizes.settingsControlBreakpoint
              ? Padding(
                  padding: const EdgeInsets.all(BusyApiSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(icons[0]),
                          const SizedBox(width: BusyApiSpacing.md),
                          Text(l.theme),
                        ],
                      ),
                      const SizedBox(height: BusyApiSpacing.sm),
                      themeControl,
                    ],
                  ),
                )
              : BusyApiActionRow(
                  title: l.theme,
                  leading: Icon(icons[0]),
                  trailing: SizedBox(
                    width: BusyApiSizes.controlRowWidth,
                    child: themeControl,
                  ),
                ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= BusyApiSizes.settingsSidebarBreakpoint;
        return BusyApiLocalTextEditingShortcuts(
          child: Scaffold(
            backgroundColor: BusyApiSurfaceColors.of(context).view,
            body: LinuxPageFrame(
              header: BusyApiLinuxHeaderLayout(
                trailing: BusyApiLinuxHeaderControlGroup(
                  children: [if (widget.menu != null) widget.menu!],
                ),
                leading: BusyApiLinuxHeaderControlGroup(
                  children: [
                    BusyApiLinuxHeaderIconButton(
                      tooltip: l.navigationBack,
                      icon: BusyApiGlyphs.headerBackFor(
                        Directionality.of(context),
                      ),
                      onPressed: widget.onBack,
                    ),
                  ],
                ),
                title: BusyApiLinuxHeaderTitle(labels[page]),
              ),
              sidebarHeader: const BusyApiLinuxBrandHeader(),
              sidebarAvailable: wide,
              sidebarExpanded: true,
              sidebarBody: BusyApiSidebarSurface(
                showEndBorder: false,
                child: BusyApiSidebarNavigation(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      BusyApiSidebarNavigationTile(
                        key: ValueKey('settings-navigation-$i'),
                        selected: page == i,
                        title: Text(labels[i]),
                        leading: Icon(icons[i]),
                        onTap: () => setState(() => page = i),
                      ),
                  ],
                ),
              ),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!wide)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        BusyApiSpacing.lg,
                        BusyApiSpacing.md,
                        BusyApiSpacing.lg,
                        0,
                      ),
                      child: BusyApiPopupSelector<int>(
                        value: page,
                        label: labels[page],
                        leading: Icon(icons[page]),
                        tooltip: l.settings,
                        fullWidth: true,
                        options: [
                          for (var i = 0; i < labels.length; i++)
                            BusyApiPopupSelectorOption(
                              value: i,
                              label: labels[i],
                              icon: icons[i],
                            ),
                        ],
                        onSelected: (value) => setState(() => page = value),
                      ),
                    ),
                  if (widget.appearanceFailure != null)
                    BusyApiStatusBox(
                      message: l.appearancePersistenceFailed,
                      kind: BusyApiStatusKind.error,
                    ),
                  Expanded(
                    child: BusyApiClamp(
                      maxWidth: BusyApiSizes.settingsWidth,
                      margin: EdgeInsets.zero,
                      padding: BusyApiInsets.settingsPage,
                      child: BusyApiKeyedCrossfade(
                        transitionKey: page,
                        child: page == 0 ? appearance : widget.projectSettings,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
