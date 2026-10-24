import 'dart:async';
import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../l10n/generated/app_localizations.dart';
import '../platform/gtk_animation_settings_service.dart';
import '../platform/gtk_header_icon_service.dart';
import '../platform/documentation_window_service.dart';
import '../designer/designer.dart';
import '../reference/reference_view.dart';
import '../source/source_editor.dart';
import '../workspace/workspace_controller.dart';
import '../workspace/search_session.dart';
import '../workspace/search_sidebar.dart';
import '../workspace/file_move.dart';
import '../workspace/file_presence.dart';
import '../workspace/root_configuration.dart';
import '../workspace/api_navigator.dart';
import '../workspace/problems_panel.dart';
import '../workspace/document_status_bar.dart';
import '../workspace/diagnostic_fix.dart';
import '../workspace/bundle_run.dart';
import '../workspace/request_run.dart';
import '../workspace/mock_run.dart';
import '../workspace/git_workspace.dart';
import '../workspace/test_run.dart';
import '../workspace/governance_dialog.dart';
import '../workspace/output_destination.dart';
import '../workspace/bundle_actions.dart';
import '../workspace/project_import.dart';
import '../workspace/client_generation.dart';
import '../workspace/documentation_actions.dart';
import '../workspace/workspace_tab_button.dart';
import 'app_theme.dart';
import 'app_settings.dart';
import 'command_registry.dart';
import 'command_shortcuts.dart';
import 'shortcut_binding.dart';
import 'busyapi_motion_widgets.dart';
import 'path_label.dart';
import '../workspace/settings_screen.dart';
import 'busyapi_design.dart';
import 'busyapi_dialogs.dart';
import 'busyapi_glyphs.dart';
import 'busyapi_search_field.dart';
import 'busyapi_toast.dart';
import 'linux/linux_window_host.dart';
import 'linux/linux_page_frame.dart';
import 'linux/linux_header_style.dart';
import 'localization.dart';
import 'contract_labels.dart';
import 'system_accent.dart';
import 'window_control_service.dart';

enum _ShortcutPersistence { saved, pending, failed }

class BusyApiApp extends ConsumerStatefulWidget {
  const BusyApiApp({
    super.key,
    required this.controller,
    this.startupPath,
    this.chooseProjectDirectory,
    this.initializerBoundary,
    this.chooseBundleDestination,
    this.chooseDocumentationDestination,
    this.initialAppearance = const BusyApiAppearance(),
    this.saveAppearance = BusyApiAppearance.save,
    this.saveRequestShortcut = BusyApiRequestShortcut.save,
  });
  final WorkspaceController controller;
  final String? startupPath;
  final Future<String?> Function()? chooseProjectDirectory;
  final PublicationBoundary? initializerBoundary;
  final Future<String?> Function()? chooseBundleDestination;
  final Future<String?> Function()? chooseDocumentationDestination;
  final BusyApiAppearance initialAppearance;
  final Future<void> Function(StateLocations, ThemeMode) saveAppearance;
  final Future<void> Function(StateLocations, BusyApiKeyBinding)
  saveRequestShortcut;
  @override
  ConsumerState<BusyApiApp> createState() => _BusyApiAppState();
}

class _BusyApiAppState extends ConsumerState<BusyApiApp> {
  late ThemeMode mode;
  Object? appearanceFailure;
  Future<Object?> _lastAppearanceSave = Future<Object?>.value();
  int _appearanceGeneration = 0;
  BusyApiKeyBinding? _requestShortcut;
  int _requestShortcutGeneration = 0;
  late final Future<void> _requestShortcutLoad;
  Future<Object?> _requestShortcutSave = Future.value();
  BusyApiKeyBinding? _persistedRequestShortcut;
  _ShortcutPersistence _shortcutPersistence = _ShortcutPersistence.saved;
  final _workspaceKey = GlobalKey<WorkspaceScreenState>();
  @override
  void initState() {
    super.initState();
    mode = widget.initialAppearance.mode;
    appearanceFailure = widget.initialAppearance.failure;
    final generation = _requestShortcutGeneration;
    _requestShortcutLoad =
        BusyApiRequestShortcut.load(widget.controller.locations).then<void>(
          (binding) {
            if (mounted) {
              _persistedRequestShortcut = binding;
              if (generation == _requestShortcutGeneration) {
                setState(() => _requestShortcut = binding);
              }
            }
          },
          onError: (Object _) {
            /* Default binding remains visible. */
          },
        );
  }

  Future<void> configureRequestShortcut(
    String id,
    BusyApiKeyBinding binding,
  ) async {
    if (id != 'request-send' ||
        !mounted ||
        _workspaceKey.currentState?.closing == true) {
      return;
    }
    if (binding.key != LogicalKeyboardKey.enter ||
        !(binding.control || binding.alt || binding.meta)) {
      throw CoreFailure(
        'settings.shortcut',
        'Send requires Enter with a command modifier.',
      );
    }
    final conflict = busyApiDefaultKeyBindings.entries.any(
      (entry) =>
          entry.key != id &&
          jsonEncode(entry.value.toJson()) == jsonEncode(binding.toJson()),
    );
    if (conflict) {
      throw CoreFailure(
        'settings.shortcut',
        'Choose a shortcut that does not conflict with an existing command.',
      );
    }
    await _saveRequestShortcut(binding);
  }

  Future<void> _saveRequestShortcut(BusyApiKeyBinding binding) async {
    final generation = ++_requestShortcutGeneration;
    setState(() {
      _requestShortcut = binding;
      _shortcutPersistence = _ShortcutPersistence.pending;
    });
    final previous = _requestShortcutSave;
    final saving = () async {
      await _requestShortcutLoad;
      await previous;
      try {
        await widget.saveRequestShortcut(widget.controller.locations, binding);
        if (mounted) _persistedRequestShortcut = binding;
        return null;
      } on Object catch (error) {
        return error;
      }
    }();
    _requestShortcutSave = saving;
    final failure = await saving;
    if (mounted && generation == _requestShortcutGeneration) {
      setState(() {
        _shortcutPersistence = failure == null
            ? _ShortcutPersistence.saved
            : _ShortcutPersistence.failed;
      });
    }
    if (failure != null) {
      throw CoreFailure(
        'settings.shortcut.save',
        'The Send shortcut could not be saved. Retry or discard this preference when closing.',
      );
    }
  }

  Future<bool> _flushRequestShortcut() async {
    while (mounted) {
      final pending = _requestShortcutSave;
      final failure = await pending;
      if (!identical(pending, _requestShortcutSave)) continue;
      if (!mounted) return false;
      if (failure == null &&
          _shortcutPersistence == _ShortcutPersistence.saved) {
        return true;
      }
      final context = _workspaceKey.currentContext;
      if (context == null || !context.mounted) return false;
      final l = context.l10n;
      final action = await showBusyApiModalDialog<String>(
        context: context,
        builder: (context) => BusyApiDialogShell(
          title: l.requestSend,
          actions: [
            BusyApiDialogButton(
              label: l.cancel,
              onPressed: () => Navigator.pop(context, 'cancel'),
            ),
            BusyApiDialogButton(
              label: l.shortcutDiscard,
              onPressed: () => Navigator.pop(context, 'discard'),
            ),
            BusyApiDialogButton(
              label: l.shortcutRetrySave,
              suggested: true,
              onPressed: () => Navigator.pop(context, 'retry'),
            ),
          ],
          children: [Text(l.shortcutSaveFailure)],
        ),
      );
      if (!mounted) return false;
      if (action == 'discard') {
        ++_requestShortcutGeneration;
        setState(() {
          _requestShortcut = _persistedRequestShortcut;
          _shortcutPersistence = _ShortcutPersistence.saved;
          _requestShortcutSave = Future.value();
        });
        return true;
      }
      if (action != 'retry') return false;
      try {
        await _saveRequestShortcut(_requestShortcut!);
      } on CoreFailure {
        /* The recovery dialog remains available. */
      }
    }
    return false;
  }

  Future<void> setMode(ThemeMode value) async {
    if (!mounted || _workspaceKey.currentState?.closing == true) return;
    final generation = ++_appearanceGeneration;
    setState(() => mode = value);
    // BusyMark's AppSettingsController keeps preference writes in order.
    final previousSave = _lastAppearanceSave;
    final save = () async {
      await previousSave;
      try {
        await widget.saveAppearance(widget.controller.locations, value);
        return null;
      } on Object catch (error) {
        return error;
      }
    }();
    _lastAppearanceSave = save;
    final failure = await save;
    if (mounted && generation == _appearanceGeneration) {
      setState(() => appearanceFailure = failure);
    }
  }

  Future<bool> flushAppearance() async {
    if (!await _flushRequestShortcut()) return false;
    // Drain the ordered writer, including a preference queued while awaiting
    // an earlier one. A failed save keeps the existing error/retry UI alive.
    while (true) {
      final pending = _lastAppearanceSave;
      final failure = await pending;
      if (!identical(pending, _lastAppearanceSave)) continue;
      if (!mounted) return false;
      setState(() => appearanceFailure = failure);
      return failure == null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent =
        ref.watch(systemAccentColorProvider).asData?.value ??
        ref.watch(initialSystemAccentColorProvider) ??
        busyApiDefaultAccentColor;
    final animations =
        ref.watch(gtkAnimationsEnabledProvider).asData?.value ??
        ref.watch(initialGtkAnimationsEnabledProvider) ??
        true;
    final commands = _workspaceCommands(
      widget.controller,
      () => _workspaceKey.currentState,
      requestShortcut: _requestShortcut,
      configureShortcut: configureRequestShortcut,
    );
    return MaterialApp(
      title: 'BusyAPI',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: buildBusyApiTheme(
        brightness: Brightness.light,
        accentColor: accent,
      ),
      darkTheme: buildBusyApiTheme(
        brightness: Brightness.dark,
        accentColor: accent,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => BusyApiCommandRegistryScope(
        registry: commands,
        child: BusyApiCommandShortcuts(
          shortcuts: commands.shortcutIntents(),
          isComposing: busyApiFocusedInputIsComposing,
          child: Actions(
            actions: <Type, Action<Intent>>{
              BusyApiCommandIntent: CallbackAction<BusyApiCommandIntent>(
                onInvoke: (intent) {
                  _workspaceKey.currentState?.run(() async {
                    await commands.execute(intent.commandId);
                  });
                  return null;
                },
              ),
            },
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations:
                    !animations || MediaQuery.disableAnimationsOf(context),
              ),
              child: GtkHeaderIconScope(
                service: ref.watch(gtkHeaderIconServiceProvider),
                child: LinuxWindowHost(
                  child: BusyApiToastOverlay(child: child!),
                ),
              ),
            ),
          ),
        ),
      ),
      home: WorkspaceScreen(
        key: _workspaceKey,
        controller: widget.controller,
        startupPath: widget.startupPath,
        themeMode: mode,
        setTheme: setMode,
        flushAppearance: flushAppearance,
        appearanceFailure: appearanceFailure,
        chooseProjectDirectory: widget.chooseProjectDirectory,
        initializerBoundary: widget.initializerBoundary,
        chooseBundleDestination: widget.chooseBundleDestination,
        chooseDocumentationDestination: widget.chooseDocumentationDestination,
      ),
    );
  }
}

