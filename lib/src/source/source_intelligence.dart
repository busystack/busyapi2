// Popup geometry and keyboard mechanics adapted from BusyMark's native Source
// controls, Copyright 2026 BusyStack (Apache-2.0). No Markdown dependencies.
part of 'source_editor.dart';

class _SourceIntelligence extends StatefulWidget {
  const _SourceIntelligence({
    super.key,
    required this.editor,
    required this.child,
  });
  final SourceEditorState editor;
  final Widget child;
  @override
  State<_SourceIntelligence> createState() => _SourceIntelligenceState();
}

class _SourceIntelligenceState extends State<_SourceIntelligence> {
  SourceEditorState get editor => widget.editor;
  late final buffer = editor.widget.buffer;
  late final owner = editor.widget.owner;
  late final changes = editor.widget.changes;
  late final FocusOnKeyEventCallback keyHandler = key;
  late final void Function(String) show = showAction;
  void showAction(String action) => unawaited(request(action));
  final popupHost = GlobalKey();
  final scroll = ScrollController();
  SourceAssistanceJob? job;
  SourceAssistance? result;
  Timer? hover;
  int epoch = 0, selected = 0, capturedGeneration = -1;
  SourceSelection? capturedSelection;
  String? action, error;
  bool pending = false, hovering = false;
  double rowHeight = 40;
  bool get owns =>
      mounted &&
      identical(editor.widget.buffer, buffer) &&
      editor.widget.owner == owner &&
      (editor.widget.isCurrent?.call() ?? true);
  bool get sameCaret =>
      capturedSelection?.base == editor.selection.base &&
      capturedSelection?.extent == editor.selection.extent;
  @override
  void initState() {
    super.initState();
    editor._focus.onKeyEvent = keyHandler;
    editor._showAssistance = show;
    editor._controller.addListener(changed);
    editor._scroll.addListener(scrolled);
    changes?.addListener(changed);
  }

  @override
  void dispose() {
    epoch++;
    hover?.cancel();
    unawaited(job?.cancel());
    editor._controller.removeListener(changed);
    editor._scroll.removeListener(scrolled);
    changes?.removeListener(changed);
    if (identical(editor._focus.onKeyEvent, keyHandler)) {
      editor._focus.onKeyEvent = null;
    }
    if (identical(editor._showAssistance, show)) editor._showAssistance = null;
    scroll.dispose();
    super.dispose();
  }

  void paint() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void hide() {
    epoch++;
    hover?.cancel();
    unawaited(job?.cancel());
    job = null;
    if (!pending && result == null && error == null) return;
    pending = false;
    result = null;
    error = null;
    paint();
  }

  void changed() {
    hover?.cancel();
    if (!pending && result == null && error == null) return;
    if (!owns ||
        editor._composing ||
        buffer.generation != capturedGeneration ||
        !sameCaret ||
        result?.current == false) {
      hide();
    }
  }

  void scrolled() {
    hover?.cancel();
    if (hovering) hide();
  }

