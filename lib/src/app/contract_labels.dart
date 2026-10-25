import 'package:flutter/widgets.dart';

import 'localization.dart';

/// Presentation only. Source locations and edit plans keep the complete value.
String contractIdentityLabel(String value, {int limit = 480}) {
  if (value.length <= limit) return value;
  final end =
      value.codeUnitAt(limit - 1) >= 0xd800 &&
          value.codeUnitAt(limit - 1) <= 0xdbff
      ? limit - 1
      : limit;
  return '${value.substring(0, end)}…';
}

/// Authored keyword names remain recognizable; ordinary concepts use the
/// same localized labels in native authoring and read-only documentation.
String contractFieldLabel(BuildContext context, String key) => switch (key) {
  '' => context.l10n.emptyObjectName,
  'title' => context.l10n.title,
  'version' => context.l10n.apiVersion,
  'summary' => context.l10n.summary,
  'description' => context.l10n.description,
  'name' => context.l10n.name,
  'type' => context.l10n.type,
  'required' => context.l10n.required,
  'parameters' => context.l10n.parameters,
  'responses' => context.l10n.responses,
  'properties' => context.l10n.properties,
  'schemas' => context.l10n.schemas,
  'contact' => context.l10n.contact,
  'license' => context.l10n.license,
  'servers' => context.l10n.servers,
  'security' => context.l10n.security,
  'tags' => context.l10n.tags,
  'requestBody' => context.l10n.requestBody,
  'headers' => context.l10n.headers,
  'examples' => context.l10n.examples,
  'example' => context.l10n.example,
  'callbacks' => context.l10n.callbacks,
  _ => context.l10n.specificationField(key),
};
