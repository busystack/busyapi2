import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/localization.dart';
import 'request_run.dart';

class RequestPartMediaEditor extends StatelessWidget {
  const RequestPartMediaEditor({super.key, required this.run});
  final RequestRunController run;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final options = run.plan!.formMediaOptions(run.bodyMediaType);
    final names = options.map((option) => option.name).toSet();
    final enabled = !run.busy && !run.hasComposingInput;
    return Column(
      children: [
        for (final option in options) ...[
          if (option.error != null)
            BusyApiStatusBox(message: '${option.name}: ${option.error}')
          else if (!option.styled) ...[
            if (option.requiresChoice ||
                run.partMediaTypes.containsKey(option.name))
              BusyApiComboRow<String?>(
                title: '${option.name} · Content-Type',
                subtitle: option.contentTypes.join(', '),
                values: {
                  null,
                  ...option.concreteTypes,
                  if (run.partMediaTypes[option.name]
                      case final String selected)
                    selected,
                }.toList(),
                selected: run.partMediaTypes[option.name],
                labelFor: (type) => type ?? l.requestPartMediaChoose,
                enabled: enabled,
                onSelected: (type) => run.selectPartMedia(option.name, type),
              )
            else
              BusyApiActionRow(
                title: option.name,
                subtitle: option.contentTypes.join(', '),
              ),
            if (option.allowsCustom)
              RequestDraftEntry(
                run: run,
                key: ValueKey(
                  'part-media/${run.plan!.identity}/${run.bodyMediaType}/${option.name}',
                ),
                label: '${option.name} · ${l.requestPartMediaConcrete}',
                value: run.partMediaTypes[option.name] ?? '',
                enabled: !run.busy,
                onChanged: (type) => run.selectPartMedia(option.name, type),
              ),
          ],
          if (option.styled && run.partMediaTypes.containsKey(option.name))
            BusyApiActionRow(
              title: '${option.name} · ${run.partMediaTypes[option.name]}',
              subtitle: l.requestPartMediaStale,
              enabled: enabled,
              onTap: () => run.selectPartMedia(option.name, null),
            ),
        ],
        for (final name in run.partMediaTypes.keys.where(
          (name) => !names.contains(name),
        ))
          BusyApiActionRow(
            title: '$name · ${run.partMediaTypes[name]}',
            subtitle: l.requestPartMediaStale,
            enabled: enabled,
            onTap: () => run.selectPartMedia(name, null),
          ),
        for (final (index, file) in run.bodyFiles.indexed)
          RequestDraftEntry(
            run: run,
            key: ValueKey(
              'file-media/${run.plan!.identity}/${run.bodyMediaType}/$index/${file.path}',
            ),
            label:
                '${file.name} · ${file.filename ?? file.name} · ${l.requestPartMediaConcrete}',
            value: file.selectedMediaType ?? '',
            enabled: !run.busy,
            onChanged: (type) => run.selectFileMedia(index, type),
          ),
      ],
    );
  }
}