class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.setTheme,
    this.startupPath,
    this.chooseProjectDirectory,
    this.initializerBoundary,
    this.chooseBundleDestination,
    this.chooseDocumentationDestination,
    this.appearanceFailure,
    this.flushAppearance,
  });
  final WorkspaceController controller;
  final String? startupPath;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) setTheme;
  final Future<String?> Function()? chooseProjectDirectory;
  final PublicationBoundary? initializerBoundary;
  final Future<String?> Function()? chooseBundleDestination;
  final Future<String?> Function()? chooseDocumentationDestination;
  final Object? appearanceFailure;
  final Future<bool> Function()? flushAppearance;
  @override
  ConsumerState<WorkspaceScreen> createState() => WorkspaceScreenState();
}

class WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  WorkspaceController get c => widget.controller;
  bool sidebar = true, files = false, problems = false;
  bool _settingsOpen = false;
  FocusNode? _settingsFocus;
  (BusyProject?, String?, String?)? _settingsOwner;
  bool _sidebarAvailable = true;
  String filter = '';
  double fraction = .5;
  int transition = 0;
  bool _creating = false, _closing = false;
  bool _closeCommitted = false;
  bool get closing => _closeCommitted;
  int _navigation = 0;
  int _sourceReveal = 0;
  late final WindowControlService _windows;
  final sourceKey = GlobalKey<SourceEditorState>();
  final searchKey = GlobalKey<BusyApiSearchSidebarState>();
  final _navigationContentKey = GlobalKey();
  GlobalKey<ApiNavigatorState> _apiNavigatorKey =
      GlobalKey<ApiNavigatorState>();
  (BusyProject?, String?)? _apiNavigatorOwner;
  final _filesScroll = ScrollController();
  final _fileAnchors = <String, GlobalKey>{};
  (BusyProject, String, int)? _fileSearchView;
  late final BusyApiSearchSession search;
  late final BundleRunController bundleRun;
  late final RequestRunController requestRun;
  late final MockRunController mockRun;
  DocumentationWindowService? _documentationWindows;
  BusyProject? _documentationOwner;
  bool _openingDocumentation = false;
  int _documentationEpoch = 0;
  Map<String, Object?>? _layout;
  void _saveLayout() {
    c.layoutState = {
      ...c.layoutState,
      'sidebar': sidebar,
      'files': files,
      'fraction': fraction,
      'sidebarSearch': filter,
    };
    _layout = c.layoutState;
  }

  @override
  void initState() {
    super.initState();
    _windows = ref.read(windowControlServiceProvider);
    search = BusyApiSearchSession(c)..addListener(_searchChanged);
    bundleRun = BundleRunController(c);
    requestRun = RequestRunController(c);
    mockRun = MockRunController(c);
    c.addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final windows = _windows;
      windows.initialize();
      windows.registerCloseHandler(close);
      if (widget.startupPath != null) {
        run(() => open(widget.startupPath!));
      } else {
        run(recover);
      }
    });
  }

  void _searchChanged() {
    if (!mounted) return;
    if (search.active && search.category == BusyApiSearchCategory.navigation) {
      filter = search.query.text;
      _saveLayout();
    }
    setState(() {});
  }

  Future<void> _revealNavigationFile(
    BusyProject owner,
    String query,
    String path,
    int index,
  ) async {
    while (mounted &&
        files &&
        identical(c.project, owner) &&
        search.active &&
        search.category == BusyApiSearchCategory.navigation &&
        search.query.text == query &&
        search.selected == index &&
        _filesScroll.hasClients) {
      final target = _fileAnchors[path]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(target, alignment: .5);
        return;
      }
      final mountedPaths = _fileAnchors.entries
          .where((e) => e.value.currentContext != null)
          .map((e) => e.key);
      final before =
          mountedPaths.isNotEmpty && path.compareTo(mountedPaths.first) < 0;
      final position = _filesScroll.position;
      final offset =
          (position.pixels + position.viewportDimension * (before ? -.8 : .8))
              .clamp(0.0, position.maxScrollExtent);
      if (offset == position.pixels) return;
      _filesScroll.jumpTo(offset);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _refresh() {
    if (_documentationWindows != null) {
      if (!identical(_documentationOwner, c.project)) {
        final retired = _documentationWindows!;
        _documentationWindows = null;
        _documentationOwner = null;
        _documentationEpoch++;
        unawaited(
          retired.close().catchError((Object _) {
            if (mounted) {
              BusyApiToastOverlay.show(
                context,
                message: context.l10n.documentationFailed('cleanup'),
              );
            }
          }),
        );
      } else {
        unawaited(_documentationWindows!.synchronize());
      }
    }
    if (c.sourceNotification && c.mode == 'Source') return;
    if (mounted) setState(() {});
  }

  void run(Future<void> Function() action) {
    unawaited(() async {
      try {
        await action();
      } on Object catch (e) {
        if (!mounted) return;
        await showBusyApiModalDialog<void>(
          context: context,
          builder: (context) => BusyApiDialogShell(
            title: context.l10n.appTitle,
            actions: [
              BusyApiDialogButton(
                label: context.l10n.close,
                onPressed: () => Navigator.pop(context),
              ),
            ],
            children: [SelectableText(e.toString())],
          ),
        );
      }
    }());
  }

  Future<bool> protect({Set<String>? only}) async {
    final owner = c.project, navigation = c.navigationGeneration;
    bool current() =>
        mounted &&
        !c.disposed &&
        identical(c.project, owner) &&
        navigation == c.navigationGeneration;
    bool resolved() =>
        current() &&
        !c.hasPendingFields &&
        !(owner?.store.fileBuffers.any(
              (b) => b.dirty && (only == null || only.contains(b.id)),
            ) ??
            false);
    if (!await c.flush()) {
      if (!mounted) return false;
      await showBusyApiModalDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BusyApiDialogShell(
          title: context.l10n.pendingError,
          actions: [
            BusyApiDialogButton(
              label: context.l10n.cancel,
              onPressed: () => Navigator.pop(context),
            ),
            BusyApiDialogButton(
              label: context.l10n.discardDrafts,
              onPressed: () async {
                await c.discardDrafts();
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
          children: [Text(c.error ?? '')],
        ),
      );
      if (!current() || c.hasPendingFields) return false;
    }
    if (!current()) return false;
    final dirty =
        c.store?.fileBuffers
            .where((b) => b.dirty && (only == null || only.contains(b.id)))
            .toList() ??
        <DocumentBuffer>[];
    if (dirty.isEmpty) return resolved();
    if (!mounted) return false;
    final action = await showBusyApiModalDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.unsavedChanges,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.cancel,
            onPressed: () => Navigator.pop(context, 'cancel'),
          ),
          BusyApiDialogButton(
            label: context.l10n.discard,
            onPressed: () => Navigator.pop(context, 'discard'),
          ),
          BusyApiDialogButton(
            label: context.l10n.save,
            suggested: true,
            onPressed: () => Navigator.pop(context, 'save'),
          ),
        ],
        children: [
          if (c.project != null &&
              c.publications.hasPendingFileMoves(c.project!))
            Text(context.l10n.discardPartialFileMove),
          for (final b in dirty) Text(b.path),
        ],
      ),
    );
    if (!current()) return false;
    if (action == 'discard') {
      await c.discardBuffers(only: only);
      return resolved();
    }
    if (action == 'save') {
      await c.saveBuffers(only: only);
      return resolved();
    }
    return false;
  }

  Future<void> close() async {
    if (_closing || _creating || c.formApplying) return;
    _closing = true;
    var closed = false;
    try {
      if (!await protect() || !mounted) return;
      // Stop accepting appearance changes before draining their writer. Keep
      // this boundary through workspace shutdown and native window closure.
      setState(() => _closeCommitted = true);
      if (widget.flushAppearance case final flush?) {
        if (!await flush() || !mounted) return;
      }
      await c.shutdown();
      if (!mounted) return;
      await ref.read(windowControlServiceProvider).closeWindow();
      closed = true;
    } finally {
      _closing = false;
      if (!closed && mounted) setState(() => _closeCommitted = false);
    }
  }

  Future<void> open(String path, {String? selectedRoot}) async {
    ++_navigation;
    if (!await protect() || !mounted) return;
    final navigation = _navigation;
    bool cancelled = false;
    ModalRoute<dynamic>? ownedRoute;
    NavigatorState? ownedNavigator;
    final dialog = showBusyApiModalDialog<void>(
      context: context,
      barrierDismissible: false,
      onRoutePushed: (route, navigator) {
        ownedRoute = route;
        ownedNavigator = navigator;
      },
      builder: (context) {
        return BusyApiDialogShell(
          title: context.l10n.open,
          closable: false,
          actions: [
            BusyApiDialogButton(
              label: context.l10n.cancel,
              onPressed: () {
                cancelled = true;
              },
            ),
          ],
          children: [const LinearProgressIndicator(), Text(path)],
        );
      },
    );
    int? generation;
    try {
      final opening = c.open(path, cancelled: () => cancelled);
      generation = c.navigationGeneration;
      await opening;
    } finally {
      final route = ownedRoute, navigator = ownedNavigator;
      if (route != null &&
          navigator != null &&
          navigator.mounted &&
          route.isActive) {
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      }
      await dialog;
    }
    if (cancelled ||
        !mounted ||
        navigation != _navigation ||
        c.disposed ||
        generation != c.navigationGeneration) {
      return;
    }
    if (selectedRoot != null) {
      final owner = c.project;
      if (!await c.selectRoot(selectedRoot) ||
          !mounted ||
          c.disposed ||
          navigation != _navigation ||
          generation != c.navigationGeneration ||
          !identical(c.project, owner)) {
        return;
      }
    } else if (c.project!.roots.length > 1) {
      await chooseRoot();
    }
    await recover();
  }

  Future<void> chooseRoot() async {
    final owner = c.project, navigation = c.navigationGeneration;
    if (!mounted || owner == null) return;
    final roots = List<ProjectRoot>.of(owner.roots);
    final choice =
        await showBusyApiModalDialog<({ProjectRoot root, bool remove})>(
          context: context,
          builder: (context) => BusyApiDialogShell(
            title: context.l10n.selectRoot,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: BusyApiSizes.problemsListHeight,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: roots.length,
                  itemBuilder: (context, index) {
                    final r = roots[index];
                    return BusyApiActionRow(
                      title: contractIdentityLabel(r.name),
                      subtitle: contractIdentityLabel(
                        p.relative(
                          Uri.parse(r.id).toFilePath(),
                          from: owner.access.boundary,
                        ),
                      ),
                      trailing: owner.hasRootConfiguration
                          ? BusyApiCompactIconButton(
                              tooltip: context.l10n.removeContractRoot,
                              icon: BusyApiGlyphs.delete,
                              onPressed: () => Navigator.pop(context, (
                                root: r,
                                remove: true,
                              )),
                            )
                          : null,
                      onTap: () =>
                          Navigator.pop(context, (root: r, remove: false)),
                    );
                  },
                ),
              ),
            ],
          ),
        );
    if (!mounted ||
        !identical(c.project, owner) ||
        c.navigationGeneration != navigation ||
        choice == null) {
      return;
    }
    if (choice.remove) {
      await showRootRemoval(context, c, choice.root, reveal: reveal);
    } else {
      try {
        await c.selectRoot(choice.root.id);
      } on CoreFailure catch (failure) {
        if (!mounted) return;
        if (failure.code != 'root.unconfigured') rethrow;
        throw CoreFailure(failure.code, context.l10n.rootSelectionUnavailable);
      }
    }
  }

  Future<void> chooseFile() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'OpenAPI', extensions: ['yaml', 'yml', 'json']),
      ],
    );
    if (file != null) await open(file.path);
  }

  Future<void> chooseDirectory() async {
    final dir = await getDirectoryPath();
    if (dir != null) await open(dir);
  }

  Future<void> importProject() async {
    if (_creating || c.disposed || !mounted) return;
    final navigation = ++_navigation;
    if (!await protect() || !mounted || navigation != _navigation) return;
    final owner = c.project, generation = c.navigationGeneration;
    final acquired = await showProjectImport(context, c);
    if (!mounted ||
        c.disposed ||
        navigation != _navigation ||
        generation != c.navigationGeneration ||
        !identical(owner, c.project)) {
      return;
    }
    if (acquired != null) {
      await open(
        acquired.destination,
        selectedRoot: Uri.file(acquired.root).toString(),
      );
    }
  }

  Future<void> create() async {
    if (_creating || c.disposed) return;
    _creating = true;
    final navigation = ++_navigation;
    var generation = c.navigationGeneration;
    bool current() =>
        mounted &&
        !c.disposed &&
        navigation == _navigation &&
        generation == c.navigationGeneration;
    try {
      if (!await protect() || !mounted || !current()) return;
      final destination =
          await (widget.chooseProjectDirectory?.call() ?? getDirectoryPath());
      if (destination == null || !mounted || !current()) return;
      final l = context.l10n;
      String? createdPath;
      String? partialPath;
      CoreFailure? partialFailure;
      Map<String, dynamic>? publishedValues;
      await editForm(
        context,
        l.createProject,
        [
          FormFieldSpec('folder', l.name),
          FormFieldSpec('title', l.title),
          FormFieldSpec('apiVersion', l.apiVersion),
          FormFieldSpec(
            'openapi',
            l.openapiVersion,
            options: ['2.0', '3.0.4', '3.1.2', '3.2.1'],
          ),
          FormFieldSpec('format', l.format, options: ['yaml', 'json']),
        ],
        {
          'folder': 'api',
          'title': '',
          'apiVersion': '1.0.0',
          'openapi': '3.1.2',
          'format': 'yaml',
        },
        applyLabel: () => createdPath == null ? null : l.retryOpening,
        validate: (v) =>
            v['folder'].isEmpty ||
                v['folder'] == '.' ||
                v['folder'] == '..' ||
                p.basename(v['folder']) != v['folder']
            ? l.projectFolderRequired
            : v['title'].trim().isEmpty
            ? l.apiTitleRequired
            : v['apiVersion'].trim().isEmpty
            ? l.apiVersionRequired
            : null,
        onApply: (values) async {
          if (!current()) {
            throw CoreFailure('create.superseded', l.creationSuperseded);
          }
          final path = p.join(destination, values['folder']);
          if (path == partialPath) throw partialFailure!;
          if (createdPath == null) {
            // Failures stay in this form with their inputs, including init.partial.
            // A retry is always explicit and uses the initializer's collision guard.
            try {
              await Initializer.create(
                destination: path,
                title: values['title'],
                apiVersion: values['apiVersion'],
                openapi: values['openapi'],
                format: values['format'],
                beforePublish: widget.initializerBoundary,
              );
            } on CoreFailure catch (e) {
              if (e.code == 'init.partial') {
                partialPath = path;
                partialFailure = e;
              }
              rethrow;
            }
            createdPath = path;
            publishedValues = Map<String, dynamic>.from(values);
          } else if (jsonEncode(publishedValues) != jsonEncode(values)) {
            throw CoreFailure(
              'create.created',
              l.projectCreatedOpenFailed(createdPath!, l.createdFieldsLocked),
            );
          }
          if (!current()) return; // Published files survive host removal.
          try {
            final opening = c.open(createdPath!, cancelled: () => !current());
            generation = c.navigationGeneration;
            await opening;
            if (!current()) return;
            c.setMode('Design');
            await c.analyse();
            if (!current()) return;
            if (c.error != null ||
                c.analysis == null ||
                c.analysis?['complete'] != true) {
              throw CoreFailure(
                'create.open',
                c.error ?? c.analysis?['status'] ?? l.analysisDidNotComplete,
              );
            }
          } on Object catch (e) {
            throw CoreFailure(
              'create.open',
              l.projectCreatedOpenFailed(createdPath!, e.toString()),
            );
          }
        },
      );
    } finally {
      _creating = false;
    }
  }

  Future<void> recover() async {
    final capturedProject = c.project;
    for (final record in c.interruptedPublications) {
      if (!mounted ||
          capturedProject == null ||
          !identical(c.project, capturedProject)) {
        return;
      }
      final action = await showBusyApiModalDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BusyApiDialogShell(
          title: context.l10n.recoveryAvailable,
          actions: [
            BusyApiDialogButton(
              label: context.l10n.cancel,
              onPressed: () => Navigator.pop(context, false),
            ),
            BusyApiDialogButton(
              label: context.l10n.recover,
              suggested: true,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
          children: [
            if (record['version'] == 2) Text(context.l10n.fileMoveRecovery),
            for (final entry in record['outcomes'])
              Text('${entry['path']} · ${entry['outcome']}'),
          ],
        ),
      );
      if (action != true ||
          !identical(c.project, capturedProject) ||
          c.disposed) {
        continue;
      }
      if (record['version'] == 2) {
        if (!await c.recoverFileOperation(record, publication: true)) continue;
      } else {
        for (final entry in record['outcomes']) {
          if (entry['outcome'] == 'published') continue;
          await c.publications.recover(
            capturedProject,
            Map<String, dynamic>.from(entry),
          );
          await c.openFile(entry['id']);
        }
      }
      await c.persist();
      if (record['version'] != 2) await c.publications.retire(record);
      c.setMode('Source');
      c.schedule(immediate: true);
    }
    final records = await c.recovery.available();
    for (final record in records) {
      if (!mounted) return;
      if (record['version'] == 2) {
        final restore = await showBusyApiModalDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => BusyApiDialogShell(
            title: context.l10n.recoveryAvailable,
            actions: [
              BusyApiDialogButton(
                label: context.l10n.cancel,
                onPressed: () => Navigator.pop(context, false),
              ),
              BusyApiDialogButton(
                label: context.l10n.recover,
                suggested: true,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
            children: [
              Text(context.l10n.fileMoveRecovery),
              for (final b in record['buffers'] as List)
                Text('${b['sourcePath']} → ${b['path']}'),
            ],
          ),
        );
        if (restore != true || !mounted) continue;
        if (c.project?.access.boundary != record['boundary']) {
          await c.open(record['boundary'] as String);
        }
        final owner = c.project;
        if (owner == null || owner.access.boundary != record['boundary']) {
          continue;
        }
        if (!await c.recoverFileOperation(record)) continue;
        if (c.form != null && mounted) await resumeCapturedForm(context, c);
        if (c.draft != null && mounted) await c.resumePropertyDraft();
        continue;
      }
      final action = await showBusyApiModalDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BusyApiDialogShell(
          title: context.l10n.recoveryAvailable,
          actions: [
            BusyApiDialogButton(
              label: context.l10n.cancel,
              onPressed: () => Navigator.pop(context, 'cancel'),
            ),
            BusyApiDialogButton(
              label: context.l10n.recover,
              suggested: true,
              onPressed: () => Navigator.pop(context, 'recover'),
            ),
          ],
          children: [
            Text(record['path']),
            if (record['draft'] != null || record['form'] != null)
              Text(context.l10n.capturedFields),
          ],
        ),
      );
      if (action != 'recover') continue;
      if (c.project == null ||
          !p.isWithin(c.project!.access.boundary, record['path'])) {
        await c.open(p.dirname(record['path']), recovering: record);
      }
      await c.project!.buffer(record['id'], recovery: record);
      await c.openFile(record['id']);
      final d = record['draft'];
      if (d != null) {
        c.draft = PropertySession(
          root: d['root'],
          buffer: d['buffer'],
          generation: d['generation'],
          pointer: d['pointer'],
          range: List<int>.from(d['range']),
          expected: d['expected'],
        );
        c.draft!.committed.addAll(Map<String, Object?>.from(d['committed']));
        c.draft!.values.addAll(Map<String, Object?>.from(d['values']));
      }
      if (record['form'] != null) {
        c.form = FormSession.restore(Map<String, dynamic>.from(record['form']));
      }
      c.store!.retireHistory({c.buffer!.id});
      await c.recovery.adopt(record, c.buffer!, draft: c.draft, form: c.form);
      c.mode = 'Source';
      c.schedule(immediate: true);
      if (c.form != null && mounted) await resumeCapturedForm(context, c);
      if (c.draft != null && mounted) await c.resumePropertyDraft();
    }
  }

  Future<void> resolveConflict() async {
    final buffer = c.buffer;
    if (buffer == null || !await c.flush() || !mounted) return;
    final owner = c.project;
    if (owner == null || !owner.store.ownsFileBuffer(buffer)) return;
    BufferReloadCapture? acceptedReload;
    final grouped = buffer.hasPathIntent || buffer.pendingFilePublication;
    final action = await showBusyApiModalDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.fileConflict,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.keepEditing,
            onPressed: () => Navigator.pop(context, 'keep'),
          ),
          BusyApiDialogButton(
            label: context.l10n.saveDraftCopy,
            onPressed: () => Navigator.pop(context, 'copy'),
          ),
          BusyApiDialogButton(
            label: grouped
                ? context.l10n.discardFileOperation
                : context.l10n.useDisk,
            onPressed: () {
              if (!grouped && identical(c.project, owner)) {
                acceptedReload = owner.captureReload(buffer);
              }
              Navigator.pop(
                context,
                grouped ? 'discard-file-operation' : 'disk',
              );
            },
          ),
        ],
        children: [
          Text(context.l10n.conflict),
          Text(buffer.path),
          if (grouped) Text(context.l10n.discardPartialFileMove),
        ],
      ),
    );
    if (action == 'copy') {
      final location = await getSaveLocation(
        suggestedName:
            '${p.basenameWithoutExtension(buffer.path)}.busyapi-draft${p.extension(buffer.path)}',
      );
      if (location == null) return;
      final bytes = buffer.bytes();
      final access = await ProjectAccess.open(p.dirname(location.path));
      try {
        // The native destination grants access to this directory, but never
        // permission to overwrite an existing file, including the conflicted one.
        await access.publish(location.path, bytes, mode: buffer.mode);
      } finally {
        access.close();
      }
      if (mounted) {
        BusyApiToastOverlay.show(context, message: context.l10n.draftCopySaved);
      }
    } else if (action == 'discard-file-operation') {
      await c.discardBuffers(only: {buffer.id});
    } else if (action == 'disk') {
      if (acceptedReload == null) return;
      final result = await c.reloadFromDisk(acceptedReload!);
      if (result.failure case final failure?) throw failure;
    }
  }

  Future<void> revealDocumentationSource(
    BusyProject owner,
    DocumentationPresentation presentation,
    int index,
  ) async {
    if (!mounted) return;
    final outdatedMessage = context.l10n.outdated;
    final opening = c.navigationGeneration,
        request = ++_sourceReveal,
        initialRoot = c.root,
        initialResource = c.active,
        initialMode = c.mode,
        initialResourceNavigation = c.resourceNavigationGeneration;
    var entering = true;
    bool current() =>
        mounted &&
        !c.disposed &&
        identical(c.project, owner) &&
        opening == c.navigationGeneration &&
        request == _sourceReveal &&
        presentation.belongsTo(owner) &&
        !presentation.outdated &&
        (!entering ||
            c.root == initialRoot &&
                c.active == initialResource &&
                c.mode == initialMode &&
                c.resourceNavigationGeneration == initialResourceNavigation);
    void requireCurrent() {
      if (!current()) {
        throw CoreFailure('navigation.outdated', outdatedMessage);
      }
    }

    requireCurrent();
    final action = presentation.resolveSourceAction(index);
    if (!await c.flush()) return;
    requireCurrent();
    // Acquiring an already-approved fragment must not switch the visible
    // resource before checking its captured identity and generation again.
    var acquired = false;
    try {
      await owner.buffer(action.source['resource'] as String);
      acquired = true;
    } finally {
      // A newly read fragment can expose an external change even when its
      // captured navigation is refused. Notify only the still-mounted owner;
      // do not leave another current Source/Reference pane reading old results.
      if (mounted &&
          !c.disposed &&
          identical(c.project, owner) &&
          opening == c.navigationGeneration &&
          (!acquired || presentation.outdated)) {
        c.cached.clear();
        c.schedule(immediate: true);
      }
    }
    requireCurrent();
    entering = false;
    if (c.root != presentation.snapshot.root) {
      final selected = await c.selectRoot(
        presentation.snapshot.root,
        resource: action.source['resource'] as String,
      );
      requireCurrent();
      if (!selected) {
        throw CoreFailure('navigation.outdated', outdatedMessage);
      }
    }
    if (c.root != presentation.snapshot.root) return;
    await _reveal(
      {
        ...action.source,
        'root': presentation.snapshot.root,
        // Source means the authored occurrence. A separate definition action
        // still retains its physical source range; aliases are not expanded.
        if (action.source['occurrenceRange'] != null)
          'range': action.source['occurrenceRange'],
      },
      request: request,
      current: () => current() && c.root == presentation.snapshot.root,
    );
  }

  Future<void> reveal(Map<String, dynamic> item, {bool Function()? current}) =>
      _reveal(item, current: current, request: ++_sourceReveal);

  Future<void> _reveal(
    Map<String, dynamic> item, {
    required int request,
    bool Function()? current,
  }) async {
    if (!mounted) return;
    final captured = c.project,
        navigation = _navigation,
        root = c.root,
        opening = c.navigationGeneration,
        resource = item['resource'];
    var resourceNavigation = c.resourceNavigationGeneration;
    var expectedMode = c.mode;
    bool owns() =>
        mounted &&
        !c.disposed &&
        identical(c.project, captured) &&
        navigation == _navigation &&
        opening == c.navigationGeneration &&
        root == c.root &&
        request == _sourceReveal &&
        expectedMode == c.mode &&
        resourceNavigation == c.resourceNavigationGeneration &&
        (current?.call() ?? true);
    final outdatedMessage = context.l10n.outdated;
    if (!owns() || !await c.flush() || !owns()) return;
    final origin = (c.projection?['resources'] as List? ?? [])
        .where((r) => r['id'] == resource)
        .firstOrNull;
    if (item['snapshot'] != null &&
        item['snapshot'] != c.analysis?['snapshot']) {
      throw CoreFailure('navigation.outdated', outdatedMessage);
    }
    final loading = c.openFile(resource);
    resourceNavigation = c.resourceNavigationGeneration;
    await loading;
    if (!owns() || c.active != resource) return;
    c.mode = 'Source';
    expectedMode = 'Source';
    if (item['outdated'] == true ||
        item['generation'] != null &&
            item['generation'] != c.buffer!.generation ||
        (item['identity'] != null
            ? c.buffer!.sourceIdentity != item['identity']
            : origin != null &&
                  c.buffer!.sourceIdentity != origin['identity'])) {
      setState(() {});
      return;
    }
    final range = item['range'] as List;
    c.buffer!.selection = SourceSelection(range[0], range[0]);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (owns() && c.active == resource && c.mode == 'Source') {
        sourceKey.currentState?.reveal(range[0]);
      }
    });
  }

  Future<void> view(String value) async {
    if (!await c.flush()) return;
    c.mode = value;
    setState(() {});
  }

  Future<void> closeTab(String id) async {
    if (!await protect(only: {id})) return;
    c.tabs.remove(id);
    if (c.active == id) c.active = c.tabs.lastOrNull;
    setState(() {});
  }

  Future<void> settings() async {
    if (!mounted) return;
    if (!_settingsOpen) {
      _settingsFocus = FocusManager.instance.primaryFocus;
      _settingsOwner = (c.project, c.root, c.active);
    }
    setState(() => _settingsOpen = true);
  }

  void closeSettings() {
    if (!_settingsOpen) return;
    final focus = _settingsFocus, owner = _settingsOwner;
    _settingsFocus = null;
    _settingsOwner = null;
    setState(() => _settingsOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_settingsOpen &&
          owner == (c.project, c.root, c.active) &&
          focus?.context != null &&
          focus!.canRequestFocus) {
        focus.requestFocus();
      }
    });
  }

  Widget projectSettings(BuildContext context) => BusyApiGroupedList(
    title: context.l10n.projectSettings,
    filled: true,
    children: [
      if (c.project == null) Text(context.l10n.noProject),
      if (c.project != null)
        BusyApiActionRow(
          title: context.l10n.resourceBoundary,
          subtitle: c.project!.approvedContexts.join('\n'),
          tooltip: c.project!.approvedContexts.join('\n'),
        ),
      if (c.project?.configurationResource != null)
        BusyApiActionRow(
          title: context.l10n.openProjectConfiguration,
          subtitle: context.l10n.projectConfigurationExplanation,
          onTap: () {
            closeSettings();
            run(c.openProjectConfiguration);
          },
        ),
      if (c.project != null)
        BusyApiActionRow(
          title: context.l10n.approveLocalContext,
          subtitle: context.l10n.contextApprovalExplanation,
          onTap: () => run(() async {
            final owner = c.project, navigation = c.navigationGeneration;
            final directory = await getDirectoryPath();
            if (directory == null ||
                !context.mounted ||
                !identical(owner, c.project) ||
                navigation != c.navigationGeneration) {
              return;
            }
            final confirmed = await showBusyApiModalDialog<bool>(
              context: context,
              builder: (context) => BusyApiDialogShell(
                title: context.l10n.approveLocalContext,
                actions: [
                  BusyApiDialogButton(
                    label: context.l10n.cancel,
                    onPressed: () => Navigator.pop(context, false),
                  ),
                  BusyApiDialogButton(
                    label: context.l10n.approve,
                    suggested: true,
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ],
                children: [
                  Text(context.l10n.contextApprovalExplanation),
                  Text(directory),
                ],
              ),
            );
            if (confirmed != true ||
                !identical(owner, c.project) ||
                navigation != c.navigationGeneration) {
              return;
            }
            await owner!.approveContext(directory);
            c.schedule(immediate: true);
          }),
        ),
      if (c.project != null)
        BusyApiActionRow(
          title: context.l10n.mapResource,
          subtitle: context.l10n.resourceMappingExplanation,
          onTap: () => run(() async {
            final owner = c.project!, navigation = c.navigationGeneration;
            final l = context.l10n;
            final input = await editForm(
              context,
              l.mapResource,
              [FormFieldSpec('uri', l.resourceUri)],
              {},
              validate: (values) {
                final uri = Uri.tryParse(values['uri'] as String? ?? '');
                return uri != null &&
                        uri.hasScheme &&
                        !uri.hasFragment &&
                        uri.userInfo.isEmpty
                    ? null
                    : l.resourceUriRequired;
              },
            );
            if (input == null || !context.mounted) return;
            final selected = await openFile();
            if (selected == null || !context.mounted) return;
            if (!identical(c.project, owner) ||
                c.navigationGeneration != navigation) {
              throw CoreFailure('resource.owner', l.resourceMappingSuperseded);
            }
            await owner.approveResource(
              input['uri'] as String,
              Uri.file(selected.path).toString(),
            );
            if (identical(c.project, owner) &&
                c.navigationGeneration == navigation) {
              c.schedule(immediate: true);
            }
          }),
        ),
    ],
  );

  Future<void> palette() async => search.open(BusyApiSearchCategory.actions);

  Future<void> projectSearch() async =>
      search.open(BusyApiSearchCategory.project);

  Future<void> revealSearch(Map<String, dynamic> target) async {
    final owner = c.project;
    final root = target['root'] as String?;
    if (root != null && root != c.root) await c.selectRoot(root);
    if (mounted &&
        identical(owner, c.project) &&
        (root == null || c.root == root)) {
      await reveal({
        ...target,
        if (target['occurrenceRange'] != null)
          'range': target['occurrenceRange'],
      });
    }
  }

  Future<void> toggleSidebar() async {
    setState(() {
      sidebar = !sidebar;
      _saveLayout();
      transition++;
    });
  }

  Future<void> toggleSearch() async {
    if (search.active) {
      search.close();
    } else {
      search.open(c.project == null ? BusyApiSearchCategory.actions : null);
    }
  }

  Future<void> togglePreview() async {
    if (await c.flush() && mounted) setState(() => c.preview = !c.preview);
  }

  Future<void> back() async {
    if (_settingsOpen) {
      closeSettings();
      return;
    }
    await c.navigateHistory(-1);
  }

  Future<void> createBundle() async {
    final owner = c.project, root = c.root;
    if (owner == null || root == null || bundleRun.busy) return;
    final format = await chooseBundleFormat(context);
    if (format == null ||
        !mounted ||
        !identical(c.project, owner) ||
        c.root != root) {
      return;
    }
    final selected = widget.chooseBundleDestination != null
        ? await widget.chooseBundleDestination!()
        : await chooseOutputDestination(
            context,
            initialPath: p.join(owner.access.boundary, 'busyapi-bundle'),
          );
    if (selected == null ||
        !mounted ||
        c.disposed ||
        !identical(c.project, owner) ||
        c.root != root) {
      return;
    }
    await bundleRun.prepare(selected, format: format);
  }

  Future<void> generateClient() async {
    final owner = c.project, root = c.root, navigation = c.navigationGeneration;
    if (owner == null || root == null || bundleRun.busy) return;
    final selection = await showClientGeneration(context);
    bool current() =>
        mounted &&
        !c.disposed &&
        identical(c.project, owner) &&
        c.root == root &&
        c.navigationGeneration == navigation;
    if (selection == null || !mounted || !current()) return;
    final destination = await chooseOutputDestination(
      context,
      initialPath: p.join(owner.access.boundary, 'busyapi-client'),
    );
    if (destination == null || !current()) return;
    await bundleRun.prepare(
      destination,
      generator: selection.generator,
      generatorOptions: selection.options,
      templateDirectory: selection.templates,
    );
  }

  Future<void> governance() async {
    final target = await showGovernance(context, c);
    if (target != null && mounted) await reveal(target);
  }

  Future<void> createDocumentation() async {
    final owner = c.project, root = c.root;
    if (owner == null || root == null || bundleRun.busy) return;
    final preset = await chooseDocumentationPreset(context);
    if (preset == null ||
        !mounted ||
        !identical(c.project, owner) ||
        c.root != root) {
      return;
    }
    final labels = documentationLabels(context.l10n);
    final selected = widget.chooseDocumentationDestination != null
        ? await widget.chooseDocumentationDestination!()
        : await chooseOutputDestination(
            context,
            initialPath: p.join(owner.access.boundary, 'busyapi-docs'),
          );
    if (selected == null ||
        !mounted ||
        c.disposed ||
        !identical(c.project, owner) ||
        c.root != root) {
      return;
    }
    await bundleRun.prepare(
      selected,
      documentation: true,
      preset: preset,
      labels: labels,
    );
  }

  Future<void> openRedocReference() => _openDocumentationReference('redoc');
  Future<void> openSwaggerReference() => _openDocumentationReference('swagger');

  Future<void> _openDocumentationReference(String preset) async {
    final owner = c.project, root = c.root;
    if (owner == null || root == null || _openingDocumentation) return;
    final opening = c.navigationGeneration, epoch = _documentationEpoch;
    final l = context.l10n, labels = documentationLabels(context.l10n);
    bool current() =>
        mounted &&
        !c.disposed &&
        identical(c.project, owner) &&
        c.root == root &&
        opening == c.navigationGeneration &&
        epoch == _documentationEpoch;
    _openingDocumentation = true;
    DocumentationWindowSession? session;
    try {
      if (!await c.flush() || !current()) return;
      final captured = await owner.captureDocumentationPresentation(
        root,
        cancelled: () => !current(),
        onResourceRefreshed: (resource) => c.resourceRefreshed(owner, resource),
      );
      if (!current()) return;
      final assets = await DocumentationRuntime.forEngine(
        c.engine,
        preset: preset,
      );
      if (!current()) return;
      final resources = await assets.page(
        captured.toJson(),
        labels: labels,
        native: true,
      );
      if (!current()) return;
      final windows = _documentationWindows ??= DocumentationWindowService();
      _documentationOwner = owner;
      session = await windows.open(
        presentation: captured,
        resources: resources,
        title: preset == 'redoc'
            ? l.redocReferenceTitle
            : l.swaggerReferenceTitle,
        loadingLabel: l.documentationLoading,
        failureLabel: l.documentationFailed('renderer-failed'),
        outdatedLabel: l.documentationOutdated,
        cancelled: () => !current(),
        onSource: (action) =>
            revealDocumentationSource(owner, captured, action.index),
      );
      await session.ready;
      if (!current()) {
        await session.close();
        return;
      }
      final opened = session;
      var reported = false;
      void observe() {
        if (opened.state == DocumentationWindowState.closed) {
          opened.removeListener(observe);
          return;
        }
        if (!reported &&
            opened.state == DocumentationWindowState.failed &&
            mounted &&
            identical(c.project, owner)) {
          reported = true;
          BusyApiToastOverlay.show(
            context,
            message: documentationWindowFailure(
              l,
              opened.error?.code ?? 'renderer-failed',
            ),
          );
        }
      }

      opened.addListener(observe);
      observe();
    } on Object catch (error) {
      if (session != null) {
        try {
          await session.close();
        } on Object {
          /* Native failure remains source-independent. */
        }
      }
      if (!current()) return;
      throw error is DocumentationAssetsFailure
          ? l.documentationAssetsMissing('${error.preset}/${error.component}')
          : documentationWindowFailure(
              l,
              error is CoreFailure ? error.code : 'renderer-failed',
            );
    } finally {
      _openingDocumentation = false;
    }
  }

  @override
  void dispose() {
    _documentationEpoch++;
    final documentation = _documentationWindows;
    _documentationWindows = null;
    if (documentation != null) {
      unawaited(
        documentation.close().catchError((Object _) {
          /* Owner is disposed; native host also tears down with its parent. */
        }),
      );
    }
    bundleRun.dispose();
    requestRun.dispose();
    mockRun.dispose();
    c.removeListener(_refresh);
    search.removeListener(_searchChanged);
    search.dispose();
    _filesScroll.dispose();
    _windows.unregisterCloseHandler();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final project = c.project, sourceRoot = c.root, sourceResource = c.active;
    final sourceViewRevision = c.semanticViewRevision;
    if (!identical(_layout, c.layoutState)) {
      _layout = c.layoutState;
      sidebar = c.layoutState['sidebar'] as bool? ?? true;
      files = c.layoutState['files'] as bool? ?? false;
      filter = c.layoutState['sidebarSearch'] as String? ?? '';
      final size = c.layoutState['fraction'];
      fraction = size is num && size.isFinite
          ? size.toDouble().clamp(.25, .75)
          : .5;
    }
    final colors = BusyApiSurfaceColors.of(context);
    final projection = c.projection;
    if (_apiNavigatorOwner != (project, c.root)) {
      _apiNavigatorOwner = (project, c.root);
      _apiNavigatorKey = GlobalKey<ApiNavigatorState>();
      _fileAnchors.clear();
    }
    final navigationSearch =
        search.active && search.category == BusyApiSearchCategory.navigation;
    final navigationQuery = filter;
    final visibleFiles =
        project?.files
            .where((f) => f.toLowerCase().contains(filter.toLowerCase()))
            .toList() ??
        const <String>[];
    final fileSearchView =
        navigationSearch && files && project != null && visibleFiles.isNotEmpty
        ? (
            project,
            navigationQuery,
            search.selected.clamp(0, visibleFiles.length - 1),
          )
        : null;
    if (fileSearchView != null && _fileSearchView != fileSearchView) {
      _fileSearchView = fileSearchView;
      final path = visibleFiles[fileSearchView.$3];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_fileSearchView == fileSearchView) {
          unawaited(
            _revealNavigationFile(
              fileSearchView.$1,
              fileSearchView.$2,
              path,
              fileSearchView.$3,
            ),
          );
        }
      });
    }
    final commands =
        BusyApiCommandRegistryScope.maybeOf(context) ??
        _workspaceCommands(c, () => this);
    final navigationContent = KeyedSubtree(
      key: _navigationContentKey,
      child: files
          ? ListView.builder(
              controller: _filesScroll,
              itemCount: visibleFiles.length,
              itemBuilder: (context, index) {
                final path = visibleFiles[index];
                return BusyApiSidebarRecordRow<String>(
                  key: ValueKey(path),
                  geometryKey: _fileAnchors.putIfAbsent(path, GlobalKey.new),
                  selected: navigationSearch
                      ? index ==
                            search.selected.clamp(0, visibleFiles.length - 1)
                      : c.active == Uri.file(path).toString(),
                  title: p.basename(path),
                  subtitle: p.relative(
                    p.dirname(path),
                    from: project!.access.boundary,
                  ),
                  pathSubtitle: true,
                  tooltip: path,
                  compact: true,
                  icon: BusyApiGlyphs.document,
                  menuTooltip: l.fileActions,
                  menuItemsBuilder: (_) => [
                    BusyApiPopupMenuItem<String>(
                      value: 'move',
                      icon: BusyApiGlyphs.edit,
                      label: l.moveSourceFile,
                    ),
                    BusyApiPopupMenuItem<String>(
                      value: 'delete',
                      icon: BusyApiGlyphs.delete,
                      label: l.deleteSourceFile,
                    ),
                  ],
                  onMenuSelected: (action) => run(
                    () => action == 'delete'
                        ? showFileDeletion(
                            context,
                            c,
                            Uri.file(path).toString(),
                          )
                        : showFileMove(context, c, Uri.file(path).toString()),
                  ),
                  onTap: () => run(() async {
                    if (navigationSearch) search.select(index);
                    await c.openFile(Uri.file(path).toString());
                    c.mode = 'Source';
                  }),
                );
              },
            )
          : project == null
          ? const SizedBox.shrink()
          : ApiNavigator(
              key: _apiNavigatorKey,
              controller: c,
              projection: projection,
              filter: filter,
              run: run,
              search: navigationSearch ? search : null,
            ),
    );
    final navigationSidebar = BusyApiSidebarSurface(
      showEndBorder: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (project != null)
            Padding(
              padding: BusyApiInsets.sidebarHeader,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        BusyApiGlyphs.folder,
                        size: BusyApiSizes.iconSm,
                      ),
                      const SizedBox(width: BusyApiSpacing.sm),
                      Expanded(
                        child: Text(
                          p.basename(project.access.boundary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      BusyApiHeaderPopupMenuButton<String>(
                        tooltip: l.sidebarView,
                        icon: files
                            ? BusyApiGlyphs.folder
                            : BusyApiGlyphs.document,
                        transparent: true,
                        borderRadius: BusyApiRadius.nativeHeaderButton,
                        highlightWhenOpen: false,
                        itemBuilder: (_) => [
                          BusyApiPopupMenuItem(
                            value: 'api',
                            label: l.api,
                            icon: BusyApiGlyphs.document,
                            checked: !files,
                            trailingCheck: true,
                          ),
                          BusyApiPopupMenuItem(
                            value: 'files',
                            label: l.files,
                            icon: BusyApiGlyphs.folder,
                            checked: files,
                            trailingCheck: true,
                          ),
                          const PopupMenuDivider(),
                          BusyApiPopupMenuItem(
                            value: 'filter',
                            label: l.filterNavigation,
                            icon: BusyApiGlyphs.search,
                          ),
                          if (files)
                            BusyApiPopupMenuItem(
                              value: 'create-file',
                              label: l.createSourceFile,
                              icon: BusyApiGlyphs.newDocument,
                            ),
                          if (!files)
                            BusyApiPopupMenuItem(
                              value: 'add-operation',
                              label: l.addOperation,
                              icon: BusyApiGlyphs.add,
                              enabled: c.root != null && c.designSafe,
                            ),
                        ],
                        onSelected: (value) {
                          if (value == 'filter') {
                            search.open(BusyApiSearchCategory.navigation);
                            return;
                          }
                          if (value == 'create-file') {
                            run(() => showFileCreation(context, c));
                            return;
                          }
                          if (value == 'add-operation') {
                            run(() => addOperation(context, c));
                            return;
                          }
                          setState(() {
                            files = value == 'files';
                            _saveLayout();
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: BusyApiSpacing.sm),
                  if (files)
                    Tooltip(
                      message: project.access.boundary,
                      child: BusyApiPathLabel(
                        path: project.access.boundary,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.mutedForeground),
                      ),
                    )
                  else
                    BusyApiPopupSelector<String>(
                      value: c.root,
                      label: contractIdentityLabel(
                        project.roots
                                .where((r) => r.id == c.root)
                                .firstOrNull
                                ?.name ??
                            l.selectRoot,
                      ),
                      tooltip: l.selectRoot,
                      fullWidth: true,
                      options: [
                        for (final root in project.roots)
                          BusyApiPopupSelectorOption(
                            value: root.id,
                            label: contractIdentityLabel(root.name),
                          ),
                      ],
                      onSelected: (value) =>
                          run(() => c.selectRoot(value).then((_) {})),
                    ),
                ],
              ),
            ),
          if (project == null)
            Expanded(
              child: ListView.builder(
                padding: BusyApiInsets.sidebarList,
                itemCount: c.recent.length,
                itemBuilder: (context, index) {
                  final path = c.recent[index];
                  final projectPath =
                      {
                        '.yaml',
                        '.yml',
                        '.json',
                      }.contains(p.extension(path).toLowerCase())
                      ? p.dirname(path)
                      : path;
                  return BusyApiSidebarRecordRow<void>(
                    key: ValueKey(path),
                    icon: BusyApiGlyphs.folder,
                    title: p.basename(projectPath),
                    subtitle: path,
                    pathSubtitle: true,
                    tooltip: path,
                    onTap: () => run(() => open(path)),
                  );
                },
              ),
            ),
          if (project != null)
            Expanded(
              child:
                  search.active &&
                      search.category == BusyApiSearchCategory.navigation
                  ? const SizedBox.shrink()
                  : navigationContent,
            ),
        ],
      ),
    );
    final sidebarBody = BusyApiRetainedCrossfade(
      index: search.active ? 1 : 0,
      duration: BusyApiMotion.search,
      children: [
        ExcludeFocus(excluding: search.active, child: navigationSidebar),
        BusyApiSidebarSurface(
          showEndBorder: false,
          child: BusyApiSearchSidebar(
            key: searchKey,
            session: search,
            onMoveNavigation: (delta) {
              if (!navigationSearch ||
                  navigationQuery != search.query.text ||
                  !identical(project, c.project) ||
                  sourceRoot != c.root) {
                return;
              }
              if (!files) {
                _apiNavigatorKey.currentState?.moveSearchSelection(delta);
              } else if (project != null && visibleFiles.isNotEmpty) {
                search.move(delta, visibleFiles.length);
              }
            },
            onActivateNavigation: () async {
              if (!navigationSearch ||
                  navigationQuery != search.query.text ||
                  !identical(project, c.project) ||
                  sourceRoot != c.root) {
                return;
              }
              if (!files) {
                await _apiNavigatorKey.currentState?.activateSearchSelection();
              } else if (visibleFiles.isNotEmpty) {
                final index = search.selected.clamp(0, visibleFiles.length - 1);
                await c.openFile(Uri.file(visibleFiles[index]).toString());
                if (mounted && identical(project, c.project)) c.mode = 'Source';
              }
            },
            navigation:
                search.active &&
                    search.category == BusyApiSearchCategory.navigation
                ? navigationContent
                : null,
            registry: commands,
            onReveal: revealSearch,
            run: run,
          ),
        ),
      ],
    );
    IconData modeIcon(String mode) => switch (mode) {
      'Design' => BusyApiGlyphs.edit,
      'Source' => BusyApiGlyphs.code,
      _ => BusyApiGlyphs.preview,
    };
    final mainMenu = BusyApiHeaderPopupMenuButton<String>(
      tooltip: l.appTitle,
      icon: BusyApiGlyphs.menuVertical,
      itemBuilder: (context) => [
        for (final id in [
          'create',
          'open',
          'folder',
          'import',
          'save',
          'palette',
          'settings',
          'root',
          'bundle',
          'generate',
          'documentation',
          'redoc-reference',
          'swagger-reference',
          'governance',
          'mock',
          'contract-tests',
          'git',
          'semantic-review',
          'quit',
        ])
          BusyApiPopupMenuItem(
            value: id,
            label: commands[id]!.label(context),
            shortcut: commands[id]!.shortcut?.label,
            gtkAccelerator: commands[id]!.shortcut?.gtkAccelerator,
            enabled: commands[id]!.canExecute,
          ),
      ],
      onSelected: (id) => run(() async {
        await commands.execute(id);
      }),
    );
    Widget header(bool sidebarAvailable) {
      _sidebarAvailable = sidebarAvailable;
      return BusyApiLinuxHeaderLayout(
        centerAllocation: search.active
            ? BusyApiLinuxHeaderCenterAllocation.fillBetweenControls
            : BusyApiLinuxHeaderCenterAllocation.centeredBetweenControls,
        leading: BusyApiLinuxHeaderControlGroup(
          children: [
            BusyApiLinuxHeaderIconButton(
              icon: BusyApiGlyphs.sidebar,
              tooltip: sidebarAvailable && sidebar
                  ? l.hideSidebar
                  : l.showSidebar,
              selected: sidebarAvailable && sidebar,
              shortcut: commands['sidebar']!.shortcut?.label,
              onPressed: sidebarAvailable
                  ? () => run(() async {
                      await commands.execute('sidebar');
                    })
                  : null,
            ),
            if (project != null && !search.active)
              BusyApiLinuxHeaderIconButton(
                icon: BusyApiGlyphs.headerBackFor(Directionality.of(context)),
                tooltip: l.navigationBack,
                shortcut: commands['back']!.shortcut?.label,
                onPressed: commands['back']!.canExecute
                    ? () => run(back)
                    : null,
              ),
          ],
        ),
        title: BusyApiRetainedCrossfade(
          index: search.active ? 1 : 0,
          duration: BusyApiMotion.search,
          children: [
            BusyApiLinuxHeaderTitle(
              c.buffer == null ? l.appTitle : p.basename(c.buffer!.path),
            ),
            BusyApiSearchField(
              key: const ValueKey('shared-search-query'),
              controller: search.query,
              hintText: l.search,
              focusRequest: search.focusRequest,
              clearOnEscape: false,
              onMoveSelection: (delta) => searchKey.currentState?.move(delta),
              onSubmitted: (_) => run(() async {
                await searchKey.currentState?.activateSelected();
              }),
              onEscape: search.close,
            ),
          ],
        ),
        trailing: BusyApiLinuxHeaderControlGroup(
          children: [
            if (project != null && !search.active) ...[
              BusyApiHeaderPopupMenuButton<String>(
                tooltip: l.viewMode,
                icon: modeIcon(c.mode),
                itemBuilder: (context) => [
                  for (final mode
                      in c.root == null
                          ? ['Source']
                          : ['Design', 'Source', 'Reference'])
                    BusyApiPopupMenuItem(
                      value: 'view-$mode',
                      label: commands['view-$mode']!.label(context),
                      icon: modeIcon(mode),
                      enabled: commands['view-$mode']!.canExecute,
                      checked: c.mode == mode,
                      trailingCheck: true,
                    ),
                  const PopupMenuDivider(),
                  BusyApiPopupMenuItem(
                    value: 'preview',
                    label: l.preview,
                    icon: BusyApiGlyphs.preview,
                    checked: c.preview,
                    trailingCheck: true,
                    enabled: commands['preview']!.canExecute,
                  ),
                ],
                onSelected: (id) => run(() async {
                  await commands.execute(id);
                }),
              ),
              BusyApiLinuxHeaderIconButton(
                icon: BusyApiGlyphs.save,
                tooltip: l.save,
                shortcut: commands['save']!.shortcut?.label,
                onPressed: commands['save']!.canExecute
                    ? () => run(() async {
                        await commands.execute('save');
                      })
                    : null,
              ),
            ],
            BusyApiHeaderIconButton(
              icon: BusyApiGlyphs.search,
              tooltip: l.search,
              selected: search.active,
              onPressed: () => run(toggleSearch),
            ),
            mainMenu,
          ],
        ),
      );
    }

    final workspace = FocusScope(
      autofocus: true,
      debugLabel: 'BusyAPI workspace commands',
      child: Scaffold(
        backgroundColor: project == null ? colors.view : colors.window,
        body: LayoutBuilder(
          builder: (context, constraints) => LinuxPageFrame(
            header: header(
              constraints.maxWidth >= BusyApiSizes.workspaceSidebarBreakpoint,
            ),
            sidebarHeader: const BusyApiLinuxBrandHeader(),
            sidebarBody: sidebarBody,
            sidebarAvailable:
                search.active ||
                constraints.maxWidth >= BusyApiSizes.workspaceSidebarBreakpoint,
            sidebarOverlay:
                search.active &&
                constraints.maxWidth < BusyApiSizes.workspaceSidebarBreakpoint,
            sidebarExpanded: sidebar || search.active,
            sidebarTransitionGeneration: transition,
            body: LayoutBuilder(
              builder: (context, _) => Column(
                children: [
                  if (widget.appearanceFailure != null && project != null)
                    BusyApiStatusBox(
                      message: l.appearancePersistenceFailed,
                      kind: BusyApiStatusKind.error,
                    ),
                  if (project != null)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: BusyApiSurfaceColors.of(context).headerbarFlat,
                        border: Border(
                          bottom: BorderSide(
                            color: BusyApiSurfaceColors.of(context)
                                .subtleBorder,
                          ),
                        ),
                      ),
                      child: SizedBox(
                        height: BusyApiSizes.paneHeaderHeight,
                        child: Row(
                          children: [
                            Expanded(
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.fromLTRB(
                                  BusyApiSpacing.sm,
                                  BusyApiSpacing.xs,
                                  BusyApiSpacing.sm,
                                  0,
                                ),
                                itemCount: c.tabs.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: BusyApiSpacing.xs),
                                itemBuilder: (context, index) {
                                  final id = c.tabs[index];
                                  return ListenableBuilder(
                                    key: ValueKey(id),
                                    listenable: c,
                                    builder: (context, _) =>
                                        BusyApiWorkspaceTabButton(
                                          key: ValueKey(id),
                                          title: p.relative(
                                            Uri.parse(id).toFilePath(),
                                            from: project.access.boundary,
                                          ),
                                          icon: BusyApiGlyphs.document,
                                          active: c.active == id,
                                          dirty: c.store!.get(id).dirty,
                                          onSelected: () =>
                                              run(() => c.openFile(id)),
                                          onClose: () =>
                                              run(() => closeTab(id)),
                                          onSecondaryTapUp: (details) => run(
                                            () async {
                                              final action =
                                                  await showBusyApiContextMenu<
                                                    String
                                                  >(
                                                    context,
                                                    details.globalPosition,
                                                    items: [
                                                      BusyApiPopupMenuItem(
                                                        value: 'close',
                                                        label: l.close,
                                                      ),
                                                      BusyApiPopupMenuItem(
                                                        value: 'copy',
                                                        label: l.copyPath,
                                                      ),
                                                    ],
                                                  );
                                              if (action == 'close') {
                                                await closeTab(id);
                                              }
                                              if (action == 'copy') {
                                                await Clipboard.setData(
                                                  ClipboardData(
                                                    text: Uri.parse(id)
                                                        .toFilePath(),
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (project != null &&
                      c.root != null &&
                      !project.roots.any((root) => root.id == c.root))
                    BusyApiBanner(
                      title: l.unconfiguredRoot,
                      actionLabel: l.selectRoot,
                      onAction: project.roots.isEmpty
                          ? null
                          : () => run(chooseRoot),
                    ),
                  if (c.buffer?.externalConflict ?? false)
                    BusyApiActionRow(
                      title: l.conflict,
                      subtitle: l.reload,
                      onTap: () => run(resolveConflict),
                    ),
                  if (c.form != null)
                    BusyApiActionRow(
                      title: l.resumeCapturedForm,
                      onTap: () => run(() => resumeCapturedForm(context, c)),
                    ),
                  if (c.storageError != null)
                    BusyApiActionRow(
                      title: l.recoveryUnavailable,
                      subtitle: c.storageError,
                      onTap: () => run(c.persist),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      key: const ValueKey('workspace-working-area'),
                      builder: (context, available) => Column(
                        children: [
                          Expanded(
                            child: project == null
                                ? ColoredBox(
                                    color: colors.view,
                                    child: BusyApiClamp(
                                      maxWidth: BusyApiSizes.contentWidth,
                                      margin: EdgeInsets.zero,
                                      padding: BusyApiInsets.welcomePage,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          BusyApiGroupedList(
                                            title: l.create,
                                            filled: true,
                                            children: [
                                              BusyApiActionRow(
                                                title: l.createProject,
                                                subtitle:
                                                    l.createProjectDescription,
                                                leading: const Icon(
                                                  BusyApiGlyphs.newDocument,
                                                ),
                                                trailing: Icon(
                                                  BusyApiGlyphs.forwardFor(
                                                    Directionality.of(context),
                                                  ),
                                                ),
                                                onTap: () => run(create),
                                              ),
                                            ],
                                          ),
                                          BusyApiGroupedList(
                                            title: l.open,
                                            filled: true,
                                            children: [
                                              BusyApiActionRow(
                                                title: l.openFile,
                                                subtitle:
                                                    l.openContractDescription,
                                                leading: const Icon(
                                                  BusyApiGlyphs.documentOpen,
                                                ),
                                                trailing: Icon(
                                                  BusyApiGlyphs.forwardFor(
                                                    Directionality.of(context),
                                                  ),
                                                ),
                                                onTap: () => run(chooseFile),
                                              ),
                                              BusyApiActionRow(
                                                title: l.openFolder,
                                                subtitle:
                                                    l.openProjectDescription,
                                                leading: const Icon(
                                                  BusyApiGlyphs.folderOpen,
                                                ),
                                                trailing: Icon(
                                                  BusyApiGlyphs.forwardFor(
                                                    Directionality.of(context),
                                                  ),
                                                ),
                                                onTap: () =>
                                                    run(chooseDirectory),
                                              ),
                                              BusyApiActionRow(
                                                title: l.importProject,
                                                subtitle:
                                                    l.importProjectDescription,
                                                leading: const Icon(
                                                  BusyApiGlyphs.documentOpen,
                                                ),
                                                trailing: Icon(
                                                  BusyApiGlyphs.forwardFor(
                                                    Directionality.of(context),
                                                  ),
                                                ),
                                                onTap: () => run(importProject),
                                              ),
                                            ],
                                          ),
                                          if (widget.appearanceFailure != null)
                                            BusyApiStatusBox(
                                              message:
                                                  l.appearancePersistenceFailed,
                                              kind: BusyApiStatusKind.error,
                                            ),
                                        ],
                                      ),
                                    ),
                                  )
                                : LayoutBuilder(
                                    builder: (context, constraints) {
                                      final main = c.mode == 'Reference'
                                          ? ReferenceView(
                                              controller: c,
                                              reveal: (i) =>
                                                  run(() => reveal(i)),
                                              tryOperation: (operation) => run(
                                                () =>
                                                    requestRun.open(operation),
                                              ),
                                            )
                                          : c.mode == 'Design' && c.root != null
                                          ? Designer(
                                              controller: c,
                                              run: run,
                                              reveal: (i) =>
                                                  run(() => reveal(i)),
                                              tryOperation: (operation) => run(
                                                () =>
                                                    requestRun.open(operation),
                                              ),
                                            )
                                          : c.buffer == null
                                          ? Center(child: Text(l.selectRoot))
                                          : SourceEditor(
                                              key: sourceKey,
                                              onFind: () => search.open(
                                                BusyApiSearchCategory.document,
                                              ),
                                              changes: c,
                                              buffer: c.buffer!,
                                              diagnostics: sourceDiagnostics(
                                                context,
                                                c,
                                              ),
                                              owner: (
                                                project,
                                                sourceRoot,
                                                sourceResource,
                                              ),
                                              isCurrent: () =>
                                                  !c.disposed &&
                                                  identical(
                                                    c.project,
                                                    project,
                                                  ) &&
                                                  c.root == sourceRoot &&
                                                  c.active == sourceResource &&
                                                  c.mode == 'Source',
                                              onEdit: c.sourceDelta,
                                              backgroundAssistanceReady: () =>
                                                  !c.checking,
                                              foldedPointers: sourceRoot == null
                                                  ? const []
                                                  : c.sourceFolds(
                                                      sourceRoot,
                                                      sourceResource!,
                                                    ),
                                              onFoldStateChanged:
                                                  sourceRoot == null
                                                  ? null
                                                  : (
                                                      pointers,
                                                    ) => c.rememberSourceFolds(
                                                      project,
                                                      sourceRoot,
                                                      sourceResource!,
                                                      pointers,
                                                      viewRevision:
                                                          sourceViewRevision,
                                                    ),
                                              assistance: sourceRoot == null
                                                  ? null
                                                  : (selection) =>
                                                        c.sourceAssistance(
                                                          project,
                                                          sourceRoot,
                                                          sourceResource!,
                                                          selection,
                                                        ),
                                              onReveal: (item) =>
                                                  run(() => reveal(item)),
                                              onQuickFix: sourceRoot == null
                                                  ? null
                                                  : (selection) => run(
                                                      () =>
                                                          showSourceDiagnosticFixes(
                                                            context,
                                                            c,
                                                            selection,
                                                          ),
                                                    ),
                                              onChanged: (t) =>
                                                  c.sourceEdit(c.active!, t),
                                              undo: () => run(() async {
                                                await commands.execute('undo');
                                              }),
                                              redo: () => run(() async {
                                                await commands.execute('redo');
                                              }),
                                            );
                                      if (c.preview &&
                                          c.mode != 'Reference' &&
                                          constraints.maxWidth >=
                                              BusyApiSizes.previewMinWidth *
                                                  2) {
                                        return Row(
                                          children: [
                                            SizedBox(
                                              width:
                                                  constraints.maxWidth *
                                                  fraction,
                                              child: main,
                                            ),
                                            GestureDetector(
                                              onHorizontalDragUpdate:
                                                  (details) => setState(() {
                                                    fraction =
                                                        (fraction +
                                                                details
                                                                        .delta
                                                                        .dx /
                                                                    constraints
                                                                        .maxWidth)
                                                            .clamp(.25, .75);
                                                    _saveLayout();
                                                  }),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors
                                                    .resizeColumn,
                                                child: Container(
                                                  width: BusyApiSpacing.xs,
                                                  color: colors.divider,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: ReferenceView(
                                                controller: c,
                                                reveal: (i) =>
                                                    run(() => reveal(i)),
                                                tryOperation: (operation) =>
                                                    run(
                                                      () => requestRun.open(
                                                        operation,
                                                      ),
                                                    ),
                                              ),
                                            ),
                                          ],
                                        );
                                      }
                                      return BusyApiSemanticFade(
                                        transitionKey: (c.mode, c.preview),
                                        child: main,
                                      );
                                    },
                                  ),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: available.maxHeight / 2,
                            ),
                            child: ListenableBuilder(
                              listenable: Listenable.merge([
                                requestRun,
                                mockRun,
                                bundleRun,
                                c,
                              ]),
                              builder: (context, _) {
                                final panels = <Widget>[
                                  if (requestRun.phase != 'idle')
                                    RequestRunPanel(run: requestRun),
                                  if (mockRun.phase != 'idle')
                                    MockRunPanel(controller: mockRun),
                                  if (bundleRun.phase != 'idle')
                                    BundleRunPanel(run: bundleRun),
                                  if (problems && project != null)
                                    ProblemsPanel(
                                      controller: c,
                                      reveal: (finding) =>
                                          run(() => reveal(finding)),
                                    ),
                                ];
                                if (panels.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return LayoutBuilder(
                                  builder: (context, bounds) {
                                    // Keep room for a header and a scrollable body.
                                    // At small heights the surrounding native scroll
                                    // body keeps every retained tool reachable.
                                    final allocated =
                                        bounds.maxHeight / panels.length;
                                    final height =
                                        allocated <
                                            BusyApiSizes.paneHeaderHeight * 2
                                        ? bounds.maxHeight <
                                                  BusyApiSizes
                                                          .paneHeaderHeight *
                                                      2
                                              ? BusyApiSizes.paneHeaderHeight *
                                                    2
                                              : bounds.maxHeight
                                        : allocated;
                                    return SingleChildScrollView(
                                      key: const ValueKey('workspace-tools'),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final panel in panels)
                                            ConstrainedBox(
                                              constraints: BoxConstraints(
                                                maxHeight: height,
                                              ),
                                              child: panel,
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (project != null)
                    ListenableBuilder(
                      listenable: c,
                      builder: (context, _) => BusyApiDocumentStatusBar(
                        label: l.problemsStatus(
                          (c.analysis?['findings'] as List? ?? []).length,
                          workspaceCheckSummary(context, c),
                        ),
                        details: c.error ?? '${c.analysis?['status'] ?? ''}',
                        location: c.buffer == null
                            ? ''
                            : p.relative(
                                c.buffer!.path,
                                from: project.access.boundary,
                              ),
                        onPressed: () => setState(() => problems = !problems),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return BusyApiRetainedCrossfade(
      index: _settingsOpen ? 1 : 0,
      children: [
        workspace,
        BusyApiSettingsScreen(
          mode: widget.themeMode,
          appearanceEnabled: !_closeCommitted,
          onThemeChanged: (mode) {
            if (!_closeCommitted) run(() => widget.setTheme(mode));
          },
          appearanceFailure: widget.appearanceFailure,
          onBack: closeSettings,
          projectSettings: projectSettings(context),
          menu: mainMenu,
        ),
      ],
    );
  }
}

// BusyMark's command metadata is shared by menus, Actions, tooltips, keyboard
// dispatch and modal boundaries. Callbacks always resolve the live workspace.
BusyApiCommandRegistry _workspaceCommands(
  WorkspaceController c,
  WorkspaceScreenState? Function() current, {
  BusyApiKeyBinding? requestShortcut,
  Future<void> Function(String, BusyApiKeyBinding)? configureShortcut,
}) {
  BusyApiCommand command(
    String id,
    String Function(AppLocalizations) label,
    Future<void> Function(WorkspaceScreenState) action, {
    bool Function()? enabled,
    bool Function()? selected,
    BusyApiCommandScope scope = BusyApiCommandScope.application,
  }) => BusyApiCommand(
    id: id,
    label: (context) => label(context.l10n),
    category: (context) => scope == BusyApiCommandScope.editor
        ? context.l10n.source
        : scope == BusyApiCommandScope.sidebar
        ? context.l10n.navigation
        : context.l10n.appTitle,
    scope: scope,
    shortcut: id == 'request-send'
        ? requestShortcut ?? busyApiDefaultKeyBindings[id]
        : busyApiDefaultKeyBindings[id],
    enabled: () =>
        current() != null &&
        !c.disposed &&
        (current()?._settingsOpen != true ||
            {'settings', 'back', 'quit'}.contains(id)) &&
        (enabled?.call() ?? true),
    selected: selected ?? () => false,
    execute: () async {
      final state = current();
      if (state != null) await action(state);
    },
  );
  bool project() => c.project != null;
  bool root() =>
      project() &&
      c.root != null &&
      c.project!.roots.any((root) => root.id == c.root);
  return BusyApiCommandRegistry([
    command('create', (l) => l.createProject, (s) => s.create()),
    command('open', (l) => l.openFile, (s) => s.chooseFile()),
    command('folder', (l) => l.openFolder, (s) => s.chooseDirectory()),
    command('import', (l) => l.importProject, (s) => s.importProject()),
    command('save', (l) => l.save, (s) => c.saveAll(), enabled: project),
    command(
      'request-send',
      (l) => l.requestSend,
      (s) => s.requestRun.send(),
      enabled: () => current()?.requestRun.canSend == true,
    ),
    command(
      'undo',
      (l) => l.undo,
      (s) => c.undo(),
      enabled: () => c.hasPendingFields || (c.store?.canUndo ?? false),
      scope: BusyApiCommandScope.editor,
    ),
    command(
      'redo',
      (l) => l.redo,
      (s) => c.redo(),
      enabled: () => c.store?.canRedo ?? false,
      scope: BusyApiCommandScope.editor,
    ),
    command(
      'close-tab',
      (l) => l.close,
      (s) => c.active == null ? s.close() : s.closeTab(c.active!),
    ),
    command('quit', (l) => l.quit, (s) => s.close()),
    command(
      'back',
      (l) => l.navigationBack,
      (s) => s.back(),
      enabled: () => current()?._settingsOpen == true || c.historyIndex > 0,
    ),
    command(
      'forward',
      (l) => l.navigationForward,
      (s) => c.navigateHistory(1),
      enabled: () => c.historyIndex + 1 < c.history.length,
    ),
    command(
      'sidebar',
      (l) => l.sidebarView,
      (s) => s.toggleSidebar(),
      selected: () => current()?.sidebar == true,
      enabled: () => current()?._sidebarAvailable == true,
      scope: BusyApiCommandScope.sidebar,
    ),
    command(
      'search',
      (l) => l.search,
      (s) async => s.search.open(BusyApiSearchCategory.document),
      enabled: () => project() && c.buffer != null,
    ),
    command(
      'project-search',
      (l) => l.projectSearch,
      (s) => s.projectSearch(),
      enabled: project,
    ),
    command('palette', (l) => l.actions, (s) => s.palette()),
    command('settings', (l) => l.settings, (s) => s.settings()),
    command(
      'root',
      (l) => l.selectRoot,
      (s) => s.chooseRoot(),
      enabled: project,
    ),
    for (final mode in ['Design', 'Source', 'Reference'])
      command(
        'view-$mode',
        (l) => switch (mode) {
          'Design' => l.design,
          'Source' => l.source,
          _ => l.reference,
        },
        (s) => s.view(mode),
        enabled: mode == 'Source' ? project : root,
        selected: () => c.mode == mode,
        scope: BusyApiCommandScope.documentView,
      ),
    command(
      'preview',
      (l) => l.preview,
      (s) => s.togglePreview(),
      enabled: root,
      selected: () => c.preview,
      scope: BusyApiCommandScope.documentView,
    ),
    command(
      'bundle',
      (l) => l.bundleContract,
      (s) => s.createBundle(),
      enabled: () => root() && current()?.bundleRun.busy == false,
    ),
    command(
      'generate',
      (l) => l.generateClient,
      (s) => s.generateClient(),
      enabled: () => root() && current()?.bundleRun.busy == false,
    ),
    command(
      'documentation',
      (l) => l.buildDocumentation,
      (s) => s.createDocumentation(),
      enabled: () => root() && current()?.bundleRun.busy == false,
    ),
    command(
      'redoc-reference',
      (l) => l.openRedocReference,
      (s) => s.openRedocReference(),
      enabled: root,
    ),
    command(
      'swagger-reference',
      (l) => l.openSwaggerReference,
      (s) => s.openSwaggerReference(),
      enabled: root,
    ),
    command(
      'governance',
      (l) => l.policyGovernance,
      (s) => s.governance(),
      enabled: root,
    ),
    command(
      'mock',
      (l) => l.mockRun,
      (s) => s.mockRun.prepare(),
      enabled: () => root() && current()?.mockRun.busy == false,
    ),
    command(
      'contract-tests',
      (l) => l.contractTests,
      (s) => showContractTests(s.context, c, s.requestRun.secrets),
      enabled: root,
    ),
    command(
      'git',
      (l) => l.gitChanges,
      (s) => showGitWorkspace(s.context, c),
      enabled: project,
    ),
    command(
      'semantic-review',
      (l) => l.semanticReview,
      (s) => showSemanticReview(s.context, c, s.reveal),
      enabled: root,
    ),
  ], configureShortcut: configureShortcut);
}
