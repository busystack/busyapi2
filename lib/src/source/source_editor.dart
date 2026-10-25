import 'source_geometry.dart';

import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle, FontFeature;

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_glyphs.dart';
import '../app/busyapi_search_field.dart';
import '../app/localization.dart';

part 'source_intelligence.dart';
part 'source_diagnostics.dart';
part 'source_folding.dart';

/// A bounded visible-document adapter. The core owns all source and history.
/// Windowing avoids shaping megabytes of text in Flutter's EditableText.
class SourceEditor extends StatefulWidget {
  const SourceEditor({
    super.key,
    required this.buffer,
    required this.onChanged,
    this.onEdit,
    this.owner,
    this.isCurrent,
    this.changes,
    this.assistance,
    this.backgroundAssistanceReady,
    this.onReveal,
    this.onQuickFix,
    this.onCompositionChanged,
    this.onFind,
    this.foldedPointers = const [],
    this.onFoldStateChanged,
    this.syntaxHighlight = true,
    this.diagnostics = const [],
    required this.undo,
    required this.redo,
  });
  final DocumentBuffer buffer;
  final void Function(String) onChanged;
  // Synchronous transaction adapter: acceptance updates this physical buffer.
  final void Function(TextEdit)? onEdit;
  final Object? owner;
  final bool Function()? isCurrent;
  final Listenable? changes;
  final SourceAssistanceJob Function(SourceSelection)? assistance;
  // Automatic outlines can reuse the workspace's current structural capture.
  // Explicit completion/hover/folding still owns its independent current job.
  final bool Function()? backgroundAssistanceReady;
  final void Function(Map<String, dynamic>)? onReveal;
  final void Function(SourceSelection)? onQuickFix;
  // Passive draft presentation observation, not an input-method update.
  final ValueChanged<bool>? onCompositionChanged;
  final VoidCallback? onFind;
  final List<String> foldedPointers;
  final ValueChanged<List<String>>? onFoldStateChanged;
  final bool syntaxHighlight;
  final List<SourceDiagnostic> diagnostics;
  final VoidCallback undo, redo;
  @override
  State<SourceEditor> createState() => SourceEditorState();
}

class SourceEditorState extends State<SourceEditor> {
  /// Passive development/test observation. Unset in the shipped entry point.
  /// Consumers must keep authored values out of routine logs.
  static void Function(SourceInputObservation)? debugObservation;
  void _paintFolds() {
    if (mounted) setState(() {});
  }

  void _observe(String phase, {TextEdit? edit}) {
    final observer = debugObservation;
    if (observer == null) return;
    observer(
      SourceInputObservation(
        phase: phase,
        resource: widget.buffer.id,
        generation: widget.buffer.generation,
        source: widget.buffer.text,
        start: _start,
        end: _end,
        value: _controller.value,
        selection: selection,
        edit: edit,
        pieces: _window?.pieces,
      ),
    );
  }

  final _controller = SyntaxController();
  final _searchController = TextEditingController();
  int _searchFocus = 0;
  final _focus = FocusNode();
  final _textHost = GlobalKey();
  void Function(String)? _showAssistance;
  late final ScrollController _scroll;
  final _undo = UndoHistoryController();
  final _geometry = SourceGeometry();
  int _start = 0, _end = 0, _firstLine = 1;
  SourceFoldWindow? _window;
  late _SourceFolding _folding;
  int _physicalOffset(int visible) =>
      _window?.fullOffset(visible) ?? _start + visible;
  int _visibleOffset(int physical) =>
      _window?.visibleOffset(physical) ??
      (physical - _start).clamp(0, _end - _start);
  String get _windowText => _window?.text ?? _full.substring(_start, _end);
  List<int> _visibleLines = const [];
  SourceFoldWindow? _visibleWindow;
  SourceLineIndex? _visibleIndex;
  int _visibleStart = -1, _visibleEnd = -1;
  int _viewportEpoch = 0;
  static const _windowUnits = 16384;
  String _full = '';
  SourceLineIndex? _displayIndex;
  // A retired owner can paint before its replacement is installed. Its
  // retained text, geometry and gutter still need the same source index.
  SourceLineIndex get _sourceLines {
    final lines = widget.buffer.lines;
    if (lines.source == _full) return _displayIndex = lines;
    if (_displayIndex?.source != _full) _displayIndex = SourceLineIndex(_full);
    return _displayIndex!;
  }

  bool _sync = false, _find = false, _loadingScroll = false;
  bool _accepting = false;
  TextRange _seenComposing = TextRange.empty;
  String _query = '';
  SourceLineIndex? _indexed;
  double _lineHeight = 20, _viewportHeight = 400;
  int _columns = 80;
  List<double> _tops = [0];
  List<double>? _gutterHeights;
  TextStyle? _gutterStyle;
  int? _gutterFirstLine;
  int? _gutterActiveLine;
  double? _gutterLineHeight;
  Widget? _gutter;
  List<SourceDiagnostic>? _gutterDiagnostics;
  Object? _gutterPalette;
  bool? _gutterComposing;
  List<SourceDiagnostic>? _diagnosticInput;
  final _diagnosticIndex = <(String, int), List<SourceDiagnostic>>{};
  List<SourceDiagnostic> _currentDiagnostics() {
    if (_full != widget.buffer.text) return const [];
    if (!identical(_diagnosticInput, widget.diagnostics)) {
      _diagnosticInput = widget.diagnostics;
      _diagnosticIndex.clear();
      for (final diagnostic in widget.diagnostics) {
        (_diagnosticIndex[(diagnostic.resource, diagnostic.generation)] ??= [])
            .add(diagnostic);
      }
    }
    return _diagnosticIndex[(widget.buffer.id, widget.buffer.generation)] ??
        const [];
  }

