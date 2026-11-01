import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';

Future<BundleFormat?> chooseBundleFormat(BuildContext context) async {
  ModalRoute<BundleFormat>? route;
  final result = await showBusyApiModalDialog<BundleFormat>(
    context: context,
    onRoutePushed: (value, _) => route = value,
    builder: (_) => const _BundleFormatDialog(),
  );
  await route?.completed;
  return result;
}

class _BundleFormatDialog extends StatefulWidget {
  const _BundleFormatDialog();
  @override
  State<_BundleFormatDialog> createState() => _BundleFormatDialogState();
}

class _BundleFormatDialogState extends State<_BundleFormatDialog> {
  BundleFormat format = BundleFormat.singleFile;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return BusyApiDialogShell(
      title: l.bundleFormat,
      actions: [
        BusyApiDialogButton(
          label: l.cancel,
          onPressed: () => Navigator.pop(context),
        ),
        BusyApiDialogButton(
          label: l.chooseOutputFolder,
          suggested: true,
          onPressed: () => Navigator.pop(context, format),
        ),
      ],
      children: [
        BusyApiComboRow<BundleFormat>(
          title: l.bundleFormat,
          selected: format,
          values: BundleFormat.values,
          labelFor: (value) => value == BundleFormat.singleFile
              ? l.bundleSingleFile
              : l.bundleResourcePackage,
          onSelected: (value) => setState(() => format = value),
        ),
        Text(
          format == BundleFormat.singleFile
              ? l.bundleSingleFileHelp
              : l.bundleResourcePackageHelp,
        ),
      ],
    );
  }
}
