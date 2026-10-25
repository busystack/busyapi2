import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:path/path.dart' as p;

class WorkspaceController extends ChangeNotifier {
  WorkspaceController(
    this.engine,
    this.locations, {
    PublicationStore? publications,
    RecoveryStore? recovery,
    Future<void> Function(String, Object)? viewStateWriter,
  }) : recovery =
           recovery ?? RecoveryStore(p.join(locations.state, 'recovery')),
       publications =
           publications ??
           PublicationStore(p.join(locations.state, 'publication')),
       _viewStateWriter = viewStateWriter ?? writePrivateJson;
  final EngineProcess engine;
  final StateLocations locations;
  final RecoveryStore recovery;
  final Future<void> Function(String, Object) _viewStateWriter;
  Future<void>? _viewWriting;
  String? _pendingView;
  final PublicationStore publications;
  List<Map<String, dynamic>> interruptedPublications = [];
  BusyProject? project;
  String? root, active;
  String mode = 'Design';
  bool preview = false, checking = false, checkingSemantics = false;
  Map<String, dynamic>? analysis, lastGood;
  String? error;
  String? storageError;
  PropertySession? draft;
  FormSession? form, restoringForm;
  FormSession? _applyingForm;
  bool formApplying = false;
  bool get hasPendingFields =>
      (draft?.pending ?? false) || form != null || formApplying;
  final List<String> tabs = [];
  final List<Map<String, Object?>> history = [];
  int historyIndex = -1;
  final Map<String, Map<String, dynamic>> cached = {};
  List<String> recent = [];
  final Map<String, Map<String, Object?>> viewStates = {};
  Map<String, Object?> layoutState = {};
  final Set<String> expandedReferences = {};
  Timer? _debounce, _monitor;
  int _context = 0;
  int? _governanceContext;
  bool get governanceRunning =>
      !disposed &&
      _governanceContext == _context &&
      (checking || checkingSemantics);
  void cancelGovernance() {
    if (governanceRunning) schedule(immediate: true);
  }

  int _opening = 0;
  int _selection = 0;
  bool _disposed = false, _shuttingDown = false;
  Future<void>? _shutdown;
  bool get disposed => _disposed || _shuttingDown;
  int get navigationGeneration => _opening;
  int get resourceNavigationGeneration => _selection;
  // Intentional navigator activation is separate from reconciliation and
  // refactoring. A Reference pane consumes this command once; reparsing must
  // not retarget its independently chosen definition or reading position.
  Map<String, dynamic>? _referenceNavigation;
  int _semanticViewRevision = 0;
  int get semanticViewRevision => _semanticViewRevision;
  Map<String, dynamic>? consumeReferenceNavigation() {
    if (mode != 'Reference') return null;
    final target = _referenceNavigation;
    _referenceNavigation = null;
    return target?['root'] == root ? target : null;
  }

  String selectedPointer = '/info';
  String? selectedResource, selectedOccurrence;
  final Map<String, Map<String, dynamic>> _savedViews = {};
  bool isSelected(Map<String, dynamic> item) =>
      selectedPointer == item['pointer'] &&
      (selectedResource ?? root) == item['resource'] &&
      (selectedOccurrence == null || selectedOccurrence == item['occurrence']);
  BufferStore? get store => project?.store;
  DocumentBuffer? get buffer => active == null ? null : store?.buffers[active];
  SpecificationContext? get specification =>
      projection?['specification'] == null
      ? null
      : SpecificationContext.fromJson(projection!['specification']);
  Map<String, dynamic>? get projection {
    final current =
            analysis?['projection'] as Map<String, dynamic>? ?? analysis,
        previous = lastGood;
    if (current?['info'] == null) return previous;
    if (current?['specification']?['declaredVersion'] !=
            previous?['specification']?['declaredVersion'] ||
        current?['specification']?['schemaDialect'] !=
            previous?['specification']?['schemaDialect']) {
      return current;
    }
    if (previous == null || current!['complete'] == true) return current;
    final operations = List<dynamic>.from(current['operations'] as List? ?? []);
    final keys = operations
        .map((v) => '${v['resource']}#${v['pointer']}#${v['occurrence']}')
        .toSet();
    for (final old in previous['operations'] as List? ?? []) {
      if (!keys.contains(
        '${old['resource']}#${old['pointer']}#${old['occurrence']}',
      )) {
        operations.add({
          ...Map<String, dynamic>.from(old as Map),
          'outdated': true,
        });
      }
    }
    return {...current, 'operations': operations};
  }

  bool get outdated =>
      analysis == null ||
      analysis?['info'] == null ||
      (projection?['operations'] as List? ?? []).any(
        (v) => v['outdated'] == true,
      );
  bool get designSafe => scopeSafe(projection?['info']);
  bool scopeSafe(
    dynamic item, {
    String? referenceField,
    String? authoredField,
  }) {
    // A string field can remain editable beside an invalid child collection.
    // This narrows the diagnostic scope, not the transaction: bind/flush still
    // verify the whole original owner, generation and expected source text.
    if (referenceField != null && authoredField != null) return false;
    if (_disposed ||
        checking ||
        analysis == null ||
        item is! Map ||
        analysis?['status'] == 'unsupported') {
      return false;
    }
    final resource = item['resource'], buffer = store?.buffers[resource];
    if (resource is! String || Uri.parse(resource).scheme != 'file') {
      return false;
    }
    if (item['outdated'] == true ||
        item['syntaxSafe'] != true ||
        item['shared'] == true ||
        !const ['object', 'array', 'boolean'].contains(item['nodeKind'])) {
      return false;
    }
    final current = (analysis?['resources'] as List? ?? [])
        .where((r) => r['id'] == resource)
        .firstOrNull;
    if (current == null ||
        current['generation'] != item['generation'] ||
        buffer != null &&
            (buffer.generation != item['generation'] ||
                buffer.sourceIdentity != current['identity'])) {
      return false;
    }
    final ownerPointer = item['pointer'] as String;
    final pointer = authoredField == null
        ? ownerPointer
        : '$ownerPointer/${authoredField.replaceAll('~', '~0').replaceAll('/', '~1')}';
    return !(analysis?['findings'] as List? ?? []).any((d) {
      if (d['resource'] != resource) return false;
      if ((d['code'] as String).startsWith('limit.')) {
        return true;
      }
      final at = d['pointer'] as String? ?? '';
      // Choosing a new, graph-proved reference can repair this exact authored
      // field. It does not authorize editing an ambiguous parent, alias or
      // another invalid local constraint. Ordinary forms keep their eligibility.
      if (const [
            r'$ref',
            r'$dynamicRef',
            'operationRef',
          ].contains(referenceField) &&
          item['nodeKind'] == 'object' &&
          at == '$ownerPointer/$referenceField') {
        return false;
      }
      final unsafe =
          d['code'] == 'structure.type' ||
          d['code'] == 'parameter.container.type' ||
          d['code'] == 'reference.missing';
      return unsafe &&
          (at.isEmpty ||
              at == pointer ||
              at.startsWith('$pointer/') ||
              pointer.startsWith('$at/'));
    });
  }

  Future<void> initialize() async {
    await locations.prepare();
    try {
      final v = jsonDecode(
        await File(p.join(locations.config, 'preferences.json')).readAsString(),
      );
      recent = List<String>.from(v['recent'] ?? []).take(12).toList();
    } on Object {
      /* No persisted preferences yet. */
    }
    try {
      final f = File(p.join(locations.state, 'views.json'));
      if (await f.length() > 1024 * 1024) return;
      final data = jsonDecode(await f.readAsString());
      if (data['version'] == 1) {
        for (final e in (data['projects'] as Map).entries.take(12)) {
          _savedViews[e.key as String] = Map<String, dynamic>.from(
            e.value as Map,
          );
        }
      }
    } on Object {
      /* Missing/corrupt state never changes project files. */
    }
  }

  Future<void> remember() => writePrivateJson(
    p.join(locations.config, 'preferences.json'),
    {'version': 1, 'recent': recent.take(12).toList()},
  );

  void _captureRootView() {
    if (root == null) return;
    viewStates[root!] = {
      'pointer': selectedPointer,
      'resource': selectedResource,
      'occurrence': selectedOccurrence,
      'mode': mode,
      'active': active,
      'preview': preview,
    };
  }

  Future<void> persistView() async {
    final captured = project;
    if (captured == null) return;
    _captureRootView();
    _savedViews[captured.location] = {
      'layout': Map.of(layoutState),
      'expandedReferences': expandedReferences.take(2048).toList(),
      'root': root,
      'active': active,
      'tabs': tabs.take(128).toList(),
      'mode': mode,
      'preview': preview,
      'roots': Map.of(viewStates),
      'buffers': {
        for (final b in captured.store.fileBuffers.where(
          (b) => b.present || b.dirty,
        ))
          b.id: {
            'base': b.selection.base,
            'extent': b.selection.extent,
            'scroll': b.scroll,
          },
      },
    };
    while (_savedViews.length > 12) {
      _savedViews.remove(_savedViews.keys.first);
    }
    final payload = jsonEncode({'version': 1, 'projects': _savedViews});
    if (utf8.encode(payload).length > 1024 * 1024) {
      throw CoreFailure(
        'view.limit',
        'View state exceeds its private storage budget; prior state was retained',
      );
    }
    // Freeze before yielding: maps in later view captures remain mutable.
    // Only one write and one replacement payload can be pending. Every joined
    // caller waits until the latest capture is durable, including shutdown.
    _pendingView = payload;
    final writing = _viewWriting;
    if (writing != null) return writing;
    final completion = Completer<void>();
    _viewWriting = completion.future;
    unawaited(() async {
      try {
        while (_pendingView != null) {
          final next = _pendingView!;
          _pendingView = null;
          await _viewStateWriter(
            p.join(locations.state, 'views.json'),
            jsonDecode(next) as Object,
          );
        }
        // Clear synchronously before notifying joined callers; a new capture
        // must not join an already completed drain and remain unwritten.
        _viewWriting = null;
        completion.complete();
      } on Object catch (error, stack) {
        _pendingView = null;
        _viewWriting = null;
        completion.completeError(error, stack);
      }
    }());
    return completion.future;
  }