  Widget _lineNumbers(List<double> heights, TextStyle style) {
    final activeOffset = _full == widget.buffer.text
        ? selection.extent
        : _physicalOffset(_controller.selection.extentOffset);
    final active = _sourceLines.lineAtOffset(activeOffset).number;
    final diagnostics = _currentDiagnostics();
    final palette = (
      busyApiStatusColor(context, BusyApiStatusKind.error),
      busyApiStatusColor(context, BusyApiStatusKind.warning),
      busyApiStatusColor(context, BusyApiStatusKind.information),
    );
    if (identical(heights, _gutterHeights) &&
        style == _gutterStyle &&
        _gutter != null &&
        _firstLine == _gutterFirstLine &&
        active == _gutterActiveLine &&
        _lineHeight == _gutterLineHeight &&
        identical(_gutterDiagnostics, diagnostics) &&
        _gutterComposing == _composing &&
        _gutterPalette == palette) {
      return _gutter!;
    }
    _gutterHeights = heights;
    _gutterStyle = style;
    _gutterFirstLine = _firstLine;
    _gutterActiveLine = active;
    _gutterLineHeight = _lineHeight;
    _gutterDiagnostics = diagnostics;
    _gutterPalette = palette;
    _gutterComposing = _composing;
    final markers = <int, List<SourceDiagnostic>>{};
    for (final diagnostic in _currentDiagnostics()) {
      if (!diagnostic.current(widget.buffer)) continue;
      final line = _sourceLines.lineNumberAtOffset(diagnostic.start);
      if (!_visibleLines.contains(line)) continue;
      (markers[line] ??= []).add(diagnostic);
    }
    final colors = BusyApiSurfaceColors.of(context);
    return _gutter = SizedBox(
      width: BusyApiSizes.sourceGutterWidth,
      child: Padding(
        padding: const EdgeInsets.only(
          top: BusyApiSourceEditorMetrics.paddingTop,
        ),
        child: Column(
          children: [
            for (var i = 0; i < heights.length; i++)
              SizedBox(
                height: heights[i],
                child: Align(
                  alignment: Alignment.topCenter,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _visibleLines[i] == active
                          ? colors.foreground.withValues(
                              alpha: BusyApiAlpha.sourceCollapsedLine,
                            )
                          : Colors.transparent,
                    ),
                    child: SizedBox(
                      width: BusyApiSizes.sourceGutterWidth,
                      height: _lineHeight,
                      child: Stack(
                        children: [
                          Center(
                            child: Text(
                              '${_visibleLines[i]}',
                              textDirection: TextDirection.ltr,
                              style: style.copyWith(
                                color: _visibleLines[i] == active
                                    ? colors.foreground
                                    : colors.mutedForeground,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          if (markers.containsKey(_visibleLines[i]))
                            Positioned(
                              left: BusyApiSpacing.xxs,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: _SourceDiagnosticDot(
                                  markers[_visibleLines[i]]!,
                                ),
                              ),
                            ),
                          if (_folding.onLine(_visibleLines[i])
                              case final fold?)
                            Positioned(
                              right: BusyApiSizes.sourceFoldButtonRightInset,
                              top: 0,
                              child: BusyApiCompactIconButton(
                                key: ValueKey(('source-fold', fold.pointer)),
                                tooltip:
                                    _folding.collapsed.contains(fold.pointer)
                                    ? context.l10n.sourceUnfoldLine(
                                        _visibleLines[i],
                                      )
                                    : context.l10n.sourceFoldLine(
                                        _visibleLines[i],
                                      ),
                                icon: _folding.collapsed.contains(fold.pointer)
                                    ? BusyApiGlyphs.rightArrow
                                    : BusyApiGlyphs.downArrow,
                                size: BusyApiSizes.sourceFoldButton,
                                glyphSize: 12,
                                foregroundColor: colors.mutedForeground,
                                onPressed: !_folding.canToggle(fold)
                                    ? null
                                    : () => _folding.toggle(fold),
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

  SourceSelection get selection => widget.buffer.selection;
  int get _lo =>
      math.min(selection.base, selection.extent).clamp(0, _full.length);
  int get _hi =>
      math.max(selection.base, selection.extent).clamp(0, _full.length);
  bool get _composing =>
      _controller.value.isComposingRangeValid &&
      !_controller.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(
      initialScrollOffset: math.max(0, widget.buffer.scroll),
    );
    _full = widget.buffer.text;
    _folding = _SourceFolding(this);
    _load(selection.extent);
    _controller.addListener(_edit);
    _scroll.addListener(_scrolled);
    _controller.diagnosticProvider = _currentDiagnostics;
    widget.changes?.addListener(_modelChanged);
    _restoreWindowForViewport();
    _folding.schedule();
  }

  void _restoreWindowForViewport() {
    final token = ++_viewportEpoch,
        buffer = widget.buffer,
        generation = buffer.generation,
        owner = widget.owner;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          token != _viewportEpoch ||
          !identical(widget.buffer, buffer) ||
          widget.owner != owner ||
          buffer.generation != generation ||
          !_scroll.hasClients ||
          !identical(_indexed, buffer.lines) ||
          !(widget.isCurrent?.call() ?? true) ||
          _composing) {
        return;
      }
      // A full selection can end far from where the reader was scrolling.
      // Reuse continuous scrolling's window mapping after current layout;
      // neither the selection nor the saved scroll position is a reveal.
      _scrolled();
    });
  }

  void _modelChanged() {
    if (!mounted || _accepting || !(widget.isCurrent?.call() ?? true)) return;
    _folding.resumeDeferred();
    if (_full != widget.buffer.text) {
      _reconcileFolds(widget.buffer.text);
      _full = widget.buffer.text;
      _indexed = null;
      _load(selection.extent, preserveComposition: false);
      _restoreWindowForViewport();
      _folding.schedule();
    }
  }

  @override
  void didUpdateWidget(SourceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.changes, oldWidget.changes)) {
      oldWidget.changes?.removeListener(_modelChanged);
      widget.changes?.addListener(_modelChanged);
    }
    final changedBuffer = !identical(widget.buffer, oldWidget.buffer);
    final changedOwner = widget.owner != oldWidget.owner;
    final changedFolds =
        !changedBuffer &&
        !changedOwner &&
        !identical(oldWidget.foldedPointers, widget.foldedPointers) &&
        (oldWidget.foldedPointers.length != widget.foldedPointers.length ||
            Iterable<int>.generate(widget.foldedPointers.length).any(
              (i) => oldWidget.foldedPointers[i] != widget.foldedPointers[i],
            ));
    if (changedFolds) {
      _folding.restore(widget.foldedPointers);
    }
    if (changedBuffer ||
        changedOwner ||
        changedFolds ||
        widget.buffer.id != oldWidget.buffer.id ||
        widget.buffer.text != _full) {
      if (changedBuffer || changedOwner) {
        _folding.dispose();
        _full = widget.buffer.text;
        _folding = _SourceFolding(this);
        _window = null;
      } else {
        _reconcileFolds(widget.buffer.text);
      }
      _full = widget.buffer.text;
      _indexed = null;
      _load(
        selection.extent,
        preserveComposition: !changedBuffer && !changedOwner,
      );
      if (changedBuffer) {
        final captured = widget.buffer, saved = captured.scroll;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !_scroll.hasClients ||
              !identical(widget.buffer, captured)) {
            return;
          }
          _loadingScroll = true;
          _scroll.jumpTo(saved.clamp(0, _scroll.position.maxScrollExtent));
          _loadingScroll = false;
        });
      }
      _restoreWindowForViewport();
      _folding.schedule();
    } else if (_controller.selection != _projectSelection()) {
      _load(selection.extent);
      _restoreWindowForViewport();
    }
  }

  TextSelection _projectSelection() => TextSelection(
    baseOffset: _visibleOffset(selection.base),
    extentOffset: _visibleOffset(selection.extent),
  );

  int _safe(int offset, {bool forward = false}) {
    offset = offset.clamp(0, _full.length);
    if (offset > 0 &&
        offset < _full.length &&
        _full.codeUnitAt(offset) >= 0xdc00 &&
        _full.codeUnitAt(offset) <= 0xdfff) {
      offset += forward ? 1 : -1;
    }
    return offset;
  }

  void select(SourceSelection value, {bool reveal = true}) {
    if (reveal) _viewportEpoch++;
    if (reveal) _folding.reveal(value.base, value.extent);
    widget.buffer.selection = SourceSelection(
      _safe(value.base),
      _safe(value.extent),
    );
    if (reveal) {
      _load(selection.extent, moveScroll: true);
    } else {
      // Whole-document selection projects into the existing viewport. Moving
      // that window without moving scroll can hide its visible first lines.
      _sync = true;
      _controller.selection = _projectSelection();
      _sync = false;
      if (mounted &&
          _gutterActiveLine !=
              widget.buffer.lines.lineAtOffset(selection.extent).number) {
        setState(() {});
      }
    }
  }

  void reveal(int offset) {
    select(SourceSelection(offset, offset));
    _focus.requestFocus();
  }

  void _load(
    int offset, {
    bool moveScroll = false,
    bool preserveComposition = true,
  }) {
    _observe('window.before');
    final previous = _controller.value;
    final retainComposition =
        preserveComposition &&
        _composing &&
        offset >= _start &&
        offset <= _end &&
        selection.base >= _start &&
        selection.base <= _end &&
        selection.extent >= _start &&
        selection.extent <= _end &&
        _end <= _full.length &&
        previous.text == _windowText;
    widget.buffer.selection = SourceSelection(
      _safe(selection.base),
      _safe(selection.extent),
    );
    offset = _safe(offset);
    final lines = widget.buffer.lines;
    final line = lines.lineNumberAtOffset(offset);
    // Shape the viewport plus one screen of overscan at each end. The source,
    // selection and scroll space still cover the entire physical document.
    final visibleRows = math.max(1, (_viewportHeight / _lineHeight).ceil());
    final windowRows = visibleRows * 3 + 4;
    final windowUnits = math.min(
      _windowUnits,
      math.max(1024, _columns * windowRows),
    );
    // An IM owns coordinates in this editing window until commit/cancel. A
    // rebuild must not clear its composing range or rebase that live context.
    if (!retainComposition) {
      if (_folding.map.folded) {
        final map = _folding.map;
        final visible = map.visibleOffset(offset);
        var begin = math.max(0, visible - windowUnits ~/ 4);
        final physical = map.fullOffset(begin);
        final lineStart = lines.lineAtOffset(physical).startOffset;
        if (visible - map.visibleOffset(lineStart) < windowUnits ~/ 2) {
          begin = map.visibleOffset(lineStart);
        }
        begin = map.visibleOffset(_safe(map.fullOffset(begin)));
        final finish = map.visibleOffset(
          _safe(
            map.fullOffset(math.min(map.visibleLength, begin + windowUnits)),
          ),
        );
        _window = map.window(_full, begin, finish);
        _start = _window!.start;
        _end = _window!.end;
        _firstLine = lines.lineNumberAtOffset(_start);
      } else {
        _window = null;
        _firstLine = math.max(1, line - visibleRows);
        _start = lines.offsetForLine(_firstLine);
        if (offset - _start >= windowUnits ~/ 2) {
          _start = _safe(offset - windowUnits ~/ 4);
        }
        _firstLine = lines.lineNumberAtOffset(_start);
        _end = _safe(
          math.min(
            lines.offsetForLine(_firstLine + windowRows),
            _start + windowUnits,
          ),
        );
      }
    }
    _sync = true;
    _controller.value = TextEditingValue(
      text: _windowText,
      selection: _projectSelection(),
      composing: retainComposition ? previous.composing : TextRange.empty,
    );
    _controller.json = widget.buffer.path.toLowerCase().endsWith('.json');
    _controller.syntax = widget.syntaxHighlight;
    _seenComposing = _controller.value.composing;
    _sync = false;
    _updateVisibleLines();
    _folding.schedule();
    _observe('window.after');
    if (mounted) setState(() {});
    if (moveScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final y = _yForOffset(offset);
        final top = _scroll.offset;
        final next = y < top
            ? y
            : y > top + _viewportHeight - _lineHeight * 2
            ? y - _viewportHeight + _lineHeight * 2
            : top;
        _loadingScroll = true;
        _scroll.jumpTo(next.clamp(0, _scroll.position.maxScrollExtent));
        _loadingScroll = false;
        widget.buffer.scroll = _scroll.offset;
      });
    }
  }

  void _indexViewport(
    double width,
    double height,
    TextStyle style,
    BuildContext context,
  ) {
    _viewportHeight = height;
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final columns = math.max(8, (width / math.max(1, painter.width)).floor());
    final lineHeight = painter.height;
    painter.dispose();
    final lines = _sourceLines;
    if (identical(_indexed, lines) &&
        columns == _columns &&
        _lineHeight == lineHeight) {
      return;
    }
    _indexed = lines;
    _columns = columns;
    _lineHeight = lineHeight;
    _tops = [0];
    for (final line in _indexed!.lines) {
      _tops.add(
        _tops.last +
            (_folding.map.hides(line.startOffset)
                ? 0
                : math.max(1, (line.text.length / _columns).ceil()) *
                      _lineHeight),
      );
    }
  }

  double _yForOffset(int offset) {
    final line = _sourceLines.lineAtOffset(offset.clamp(0, _full.length));
    final row = ((offset - line.startOffset) / _columns).floor();
    return (_tops.length > line.number ? _tops[line.number - 1] : 0) +
        row * _lineHeight;
  }

  void _scrolled() {
    if (_loadingScroll || _sync || !mounted) return;
    widget.buffer.scroll = _scroll.offset;
    if (_composing || _indexed == null) return;
    var lo = 0, hi = _tops.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_tops[mid] <= _scroll.offset) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final line = widget.buffer.lines.lineAt(lo + 1);
    final offset = _safe(
      math.min(
        line.endOffset,
        line.startOffset +
            ((_scroll.offset - _tops[lo]) / _lineHeight).floor() * _columns,
      ),
    );
    if (offset < _start ||
        offset > _end ||
        _visibleOffset(offset) >
            _controller.text.length - math.min(2048, _controller.text.length)) {
      _load(offset);
    }
  }

  void _edit() {
    if (_sync) return;
    _observe('editing.received');
    if (!(widget.isCurrent?.call() ?? true)) {
      _load(selection.extent);
      return;
    }
    final value = _controller.value;
    final compositionChanged = _seenComposing != value.composing;
    _seenComposing = value.composing;
    if (compositionChanged) widget.onCompositionChanged?.call(_composing);
    if (_window != null) {
      _editFolded(value, compositionChanged);
      return;
    }
    final previous = _full.substring(_start, _end);
    if (value.text == previous) {
      if (value.selection != _projectSelection()) {
        widget.buffer.selection = SourceSelection(
          _safe(_start + math.max(0, value.selection.baseOffset)),
          _safe(_start + math.max(0, value.selection.extentOffset)),
        );
      }
      if (mounted &&
          (compositionChanged ||
              _gutterActiveLine !=
                  widget.buffer.lines.lineAtOffset(selection.extent).number)) {
        setState(() {});
      }
      if (compositionChanged && !_composing) _folding.schedule();
      return;
    }
    var a = 0, beforeEnd = previous.length, afterEnd = value.text.length;
    while (a < beforeEnd &&
        a < afterEnd &&
        previous.codeUnitAt(a) == value.text.codeUnitAt(a)) {
      a++;
    }
    while (beforeEnd > a &&
        afterEnd > a &&
        previous.codeUnitAt(beforeEnd - 1) ==
            value.text.codeUnitAt(afterEnd - 1)) {
      beforeEnd--;
      afterEnd--;
    }
    if (a > 0 &&
        a < previous.length &&
        previous.codeUnitAt(a) >= 0xdc00 &&
        previous.codeUnitAt(a) <= 0xdfff) {
      a--;
    }
    if (beforeEnd < previous.length &&
        previous.codeUnitAt(beforeEnd) >= 0xdc00 &&
        previous.codeUnitAt(beforeEnd) <= 0xdfff) {
      beforeEnd++;
      afterEnd++;
    }
    final outside = _lo < _start || _hi > _end;
    final from = outside ? _lo : _start + a;
    final to = outside ? _hi : _start + beforeEnd;
    // A diff of the visible slice is insufficient when its projected selection
    // represents a larger physical range. Equal prefix/suffix characters can be
    // newly entered text, not retained source. Strip only the *unselected*
    // slice context, whose ownership is known before this input update.
    final projected = _projectSelection();
    final replacement = outside
        ? value.text.substring(
            projected.start,
            value.text.length - (previous.length - projected.end),
          )
        : value.text.substring(a, afterEnd);
    final edit = TextEdit(
      buffer: widget.buffer.id,
      generation: widget.buffer.generation,
      start: from,
      end: to,
      expected: _full.substring(from, to),
      replacement: replacement,
    );
    final previousSelection = selection;
    final delta = replacement.length - (to - from);
    if (outside) {
      _start = math.min(_start, from);
      _end = _start + value.text.length;
    } else {
      _end += delta;
    }
    widget.buffer.selection = outside
        ? SourceSelection(from + replacement.length, from + replacement.length)
        : SourceSelection(
            _start + math.max(0, value.selection.baseOffset),
            _start + math.max(0, value.selection.extentOffset),
          );
    _accept(edit, previousSelection);
    _retainViewport(from, to, replacement);
    if (!_composing && (_controller.text.length > _windowUnits || outside)) {
      _load(selection.extent, moveScroll: true);
    } else if (mounted) {
      setState(() {});
    }
    _observe('editing.complete', edit: edit);
  }

  void _replace(SourceSelection captured, String text) {
    _observe('replacement.request');
    if (_composing || !(widget.isCurrent?.call() ?? true)) return;
    final lo = math.min(captured.base, captured.extent),
        hi = math.max(captured.base, captured.extent);
    final inWindow =
        _window == null &&
        lo >= _start &&
        hi <= _end &&
        _end - _start + text.length - (hi - lo) <= _windowUnits;
    final edit = TextEdit(
      buffer: widget.buffer.id,
      generation: widget.buffer.generation,
      start: lo,
      end: hi,
      expected: _full.substring(lo, hi),
      replacement: text,
    );
    final previousSelection = selection;
    widget.buffer.selection = SourceSelection(
      lo + text.length,
      lo + text.length,
    );
    _accept(edit, previousSelection);
    _retainViewport(lo, hi, text);
    if (inWindow) {
      // Keep the input coordinate space stable for a local editing action.
      // The core has already accepted this source; only its visible slice is
      // reconciled here. Rewindow only when a full-document action needs it.
      _end += text.length - (hi - lo);
      _sync = true;
      _controller.value = TextEditingValue(
        text: _full.substring(_start, _end),
        selection: _projectSelection(),
      );
      _seenComposing = _controller.value.composing;
      _sync = false;
      if (mounted) setState(() {});
    } else {
      _load(selection.extent, moveScroll: true);
    }
    _observe('replacement.complete', edit: edit);
  }

  void _accept(TextEdit edit, SourceSelection previousSelection) {
    _accepting = true;
    try {
      if (widget.onEdit != null) {
        widget.onEdit!(edit);
        // The core already constructed and accepted the complete source. Reuse
        // that immutable value instead of allocating a second document here.
        _folding.accepted(edit);
        _full = widget.buffer.text;
      } else {
        _folding.accepted(edit);
        _full = _full.replaceRange(edit.start, edit.end, edit.replacement);
        widget.onChanged(_full);
      }
      _observe('transaction.accepted', edit: edit);
    } on Object {
      _full = widget.buffer.text;
      widget.buffer.selection = previousSelection;
      _indexed = null;
      _load(previousSelection.extent);
      rethrow;
    } finally {
      _accepting = false;
    }
  }

  void _retainViewport(int from, int to, String replacement) {
    final before = _indexed, after = widget.buffer.lines;
    if (before != null &&
        after.source == _full &&
        before.lineCount == after.lineCount &&
        !replacement.contains(RegExp(r'[\r\n]'))) {
      final line = before.lineAtOffset(from);
      // Single-line text changes that retain the estimated wrapped height do
      // not alter any cumulative viewport position. Keep the existing index
      // instead of allocating a document-sized list of tops on every key.
      if (to <= line.endOffset &&
          math.max(1, (line.text.length / _columns).ceil()) ==
              math.max(
                1,
                (after.lineAt(line.number).text.length / _columns).ceil(),
              )) {
        _indexed = after;
        return;
      }
    }
    _indexed = null;
  }

  bool _owns(
    DocumentBuffer buffer,
    int generation,
    SourceSelection selected,
    Object? owner,
  ) =>
      mounted &&
      widget.owner == owner &&
      (widget.isCurrent?.call() ?? true) &&
      identical(widget.buffer, buffer) &&
      buffer.generation == generation &&
      selection.base == selected.base &&
      selection.extent == selected.extent;

  Future<void> _copy({bool cut = false}) async {
    if (!(widget.isCurrent?.call() ?? true)) return;
    final buffer = widget.buffer,
        generation = buffer.generation,
        selected = selection,
        owner = widget.owner;
    final text = _full.substring(_lo, _hi);
    await Clipboard.setData(ClipboardData(text: text));
    if (cut && _owns(buffer, generation, selected, owner)) {
      _replace(selected, '');
    }
  }

  Future<void> _paste() async {
    if (!(widget.isCurrent?.call() ?? true)) return;
    final buffer = widget.buffer,
        generation = buffer.generation,
        selected = selection,
        owner = widget.owner;
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && _owns(buffer, generation, selected, owner)) {
      _replace(selected, data!.text!);
    }
  }

