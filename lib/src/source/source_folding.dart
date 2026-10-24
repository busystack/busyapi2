// Native folding geometry follows BusyMark's source gutter (Apache-2.0).
// Metadata comes from the canonical parser. This is view state, not a buffer.
part of 'source_editor.dart';

class _SourceFold {
  _SourceFold(this.pointer, this.header, this.hidden);
  final String pointer;
  final int header;
  final SourceRange hidden;
}

class _SourceFolding {
  _SourceFolding(this.editor) {
    collapsed.addAll(editor.widget.foldedPointers.take(20000));
    map = SourceFoldMap(editor._full.length, const []);
  }
  final SourceEditorState editor;
  final collapsed = <String>{};
  Map<String, _SourceFold> regions = {};
  final Map<int, _SourceFold> _byLine = {};
  late SourceFoldMap map;
  SourceAssistanceJob? job;
  Timer? timer;
  bool deferred = false;
  int epoch = 0, generation = -1;
  Object? requested;
  String? error;
  bool disposed = false;
  bool get owns =>
      !disposed && editor.mounted && (editor.widget.isCurrent?.call() ?? true);

  void dispose() {
    disposed = true;
    timer?.cancel();
    epoch++;
    unawaited(job?.cancel());
  }

  void schedule() {
    if (!owns || editor.widget.assistance == null) return;
    timer?.cancel();
    deferred = false;
    timer = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(refresh(automatic: true)),
    );
  }

  void resumeDeferred() {
    if (deferred &&
        owns &&
        (editor.widget.backgroundAssistanceReady?.call() ?? true)) {
      schedule();
    }
  }

  bool canToggle(_SourceFold fold) =>
      owns &&
      !editor._composing &&
      (generation == editor.widget.buffer.generation ||
          collapsed.contains(fold.pointer));

  void restore(List<String> pointers) {
    final previous = regions;
    final next = pointers.take(20000).toSet();
    // Resource/semantic navigation owns this state update. Unknown relocated
    // pointers await a fresh physical range, never reuse another object's mask.
    regions = {
      for (final entry in previous.entries)
        if (!collapsed.contains(entry.key) || next.contains(entry.key))
          entry.key: entry.value,
    };
    collapsed
      ..clear()
      ..addAll(next);
    map = SourceFoldMap(editor._full.length, [
      for (final pointer in collapsed)
        if (regions[pointer] case final region?) region.hidden,
    ]);
    editor._indexed = null;
    editor._window = null;
    editor._gutter = null;
    requested = null;
    schedule();
  }

  Future<void> refresh({bool automatic = false}) async {
    if (!owns || editor._composing) return;
    if (automatic &&
        !(editor.widget.backgroundAssistanceReady?.call() ?? true)) {
      deferred = true;
      return;
    }
    final buffer = editor.widget.buffer, owner = editor.widget.owner;
    final capturedGeneration = buffer.generation;
    final signature = (
      capturedGeneration,
      editor._start,
      editor._end,
      Object.hashAll(collapsed),
    );
    if (requested == signature) return;
    requested = signature;
    final token = ++epoch;
    unawaited(job?.cancel());
    final captured = editor.widget.assistance?.call(
      const SourceSelection(0, 0),
    );
    if (captured == null) return;
    job = captured;
    bool current() =>
        owns &&
        token == epoch &&
        identical(editor.widget.buffer, buffer) &&
        editor.widget.owner == owner &&
        capturedGeneration == buffer.generation;
    try {
      final result = await captured.run(
        'folds',
        viewport: SourceRange(editor._start, editor._end),
        foldedPointers: collapsed.toList(),
      );
      if (!current() || !result.current || editor._composing) {
        requested = null;
        return;
      }
      final next = <String, _SourceFold>{};
      final lines = buffer.lines;
      for (final entry in result.result['folds'] as List) {
        final header = entry['header'] as int, end = entry['end'] as int;
        final first = lines.lineAtOffset(header);
        final last = lines.lineAtOffset(end);
        final start = lines.offsetForLine(first.number + 1);
        // Flow collections keep their closing line. Block collections/scalars
        // hide only whole lines; never swallow an unrelated trailing sibling.
        var stop = last.startOffset;
        if (entry['flow'] != true &&
            !buffer.path.endsWith('.json') &&
            buffer.text.substring(end, last.endOffset).trim().isEmpty) {
          stop = lines.offsetForLine(last.number + 1);
        }
        if (stop > start) {
          final pointer = entry['pointer'] as String;
          next[pointer] = _SourceFold(
            pointer,
            header,
            SourceRange(start, stop),
          );
          if (regions[pointer] case final previous?) {
            if (collapsed.contains(pointer) && previous.header != header) {
              collapsed.remove(pointer);
            }
          }
        }
      }
      // Viewport requests retain only existing collapsed ancestors outside the
      // viewport. Missing/invalid owners expand rather than hiding other data.
      collapsed.removeWhere((p) => !next.containsKey(p));
      regions = next;
      generation = capturedGeneration;
      error = null;
      _rebuild();
    } on Object catch (failure) {
      if (!current()) return;
      requested = null;
      if (failure is CoreFailure &&
          [
            'cancelled',
            'assist.stale',
            'inspect.stale',
          ].contains(failure.code)) {
        return;
      }
      error = failure is CoreFailure ? failure.code : 'assist.folds';
      editor._paintFolds();
    } finally {
      if (identical(job, captured)) job = null;
    }
  }

  void _rebuild() {
    final next = SourceFoldMap(editor._full.length, [
      for (final pointer in collapsed)
        if (regions[pointer] case final region?) region.hidden,
    ]);
    final changed =
        next.ranges.length != map.ranges.length ||
        next.length != map.length ||
        Iterable<int>.generate(next.ranges.length).any(
          (i) =>
              next.ranges[i].start != map.ranges[i].start ||
              next.ranges[i].end != map.ranges[i].end,
        );
    map = next;
    _indexLines();
    editor._gutter = null;
    if (changed) {
      editor._indexed = null;
      editor._load(editor.selection.extent, preserveComposition: false);
      editor._restoreWindowForViewport();
    } else {
      editor._paintFolds();
    }
  }

  _SourceFold? onLine(int number) {
    return _byLine[number];
  }

  void _indexLines() {
    _byLine.clear();
    for (final region in regions.values) {
      final number = editor.widget.buffer.lines.lineNumberAtOffset(
        region.header,
      );
      final previous = _byLine[number];
      if (previous == null || region.hidden.end > previous.hidden.end) {
        _byLine[number] = region;
      }
    }
  }

  void toggle(_SourceFold fold) {
    if (!canToggle(fold)) {
      return;
    }
    if (!collapsed.remove(fold.pointer)) collapsed.add(fold.pointer);
    // Never leave the native input selection inside newly hidden text.
    if (collapsed.contains(fold.pointer) &&
        (fold.hidden.start <= editor.selection.base &&
                editor.selection.base < fold.hidden.end ||
            fold.hidden.start <= editor.selection.extent &&
                editor.selection.extent < fold.hidden.end)) {
      editor.widget.buffer.selection = SourceSelection(
        fold.header,
        fold.header,
      );
    }
    editor.widget.onFoldStateChanged?.call(collapsed.toList());
    _rebuild();
    editor._focus.requestFocus();
    schedule();
  }

  void reveal(int start, int end) {
    if (editor._composing) return;
    final removed = collapsed.where((p) {
      final range = regions[p]?.hidden;
      return range != null &&
          (range.start <= start && start < range.end ||
              range.start <= end && end < range.end);
    }).toList();
    if (removed.isEmpty) return;
    collapsed.removeAll(removed);
    editor.widget.onFoldStateChanged?.call(collapsed.toList());
    // Caller immediately reloads/reveals, without a second viewport restore.
    map = SourceFoldMap(editor._full.length, [
      for (final p in collapsed)
        if (regions[p] case final r?) r.hidden,
    ]);
    editor._indexed = null;
    editor._gutter = null;
    schedule();
  }

  void accepted(TextEdit edit) {
    final previousCollapsed = collapsed.length;
    if (map.length != editor._full.length) {
      regions.clear();
      collapsed.clear();
      map = SourceFoldMap(editor._full.length, const []);
      return;
    }
    final delta = edit.replacement.length - (edit.end - edit.start);
    if (regions.isEmpty && !map.folded) {
      map = SourceFoldMap(map.length + delta, const []);
      requested = null;
      schedule();
      return;
    }
    final next = <String, _SourceFold>{};
    for (final region in regions.values) {
      final moved = SourceFoldMap(map.length, [region.hidden]).afterEdit(edit);
      if (moved.ranges.length != 1 ||
          edit.start <= region.header && edit.end > region.header) {
        continue;
      }
      next[region.pointer] = _SourceFold(
        region.pointer,
        region.header >= edit.end ? region.header + delta : region.header,
        moved.ranges.single,
      );
    }
    regions = next;
    _indexLines();
    collapsed.removeWhere((p) => !regions.containsKey(p));
    if (collapsed.length != previousCollapsed) {
      editor.widget.onFoldStateChanged?.call(collapsed.toList());
    }
    map = SourceFoldMap(map.length + delta, [
      for (final pointer in collapsed)
        if (regions[pointer] case final region?) region.hidden,
    ]);
    editor._gutter = null;
    requested = null;
    schedule();
  }
}