  Future<void> _restoreView(BusyProject captured, int opening) async {
    final saved = _savedViews[captured.location];
    if (saved == null) return;
    bool current() =>
        !disposed && identical(project, captured) && _opening == opening;
    if (saved['layout'] is Map) {
      layoutState = Map<String, Object?>.from(saved['layout']);
    }
    expandedReferences
      ..clear()
      ..addAll(
        (saved['expandedReferences'] as List? ?? []).whereType<String>().take(
          2048,
        ),
      );
    if (saved['roots'] is Map) {
      for (final entry in (saved['roots'] as Map).entries) {
        if (captured.roots.any((r) => r.id == entry.key) &&
            entry.value is Map) {
          viewStates[entry.key] = Map<String, Object?>.from(entry.value);
        }
      }
    }
    for (final id in (saved['tabs'] as List? ?? []).take(128)) {
      if (!current()) return;
      try {
        final uri = Uri.parse(id as String);
        if (uri.scheme != 'file' ||
            !p.isWithin(captured.access.boundary, uri.toFilePath())) {
          continue;
        }
        final b = await captured.buffer(id);
        if (!current()) return;
        final state = saved['buffers']?[id];
        if (state is Map) {
          int clamp(dynamic n) => n is int ? n.clamp(0, b.text.length) : 0;
          b.selection = SourceSelection(
            clamp(state['base']),
            clamp(state['extent']),
          );
          final scroll = state['scroll'];
          b.scroll = scroll is num && scroll.isFinite && scroll >= 0
              ? scroll.toDouble()
              : 0;
        }
        if (!tabs.contains(id)) tabs.add(id);
      } on Object {
        /* Missing/unsafe resources are not restored. */
      }
    }
    if (!current()) return;
    if (['Design', 'Source', 'Reference'].contains(saved['mode'])) {
      mode = saved['mode'];
    }
    preview = saved['preview'] == true;
    final selected = saved['root'];
    if (captured.roots.any((r) => r.id == selected)) await selectRoot(selected);
    if (!current()) return;
    final selectedFile = saved['active'];
    if (tabs.contains(selectedFile)) await openFile(selectedFile);
  }

  Future<void> open(
    String path, {
    bool Function()? cancelled,
    Map<String, dynamic>? recovering,
  }) async {
    if (disposed) throw CoreFailure('workspace.closed', 'Workspace is closed');
    final opening = ++_opening;
    bool superseded() =>
        disposed || opening != _opening || (cancelled?.call() ?? false);
    _context++;
    _debounce?.cancel();
    final next = await BusyProject.open(path, engine, cancelled: superseded);
    if (superseded()) {
      next.close();
      throw CoreFailure(
        'open.cancelled',
        'Project opening was cancelled or superseded',
      );
    }
    if (recovering != null) {
      await next.buffer(recovering['id'] as String, recovery: recovering);
      if (superseded()) {
        next.close();
        throw CoreFailure(
          'open.cancelled',
          'Project opening was cancelled or superseded',
        );
      }
    }
    try {
      await persist();
      await persistView();
    } on Object {
      next.close();
      rethrow;
    }
    if (superseded()) {
      next.close();
      return;
    }
    if (project case final previous?) {
      publications.releaseProject(previous);
      previous.close();
    }
    project = next;
    next.acceptsBufferReload = (buffer) =>
        !disposed &&
        identical(project, next) &&
        ![
          form,
          _applyingForm,
          restoringForm,
        ].any((session) => session?.target.buffer == buffer.id) &&
        !(draft?.buffer == buffer.id && (draft!.pending || draft!.composing));
    error = next.discoveryFailure;
    root = null;
    active = null;
    analysis = null;
    lastGood = null;
    draft = null;
    form = null;
    tabs.clear();
    history.clear();
    historyIndex = -1;
    cached.clear();
    viewStates.clear();
    layoutState = {};
    expandedReferences.clear();
    selectedResource = null;
    selectedOccurrence = null;
    recent
      ..remove(path)
      ..insert(0, path);
    await remember();
    if (superseded() || !identical(project, next)) return;
    if (next.roots.length == 1) {
      await selectRoot(next.roots.single.id);
    } else if (next.roots.isEmpty && next.files.isNotEmpty) {
      await openFile(Uri.file(next.files.first).toString());
      if (superseded() || !identical(project, next)) return;
      mode = 'Source';
      schedule(immediate: true);
    }
    if (superseded() || !identical(project, next)) return;
    interruptedPublications = await publications.inspect(next);
    if (superseded() || !identical(project, next)) return;
    await _restoreView(next, opening);
    if (superseded() || !identical(project, next)) return;
    _monitor?.cancel();
    _monitor = Timer.periodic(const Duration(seconds: 2), (_) => _pollDisk());
    notifyListeners();
  }

