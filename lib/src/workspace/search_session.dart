// Presentation/state ownership adapted from BusyMark's search_session.dart.
// Copyright 2026 BusyStack (Apache-2.0). Uses BusyAPI's existing search jobs.
import 'dart:async';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import 'workspace_controller.dart';

enum BusyApiSearchCategory { document, project, semantic, navigation, actions }

class BusyApiSearchSession extends ChangeNotifier {
  BusyApiSearchSession(this.workspace) {
    query.addListener(_changed);
    replacement.addListener(_notify);
    workspace.addListener(_observe);
    _restorePreferences();
    _preferencesOwner = workspace.project;
  }

  void _restorePreferences() {
    final saved = workspace.layoutState['projectSearch'] as Map?;
    query.text = saved?['query'] as String? ?? '';
    replacement.text = saved?['replacement'] as String? ?? '';
    regex = saved?['regex'] == true;
    sensitive = saved?['sensitive'] == true;
    final savedCategory = saved?['category'];
    semanticCategory =
        const [
          'all',
          'operations',
          'components',
          'definitions',
          'usages',
        ].contains(savedCategory)
        ? savedCategory as String
        : 'all';
    category = saved?['mode'] == 'semantic'
        ? BusyApiSearchCategory.semantic
        : BusyApiSearchCategory.document;
  }

  final WorkspaceController workspace;
  final query = TextEditingController(), replacement = TextEditingController();
  final _scroll = <BusyApiSearchCategory, ScrollController>{};
  final _selection = <BusyApiSearchCategory, int>{};
  ScrollController get scroll =>
      _scroll.putIfAbsent(category, ScrollController.new);
  int get selected => _selection[category] ?? 0;
  bool active = false, running = false, regex = false, sensitive = false;
  bool _disposed = false;
  int focusRequest = 0, _epoch = 0;
  String semanticCategory = 'all';
  BusyApiSearchCategory category = BusyApiSearchCategory.document;
  SearchSnapshot? result;
  SemanticSearchSnapshot? semanticResult;
  CoreFailure? error;
  ProjectSearch? _job;
  SemanticSearchJob? _semanticJob;
  Timer? _debounce;
  FocusNode? _previousFocus;
  BusyProject? _owner;
  BusyProject? _preferencesOwner;
  String? _resource;
  String _query = '';
  bool _composing = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _observe() {
    if (!identical(_owner, workspace.project) ||
        category == BusyApiSearchCategory.document &&
            _resource != workspace.active) {
      _owner = workspace.project;
      _resource = workspace.active;
      _invalidate();
      if (active) _schedule();
    }
  }

  void open([BusyApiSearchCategory? destination]) {
    if (!identical(_preferencesOwner, workspace.project)) {
      // Project view settings load after the shell's session is constructed.
      // Restore them on activation only while both input owners are pristine.
      if (!active &&
          query.text.isEmpty &&
          replacement.text.isEmpty &&
          !query.value.composing.isValid &&
          !replacement.value.composing.isValid) {
        _restorePreferences();
      }
      _preferencesOwner = workspace.project;
    }
    if (!active) _previousFocus = FocusManager.instance.primaryFocus;
    active = true;
    focusRequest++;
    if (destination != null && destination != category) {
      category = destination;
      _invalidate();
    }
    _owner = workspace.project;
    _resource = workspace.active;
    _notify();
    _schedule();
  }

  void close() {
    active = false;
    remember();
    _notify();
    final focus = _previousFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed &&
          !active &&
          focus?.context != null &&
          focus!.canRequestFocus) {
        focus.requestFocus();
      }
    });
  }

  void _changed() {
    final composing = query.value.composing.isValid;
    final compositionChanged = composing != _composing;
    _composing = composing;
    if (_query == query.text || composing) {
      if (compositionChanged) _notify();
      return;
    }
    _query = query.text;
    _selection[category] = 0;
    _invalidate();
    _notify();
    _schedule();
  }

  void optionsChanged() {
    _invalidate();
    _notify();
    _schedule();
  }

  void _invalidate() {
    _epoch++;
    _debounce?.cancel();
    _job?.cancel();
    unawaited(_semanticJob?.cancel());
    result = null;
    semanticResult = null;
    error = null;
    running = false;
  }

  void _schedule() {
    _debounce?.cancel();
    if (!active || query.value.composing.isValid) return;
    _debounce = Timer(
      const Duration(milliseconds: 120),
      () => unawaited(search()),
    );
  }

  void select(int index) {
    _selection[category] = index;
    _notify();
  }

  void move(int delta, int length) {
    if (length == 0) return;
    select((selected + delta).clamp(0, length - 1));
  }

  void remember() {
    _preferencesOwner = workspace.project;
    workspace.layoutState = {
      ...workspace.layoutState,
      'projectSearch': {
        'query': query.text,
        'replacement': replacement.text,
        'regex': regex,
        'sensitive': sensitive,
        'mode': category == BusyApiSearchCategory.semantic
            ? 'semantic'
            : 'text',
        'category': semanticCategory,
      },
    };
  }

  Future<void> search() async {
    _debounce?.cancel();
    if (_disposed || !active || query.value.composing.isValid) return;
    if (category == BusyApiSearchCategory.actions ||
        category == BusyApiSearchCategory.navigation) {
      _notify();
      return;
    }
    final owner = workspace.project, resource = workspace.active;
    if (owner == null || query.text.isEmpty) return;
    if (category == BusyApiSearchCategory.document && resource == null) return;
    _invalidate();
    final request = _epoch, target = category;
    bool current() =>
        !_disposed &&
        request == _epoch &&
        identical(owner, workspace.project) &&
        category == target &&
        (target != BusyApiSearchCategory.document ||
            resource == workspace.active);
    running = true;
    _notify();
    try {
      if (!await workspace.flush() || !current()) return;
      remember();
      if (target == BusyApiSearchCategory.semantic) {
        final job = _semanticJob = workspace.semanticSearch(owner);
        final found = await job.run(query.text, category: semanticCategory);
        if (current()) semanticResult = found;
      } else {
        final job = _job = workspace.projectSearch(owner);
        final found = await job.run(
          SearchOptions(query.text, regex: regex, caseSensitive: sensitive),
          resource: target == BusyApiSearchCategory.document ? resource : null,
        );
        if (current()) {
          result = found;
        }
      }
    } on Object catch (failure) {
      if (current()) {
        error = failure is CoreFailure ? failure : CoreFailure('search.io', '');
      }
    } finally {
      if (current()) {
        running = false;
        _notify();
      }
    }
  }

  void setError(CoreFailure failure) {
    error = failure;
    _notify();
  }

  void cancel() {
    _invalidate();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    workspace.removeListener(_observe);
    query.removeListener(_changed);
    replacement.removeListener(_notify);
    query.dispose();
    replacement.dispose();
    for (final controller in _scroll.values) {
      controller.dispose();
    }
    super.dispose();
  }
}