  int _character(int at, bool forward) => forward
      ? CharacterBoundary(_full).getTrailingTextBoundaryAt(at) ?? _full.length
      : CharacterBoundary(_full).getLeadingTextBoundaryAt(at - 1) ?? 0;

  void _move(DirectionalCaretMovementIntent intent, String kind) {
    if (_composing) return;
    final extent = selection.extent.clamp(0, _full.length),
        line = widget.buffer.lines.lineAtOffset(selection.extent);
    var at = extent;
    if (kind == 'document') {
      at = intent.forward ? _full.length : 0;
    } else if (kind == 'line') {
      at = intent.forward ? line.endOffset : line.startOffset;
    } else if (kind == 'vertical' || kind == 'page') {
      final amount = kind == 'page'
          ? math.max(1, (_viewportHeight / _lineHeight).floor() - 1)
          : 1;
      final column = extent - line.startOffset;
      if (line.text.length > _columns &&
          (intent.forward
              ? column + amount * _columns <= line.text.length
              : column - amount * _columns >= 0)) {
        at = extent + (intent.forward ? amount : -amount) * _columns;
      } else {
        final other = widget.buffer.lines.lineAt(
          line.number + (intent.forward ? amount : -amount),
        );
        at = other.startOffset + math.min(column, other.text.length);
      }
    } else if (kind == 'word') {
      at = extent;
      final step = intent.forward ? 1 : -1;
      while ((intent.forward ? at < _full.length : at > 0) &&
          RegExp(r'\s').hasMatch(
            _full.substring(
              at + (intent.forward ? 0 : -1),
              at + (intent.forward ? 1 : 0),
            ),
          )) {
        at += step;
      }
      while ((intent.forward ? at < _full.length : at > 0) &&
          !RegExp(r'\s').hasMatch(
            _full.substring(
              at + (intent.forward ? 0 : -1),
              at + (intent.forward ? 1 : 0),
            ),
          )) {
        at += step;
      }
    } else {
      at = intent.collapseSelection && _lo != _hi
          ? (intent.forward ? _hi : _lo)
          : _character(extent, intent.forward);
    }
    at = _safe(at, forward: intent.forward);
    select(SourceSelection(intent.collapseSelection ? at : selection.base, at));
  }

