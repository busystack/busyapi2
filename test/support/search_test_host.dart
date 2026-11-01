import 'dart:async';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/app/busyapi_search_field.dart';
import 'package:busyapi/src/app/command_registry.dart';
import 'package:busyapi/src/workspace/search_session.dart';
import 'package:busyapi/src/workspace/search_sidebar.dart';
import 'package:flutter/material.dart';

Widget searchTestHost(
  BusyApiSearchSession session, {
  double textScale = 1,
  Future<void> Function(Map<String, dynamic>)? onReveal,
}) => MaterialApp(
  theme: buildBusyApiTheme(
    brightness: Brightness.light,
    accentColor: Colors.blue,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: Listenable.merge([session, session.workspace]),
      builder: (context, _) => Column(
        children: [
          BusyApiSearchField(
            controller: session.query,
            autofocus: true,
            focusRequest: session.focusRequest,
          ),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: BusyApiSizes.sidebarWidth,
                  child: BusyApiSearchSidebar(
                    session: session,
                    registry: BusyApiCommandRegistry(const []),
                    onReveal: onReveal ?? (_) async {},
                    run: (action) => unawaited(action()),
                  ),
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ),
    ),
  ),
);