extension _SourceFoldPresentation on SourceEditorState {
  void _updateVisibleLines() {
    if (identical(_visibleWindow, _window) &&
        identical(_visibleIndex, widget.buffer.lines) &&
        _visibleStart == _start &&
        _visibleEnd == _end) {
      return;
    }
    _visibleWindow = _window;
    _visibleIndex = widget.buffer.lines;
    _visibleStart = _start;
    _visibleEnd = _end;
    if (_window == null) {
      final first = widget.buffer.lines.lineNumberAtOffset(_start);
      final last = widget.buffer.lines.lineNumberAtOffset(_end);
      final numbers = List.generate(last - first + 1, (i) => first + i);
      if (_visibleLines.length != numbers.length ||
          Iterable<int>.generate(numbers.length)
              .any((i) => numbers[i] != _visibleLines[i])) {
        _visibleLines = numbers;
        _gutter = null;
      }
      return;
    }
    final source = _windowText;
    final numbers = <int>[
      widget.buffer.lines.lineNumberAtOffset(_physicalOffset(0)),
    ];
    for (var i = 0; i < source.length; i++) {
      final unit = source.codeUnitAt(i);
      if (unit != 10 && unit != 13) continue;
      if (unit == 13 &&
          i + 1 < source.length &&
          source.codeUnitAt(i + 1) == 10) {
        i++;
      }
      numbers.add(
        widget.buffer.lines.lineNumberAtOffset(_physicalOffset(i + 1)),
      );
    }
    if (_visibleLines.length != numbers.length ||
        Iterable<int>.generate(numbers.length)
            .any((i) => numbers[i] != _visibleLines[i])) {
      _visibleLines = numbers;
      _gutter = null;
    }
  }