  bool _polling = false;
  Future<void> pollDisk() async {
    if (disposed || _polling) return;
    final captured = project;
    if (captured == null) return;
    _polling = true;
    try {
      final refreshed = await captured.refreshResources();
      if (disposed || !identical(project, captured)) return;
      for (final id in refreshed.roots) {
        cached.remove(id);
      }
      if (refreshed.roots.contains(root ?? active)) schedule();
      if (refreshed.resources.isNotEmpty) notifyListeners();
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollDisk() => pollDisk();

  Future<bool> selectRoot(String id, {String? resource}) async {
    final captured = project, navigation = _opening, selection = ++_selection;
    final previousRoot = root;
    bool currentSelection() =>
        !_disposed &&
        identical(project, captured) &&
        navigation == _opening &&
        selection == _selection &&
        root == previousRoot;
    if (captured == null) return false;
    Future<bool> configured() async {
      final choices = await captured.configuredRoots(
        onResourceRefreshed: (_) {
          if (currentSelection()) notifyListeners();
        },
      );
      if (!currentSelection()) return false;
      if (!choices.any((choice) => choice.id == id)) {
        throw CoreFailure(
          'root.unconfigured',
          'This contract is no longer a configured project root; choose a current root or reopen the intended contract',
        );
      }
      return true;
    }

    // Preserve the established synchronous flush-entry ordering. Configuration
    // I/O must not run ahead of captured fields/composition during navigation.
    if (!await flush()) {
      throw CoreFailure('draft.pending', 'Pending fields block root selection');
    }
    if (_disposed ||
        !identical(project, captured) ||
        navigation != _opening ||
        selection != _selection) {
      return false;
    }
    if (!await configured()) return false;
    var destination = resource ?? viewStates[id]?['active'] as String? ?? id;
    try {
      await captured.buffer(destination);
    } on Object {
      if (!currentSelection()) return false;
      if (destination == id) rethrow;
      destination = id;
      await captured.buffer(destination);
    }
    if (!currentSelection()) return false;
    // Keep the original root, resource and field owner together throughout
    // acquisition. Late input must commit there before the transition is visible.
    final flushed = await flush();
    if (!currentSelection()) return false;
    if (!flushed || hasPendingFields) {
      throw CoreFailure('draft.pending', 'Pending fields block root selection');
    }
    if (root != id) _captureRootView();
    _context++;
    root = id;
    selectedPointer = viewStates[id]?['pointer'] as String? ?? '/info';
    selectedResource = viewStates[id]?['resource'] as String? ?? id;
    selectedOccurrence = viewStates[id]?['occurrence'] as String?;
    mode = viewStates[id]?['mode'] as String? ?? mode;
    preview = viewStates[id]?['preview'] as bool? ?? preview;
    final saved = cached[id];
    if (saved != null &&
        !(saved['resources'] as List? ?? []).every((r) {
          final b = store?.buffers[r['id']];
          return b != null
              ? b.generation == r['generation']
              : project!.resourceFingerprints[r['id']] == r['identity'];
        })) {
      cached.remove(id);
    }
    analysis = cached[id];
    lastGood = analysis;
    _activateFile(destination);
    if (disposed ||
        !identical(project, captured) ||
        navigation != _opening ||
        root != id ||
        selection != _selection) {
      return false;
    }
    schedule(immediate: true);
    return true;
  }

  Future<void> openFile(String id) async {
    final selection = ++_selection;
    final capturedProject = project, capturedRoot = root, navigation = _opening;
    if (!await flush()) {
      throw CoreFailure('draft.pending', 'Pending fields block navigation');
    }
    if (_disposed ||
        capturedProject == null ||
        !identical(project, capturedProject)) {
      return;
    }
    if (selection != _selection) return;
    await capturedProject.buffer(id);
    // The mounted Design fields still own their session during file I/O.
    // Commit input received during the read before releasing that session.
    if (_disposed ||
        !identical(project, capturedProject) ||
        root != capturedRoot ||
        navigation != _opening ||
        selection != _selection) {
      return;
    }
    final flushed = await flush();
    if (_disposed ||
        !identical(project, capturedProject) ||
        root != capturedRoot ||
        navigation != _opening ||
        selection != _selection) {
      return;
    }
    if (!flushed || hasPendingFields) {
      throw CoreFailure('draft.pending', 'Pending fields block navigation');
    }
    _activateFile(id);
  }

  void _activateFile(String id) {
    active = id;
    if (!tabs.contains(id)) tabs.add(id);
    final entry = <String, Object?>{
      'resource': id,
      'root': root,
      'pointer': selectedPointer,
      'selectedResource': selectedResource,
      'occurrence': selectedOccurrence,
      'mode': mode,
    };
    if (historyIndex < 0 ||
        jsonEncode(history[historyIndex]) != jsonEncode(entry)) {
      if (historyIndex + 1 < history.length) {
        history.removeRange(historyIndex + 1, history.length);
      }
      history.add(entry);
      if (history.length > 200) history.removeAt(0);
      historyIndex = history.length - 1;
    }
    draft = null;
    notifyListeners();
  }

  Future<void> openProjectConfiguration() async {
    final owner = project, selectedRoot = root, navigation = _opening;
    final resource = owner?.configurationResource;
    if (_disposed || owner == null || resource == null) return;
    await openFile(resource);
    if (_disposed ||
        !identical(project, owner) ||
        _opening != navigation ||
        root != selectedRoot ||
        active != resource) {
      return;
    }
    selectedPointer = '';
    selectedResource = resource;
    selectedOccurrence = null;
    setMode('Source');
  }

  Future<void> navigateHistory(int delta) async {
    final captured = project, navigation = _opening, capturedRoot = root;
    final selection = ++_selection;
    if (!await flush() ||
        _disposed ||
        captured == null ||
        !identical(project, captured) ||
        navigation != _opening ||
        selection != _selection ||
        root != capturedRoot) {
      return;
    }
    final index = historyIndex + delta;
    if (index < 0 || index >= history.length) return;
    final entry = history[index];
    final nextRoot = entry['root'] as String?;
    final resource = entry['resource'] as String;
    await captured.buffer(resource);
    bool current() =>
        !_disposed &&
        identical(project, captured) &&
        navigation == _opening &&
        selection == _selection &&
        root == capturedRoot;
    if (!current()) return;
    final flushed = await flush();
    if (!current()) return;
    if (!flushed || hasPendingFields) {
      throw CoreFailure('draft.pending', 'Pending fields block navigation');
    }
    if (nextRoot != root) {
      root = nextRoot;
      analysis = nextRoot == null ? null : cached[nextRoot];
      lastGood = analysis;
    }
    draft = null;
    active = resource;
    selectedResource = entry['selectedResource'] as String? ?? resource;
    selectedOccurrence = entry['occurrence'] as String?;
    if (!tabs.contains(active)) tabs.add(active!);
    selectedPointer = entry['pointer'] as String;
    mode = entry['mode'] as String;
    if (mode == 'Reference') {
      _referenceNavigation = {
        'root': root,
        'resource': selectedResource,
        'pointer': selectedPointer,
        'occurrence': selectedOccurrence,
        'data': false,
      };
    }
    historyIndex = index;
    schedule(immediate: true);
    notifyListeners();
  }

  Future<void> selectObject(Map<String, dynamic> item) async {
    if (!await flush()) {
      throw CoreFailure('draft.pending', 'Pending fields block navigation');
    }
    final captured = project, selectedRoot = root;
    if (_disposed || item['root'] != null && item['root'] != root) return;
    final resource = item['resource'], pointer = item['pointer'];
    if (captured == null ||
        selectedRoot == null ||
        resource is! String ||
        pointer is! String) {
      throw CoreFailure(
        'navigation.target',
        'The selected object has no current root or source identity',
      );
    }
    selectedPointer = pointer;
    selectedResource = resource;
    selectedOccurrence = item['occurrence'];
    await openFile(resource);
    if (_disposed ||
        !identical(project, captured) ||
        root != selectedRoot ||
        active != item['resource']) {
      return;
    }
    if (mode == 'Source') {
      final range = item['range'] as List;
      buffer!.selection = SourceSelection(range[0], range[0]);
    }
    if (mode == 'Reference') {
      _referenceNavigation = {...item, 'root': selectedRoot, 'data': false};
    }
    notifyListeners();
  }

  /// Read-side collection can reload a clean resource before its long-running
  /// adapter completes. Notify only this still-mounted project owner, including
  /// a Source view in another root; cancellation cannot suppress that reload.
  void resourceRefreshed(BusyProject owner, String resource) {
    if (disposed || !identical(project, owner)) return;
    _invalidateResource(resource);
    schedule();
  }

  ProjectSearch projectSearch(BusyProject owner) => ProjectSearch(
    owner,
    onResourceRefreshed: (resource) {
      // Collection can reload a clean buffer while another Source view is
      // mounted. Notify that owner even if the search route was just cancelled.
      resourceRefreshed(owner, resource);
    },
  );

  SemanticSearchJob semanticSearch(BusyProject owner) => owner.semanticSearch(
    onResourceRefreshed: (resource) {
      resourceRefreshed(owner, resource);
    },
  );

  SourceAssistanceJob sourceAssistance(
    BusyProject owner,
    String root,
    String resource,
    SourceSelection selection,
  ) => owner.sourceAssistance(
    root,
    resource,
    selection,
    onResourceRefreshed: (resource) {
      resourceRefreshed(owner, resource);
    },
  );

  List<String> sourceFolds(String root, String resource) {
    final namespace = layoutState['sourceFolds'];
    final value = namespace is Map
        ? namespace[jsonEncode([root, resource])]
        : null;
    return value is List
        ? value.whereType<String>().take(20000).toList()
        : const [];
  }

  void rememberSourceFolds(
    BusyProject owner,
    String root,
    String resource,
    List<String> pointers, {
    int? viewRevision,
  }) {
    if (disposed ||
        !identical(project, owner) ||
        viewRevision != null && viewRevision != semanticViewRevision) {
      return;
    }
    final namespace = layoutState['sourceFolds'];
    final next = <String, Object?>{
      if (namespace is Map)
        for (final entry in namespace.entries)
          if (entry.key is String) entry.key as String: entry.value,
      jsonEncode([root, resource]): pointers.take(20000).toList(),
    };
    while (next.length > 128) {
      next.remove(next.keys.first);
    }
    layoutState = {...layoutState, 'sourceFolds': next};
  }

  Future<void> replaceProjectSearch(
    BusyProject owner,
    SearchSnapshot snapshot,
    String replacement,
  ) async {
    final navigation = _opening;
    bool current() =>
        !disposed && identical(project, owner) && navigation == _opening;
    if (!current()) {
      throw CoreFailure(
        'search.owner',
        'The search belongs to another workspace',
      );
    }
    if (!await flush()) {
      throw CoreFailure(
        'draft.pending',
        'Resolve pending fields before replacement',
      );
    }
    if (!current()) {
      throw CoreFailure(
        'search.owner',
        'The workspace changed before replacement',
      );
    }
    snapshot.replace(owner.store, replacement);
    for (final resource in snapshot.resources) {
      _invalidateResource(resource['id'] as String);
    }
    try {
      await persist();
    } on Object {
      if (current()) {
        schedule(immediate: true);
        notifyListeners();
      }
      throw CoreFailure(
        'search.applied.recovery',
        'Replacement was applied to buffers, but its recovery checkpoint failed',
      );
    }
    if (!current()) return;
    schedule(immediate: true);
    notifyListeners();
  }

  Future<RefactoringPlan> planReferenceSelection(
    BusyProject owner,
    ReferenceChoicePage page,
    int index, {
    String? requestId,
    bool Function()? cancelled,
  }) async {
    final navigation = _opening;
    bool current() =>
        !disposed && identical(project, owner) && _opening == navigation;
    if (!current()) {
      throw CoreFailure(
        'refactor.owner',
        'The captured workspace is no longer open',
      );
    }
    final generations = {
      for (final b in owner.store.buffers.values) b.id: b.generation,
    };
    try {
      return await owner.planReferenceSelection(
        page,
        index,
        requestId: requestId,
        cancelled: () => !current() || cancelled?.call() == true,
      );
    } finally {
      // Snapshot collection may reload a clean open resource before rejecting
      // a stale choice. Existing Source owners must observe that real reload.
      if (current() &&
          owner.store.buffers.values.any(
            (b) => generations[b.id] != b.generation,
          )) {
        cached.clear();
        schedule(immediate: true);
        notifyListeners();
      }
    }
  }

  Future<RefactoringPlan> planDiagnosticFix(
    BusyProject owner,
    Map<String, dynamic> diagnostic, {
    required String contextSnapshot,
    required String fix,
    String? requestId,
    bool Function()? cancelled,
  }) async {
    final navigation = _opening, selectedRoot = root;
    bool current() =>
        !disposed &&
        identical(project, owner) &&
        _opening == navigation &&
        root == selectedRoot &&
        !(cancelled?.call() ?? false);
    if (!current() ||
        diagnostic['root'] != selectedRoot ||
        !await flush() ||
        !current()) {
      throw CoreFailure(
        'fix.owner',
        'The diagnostic workspace changed or has pending fields',
      );
    }
    final generations = {
      for (final b in owner.store.buffers.values) b.id: b.generation,
    };
    try {
      return await owner.planDiagnosticFix(
        diagnostic,
        contextSnapshot: contextSnapshot,
        fix: fix,
        requestId: requestId,
        cancelled: () => !current(),
      );
    } finally {
      if (!disposed &&
          identical(project, owner) &&
          owner.store.buffers.values.any(
            (b) => generations[b.id] != b.generation,
          )) {
        cached.clear();
        schedule(immediate: true);
        notifyListeners();
      }
    }
  }

  Future<void> applyRefactoring(BusyProject owner, RefactoringPlan plan) async {
    final navigation = _opening;
    bool current() =>
        !disposed && identical(project, owner) && navigation == _opening;
    if (!current() || !await flush() || !current()) {
      throw CoreFailure(
        'refactor.owner',
        'Resolve pending input in the captured workspace before applying',
      );
    }
    Set<String> changed;
    try {
      changed = await owner.applyRefactoring(plan, current: current);
    } finally {
      // Freshness checks may reload a clean resource even when the proposal is
      // rejected. Mounted Source owners must observe that independent reload.
      if (current()) {
        cached.clear();
        schedule(immediate: true);
        notifyListeners();
      }
    }
    if (!current()) return;
    if (changed.isNotEmpty) {
      _followSemanticTransitions(plan.transitions);
    }
    draft = null;
    try {
      await persist();
      await persistView();
    } on Object {
      if (current()) notifyListeners();
      throw CoreFailure(
        'refactor.applied.recovery',
        'Refactoring was applied to buffers, but its recovery checkpoint failed',
      );
    }
    if (current()) notifyListeners();
  }

  Future<FileDeletionPlan> planFileDeletion(
    BusyProject owner,
    String resource,
  ) => _planFileImpact(
    owner,
    (refreshed) =>
        owner.planFileDeletion(resource, onResourceRefreshed: refreshed),
  );

  Future<RootRemovalPlan> planRootRemoval(
    BusyProject owner,
    ProjectRoot declaration,
  ) => _planFileImpact(
    owner,
    (refreshed) => owner.planRootRemoval(
      declaration.name,
      declaration.id,
      onResourceRefreshed: refreshed,
    ),
  );

  Future<FileMovePlan> planFileMove(
    BusyProject owner,
    String resource,
    String destination, {
    bool retainIdentity = false,
  }) => _planFileImpact(
    owner,
    (refreshed) => owner.planFileMove(
      resource,
      destination,
      retainIdentity: retainIdentity,
      onResourceRefreshed: refreshed,
    ),
  );

  Future<FileCreationPlan> planComponentExtractionToFile(
    BusyProject owner,
    Map<String, Object?> target,
    String name,
    String destination,
  ) => _planFileImpact(
    owner,
    (refreshed) => owner.planComponentExtractionToFile(
      target,
      name,
      destination,
      onResourceRefreshed: refreshed,
    ),
  );

  Future<T> _planFileImpact<T>(
    BusyProject owner,
    Future<T> Function(void Function(String resource)) prepare,
  ) async {
    final opening = _opening;
    bool current() =>
        !disposed && identical(project, owner) && _opening == opening;
    if (!current()) {
      throw CoreFailure(
        'refactor.owner',
        'The captured workspace is no longer open',
      );
    }
    final generations = {
      for (final b in owner.store.buffers.values) b.id: b.generation,
    };
    try {
      return await prepare((_) {
        if (!current()) return;
        cached.clear();
        schedule();
        notifyListeners();
      });
    } finally {
      if (current() &&
          owner.store.buffers.values.any(
            (b) => generations[b.id] != b.generation,
          )) {
        cached.clear();
        schedule(immediate: true);
        notifyListeners();
      }
    }
  }

  Future<bool> recoverFileOperation(
    Map<String, dynamic> record, {
    bool publication = false,
  }) async {
    final owner = project, navigation = _opening;
    bool current() =>
        !disposed && identical(project, owner) && navigation == _opening;
    if (owner == null || !await flush() || !current()) return false;
    if (publication) {
      await publications.recoverFileMoves(owner, record);
    } else {
      await recovery.adoptFileMoves(record, owner.recoveryOwner);
    }
    if (!current()) return false;
    final entries = record[publication ? 'outcomes' : 'buffers'] as List;
    _followSemanticTransitions([
      for (final value in entries)
        if (Uri.file(value['sourcePath'] as String).toString() != value['id'])
          SemanticTransition(
            Uri.file(value['sourcePath'] as String).toString(),
            '',
            '',
            destinationResource: value['id'] as String,
          ),
    ]);
    final formRecord = record['form'], draftRecord = record['draft'];
    final destination = formRecord is Map
        ? formRecord['target']['buffer']
        : draftRecord is Map
        ? draftRecord['buffer']
        : entries.first['id'];
    await openFile(destination as String);
    if (!current()) return false;
    if (draftRecord is Map) {
      draft = PropertySession.restore(Map<String, dynamic>.from(draftRecord));
    }
    if (formRecord is Map) {
      form = FormSession.restore(Map<String, dynamic>.from(formRecord));
    }
    mode = 'Source';
    schedule(immediate: true);
    notifyListeners();
    return true;
  }

  void _followSemanticTransitions(List<SemanticTransition> transitions) {
    if (transitions.isEmpty) return;
    String? occurrence(String? value, SemanticTransition t) {
      if (value == null) return null;
      for (final prefix in ['${t.resource}#', 'definition:${t.resource}#']) {
        if (value.startsWith(prefix)) {
          final pointer = value.substring(prefix.length);
          if (!t.affects(pointer)) return value;
          final nextPrefix = prefix.startsWith('definition:')
              ? 'definition:${t.toResource}#'
              : '${t.toResource}#';
          return '$nextPrefix${t.map(pointer)}';
        }
      }
      return value;
    }

    for (final t in transitions) {
      if (t.from.isEmpty && t.to.isEmpty && t.mode != 'relocation') {
        _followFilePresence(t);
        continue;
      }
      final fileMove =
          t.from.isEmpty && t.to.isEmpty && t.resource != t.toResource;
      final folds = layoutState['sourceFolds'];
      if (folds is Map) {
        final mapped = <String, Object?>{};
        for (final entry in folds.entries) {
          if (entry.key is! String || entry.value is! List) continue;
          try {
            final key = jsonDecode(entry.key as String);
            if (key is! List || key.length != 2) {
              mapped[entry.key as String] = entry.value;
              continue;
            }
            if ((entry.value as List).isEmpty) {
              mapped.putIfAbsent(
                jsonEncode([
                  key[0],
                  fileMove && key[1] == t.resource ? t.toResource : key[1],
                ]),
                () => <String>[],
              );
            }
            for (final pointer in (entry.value as List).whereType<String>()) {
              final target = jsonEncode([
                key[0],
                key[1] == t.resource
                    ? t.mapResource(t.resource, pointer)
                    : key[1],
              ]);
              final values =
                  mapped.putIfAbsent(target, () => <String>[]) as List<String>;
              final next = key[1] == t.resource ? t.map(pointer) : pointer;
              if ((next == pointer || t.mode == 'relocation') &&
                  !values.contains(next)) {
                values.add(next);
              }
            }
          } on FormatException {
            mapped[entry.key as String] = entry.value;
          }
        }
        layoutState = {...layoutState, 'sourceFolds': mapped};
      }
      Map<String, dynamic> location(Map value) {
        final next = Map<String, dynamic>.from(value);
        if (fileMove && next['root'] == t.resource) next['root'] = t.toResource;
        if (next['resource'] == t.resource && next['pointer'] is String) {
          next['resource'] = t.mapResource(
            t.resource,
            next['pointer'] as String,
          );
          next['pointer'] = t.map(next['pointer'] as String);
          next.remove('range');
          next.remove('generation');
        }
        // Logical occurrences belong to the entry root even when their
        // authored operation is in a different, unmoved resource.
        if (next['occurrence'] is String) {
          next['occurrence'] = occurrence(next['occurrence'] as String, t);
        }
        return next;
      }

      if (_referenceNavigation case final target?) {
        _referenceNavigation = location(target);
      }
      final reference = layoutState['nativeReference'];
      if (reference is Map) {
        layoutState = {
          ...layoutState,
          'nativeReference': {
            for (final entry in reference.entries)
              entry.key: entry.value is! Map
                  ? entry.value
                  : {
                      ...entry.value as Map,
                      if (entry.value['detail'] is Map)
                        'detail': location(entry.value['detail']),
                      if (entry.value['trail'] is List)
                        'trail': [
                          for (final target in entry.value['trail'])
                            if (target is Map) location(target),
                        ],
                    },
          },
        };
      }
      for (final namespace in ['referenceObjects', 'referenceText']) {
        final objects = layoutState[namespace];
        if (objects is Map) {
          final next = <String, dynamic>{};
          for (final entry in objects.entries) {
            if (entry.key is! String) continue;
            try {
              final key = jsonDecode(entry.key as String);
              if (key is List &&
                  (key.length == 4 || key.length == 5) &&
                  key[2] is String) {
                if (key.length == 5 && key[4] is String) {
                  final mappedOccurrence = occurrence(key[4] as String, t);
                  if (mappedOccurrence != key[4] && t.mode != 'relocation') {
                    continue;
                  }
                  key[4] = mappedOccurrence;
                }
                if (key[1] == t.resource) {
                  final mapped = t.map(key[2] as String);
                  // A removed object's offset is not a parent's reading offset.
                  if (mapped != key[2] && t.mode != 'relocation') continue;
                  key[1] = t.mapResource(t.resource, key[2] as String);
                  key[2] = mapped;
                }
                var state = entry.value;
                if (state is Map && state['occurrence'] is String) {
                  final previous = state['occurrence'] as String;
                  final mappedOccurrence = occurrence(previous, t);
                  if (mappedOccurrence != previous && t.mode != 'relocation') {
                    continue;
                  }
                  state = {...state, 'occurrence': mappedOccurrence};
                }
                next[jsonEncode(key)] = state;
              } else {
                next[entry.key] = entry.value;
              }
            } on FormatException {
              next[entry.key] = entry.value;
            }
          }
          layoutState = {...layoutState, namespace: next};
        }
      }
      if ((selectedResource ?? root) == t.resource) {
        final moved = t.affects(selectedPointer);
        selectedResource = t.mapResource(t.resource, selectedPointer);
        selectedPointer = t.map(selectedPointer);
        selectedOccurrence = occurrence(selectedOccurrence, t);
        if (moved && active == t.resource && t.toResource != t.resource) {
          active = t.toResource;
          if (!tabs.contains(active)) tabs.add(active!);
        }
      }
      for (final entry in viewStates.entries) {
        final state = entry.value;
        if ((state['resource'] ?? entry.key) != t.resource) continue;
        if (state['pointer'] is String) {
          final pointer = state['pointer'] as String;
          state['resource'] = t.mapResource(t.resource, pointer);
          if (state['active'] == t.resource && t.affects(pointer)) {
            state['active'] = t.toResource;
          }
          state['pointer'] = t.map(state['pointer'] as String);
        }
        state['occurrence'] = occurrence(state['occurrence'] as String?, t);
      }
      for (final entry in history) {
        if ((entry['selectedResource'] ?? entry['resource']) != t.resource) {
          continue;
        }
        if (entry['pointer'] is String) {
          final pointer = entry['pointer'] as String;
          entry['selectedResource'] = t.mapResource(t.resource, pointer);
          if (entry['resource'] == t.resource && t.affects(pointer)) {
            entry['resource'] = t.toResource;
          }
          entry['pointer'] = t.map(entry['pointer'] as String);
        }
        entry['occurrence'] = occurrence(entry['occurrence'] as String?, t);
      }
      final trees = layoutState['schemaTrees'];
      if (trees is Map) {
        final mapped = <String, dynamic>{};
        final transfers = <String, Map<String, dynamic>>{};
        String destinationTree(
          Object? contextRoot,
          String resource,
          String pointer,
        ) {
          var owner = pointer;
          for (final candidate in trees.keys.whereType<String>()) {
            try {
              final key = jsonDecode(candidate);
              if (key is List &&
                  key.length == 3 &&
                  key[0] == contextRoot &&
                  key[1] == resource &&
                  key[2] is String) {
                final at = key[2] as String;
                if ((pointer == at || pointer.startsWith('$at/')) &&
                    (owner == pointer || at.length > owner.length)) {
                  owner = at;
                }
              }
            } on FormatException {
              /* Unrelated private preferences stay unchanged. */
            }
          }
          return jsonEncode([contextRoot, resource, owner]);
        }

        for (final entry in trees.entries) {
          if (entry.key is! String || entry.value is! Map) continue;
          try {
            final key = jsonDecode(entry.key as String);
            if (key is! List ||
                key.length != 3 ||
                key[1] != t.resource ||
                key[2] is! String) {
              mapped[entry.key as String] = entry.value;
              continue;
            }
            final movedTreeRoot = t.affects(key[2] as String);
            final pointer = t.map(key[2] as String);
            if (t.mode != 'relocation' && pointer != key[2]) continue;
            final nextResource = t.mapResource(t.resource, key[2] as String);
            key[1] = nextResource;
            key[2] = pointer;
            String? mapTreePointer(String value) {
              if (t.mapResource(t.resource, value) != nextResource) return null;
              final next = t.map(value);
              if (next != pointer && !next.startsWith('$pointer/')) return null;
              return t.mode == 'relocation' || next == value ? next : null;
            }

            final value = Map<String, dynamic>.from(entry.value as Map);
            final expansion = value['expanded'], counts = value['counts'];
            if (t.mode == 'relocation' &&
                !(t.toResource == nextResource &&
                    (t.to == pointer || t.to.startsWith('$pointer/')))) {
              final transferred = <String>[
                if (expansion is List)
                  for (final item in expansion.whereType<String>())
                    if (t.affects(item)) t.map(item),
              ];
              final transferredCounts = <String, Object?>{
                if (counts is Map)
                  for (final pair in counts.entries)
                    if (pair.key is String && t.affects(pair.key as String))
                      t.map(pair.key as String): pair.value,
              };
              if (transferred.isNotEmpty || transferredCounts.isNotEmpty) {
                final destination = destinationTree(key[0], t.toResource, t.to);
                final previous = transfers[destination];
                transfers[destination] = {
                  'expanded': <String>{
                    t.to,
                    if (previous != null && previous['expanded'] is List)
                      ...(previous['expanded'] as List).whereType<String>(),
                    ...transferred,
                  }.toList(),
                  'counts': {
                    if (previous != null && previous['counts'] is Map)
                      ...previous['counts'] as Map,
                    ...transferredCounts,
                  },
                  'selection':
                      expansion is List &&
                          value['selection'] is String &&
                          t.affects(value['selection'] as String)
                      ? t.map(value['selection'] as String)
                      : t.to,
                };
              }
            }
            value['expanded'] = [
              if (expansion is List)
                for (final item in expansion.whereType<String>())
                  if (mapTreePointer(item) != null) mapTreePointer(item),
            ];
            value['counts'] = {
              if (counts is Map)
                for (final pair in counts.entries)
                  if (pair.key is String && mapTreePointer(pair.key) != null)
                    mapTreePointer(pair.key)!: pair.value,
            };
            if (value['selection'] is String) {
              final selected = value['selection'] as String;
              value['selection'] =
                  t.mapResource(t.resource, selected) == nextResource
                  ? t.map(selected)
                  : pointer;
            }
            if (t.mode == 'relocation' && movedTreeRoot) {
              final destination = destinationTree(
                key[0],
                nextResource,
                pointer,
              );
              transfers[destination] = value;
            } else {
              mapped[jsonEncode(key)] = value;
            }
          } on FormatException {
            mapped[entry.key as String] = entry.value;
          }
        }
        for (final entry in transfers.entries) {
          final previous = mapped[entry.key], incoming = entry.value;
          mapped.remove(entry.key);
          mapped[entry.key] = {
            ...incoming,
            if (previous is Map) ...previous,
            if (incoming['selection'] is String)
              'selection': incoming['selection'],
            'expanded': <String>{
              if (previous is Map && previous['expanded'] is List)
                ...(previous['expanded'] as List).whereType<String>(),
              if (incoming['expanded'] is List)
                ...(incoming['expanded'] as List).whereType<String>(),
            }.toList(),
            'counts': {
              if (previous is Map && previous['counts'] is Map)
                ...previous['counts'] as Map,
              if (incoming['counts'] is Map) ...incoming['counts'] as Map,
            },
          };
        }
        while (mapped.length > 64) {
          mapped.remove(mapped.keys.first);
        }
        layoutState = {...layoutState, 'schemaTrees': mapped};
      }
      final pages = layoutState['objectPages'];
      if (pages is Map && t.mode == 'relocation') {
        final next = Map<String, dynamic>.from(pages);
        for (final entry in pages.entries) {
          if (entry.key is! String) continue;
          for (final entryRoot in project!.roots) {
            final prefix = '${entryRoot.id}#${t.resource}#';
            if (!(entry.key as String).startsWith(prefix)) continue;
            final pointer = (entry.key as String).substring(prefix.length);
            final mapped =
                '${entryRoot.id}#${t.mapResource(t.resource, pointer)}#${t.map(pointer)}';
            if (mapped != entry.key) {
              next.remove(entry.key);
              next[mapped] = entry.value;
            }
          }
        }
        layoutState = {...layoutState, 'objectPages': next};
      }
      if (fileMove) {
        for (var i = 0; i < tabs.length; i++) {
          if (tabs[i] == t.resource) tabs[i] = t.toResource;
        }
        final unique = tabs.toSet().toList();
        tabs
          ..clear()
          ..addAll(unique);
        if (active == t.resource) active = t.toResource;
        if (root == t.resource) root = t.toResource;
        if (viewStates.containsKey(t.resource)) {
          viewStates[t.toResource] = viewStates.remove(t.resource)!;
        }
        for (final state in viewStates.values) {
          if (state['active'] == t.resource) state['active'] = t.toResource;
        }
        for (final state in history) {
          if (state['root'] == t.resource) state['root'] = t.toResource;
        }
        for (final namespace in [
          'sourceFolds',
          'schemaTrees',
          'referenceObjects',
          'referenceText',
        ]) {
          final values = layoutState[namespace];
          if (values is! Map) continue;
          final mapped = <String, Object?>{};
          for (final e in values.entries) {
            var id = e.key as String;
            try {
              final key = jsonDecode(id);
              if (key is List && key.isNotEmpty && key[0] == t.resource) {
                key[0] = t.toResource;
                id = jsonEncode(key);
              }
            } on FormatException {
              /* Unrelated preferences. */
            }
            mapped[id] = e.value;
          }
          layoutState = {...layoutState, namespace: mapped};
        }
        for (final namespace in ['nativeReference', 'objectPages']) {
          final values = layoutState[namespace];
          if (values is! Map) continue;
          final mapped = <String, Object?>{};
          for (final e in values.entries) {
            var key = e.key as String;
            if (namespace == 'nativeReference') {
              try {
                final parts = jsonDecode(key);
                if (parts is List &&
                    parts.length == 1 &&
                    parts[0] == t.resource) {
                  key = jsonEncode([t.toResource]);
                }
              } on FormatException {
                /* Unrelated preferences. */
              }
            }
            if (key == t.resource) key = t.toResource;
            if (key.startsWith('${t.resource}#')) {
              key = t.toResource + key.substring(t.resource.length);
            }
            if (namespace == 'objectPages') {
              key = key.replaceFirst('#${t.resource}#', '#${t.toResource}#');
            }
            mapped[key] = e.value;
          }
          layoutState = {...layoutState, namespace: mapped};
        }
        _context++;
        analysis = null;
        lastGood = null;
        cached.clear();
      }
    }
    _semanticViewRevision++;
  }

  void _followFilePresence(SemanticTransition transition) {
    final id = transition.toResource;
    if (id != transition.resource) {
      _followSemanticTransitions([
        SemanticTransition(
          transition.resource,
          '',
          '',
          destinationResource: id,
        ),
      ]);
    }
    final previous = layoutState['filePresenceViews'];
    final records = previous is Map
        ? Map<String, dynamic>.from(previous)
        : <String, dynamic>{};
    if (transition.mode == 'removal') {
      final at = tabs.indexOf(id),
          wasActive = active == id,
          selected = selectedResource == id;
      final remembered = <String, Object?>{
        'root': root,
        'tab': at,
        'active': wasActive,
        'selected': selected,
        'pointer': selectedPointer,
        'occurrence': selectedOccurrence,
      };
      tabs.removeWhere((resource) => resource == id);
      if (wasActive) {
        ++_selection;
        active = root != id && store?.buffers.containsKey(root) == true
            ? root
            : tabs
                  .where(
                    (resource) => store?.buffers.containsKey(resource) == true,
                  )
                  .firstOrNull;
      }
      if (selected) {
        selectedResource = root;
        selectedPointer = '/info';
        selectedOccurrence = null;
      }
      remembered['navigation'] = _selection;
      remembered['fallback'] = active;
      records[id] = remembered;
      while (records.length > 128) {
        records.remove(records.keys.first);
      }
    } else {
      final remembered = records.remove(id);
      if (remembered is Map && store?.buffers.containsKey(id) == true) {
        final at = remembered['tab'];
        if (at is int && at >= 0 && !tabs.contains(id)) {
          tabs.insert(at.clamp(0, tabs.length), id);
        }
        if (remembered['root'] == root &&
            remembered['navigation'] == _selection &&
            remembered['fallback'] == active) {
          if (remembered['active'] == true) {
            ++_selection;
            active = id;
          }
          if (remembered['selected'] == true) {
            selectedResource = id;
            selectedPointer = remembered['pointer'] as String;
            selectedOccurrence = remembered['occurrence'] as String?;
          }
        }
      }
    }
    layoutState = {...layoutState, 'filePresenceViews': records};
    _context++;
    analysis = null;
    // Keep the mounted Reference and its reading position, explicitly outdated
    // until current feedback arrives; an unrelated file addition is not a new
    // root or permission to discard the accepted last-good projection.
    cached.clear();
  }

  PropertySession bind(Map<String, dynamic> item) {
    if (item['shared'] == true) {
      throw CoreFailure(
        'draft.shared',
        'This operation belongs to a referenced Path Item. Edit its shared definition explicitly in Source.',
      );
    }
    final b = store!.get(item['resource']);
    if (draft != null &&
        draft!.pointer == item['pointer'] &&
        draft!.buffer == b.id &&
        (draft!.pending || draft!.generation == b.generation)) {
      return draft!;
    }
    if (item['root'] != null && item['root'] != root) {
      throw CoreFailure(
        'draft.root',
        'This form belongs to another contract root',
      );
    }
    if (item['generation'] != null && item['generation'] != b.generation) {
      throw CoreFailure(
        'draft.stale',
        'This form belongs to an older source generation; the captured occurrence must be reviewed',
      );
    }
    final range = List<int>.from(item['range']);
    draft = PropertySession(
      root: root ?? b.id,
      buffer: b.id,
      generation: b.generation,
      pointer: item['pointer'],
      range: range,
      expected: b.text.substring(range[0], range[1]),
    );
    return draft!;
  }

  Future<bool>? _flushing;
  Future<bool> flush() => _flushPending();

  Future<bool> _flushPending({bool acceptedSave = false}) async {
    if (_disposed || (_shuttingDown && !acceptedSave)) return false;
    if (form != null || formApplying) {
      error = 'Apply or explicitly discard the captured dialog before leaving its source target.';
      notifyListeners();
      return false;
    }
    final applying = _flushing;
    if (applying != null) {
      final completed = await applying;
      if (identical(_flushing, applying)) _flushing = null;
      if (draft?.pending ?? false) {
        return _flushPending(acceptedSave: acceptedSave);
      }
      return completed;
    }
    _flushing = _flush();
    try {
      return await _flushing!;
    } finally {
      _flushing = null;
    }
  }

  Future<bool> _flush() async {
    final captured = project, selectedRoot = root, opening = _opening;
    bool current() =>
        !_disposed &&
        identical(project, captured) &&
        root == selectedRoot &&
        opening == _opening;
    final pending = draft;
    if (pending == null || !pending.pending) {
      // Mounted fields still share this input owner. A committed field's blur
      // can flush immediately before its neighbour receives input; clearing
      // the clean binding here would orphan that neighbour's callbacks.
      // Navigation/model reconciliation replaces it at the normal boundary.
      return true;
    }
    try {
      final accepted = Map<String, Object?>.from(pending.values);
      final rebound = await captured!.proposeAndApply(
        selectedRoot!,
        pending,
        pending.actions(),
        acceptedValues: accepted,
        current: current,
      );
      if (!current()) return false;
      if (rebound == null) {
        throw CoreFailure(
          'draft.target',
          'The accepted target is unavailable; pending input remains captured',
        );
      }
      _invalidateResource(pending.buffer);
      draft = rebound;
      error = rebound.pending
          ? 'New input arrived while fields were applying. Finish the current draft before continuing.'
          : null;
      await persist();
      if (!current()) return false;
      schedule(immediate: true);
      return !rebound.pending;
    } on Object catch (e) {
      if (!current()) return false;
      pending.errors['session'] = e.toString();
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> mutate(
    Map<String, dynamic> item,
    List<Map<String, Object?>> actions, {
    String? authoredField,
  }) async {
    final capturedProject = project;
    final capturedRoot = root, opening = _opening;
    bool current() =>
        !disposed &&
        capturedProject != null &&
        identical(project, capturedProject) &&
        root == capturedRoot &&
        opening == _opening;
    if (!current()) {
      throw CoreFailure('draft.owner', 'Workspace is no longer active');
    }
    if (!await (formApplying ? _flush() : flush())) {
      throw CoreFailure('draft.pending', 'Resolve pending fields first');
    }
    if (!current()) {
      throw CoreFailure('draft.owner', 'Workspace changed before applying');
    }
    final fieldPointer = authoredField == null
        ? null
        : '${item['pointer']}/${authoredField.replaceAll('~', '~0').replaceAll('/', '~1')}';
    final singleField =
        authoredField == null ||
        actions.length == 1 &&
            const [
              'set',
              'setData',
              'remove',
            ].contains(actions.single['kind']) &&
            actions.single['pointer'] == fieldPointer;
    if (!singleField || !scopeSafe(item, authoredField: authoredField)) {
      throw CoreFailure(
        'draft.scope',
        'This source scope is unavailable or changed; retain the draft and review its source',
      );
    }
    final session = bind(item);
    await capturedProject!.proposeAndApply(
      capturedRoot!,
      session,
      actions,
      current: current,
    );
    if (!current()) {
      throw CoreFailure('draft.owner', 'Workspace changed while applying');
    }
    draft = null;
    error = null;
    _invalidateResource(session.buffer);
    await persist();
    if (!current()) return;
    await analyse();
    if (current()) notifyListeners();
  }

  void _invalidateResource(String id) {
    for (final entry
        in project?.dependencies.entries ?? <MapEntry<String, Set<String>>>[]) {
      if (entry.value.contains(id)) cached.remove(entry.key);
    }
  }

  void sourceDelta(TextEdit edit) {
    if (disposed) return;
    store!.apply([edit], label: 'Source');
    _invalidateResource(edit.buffer);
    checkpoint();
    schedule(notify: false);
    _notifySource();
  }

  void sourceEdit(String id, String text) {
    if (disposed) return;
    store!.replace(id, text);
    _invalidateResource(id);
    checkpoint();
    schedule(notify: false);
    _notifySource();
  }

  bool _sourceNotification = false;
  bool get sourceNotification => _sourceNotification;

  void _notifySource() {
    final previous = _sourceNotification;
    _sourceNotification = true;
    try {
      notifyListeners();
    } finally {
      _sourceNotification = previous;
    }
  }

  Future<void> persist() async {
    final captured = project;
    if (captured == null) return;
    try {
      if (await recovery.persistFileMoves(
        captured.recoveryOwner,
        draft: draft?.pending == true ? draft : null,
        form: form ?? _applyingForm,
      )) {
        if (identical(project, captured)) storageError = null;
        return;
      }
      for (final b in captured.store.buffers.values.toList()) {
        if (captured.store.fileBuffers.any(
          (b) => b.hasFileIntent || b.pendingFilePublication,
        )) {
          await recovery.persistFileMoves(
            captured.recoveryOwner,
            draft: draft?.pending == true ? draft : null,
            form: form ?? _applyingForm,
          );
          return;
        }
        final capturedForm = form ?? _applyingForm;
        await recovery.persist(
          b,
          draft: draft?.buffer == b.id && draft!.pending ? draft : null,
          form: capturedForm?.target.buffer == b.id ? capturedForm : null,
        );
      }
      if (identical(project, captured)) storageError = null;
    } on Object catch (e) {
      if (identical(project, captured)) storageError = e.toString();
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  void checkpoint() {
    unawaited(
      persist().catchError((Object e) {
        if (!_disposed) {
          error = e.toString();
          notifyListeners();
        }
      }),
    );
  }

  FormSession beginForm(
    String kind,
    Map<String, dynamic> item,
    Map<String, Object?> arguments,
    Map<String, dynamic> initial,
  ) {
    if (_disposed || form != null || formApplying) {
      throw CoreFailure(
        'draft.pending',
        'Another captured form needs resolution',
      );
    }
    final target = bind(item), b = store!.get(target.buffer);
    draft = null;
    final session = FormSession(
      kind: kind,
      target: target,
      contentIdentity: textIdentity(b.text),
      arguments: arguments,
      initial: Map<String, Object?>.from(initial),
    );
    final recovered = restoringForm;
    if (recovered != null) {
      recovered.verify(b, root!, restoring: true);
      if (recovered.kind != kind ||
          recovered.target.pointer != target.pointer ||
          jsonEncode(recovered.arguments) != jsonEncode(arguments)) {
        throw CoreFailure(
          'draft.target',
          'Recovered dialog ownership does not match',
        );
      }
      session.values
        ..clear()
        ..addAll(recovered.values);
      restoringForm = null;
    }
    form = session;
    notifyListeners();
    return session;
  }

  Future<void> applyForm(
    FormSession owner,
    Future<void> Function() apply,
  ) async {
    if (!ownsForm(owner) || formApplying) {
      throw CoreFailure(
        'draft.owner',
        'This dialog is no longer the active captured form',
      );
    }
    owner.verify(store!.get(owner.target.buffer), root!);
    formApplying = true;
    _applyingForm = owner;
    form = null;
    final capturedProject = project;
    try {
      await apply();
      _applyingForm = null;
      await persist();
    } on Object {
      if (!_disposed && identical(project, capturedProject) && form == null) {
        form = owner;
      }
      _applyingForm = null;
      checkpoint();
      rethrow;
    } finally {
      formApplying = false;
      _applyingForm = null;
    }
  }

  Future<void> cancelForm(FormSession owner) async {
    if (_disposed || formApplying) return;
    if (identical(form, owner)) {
      form = null;
      await persist();
      if (!_disposed) notifyListeners();
    }
  }

  bool ownsForm(FormSession owner) =>
      !_disposed && identical(form, owner) && root == owner.target.root;

  void setMode(String value) {
    if (disposed) return;
    mode = value;
    notifyListeners();
  }

  Future<void> discardDrafts() async {
    if (disposed) return;
    final owner = project, navigation = _opening;
    if (formApplying) {
      throw CoreFailure('draft.applying', 'Wait for the current transaction');
    }
    draft?.discard();
    draft = null;
    form = null;
    restoringForm = null;
    await persist();
    if (!disposed && identical(project, owner) && navigation == _opening) {
      notifyListeners();
    }
  }

  Future<void> resumePropertyDraft() async {
    final captured = draft;
    if (captured == null) return;
    final b = store!.get(captured.buffer), range = captured.range;
    if (range.length != 2 ||
        range[0] < 0 ||
        range[1] > b.text.length ||
        b.text.substring(range[0], range[1]) != captured.expected) {
      throw CoreFailure(
        'draft.stale',
        'Recovered fields remain attached to an unavailable source occurrence',
      );
    }
    draft = null;
    try {
      if (root != captured.root) await selectRoot(captured.root);
      await analyse();
      final candidates = [
        projection?['info'],
        ...projection?['operations'] ?? [],
      ];
      final item = candidates.firstWhere(
        (v) =>
            v != null &&
            v['resource'] == captured.buffer &&
            v['pointer'] == captured.pointer &&
            jsonEncode(v['range']) == jsonEncode(range),
      );
      final rebound = bind(Map<String, dynamic>.from(item));
      rebound.committed.addAll(captured.committed);
      rebound.values.addAll(captured.values);
      active = captured.buffer;
      selectedPointer = captured.pointer;
      mode = 'Design';
      checkpoint();
      notifyListeners();
    } on Object {
      draft = captured;
      rethrow;
    }
  }

  void schedule({bool immediate = false, bool notify = true}) {
    if (disposed) return;
    _debounce?.cancel();
    _context++;
    analysis = null;
    unawaited(engine.cancelPrefix('ui-'));
    checking = true;
    checkingSemantics = false;
    if (notify) notifyListeners();
    _debounce = Timer(
      Duration(milliseconds: immediate ? 0 : 300),
      () => analyse(),
    );
  }

  Future<PolicyCodeReview> reviewGovernanceCode({
    required String requestId,
    required bool Function() cancelled,
  }) async {
    final owner = project, selected = root, navigation = navigationGeneration;
    bool current() =>
        !disposed &&
        identical(owner, project) &&
        root == selected &&
        navigationGeneration == navigation &&
        !cancelled();
    if (owner == null || selected == null || !await flush() || !current()) {
      throw CoreFailure(
        'cancelled',
        'Code review no longer owns this project scope',
      );
    }
    final review = await owner.reviewPolicyCode(
      selected,
      requestId: requestId,
      cancelled: () => !current(),
      onResourceRefreshed: (_) {
        if (current()) notifyListeners();
      },
    );
    if (!current()) {
      throw CoreFailure(
        'cancelled',
        'Code review no longer owns this project scope',
      );
    }
    return review;
  }

  Future<void> runGovernance({PolicyCodeApproval? codeApproval}) async {
    final owner = project, selected = root, navigation = navigationGeneration;
    if (owner == null ||
        selected == null ||
        !await flush() ||
        disposed ||
        !identical(project, owner) ||
        root != selected ||
        navigationGeneration != navigation) {
      return;
    }
    _debounce?.cancel();
    _context++;
    await engine.cancelPrefix('ui-');
    if (disposed ||
        !identical(project, owner) ||
        root != selected ||
        navigationGeneration != navigation) {
      return;
    }
    await analyse(governance: true, codeApproval: codeApproval);
  }

  Future<void> analyse({
    bool governance = false,
    PolicyCodeApproval? codeApproval,
  }) async {
    if (disposed) return;
    _debounce?.cancel();
    final project = this.project, id = root ?? active, context = ++_context;
    if (project == null || id == null) return;
    if (governance) _governanceContext = context;
    final alreadyChecking = checking;
    checking = true;
    checkingSemantics = false;
    if (!alreadyChecking) notifyListeners();
    bool current() =>
        !disposed &&
        context == _context &&
        (root ?? active) == id &&
        identical(this.project, project);
    void adopt(Map<String, dynamic> result) {
      if (!current()) return;
      for (final resource in result['resources'] as List? ?? []) {
        final uri = Uri.parse(resource['id']);
        if (uri.scheme == 'file' && !project.files.contains(uri.toFilePath())) {
          project.files.add(uri.toFilePath());
        }
      }
      project.files.sort();
      analysis = result;
      final projection =
          result['projection'] as Map<String, dynamic>? ?? result;
      if (!(projection['status'] == 'incomplete' &&
              lastGood != null &&
              (projection['operations'] as List).length <
                  (lastGood!['operations'] as List).length) &&
          projection['info'] != null &&
          !(projection['findings'] as List).any(
            (finding) =>
                finding['category'] == 'syntax' ||
                finding['code'] == 'structure.type' ||
                finding['code'] == 'parameter.container.type',
          )) {
        lastGood = projection;
        cached[id] = projection;
        while (cached.length > 16) {
          cached.remove(cached.keys.first);
        }
      }
      error = null;
    }

    try {
      void refreshed(String _) {
        if (current()) notifyListeners();
      }

      void progress(Map<String, dynamic> result) {
        if (!current()) return;
        adopt(result);
        checking = false;
        checkingSemantics = true;
        notifyListeners();
      }

      final result = governance
          ? await project.lint(
              id,
              requestId: 'ui-$context',
              cancelled: () => !current(),
              onResourceRefreshed: refreshed,
              onProgress: progress,
              codeApproval: codeApproval,
            )
          : await project.check(
              id,
              requestId: 'ui-$context',
              cancelled: () => !current(),
              onResourceRefreshed: refreshed,
              onProgress: progress,
            );
      if (_disposed ||
          context != _context ||
          (root ?? active) != id ||
          !identical(this.project, project)) {
        return;
      }
      adopt(result);
    } on Object catch (e) {
      if (!_disposed &&
          context == _context &&
          identical(this.project, project)) {
        error = e.toString();
        analysis = null;
      }
    } finally {
      if (context == _context && !_disposed) {
        checking = false;
        checkingSemantics = false;
        notifyListeners();
      }
    }
  }

  Future<void> saveAll() => saveBuffers();
  Future<void>? _saving;
  int _queuedSaves = 0;
  Future<void> saveBuffers({Set<String>? only}) async {
    if (disposed || project == null) {
      throw CoreFailure('save.owner', 'No active workspace can be saved');
    }
    if (_queuedSaves >= 32) {
      throw CoreFailure(
        'save.queue',
        'Wait for the pending saves before saving again',
      );
    }
    final owner = project!, navigation = _opening;
    final selected = only == null ? null : Set<String>.unmodifiable(only);
    final previous = _saving;
    Future<void> run() async {
      if (previous != null) {
        try {
          await previous;
        } on Object {
          // That request reports its own failure. This separately selected save
          // must still evaluate its own current buffers and publication outcome.
        }
      }
      if (_disposed || !identical(project, owner) || navigation != _opening) {
        throw CoreFailure(
          'save.owner',
          'Workspace changed before this save could start',
        );
      }
      await _saveBuffers(only: selected);
    }

    _queuedSaves++;
    final next = run();
    _saving = next;
    try {
      await next;
    } finally {
      _queuedSaves--;
      if (identical(_saving, next)) _saving = null;
    }
  }

  Future<void> _saveBuffers({Set<String>? only}) async {
    final owner = project, navigation = _opening;
    // Only saveBuffers can enter this method, after accepting and freezing its
    // workspace/selection. Shutdown rejects new saves but drains these owners.
    if (!await _flushPending(acceptedSave: true)) {
      throw CoreFailure(
        'draft.pending',
        'Pending fields must be corrected or discarded',
      );
    }
    final captured = project;
    if (_disposed ||
        captured == null ||
        !identical(owner, captured) ||
        navigation != _opening) {
      throw CoreFailure(
        'save.owner',
        'Workspace changed while preparing this save',
      );
    }
    final chosen = captured
        .publicationBuffersFor(
          captured.store.fileBuffers.where(
            (b) =>
                (b.present || b.dirty) && (only == null || only.contains(b.id)),
          ),
        )
        .toList();
    final generations = {for (final b in chosen) b.id: b.generation};
    final result = await publications.save(captured, chosen);
    if (!disposed &&
        identical(project, captured) &&
        chosen.any((b) => b.generation != generations[b.id])) {
      for (final b in chosen) {
        _invalidateResource(b.id);
      }
      schedule(immediate: true);
    }
    await persist();
    if (!disposed && identical(project, captured) && navigation == _opening) {
      notifyListeners();
    }
    if (!result.complete) {
      throw CoreFailure(
        'save.partial',
        'Published: ${result.published.join(', ')}. Failed: ${result.failed}. Not attempted: ${result.notAttempted.join(', ')}. Recovery intent: ${result.journal}',
      );
    }
  }

  Future<void> undo() async {
    final owner = project, navigation = _opening;
    if (!await flush()) return;
    if (disposed || !identical(project, owner) || navigation != _opening) {
      return;
    }
    _followSemanticTransitions(owner?.store.undo() ?? const []);
    await persist();
    if (disposed || !identical(project, owner) || navigation != _opening) {
      return;
    }
    schedule(immediate: true);
    notifyListeners();
  }

  Future<void> redo() async {
    final owner = project, navigation = _opening;
    if (!await flush()) return;
    if (disposed || !identical(project, owner) || navigation != _opening) {
      return;
    }
    _followSemanticTransitions(owner?.store.redo() ?? const []);
    await persist();
    if (disposed || !identical(project, owner) || navigation != _opening) {
      return;
    }
    schedule(immediate: true);
    notifyListeners();
  }

  Future<void> discardAll() => discardBuffers();
  Future<BufferReloadResult> reloadFromDisk(
    BufferReloadCapture accepted, {
    Future<void> Function()? beforeReload,
  }) async {
    if (disposed || !identical(project, accepted.project)) {
      return const BufferReloadResult(BufferReloadStatus.stale);
    }
    final result = await accepted.project.reload(
      accepted.buffer,
      accepted: accepted,
      beforeReload: beforeReload,
    );
    final applied = result.applied;
    if (applied != null && !disposed && identical(project, accepted.project)) {
      schedule(immediate: true);
      notifyListeners();
      await recovery.retireIfCurrent(
        applied.id,
        () =>
            !disposed && identical(project, applied.project) && applied.current,
      );
    }
    return result;
  }

  Future<void> discardBuffers({Set<String>? only}) async {
    if (disposed) return;
    final owner = project, navigation = _opening;
    if (owner == null) return;
    final saving = _saving;
    if (saving != null) {
      final captured = {
        for (final b in owner.store.fileBuffers) b: b.generation,
      };
      try {
        await saving;
      } on Object {
        /* Its caller reports the save failure. */
      }
      if (disposed ||
          !identical(project, owner) ||
          navigation != _opening ||
          captured.entries.any((e) => e.key.generation != e.value)) {
        return;
      }
    }
    final selected = owner.store.fileBuffers
        .where(
          (b) =>
              (b.present || b.dirty) && (only == null || only.contains(b.id)),
        )
        .toList();
    final pendingBuffers = publications.pendingFileBuffers(owner);
    final pending = selected.any(pendingBuffers.contains);
    if (pending ||
        owner.fileMoveBuffersFor(selected).any((b) => b.hasFileIntent)) {
      final navigation = _opening;
      final rootName = owner.roots
          .where((entry) => entry.id == root)
          .firstOrNull
          ?.name;
      final generations = {
        for (final b in owner.store.fileBuffers) b: b.generation,
      };
      await discardDrafts();
      if (disposed || !identical(project, owner) || navigation != _opening) {
        return;
      }
      if (generations.entries.any((e) => e.key.generation != e.value)) return;
      if (pending) await publications.abandonFileMoves(owner);
      if (disposed ||
          !identical(project, owner) ||
          navigation != _opening ||
          generations.entries.any((e) => e.key.generation != e.value)) {
        return;
      }
      _followSemanticTransitions(
        owner.discardFileChanges(
          additionally: {...selected, ...pendingBuffers},
        ),
      );
      if (pending) {
        owner.reconcileRootConfiguration();
        final restored = owner.roots
            .where((entry) => entry.name == rootName)
            .firstOrNull;
        if (restored != null && restored.id != root) {
          await selectRoot(restored.id);
        }
      }
      await persist();
      schedule(immediate: true);
      notifyListeners();
      return;
    }
    final captures = [for (final b in selected) owner.captureReload(b)];
    await discardDrafts();
    if (disposed || !identical(project, owner) || navigation != _opening) {
      return;
    }
    // A late discard decision cannot erase input entered during persistence.
    if (captures.any((capture) => !capture.current)) return;
    for (final b in selected) {
      b.update(b.baseline);
    }
    owner.store.retireHistory(selected.map((b) => b.id).toSet());
    final discarded = [for (final b in selected) owner.captureReload(b)];
    for (final capture in discarded) {
      await recovery.retireIfCurrent(
        capture.id,
        () => !disposed && identical(project, owner) && capture.current,
      );
    }
    if (disposed || !identical(project, owner) || navigation != _opening) {
      return;
    }
    schedule(immediate: true);
    notifyListeners();
  }

  Future<void> shutdown() async {
    final previous = _shutdown;
    if (previous != null) return previous;
    final current = _closeOwnedWorkspace();
    _shutdown = current;
    try {
      await current;
    } finally {
      if (identical(_shutdown, current)) _shutdown = null;
    }
  }

  Future<void> _closeOwnedWorkspace() async {
    _shuttingDown = true;
    _context++;
    _debounce?.cancel();
    _monitor?.cancel();
    try {
      await _saving;
      _opening++;
      await persist();
      await persistView();
    } on Object {
      _shuttingDown = false;
      if (!_disposed && project != null) {
        _monitor = Timer.periodic(
          const Duration(seconds: 2),
          (_) => _pollDisk(),
        );
        schedule(immediate: true);
      }
      rethrow;
    }
    _disposed = true;
    if (project case final previous?) {
      publications.releaseProject(previous);
      previous.close();
    }
    await engine.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _monitor?.cancel();
    super.dispose();
  }
}
