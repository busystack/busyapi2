import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';

String documentationWindowFailure(AppLocalizations l, String code) =>
    switch (code) {
      'documentation.host.module' => l.documentationModuleUnavailable,
      'documentation.host.runtime' => l.documentationRuntimeUnavailable,
      _ => l.documentationFailed(code),
    };

Map<String, String> documentationLabels(AppLocalizations l) => {
  'title': l.reference,
  'loading': l.documentationLoading,
  'failure': l.documentationFailed('renderer-failed'),
  'source': l.sourceLink,
  'sourceOwner': l.documentationSourceOwner,
  'schemas': l.schemas,
  'previousPage': l.searchPreviousPage,
  'nextPage': l.searchNextPage,
  'page': l.documentationPage('{page}', '{pages}'),
  'definition': l.referenceReadDefinition,
  'dynamicReference': l.documentationDynamicTargets,
  'inherited': l.inherited,
  'webhooks': l.webhooks,
};

Future<String?> chooseDocumentationPreset(BuildContext context) async {
  ModalRoute<String>? route;
  final result = await showBusyApiModalDialog<String>(
    context: context,
    onRoutePushed: (value, _) => route = value,
    builder: (_) => const _DocumentationPresetDialog(),
  );
  await route?.completed;
  return result;
}

class _DocumentationPresetDialog extends StatefulWidget {
  const _DocumentationPresetDialog();
  @override
  State<_DocumentationPresetDialog> createState() =>
      _DocumentationPresetDialogState();
}

class _DocumentationPresetDialogState
    extends State<_DocumentationPresetDialog> {
  String preset = 'native-reference';
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return BusyApiDialogShell(
      title: l.documentationPreset,
      actions: [
        BusyApiDialogButton(
          label: l.cancel,
          onPressed: () => Navigator.pop(context),
        ),
        BusyApiDialogButton(
          label: l.chooseOutputFolder,
          suggested: true,
          onPressed: () => Navigator.pop(context, preset),
        ),
      ],
      children: [
        BusyApiComboRow<String>(
          title: l.documentationPreset,
          selected: preset,
          values: const ['native-reference', 'redoc', 'swagger'],
          labelFor: (value) => switch (value) {
            'redoc' => l.redocPreset,
            'swagger' => l.swaggerPreset,
            _ => l.nativeReferencePreset,
          },
          onSelected: (value) => setState(() => preset = value),
        ),
      ],
    );
  }
}