  void _reconcileFolds(String next) {
    if (!_folding.map.folded) {
      if (_folding.regions.isNotEmpty) _gutter = null;
      _folding.map = SourceFoldMap(next.length, const []);
      _folding.regions.clear();
      _folding._byLine.clear();
      _folding.generation = -1;
      _window = null;
      return;
    }
    var start = 0, before = _full.length, after = next.length;
    while (start < before &&
        start < after &&
        _full.codeUnitAt(start) == next.codeUnitAt(start)) {
      start++;
    }
    while (before > start &&
        after > start &&
        _full.codeUnitAt(before - 1) == next.codeUnitAt(after - 1)) {
      before--;
      after--;
    }
    _folding.accepted(
      TextEdit(
        buffer: widget.buffer.id,
        generation: widget.buffer.generation,
        start: start,
        end: before,
        expected: _full.substring(start, before),
        replacement: next.substring(start, after),
      ),
    );
    _window = null;
  }

  void _editFolded(TextEditingValue value, bool compositionChanged) {
    final previous = _windowText;
    if (value.text == previous) {
      if (value.selection != _projectSelection()) {
        widget.buffer.selection = SourceSelection(
          _safe(_physicalOffset(math.max(0, value.selection.baseOffset))),
          _safe(_physicalOffset(math.max(0, value.selection.extentOffset))),
        );
      }
      if (compositionChanged ||
          _gutterActiveLine !=
              widget.buffer.lines.lineNumberAtOffset(selection.extent)) {
        _paintFolds();
      }
      if (compositionChanged && !_composing) _folding.schedule();
      return;
    }
    var a = 0, before = previous.length, after = value.text.length;
    while (a < before &&
        a < after &&
        previous.codeUnitAt(a) == value.text.codeUnitAt(a)) {
      a++;
    }
    while (before > a &&
        after > a &&
        previous.codeUnitAt(before - 1) == value.text.codeUnitAt(after - 1)) {
      before--;
      after--;
    }
    if (a > 0 &&
        a < previous.length &&
        previous.codeUnitAt(a) >= 0xdc00 &&
        previous.codeUnitAt(a) <= 0xdfff) {
      a--;
    }
    if (before < previous.length &&
        previous.codeUnitAt(before) >= 0xdc00 &&
        previous.codeUnitAt(before) <= 0xdfff) {
      before++;
      after++;
    }
    final outside =
        _lo < _start || _hi > _end || _folding.map.intersects(_lo, _hi);
    final projected = _projectSelection();
    final from = outside
        ? _lo
        : a == before &&
              selection.base == selection.extent &&
              _visibleOffset(selection.extent) == a
        ? selection.extent
        : _physicalOffset(a);
    final to = outside
        ? _hi
        : a == before
        ? from
        : _physicalOffset(before);
    final replacement = outside
        ? value.text.substring(
            projected.start,
            value.text.length - (previous.length - projected.end),
          )
        : value.text.substring(a, after);
    final edit = TextEdit(
      buffer: widget.buffer.id,
      generation: widget.buffer.generation,
      start: from,
      end: to,
      expected: _full.substring(from, to),
      replacement: replacement,
    );
    final previousSelection = selection, oldStart = _start, oldEnd = _end;
    _accept(edit, previousSelection);
    final delta = replacement.length - (to - from);
    int shifted(int offset, bool end) => offset <= from
        ? offset
        : offset >= to
        ? offset + delta
        : end
        ? from + replacement.length
        : from;
    final map = _folding.map;
    final start = shifted(oldStart, false).clamp(0, _full.length);
    final end = shifted(oldEnd, true).clamp(start, _full.length);
    _window = map.window(
      _full,
      map.visibleOffset(start),
      map.visibleOffset(end),
    );
    _start = _window!.start;
    _end = _window!.end;
    widget.buffer.selection = outside
        ? SourceSelection(from + replacement.length, from + replacement.length)
        : SourceSelection(
            _safe(_physicalOffset(math.max(0, value.selection.baseOffset))),
            _safe(_physicalOffset(math.max(0, value.selection.extentOffset))),
          );
    _retainViewport(from, to, replacement);
    _updateVisibleLines();
    if (!_composing &&
        (_controller.text.length > SourceEditorState._windowUnits || outside)) {
      _load(selection.extent, moveScroll: true);
    } else {
      _paintFolds();
    }
    _observe('editing.complete', edit: edit);
  }
}
