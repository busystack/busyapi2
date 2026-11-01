import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';

typedef ClientGenerationSelection = ({
  String generator,
  Map<String, Object?> options,
  String? templates,
});

Future<ClientGenerationSelection?> showClientGeneration(
  BuildContext context, {
  GeneratorRuntime? runtime,
}) async {
  ModalRoute<ClientGenerationSelection>? route;
  final result = await showBusyApiModalDialog<ClientGenerationSelection>(
    context: context,
    onRoutePushed: (value, _) => route = value,
    builder: (_) => _ClientGenerationDialog(runtime ?? GeneratorRuntime()),
  );
  await route?.completed;
  return result;
}

class _ClientGenerationDialog extends StatefulWidget {
  const _ClientGenerationDialog(this.runtime);
  final GeneratorRuntime runtime;
  @override
  State<_ClientGenerationDialog> createState() =>
      _ClientGenerationDialogState();
}

class _ClientGenerationDialogState extends State<_ClientGenerationDialog> {
  List<ClientGenerator> catalog = const [];
  List<GeneratorOption> options = const [];
  final values = <String, TextEditingController>{};
  String? selected, failure, templates;
  var loading = true, epoch = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final current = ++epoch;
    try {
      final available = await widget.runtime.clients(
        cancelled: () => !mounted || epoch != current,
      );
      if (!mounted || epoch != current) return;
      setState(() {
        catalog = available;
        loading = false;
      });
    } on Object catch (error) {
      if (mounted && epoch == current) {
        setState(() {
          loading = false;
          failure = error is CoreFailure ? error.code : 'generate.catalog';
        });
      }
    }
  }

  Future<void> select(String name) async {
    final current = ++epoch;
    for (final controller in values.values) {
      controller.dispose();
    }
    values.clear();
    setState(() {
      selected = name;
      loading = true;
      failure = null;
      options = const [];
    });
    try {
      final documented = await widget.runtime.options(
        name,
        cancelled: () => !mounted || epoch != current,
      );
      if (!mounted || epoch != current) return;
      for (final option in documented) {
        values[option.name] = TextEditingController();
      }
      setState(() {
        options = documented;
        loading = false;
      });
    } on Object catch (error) {
      if (mounted && epoch == current) {
        setState(() {
          loading = false;
          failure = error is CoreFailure ? error.code : 'generate.options';
        });
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    for (final value in values.values) {
      value.dispose();
    }
    super.dispose();
  }

  void apply() {
    if (selected == null ||
        loading ||
        failure != null ||
        values.values.any((c) => !c.value.composing.isCollapsed)) {
      return;
    }
    final configured = <String, Object?>{};
    for (final entry in values.entries) {
      if (entry.value.text.isEmpty) continue;
      try {
        configured[entry.key] = jsonDecode(entry.value.text);
      } on FormatException {
        configured[entry.key] = entry.value.text;
      }
    }
    Navigator.pop(context, (
      generator: selected!,
      options: configured,
      templates: templates,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return BusyApiDialogShell(
      title: l.generateClient,
      actions: [
        BusyApiDialogButton(
          label: l.cancel,
          onPressed: () => Navigator.pop(context),
        ),
        BusyApiDialogButton(
          label: l.chooseOutputFolder,
          suggested: true,
          onPressed: selected != null && !loading && failure == null
              ? apply
              : null,
        ),
      ],
      children: [
        Text(l.generatorHelp(generatorVersion)),
        if (loading) const LinearProgressIndicator(),
        if (failure != null)
          BusyApiStatusBox(
            message: l.generatorProblem(failure!),
            kind: BusyApiStatusKind.error,
          ),
        if (catalog.isNotEmpty)
          BusyApiComboRow<String>(
            title: l.generatorChoice,
            values: ['', ...catalog.map((g) => g.name)],
            selected: selected ?? '',
            labelFor: (name) => name.isEmpty
                ? l.generatorChoose
                : '${catalog.firstWhere((g) => g.name == name).name} · ${catalog.firstWhere((g) => g.name == name).stability}',
            onSelected: (name) {
              if (name.isNotEmpty) select(name);
            },
          ),
        if (options.isNotEmpty) ...[
          Text(l.generatorOptionHelp),
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: options.length,
              itemBuilder: (_, index) {
                final option = options[index];
                return BusyApiGroupedList(
                  children: [
                    BusyApiGroupedTextEntry(
                      label: option.name,
                      controller: values[option.name]!,
                      enabled: !loading,
                    ),
                    Text(
                      '${option.example ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    BusyApiPushButton.standard(
                      onPressed: () => showBusyApiModalDialog<void>(
                        context: context,
                        builder: (context) => BusyApiDialogShell(
                          title: option.name,
                          actions: [
                            BusyApiDialogButton(
                              label: l.close,
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                          children: [SelectableText(option.documentation)],
                        ),
                      ),
                      child: Text(l.generatorOptionDocumentation),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
        BusyApiActionRow(
          title: l.generatorTemplates,
          subtitle: templates,
          enabled: !loading,
          onTap: loading
              ? null
              : () async {
                  final current = epoch,
                      original = templates,
                      selected = await getDirectoryPath();
                  if (mounted &&
                      epoch == current &&
                      templates == original &&
                      selected != null) {
                    setState(() => templates = selected);
                  }
                },
        ),
        if (templates != null)
          BusyApiPushButton.standard(
            onPressed: () => setState(() => templates = null),
            child: Text(l.generatorClearTemplates),
          ),
      ],
    );
  }
}