  KeyEventResult key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent || !owns) {
      return KeyEventResult.ignored;
    }
    // Like the reference control, IM composition owns its keys. No popup
    // shortcut alters preedit or creates another native editing connection.
    if (editor._composing) return KeyEventResult.skipRemainingHandlers;
    final keyboard = HardwareKeyboard.instance, logical = event.logicalKey;
    final choices = result?.completions ?? const <Map<String, dynamic>>[];
    if (choices.isNotEmpty && action == 'completion') {
      if (logical == LogicalKeyboardKey.arrowDown ||
          logical == LogicalKeyboardKey.arrowUp) {
        setState(
          () => selected =
              (selected + (logical == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
              choices.length,
        );
        if (scroll.hasClients) {
          scroll.jumpTo(
            (selected * rowHeight).clamp(0, scroll.position.maxScrollExtent),
          );
        }
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.enter ||
          logical == LogicalKeyboardKey.tab) {
        accept(selected);
        return KeyEventResult.handled;
      }
    }
    if ((pending || result != null || error != null) &&
        logical == LogicalKeyboardKey.escape) {
      hide();
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (logical == LogicalKeyboardKey.period &&
        keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        editor.widget.onQuickFix != null) {
      hide();
      editor.widget.onQuickFix!(editor.selection);
      return KeyEventResult.handled;
    }
    final command =
        logical == LogicalKeyboardKey.space &&
            keyboard.isControlPressed &&
            !keyboard.isAltPressed
        ? 'completion'
        : logical == LogicalKeyboardKey.f1
        ? 'help'
        : logical == LogicalKeyboardKey.keyB &&
              keyboard.isControlPressed &&
              !keyboard.isAltPressed
        ? 'definition'
        : logical == LogicalKeyboardKey.f7 && keyboard.isAltPressed
        ? 'usages'
        : null;
    if (command == null) return KeyEventResult.ignored;
    show(command);
    return KeyEventResult.handled;
  }

  Future<void> request(String next, {int? caret}) async {
    if (!owns || editor._composing) return;
    hide();
    final requestEpoch = ++epoch;
    capturedGeneration = buffer.generation;
    capturedSelection = editor.selection;
    hovering = caret != null;
    action = next;
    pending = true;
    selected = 0;
    paint();
    try {
      final currentJob = editor.widget.assistance!(
        caret == null ? editor.selection : SourceSelection(caret, caret),
      );
      job = currentJob;
      final found = await currentJob.run(next);
      if (!owns ||
          requestEpoch != epoch ||
          !sameCaret ||
          buffer.generation != capturedGeneration ||
          editor._composing ||
          !found.current) {
        return;
      }
      result = found;
      final definition = found.result['definition'];
      if (next == 'definition' &&
          definition is Map &&
          found.result['dynamic'] == null) {
        reveal(Map<String, dynamic>.from(definition));
        return;
      }
    } on Object catch (failure) {
      if (mounted && owns && requestEpoch == epoch) {
        final code = failure is CoreFailure ? failure.code : 'assist.failure';
        if (code != 'cancelled') {
          error = code == 'assist.stale' || code == 'inspect.stale'
              ? context.l10n.sourceAssistanceStale
              : context.l10n.sourceAssistanceFailed(code);
        }
      }
    } finally {
      if (owns && requestEpoch == epoch) {
        pending = false;
        job = null;
        paint();
      }
    }
  }

  void accept(int index) {
    final captured = result;
    if (!owns || captured == null || editor._composing) return;
    try {
      final edit = captured.completion(index, buffer);
      hide();
      editor._replace(SourceSelection(edit.start, edit.end), edit.replacement);
      editor._focus.requestFocus();
    } on CoreFailure {
      hide();
      error = context.l10n.sourceAssistanceStale;
      paint();
    }
  }

  void reveal(Map<String, dynamic> location) {
    if (!owns || result?.current != true || !sameCaret) {
      hide();
      return;
    }
    hide();
    editor.widget.onReveal?.call(location);
  }

  void hoverAt(Offset position) {
    if (!owns ||
        editor._composing ||
        pending && !hovering ||
        result != null && !hovering) {
      return;
    }
    final popup = popupHost.currentContext?.findRenderObject();
    if (popup is RenderBox &&
        popup.size.contains(popup.globalToLocal(position))) {
      hover?.cancel();
      return;
    }
    RenderEditable? editable;
    void find(RenderObject object) {
      if (object is RenderEditable) {
        editable = object;
        return;
      }
      if (editable == null) object.visitChildren(find);
    }

    final object = editor._textHost.currentContext?.findRenderObject();
    if (object == null) return;
    find(object);
    final render = editable;
    if (render == null ||
        !render.size.contains(render.globalToLocal(position))) {
      return;
    }
    final caret = editor._physicalOffset(
      render.getPositionForPoint(position).offset,
    );
    hover?.cancel();
    hover = Timer(const Duration(milliseconds: 350), () {
      if (owns && !editor._composing) unawaited(request('help', caret: caret));
    });
  }

  String short(Object? value) {
    final text = value?.toString() ?? '';
    if (text.length <= 180) return text;
    var end = 180;
    if (text.codeUnitAt(end) >= 0xdc00 && text.codeUnitAt(end) <= 0xdfff) end--;
    return '${text.substring(0, end)}…';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n,
        colors = BusyApiSurfaceColors.of(context),
        captured = result;
    final choices = captured?.completions ?? const <Map<String, dynamic>>[];
    final usages = (captured?.result['usages'] as List? ?? []).cast<Map>();
    final help = captured?.result['help'] as Map?;
    if (pending || captured != null || error != null) {
      final painter = TextPainter(
        text: TextSpan(
          text: 'Mg',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      rowHeight = (painter.height + BusyApiSpacing.sm * 2).ceilToDouble();
      painter.dispose();
    }
    return MouseRegion(
      onHover: (event) => hoverAt(event.position),
      onExit: (_) {
        hover?.cancel();
        if (hovering) hide();
      },
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            widget.child,
            if (pending || captured != null || error != null)
              Positioned(
                right: BusyApiSpacing.sm,
                bottom: BusyApiSpacing.sm,
                child: Material(
                  key: const ValueKey('source-assistance-popup'),
                  color: colors.popover,
                  elevation: BusyApiElevation.surface,
                  borderRadius: BorderRadius.circular(
                    BusyApiRadius.nativeHeaderButton,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    key: popupHost,
                    width: math.min(
                      BusyApiSizes.languagePopupMaxWidth,
                      math.max(0, constraints.maxWidth - BusyApiSpacing.sm * 2),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.min(
                          BusyApiSizes.sourceAutocompleteMaxHeight,
                          math.max(
                            0,
                            constraints.maxHeight - BusyApiSpacing.sm * 2,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(
                                    BusyApiSpacing.sm,
                                  ),
                                  child: Text(
                                    action == 'completion'
                                        ? l.sourceCompletionCount(
                                            choices.length,
                                          )
                                        : action == 'usages'
                                        ? l.resolvedUsages(usages.length)
                                        : l.sourceFieldHelp,
                                  ),
                                ),
                              ),
                              BusyApiDialogButton(
                                label: l.close,
                                onPressed: hide,
                              ),
                            ],
                          ),
                          if (pending)
                            Padding(
                              padding: const EdgeInsets.all(BusyApiSpacing.sm),
                              child: Text(l.checking),
                            ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.all(BusyApiSpacing.sm),
                              child: Text(error!, maxLines: 4),
                            ),
                          if (!pending &&
                              error == null &&
                              choices.isEmpty &&
                              action == 'completion')
                            Padding(
                              padding: const EdgeInsets.all(BusyApiSpacing.sm),
                              child: Text(l.sourceNoCompletions),
                            ),
                          if (captured?.result['dynamic'] != null)
                            Padding(
                              padding: const EdgeInsets.all(BusyApiSpacing.sm),
                              child: Text(l.sourceDynamicDefinition),
                            ),
                          if (action == 'definition' &&
                              captured != null &&
                              captured.result['definition'] == null)
                            Padding(
                              padding: const EdgeInsets.all(BusyApiSpacing.sm),
                              child: Text(
                                captured.result['resolution'] == null
                                    ? l.sourceNoReference
                                    : l.sourceDefinitionUnavailable(
                                        '${captured.result['resolution']}',
                                      ),
                              ),
                            ),
                          if (action == 'completion' && choices.isNotEmpty)
                            Flexible(
                              child: ListView.builder(
                                controller: scroll,
                                shrinkWrap: true,
                                itemExtent: rowHeight,
                                itemCount: choices.length,
                                itemBuilder: (_, index) {
                                  final choice = choices[index];
                                  return Semantics(
                                    selected: selected == index,
                                    button: true,
                                    child: InkWell(
                                      onTap: () => accept(index),
                                      child: ColoredBox(
                                        color: selected == index
                                            ? colors.controlActive
                                            : Colors.transparent,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: BusyApiSpacing.md,
                                            vertical: BusyApiSpacing.sm,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  short(choice['label']),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  textDirection:
                                                      TextDirection.ltr,
                                                ),
                                              ),
                                              const SizedBox(
                                                width: BusyApiSpacing.sm,
                                              ),
                                              Text(
                                                short(choice['type']),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: colors
                                                          .mutedForeground,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          if (action == 'usages')
                            Flexible(
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: usages.length,
                                itemBuilder: (_, index) {
                                  final usage = Map<String, dynamic>.from(
                                    usages[index],
                                  );
                                  return BusyApiActionRow(
                                    title: short(usage['pointer']),
                                    subtitle: short(usage['resource']),
                                    onTap: () => reveal(usage),
                                  );
                                },
                              ),
                            ),
                          if (help != null &&
                              action != 'completion' &&
                              action != 'usages')
                            Flexible(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(
                                  BusyApiSpacing.sm,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      help['dialectKnown'] == false
                                          ? l.sourceUnknownDialectHelp
                                          : help['kind'] == 'custom-keyword'
                                          ? l.sourceUnknownKeywordHelp
                                          : help['kind'] == 'data'
                                          ? l.sourceDataHelp
                                          : l.sourceAuthoredField(
                                              short(help['name']),
                                              short(help['kind']),
                                              short(help['type']),
                                            ),
                                    ),
                                    if ((help['blockedBy'] as List? ?? [])
                                        .isNotEmpty)
                                      Text(
                                        l.fieldConflictAuthored(
                                          (help['blockedBy'] as List).join(
                                            ', ',
                                          ),
                                        ),
                                      ),
                                    if (help.containsKey('effectiveDefault'))
                                      Text(
                                        l.effectiveDefault(
                                          '${help['effectiveDefault']}',
                                        ),
                                      ),
                                    if (help['standard'] != null)
                                      SelectableText(short(help['standard'])),
                                  ],
                                ),
                              ),
                            ),
                          if (captured?.result['definition'] is Map)
                            BusyApiActionRow(
                              title: l.sourceGoToDefinition,
                              subtitle: short(
                                captured!.result['definition']['pointer'],
                              ),
                              onTap: () => reveal(
                                Map<String, dynamic>.from(
                                  captured.result['definition'],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