  void _delete(bool forward, {String kind = 'character'}) {
    _observe('action.delete.$kind.${forward ? 'forward' : 'backward'}');
    if (_composing) return;
    if (_lo != _hi) {
      _replace(selection, '');
      return;
    }
    final old = selection;
    if (kind == 'character') {
      _replace(
        SourceSelection(old.extent, _character(old.extent, forward)),
        '',
      );
    } else {
      _move(
        ExtendSelectionByCharacterIntent(
          forward: forward,
          collapseSelection: false,
        ),
        kind,
      );
      _replace(selection, '');
    }
  }

  void _findNext() {
    if (_query.isEmpty) return;
    final pattern = RegExp(
      RegExp.escape(_query),
      caseSensitive: false,
      unicode: true,
    );
    final from = math.min(_full.length, selection.extent + 1);
    final match =
        pattern.allMatches(_full, from).firstOrNull ??
        pattern.firstMatch(_full);
    if (match != null) {
      select(SourceSelection(match.start, match.end));
      _focus.requestFocus();
    }
  }

  Future<void> _context(Offset position) async {
    final buffer = widget.buffer,
        generation = buffer.generation,
        selected = selection,
        owner = widget.owner;
    final l = context.l10n;
    final action = await showBusyApiContextMenu<String>(
      context,
      position,
      items: [
        BusyApiPopupMenuItem(value: 'undo', label: l.undo),
        BusyApiPopupMenuItem(value: 'redo', label: l.redo),
        BusyApiPopupMenuItem(value: 'copy', label: l.copy),
        BusyApiPopupMenuItem(value: 'cut', label: l.cut),
        BusyApiPopupMenuItem(value: 'paste', label: l.paste),
        BusyApiPopupMenuItem(value: 'all', label: l.selectAll),
        if (widget.assistance != null && !_composing) ...[
          BusyApiPopupMenuItem(value: 'completion', label: l.sourceComplete),
          BusyApiPopupMenuItem(value: 'help', label: l.sourceFieldHelp),
          BusyApiPopupMenuItem(
            value: 'definition',
            label: l.sourceGoToDefinition,
          ),
          BusyApiPopupMenuItem(value: 'usages', label: l.sourceFindUsages),
        ],
        if (widget.onQuickFix != null && !_composing)
          BusyApiPopupMenuItem(value: 'fix', label: l.sourceQuickFix),
      ],
    );
    if (!_owns(buffer, generation, selected, owner)) return;
    switch (action) {
      case 'undo':
        widget.undo();
      case 'redo':
        widget.redo();
      case 'copy':
        await _copy();
      case 'cut':
        await _copy(cut: true);
      case 'paste':
        await _paste();
      case 'all':
        select(SourceSelection(0, _full.length), reveal: false);
      case 'completion' || 'help' || 'definition' || 'usages':
        _showAssistance?.call(action!);
      case 'fix':
        widget.onQuickFix?.call(selected);
    }
  }

  @override
  void dispose() {
    _folding.dispose();
    widget.changes?.removeListener(_modelChanged);
    _controller.removeListener(_edit);
    _scroll.removeListener(_scrolled);
    _controller.diagnosticProvider = null;
    _controller.dispose();
    _searchController.dispose();
    _focus.dispose();
    _scroll.dispose();
    _undo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final font = TextStyle(
      fontFamily: BusyApiTypography.monoFontFamily,
      fontFamilyFallback: BusyApiTypography.monoFontFamilyFallback,
      fontSize: BusyApiTypography.defaultFontSize,
      color: BusyApiSurfaceColors.of(context).foreground,
      height: BusyApiTypography.sourceEditorLineHeight,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final colors = BusyApiSurfaceColors.of(context);
    final editor = LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth -
            BusyApiSizes.sourceGutterWidth -
            BusyApiStroke.hairline -
            BusyApiInsets.sourceEditor.horizontal;
        _indexViewport(width, constraints.maxHeight, font, context);
        _controller.diagnostics = widget.diagnostics;
        _controller.diagnosticsBuffer = widget.buffer;
        _controller.windowStart = _start;
        _controller.window = _window;
        final heights = _geometry.measure(
          context,
          _controller.text,
          font,
          width,
        );
        _updateVisibleLines();
        final top = _yForOffset(_start);
        final bottom = math.max(
          0.0,
          _tops.last - top - heights.fold<double>(0, (a, b) => a + b),
        );
        return Shortcuts(
          shortcuts: {
            if (!_find || _composing)
              const SingleActivator(LogicalKeyboardKey.escape):
                  const DoNothingAndStopPropagationIntent(),
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () {
                if (_composing) return;
                if (widget.onFind != null) {
                  widget.onFind!();
                  return;
                }
                setState(() {
                  _find = true;
                  _searchFocus++;
                });
              },
              if (_find && !_composing)
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  setState(() => _find = false);
                  _focus.requestFocus();
                },
            },
            child: Column(
              children: [
                if (_folding.error != null)
                  BusyApiStatusBox(
                    message: context.l10n.sourceFoldingUnavailable,
                    kind: BusyApiStatusKind.warning,
                  ),
                if (_find)
                  BusyApiSearchField(
                    controller: _searchController,
                    hintText: context.l10n.find,
                    autofocus: true,
                    focusRequest: _searchFocus,
                    clearOnEscape: false,
                    onChanged: (s) => _query = s,
                    onSubmitted: (_) => _findNext(),
                    onEscape: () {
                      setState(() => _find = false);
                      _focus.requestFocus();
                    },
                  ),
                Expanded(
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      UndoTextIntent: _SourceEditingAction<UndoTextIntent>(
                        canEdit: () => !_composing,
                        onInvoke: (_) {
                          widget.undo();
                          return null;
                        },
                      ),
                      RedoTextIntent: _SourceEditingAction<RedoTextIntent>(
                        canEdit: () => !_composing,
                        onInvoke: (_) {
                          widget.redo();
                          return null;
                        },
                      ),
                      CopySelectionTextIntent:
                          CallbackAction<CopySelectionTextIntent>(
                            onInvoke: (i) {
                              _copy(cut: i.collapseSelection);
                              return null;
                            },
                          ),
                      PasteTextIntent: CallbackAction<PasteTextIntent>(
                        onInvoke: (_) {
                          _paste();
                          return null;
                        },
                      ),
                      SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
                        onInvoke: (_) {
                          select(
                            SourceSelection(0, _full.length),
                            reveal: false,
                          );
                          return null;
                        },
                      ),
                      DeleteCharacterIntent:
                          _SourceEditingAction<DeleteCharacterIntent>(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _delete(i.forward);
                              return null;
                            },
                          ),
                      DeleteToNextWordBoundaryIntent:
                          _SourceEditingAction<DeleteToNextWordBoundaryIntent>(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _delete(i.forward, kind: 'word');
                              return null;
                            },
                          ),
                      DeleteToLineBreakIntent:
                          _SourceEditingAction<DeleteToLineBreakIntent>(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _delete(i.forward, kind: 'line');
                              return null;
                            },
                          ),
                      ExtendSelectionByCharacterIntent:
                          _SourceEditingAction<
                            ExtendSelectionByCharacterIntent
                          >(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _move(i, 'character');
                              return null;
                            },
                          ),
                      ExtendSelectionToNextWordBoundaryIntent:
                          _SourceEditingAction<
                            ExtendSelectionToNextWordBoundaryIntent
                          >(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _move(i, 'word');
                              return null;
                            },
                          ),
                      ExtendSelectionToLineBreakIntent:
                          _SourceEditingAction<
                            ExtendSelectionToLineBreakIntent
                          >(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _move(i, 'line');
                              return null;
                            },
                          ),
                      ExtendSelectionToDocumentBoundaryIntent:
                          _SourceEditingAction<
                            ExtendSelectionToDocumentBoundaryIntent
                          >(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _move(i, 'document');
                              return null;
                            },
                          ),
                      ExtendSelectionVerticallyToAdjacentLineIntent:
                          _SourceEditingAction<
                            ExtendSelectionVerticallyToAdjacentLineIntent
                          >(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _move(i, 'vertical');
                              return null;
                            },
                          ),
                      ExtendSelectionVerticallyToAdjacentPageIntent:
                          _SourceEditingAction<
                            ExtendSelectionVerticallyToAdjacentPageIntent
                          >(
                            canEdit: () => !_composing,
                            onInvoke: (i) {
                              _move(i, 'page');
                              return null;
                            },
                          ),
                    },
                    child: CallbackShortcuts(
                      bindings: {
                        if (!_composing) ...{
                          const SingleActivator(
                            LogicalKeyboardKey.keyZ,
                            control: true,
                          ): widget.undo,
                          const SingleActivator(
                            LogicalKeyboardKey.keyZ,
                            control: true,
                            shift: true,
                          ): widget.redo,
                          const SingleActivator(
                            LogicalKeyboardKey.keyY,
                            control: true,
                          ): widget.redo,
                          const SingleActivator(
                            LogicalKeyboardKey.keyA,
                            control: true,
                          ): () => select(
                            SourceSelection(0, _full.length),
                            reveal: false,
                          ),
                          const SingleActivator(
                            LogicalKeyboardKey.keyX,
                            control: true,
                          ): () =>
                              _copy(cut: true),
                          const SingleActivator(
                            LogicalKeyboardKey.keyC,
                            control: true,
                          ): _copy,
                          const SingleActivator(
                            LogicalKeyboardKey.keyV,
                            control: true,
                          ): _paste,
                          const SingleActivator(LogicalKeyboardKey.tab): () =>
                              _replace(selection, '  '),
                        },
                      },
                      child: Scrollbar(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          child: Column(
                            children: [
                              SizedBox(height: top),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _lineNumbers(
                                    heights,
                                    font.copyWith(
                                      color: colors.mutedForeground,
                                      fontSize:
                                          font.fontSize! *
                                          BusyApiTypography
                                              .sourceLineNumberScale,
                                    ),
                                  ),
                                  SizedBox(
                                    width: BusyApiStroke.hairline,
                                    height: math.max(
                                      _viewportHeight,
                                      heights.fold<double>(0, (a, b) => a + b) +
                                          BusyApiInsets.sourceEditor.vertical,
                                    ),
                                    child: ColoredBox(
                                      color: colors.subtleBorder,
                                    ),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      key: _textHost,
                                      onSecondaryTapDown: (details) =>
                                          _context(details.globalPosition),
                                      child: TextField(
                                        // A fresh native editing connection is
                                        // required when ownership changes,
                                        // including reopening the same URI.
                                        key: ValueKey((
                                          widget.buffer,
                                          widget.owner,
                                        )),
                                        controller: _controller,
                                        focusNode: _focus,
                                        maxLines: null,
                                        strutStyle: StrutStyle.fromTextStyle(
                                          font,
                                          forceStrutHeight: true,
                                        ),
                                        style: font,
                                        selectionHeightStyle:
                                            BoxHeightStyle.max,
                                        selectionWidthStyle:
                                            BoxWidthStyle.tight,
                                        cursorColor: colors.foreground
                                            .withValues(
                                              alpha: BusyApiAlpha.sourceCursor,
                                            ),
                                        cursorHeight:
                                            font.fontSize! *
                                            BusyApiTypography
                                                .sourceCursorHeightScale,
                                        cursorWidth: BusyApiStroke.sourceCursor,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        smartDashesType:
                                            SmartDashesType.disabled,
                                        smartQuotesType:
                                            SmartQuotesType.disabled,
                                        keyboardType: TextInputType.multiline,
                                        undoController: _undo,
                                        decoration: const InputDecoration(
                                          isCollapsed: true,
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding:
                                              BusyApiInsets.sourceEditor,
                                        ),
                                        contextMenuBuilder: (context, state) =>
                                            const SizedBox.shrink(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: bottom),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.view),
      child: DefaultTextHeightBehavior(
        textHeightBehavior: sourceTextHeightBehavior,
        child: widget.assistance == null
            ? editor
            : _SourceIntelligence(
                key: ValueKey((widget.buffer, widget.owner)),
                editor: this,
                child: editor,
              ),
      ),
    );
  }
}

// Keep IM editing keys on the native path while it owns a composing range.
// Returning skipRemainingHandlers prevents another Flutter action consuming
// the key, and lets the platform input method process it.
class _SourceEditingAction<T extends Intent> extends CallbackAction<T> {
  _SourceEditingAction({required this.canEdit, required super.onInvoke});
  final bool Function() canEdit;
  @override
  Object? invoke(T intent) => canEdit() ? super.invoke(intent) : null;
  @override
  bool consumesKey(T intent) => canEdit();
  @override
  KeyEventResult toKeyEventResult(T intent, Object? result) =>
      canEdit() ? KeyEventResult.handled : KeyEventResult.skipRemainingHandlers;
}

@immutable
class SourceInputObservation {
  const SourceInputObservation({
    required this.phase,
    required this.resource,
    required this.generation,
    required this.source,
    required this.start,
    required this.end,
    required this.value,
    required this.selection,
    this.edit,
    this.pieces,
  });
  final String phase, resource, source;
  final int generation, start, end;
  final TextEditingValue value;
  final SourceSelection selection;
  final TextEdit? edit;
  final List<SourceRange>? pieces;
}

class SyntaxController extends TextEditingController {
  bool json = false;
  bool syntax = true;
  List<SourceDiagnostic> diagnostics = const [];
  List<SourceDiagnostic> Function()? diagnosticProvider;
  DocumentBuffer? diagnosticsBuffer;
  int windowStart = 0;
  SourceFoldWindow? window;
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final colors = BusyApiSyntaxColors.of(context);
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      json ? r'"(?:[^"\\]|\\.)*"|\b(?:true|false|null|\d+(?:\.\d+)?)\b' : r'#.*$|"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27|\b(?:true|false|null|\d+(?:\.\d+)?)\b|[\w$-]+(?=\s*:)',
      multiLine: true,
    );
    final composing = value.composing;
    final decorate =
        withComposing && value.isComposingRangeValid && !composing.isCollapsed;
    final ranges = _diagnosticDecorations(
      context,
      diagnosticProvider?.call() ?? diagnostics,
      diagnosticsBuffer,
      windowStart,
      text.length,
      window,
    );
    var diagnosticIndex = 0;
    void append(int start, int end, [TextStyle? tokenStyle]) {
      if (start == end) return;
      while (start < end) {
        while (diagnosticIndex < ranges.length &&
            ranges[diagnosticIndex].end <= start) {
          diagnosticIndex++;
        }
        final diagnostic = diagnosticIndex < ranges.length
            ? ranges[diagnosticIndex]
            : null;
        final marked =
            diagnostic != null &&
            diagnostic.start <= start &&
            diagnostic.end > start;
        final preedit =
            decorate && composing.start <= start && composing.end > start;
        var next = end;
        if (diagnostic != null) {
          next = math.min(next, marked ? diagnostic.end : diagnostic.start);
        }
        if (decorate) {
          if (composing.start > start) next = math.min(next, composing.start);
          if (composing.end > start) next = math.min(next, composing.end);
        }
        final decorated = preedit
            ? (tokenStyle ?? const TextStyle()).copyWith(
                decoration: TextDecoration.underline,
              )
            : marked
            ? (tokenStyle ?? const TextStyle()).copyWith(
                decoration: TextDecoration.underline,
                decorationColor: diagnostic.color,
                decorationStyle: TextDecorationStyle.wavy,
              )
            : tokenStyle;
        spans.add(
          TextSpan(text: text.substring(start, next), style: decorated),
        );
        start = next;
      }
    }

    int at = 0;
    for (final match
        in syntax ? pattern.allMatches(text) : const <RegExpMatch>[]) {
      if (match.start > at) {
        append(at, match.start);
      }
      final token = match.group(0)!;
      final color = token.startsWith('#')
          ? colors.comment
          : token.startsWith('"') || token.startsWith("'")
          ? colors.string
          : colors.keyword;
      append(match.start, match.end, TextStyle(color: color));
      at = match.end;
    }
    append(at, text.length);
    return TextSpan(style: style, children: spans);
  }
}
