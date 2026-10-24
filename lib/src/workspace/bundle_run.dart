import 'dart:async';
import 'dart:convert';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/review_viewport.dart';
import '../app/busyapi_dialogs.dart';
import '../app/localization.dart';
import '../platform/local_output_service.dart';
import 'workspace_controller.dart';
import 'tool_surface.dart';
import '../app/busyapi_glyphs.dart';
import '../comparison/review_comparison.dart';

/// Presentation owns one frozen output, never a second source buffer. Work can
/// continue in Source while generation runs; a project switch cancels the old
/// owner and a late completion cannot publish or notify a replacement owner.
class BundleRunController extends ChangeNotifier {
  BundleRunController(this.workspace) {
    workspace.addListener(_observe);
  }
  final WorkspaceController workspace;
  BusyProject? owner;
  BundleOutput? output;
  OutputDirectoryReceipt? existing;
  String? destination, failure, previous;
  String? failureDetails;
  String? failureAssetComponent;
  Map<String, dynamic>? failureAnalysis;
  int? failureCategory;
  String phase = 'idle';
  bool expanded = true,
      _disposed = false,
      _cancelled = false,
      _starting = false;
  int _epoch = 0;
  String? _request;
  bool get busy =>
      _starting || ['generating', 'publishing', 'cancelling'].contains(phase);
  String? get failedRoot {
    final roots = failureAnalysis?['checkedRoots'];
    return roots is List && roots.length == 1 && roots.single is String
        ? roots.single as String
        : null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _observe() {
    if (owner != null && !identical(workspace.project, owner)) clear();
  }

  Future<void> prepare(
    String path, {
    bool documentation = false,
    String preset = 'native-reference',
    Map<String, String>? labels,
    BundleFormat format = BundleFormat.singleFile,
    String? generator,
    Map<String, Object?> generatorOptions = const {},
    String? templateDirectory,
    GeneratorRuntime? generatorRuntime,
  }) async {
    if (busy || workspace.project == null || workspace.root == null) return;
    final initialProject = workspace.project, initialRoot = workspace.root;
    _starting = true;
    try {
      if (!await workspace.flush() ||
          _disposed ||
          !identical(workspace.project, initialProject) ||
          workspace.root != initialRoot) {
        return;
      }
    } finally {
      _starting = false;
    }
    output?.close();
    output = null;
    existing = null;
    failure = null;
    failureDetails = null;
    failureCategory = null;
    failureAssetComponent = null;
    failureAnalysis = null;
    previous = null;
    owner = workspace.project;
    final project = owner!, root = workspace.root!;
    destination = path;
    _cancelled = false;
    phase = 'generating';
    expanded = true;
    final epoch = ++_epoch, request = 'output-bundle-$epoch:';
    _request = request;
    _notify();
    bool current() =>
        !_disposed &&
        !_cancelled &&
        epoch == _epoch &&
        identical(workspace.project, project);
    BundleOutput? prepared;
    try {
      prepared = generator != null
          ? await project.prepareClient(
              root,
              path,
              generator: generator,
              options: generatorOptions,
              templateDirectory: templateDirectory,
              runtime: generatorRuntime,
              requestId: request,
              cancelled: () => !current(),
              onResourceRefreshed: (resource) =>
                  workspace.resourceRefreshed(project, resource),
            )
          : documentation
          ? await project.prepareDocumentation(
              root,
              path,
              preset: preset,
              labels: labels,
              requestId: request,
              cancelled: () => !current(),
              onResourceRefreshed: (resource) =>
                  workspace.resourceRefreshed(project, resource),
            )
          : await project.prepareBundle(
              root,
              path,
              requestId: request,
              cancelled: () => !current(),
              onResourceRefreshed: (resource) =>
                  workspace.resourceRefreshed(project, resource),
              format: format,
            );
      final receipt = await prepared.existing();
      if (!current()) {
        prepared.close();
        return;
      }
      output = prepared;
      existing = receipt;
      phase = 'ready';
    } on Object catch (error) {
      prepared?.close();
      if (!current()) return;
      failure = error is CoreFailure ? error.code : 'output.failure';
      failureCategory = outputFailureExitCode(error);
      failureAnalysis = error is OutputAnalysisFailure ? error.analysis : null;
      final cause = error is OutputAnalysisFailure ? error.cause : error;
      failureDetails = cause is GeneratorFailure ? cause.detail : null;
      failureAssetComponent = cause is DocumentationAssetsFailure
          ? '${cause.preset}/${cause.component}'
          : cause is ResourcePackageAssetsFailure
          ? cause.component
          : null;
      phase = 'failed';
    } finally {
      if (epoch == _epoch) {
        _request = null;
        _notify();
      }
    }
  }

  Future<void> publish() async {
    final captured = output;
    if (_disposed ||
        phase != 'ready' ||
        captured == null ||
        !identical(owner, workspace.project)) {
      return;
    }
    final epoch = _epoch;
    _cancelled = false;
    phase = 'publishing';
    _notify();
    try {
      final result = await captured.publish(
        replaceIdentity: existing?.identity,
        cancelled: () =>
            _cancelled ||
            _disposed ||
            epoch != _epoch ||
            !identical(owner, workspace.project),
      );
      if (_disposed || epoch != _epoch) return;
      previous = result.previous;
      phase = 'published';
    } on Object catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (error is OutputDirectoryChanged && error.published) {
        phase = 'partial';
        previous = error.recoveryPath;
        failure = 'output.published.uncertain';
        failureCategory = 3;
      } else if (error is CoreFailure && error.code == 'cancelled') {
        phase = 'cancelled';
      } else {
        phase = 'failed';
        failure = error is CoreFailure ? error.code : 'output.publish';
        failureCategory = outputFailureExitCode(error);
      }
    } finally {
      _notify();
    }
  }

  void cancel() {
    _cancelled = true;
    final request = _request;
    if (request != null) unawaited(_cancelRequest(request));
    if (phase == 'publishing') {
      phase = 'cancelling';
    } else {
      ++_epoch;
      phase = 'cancelled';
      output?.close();
      output = null;
      _request = null;
    }
    _notify();
  }

  Future<void> _cancelRequest(String request) async {
    try {
      await owner?.engine.cancelPrefix(request);
    } on Object {
      /* Ownership is invalidated independently of worker teardown. */
    }
  }

  void clear() {
    cancel();
    output?.close();
    output = null;
    owner = null;
    phase = 'idle';
    failure = null;
    failureDetails = null;
    failureCategory = null;
    failureAssetComponent = null;
    failureAnalysis = null;
    previous = null;
    _notify();
  }

  void toggle() {
    expanded = !expanded;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    workspace.removeListener(_observe);
    _disposed = true;
    cancel();
    output?.close();
    super.dispose();
  }
}

class BundleRunPanel extends StatelessWidget {
  const BundleRunPanel({super.key, required this.run, this.openResult});
  final BundleRunController run;
  final Future<void> Function(String directory)? openResult;

  Future<void> openPublishedResult(
    BuildContext context,
    BundleOutput output,
  ) async {
    final owner = run.owner;
    try {
      await (openResult ?? LocalOutputService().reveal)(output.destination);
    } on Object {
      if (context.mounted &&
          identical(owner, run.owner) &&
          identical(output, run.output)) {
        await showBusyApiModalDialog<void>(
          context: context,
          builder: (context) => BusyApiDialogShell(
            title: context.l10n.openResult,
            actions: [
              BusyApiDialogButton(
                label: context.l10n.close,
                onPressed: () => Navigator.pop(context),
              ),
            ],
            children: [Text(context.l10n.outputOpenFailed)],
          ),
        );
      }
    }
  }

  Future<void> generatedFiles(BuildContext context, ClientOutput output) async {
    final previous = run.existing;
    final changes = await output.changes(previous);
    if (!context.mounted || !identical(run.output, output)) return;
    await showBusyApiModalDialog<void>(
      context: context,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.generatedFiles,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.close,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        children: [
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: changes.length,
              itemBuilder: (_, index) {
                final change = changes[index];
                return BusyApiActionRow(
                  title: change.path,
                  subtitle: switch (change.kind) {
                    'added' => context.l10n.generatedAdded,
                    'removed' => context.l10n.generatedRemoved,
                    'changed' => context.l10n.generatedChanged,
                    _ => context.l10n.generatedUnchanged,
                  },
                  onTap: () async {
                    try {
                      final old = previous == null
                          ? null
                          : await output.previousBytes(
                              change.path,
                              previous.identity,
                            );
                      if (!context.mounted || !identical(run.output, output)) {
                        return;
                      }
                      final current = change.kind == 'removed'
                          ? null
                          : output.bytes(change.path);
                      String display(List<int>? bytes) => bytes == null
                          ? ''
                          : utf8.decode(bytes, allowMalformed: true);
                      await showBusyApiModalDialog<void>(
                        context: context,
                        builder: (context) => BusyApiDialogShell(
                          title: change.path,
                          actions: [
                            BusyApiDialogButton(
                              label: context.l10n.close,
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                          children: [
                            Text(context.l10n.generatedPreviewBound),
                            Text(
                              context.l10n.generatedModeChanges(
                                change.kind == 'added'
                                    ? '—'
                                    : change.beforeExecutable
                                    ? '0755'
                                    : '0644',
                                change.kind == 'removed'
                                    ? '—'
                                    : change.executable
                                    ? '0755'
                                    : '0644',
                              ),
                            ),
                            BusyApiReviewComparison(
                              before: display(old),
                              after: display(current),
                            ),
                          ],
                        ),
                      );
                    } on Object {
                      if (context.mounted && identical(run.output, output)) {
                        await showBusyApiModalDialog<void>(
                          context: context,
                          builder: (context) => BusyApiDialogShell(
                            title: context.l10n.generatedFiles,
                            actions: [
                              BusyApiDialogButton(
                                label: context.l10n.close,
                                onPressed: () => Navigator.pop(context),
                              ),
                            ],
                            children: [
                              Text(context.l10n.generatedPreviewChanged),
                            ],
                          ),
                        );
                      }
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> inputs(BuildContext context, BundleOutput output) async {
    final sources = (output.metadata['sources'] as List).cast<Map>();
    await showBusyApiModalDialog<void>(
      context: context,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.outputInputs(sources.length),
        actions: [
          BusyApiDialogButton(
            label: context.l10n.close,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        children: [
          SelectableText(output.snapshot.sourceIdentity),
          BusyApiReviewViewport(
            child: ListView.builder(
              itemCount: sources.length,
              itemBuilder: (_, index) => BusyApiActionRow(
                title: sources[index]['resource'] as String,
                subtitle: sources[index]['identity'] as String,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> publish(BuildContext context) async {
    final captured = run.output;
    if (captured == null) return;
    final l = context.l10n;
    if (run.existing != null) {
      final accepted = await showBusyApiModalDialog<bool>(
        context: context,
        builder: (context) => BusyApiDialogShell(
          title: l.replaceOwnedOutput,
          actions: [
            BusyApiDialogButton(
              label: l.cancel,
              onPressed: () => Navigator.pop(context, false),
            ),
            BusyApiDialogButton(
              label: l.replaceOwnedOutput,
              suggested: true,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
          children: [
            Text(l.outputReplacementImpact),
            SelectableText(captured.destination),
            SelectableText(l.outputReceiptIdentity(run.existing!.identity)),
          ],
        ),
      );
      if (accepted != true ||
          !context.mounted ||
          !identical(run.output, captured)) {
        return;
      }
    }
    await run.publish();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([run, run.workspace]),
    builder: (context, _) {
      if (run.phase == 'idle') return const SizedBox.shrink();
      final l = context.l10n, output = run.output;
      final status = switch (run.phase) {
        'generating' => l.outputGenerating,
        'ready' => l.outputReady,
        'publishing' => l.outputPublishing,
        'cancelling' => l.outputCancelling,
        'published' => l.outputPublished,
        'cancelled' => l.outputCancelled,
        'partial' => l.outputPartial,
        _ => l.outputFailed(run.failure ?? 'output.failure'),
      };
      final publishLabel = run.existing == null
          ? output is ClientOutput
                ? l.publishClient
                : output is DocumentationOutput
                ? l.createDocumentation
                : l.createBundle
          : l.replaceOwnedOutput;
      return BusyApiToolSurface(
        title: l.outputRun,
        status: output?.outdated == true ? l.outputOutdated : status,
        expanded: run.expanded,
        onToggle: run.toggle,
        kind: run.failure == null
            ? BusyApiStatusKind.information
            : BusyApiStatusKind.error,
        actions: [
          if (run.phase == 'published' && output != null)
            BusyApiCompactIconButton(
              tooltip: l.openResult,
              icon: BusyApiGlyphs.folderOpen,
              onPressed: () => unawaited(openPublishedResult(context, output)),
            ),
          if (run.busy)
            BusyApiCompactIconButton(
              tooltip: l.cancel,
              icon: BusyApiGlyphs.clear,
              onPressed: run.cancel,
            ),
          if (run.phase == 'ready')
            BusyApiCompactIconButton(
              tooltip: publishLabel,
              icon: BusyApiGlyphs.save,
              onPressed: () => unawaited(publish(context)),
            ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (output == null && run.destination != null)
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(
                  run.destination!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (run.failureCategory != null)
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(switch (run.failureCategory) {
                  1 => l.outputContractFailure,
                  2 => l.outputIncomplete,
                  _ => l.outputOperationalFailure,
                }),
              ),
            if (run.failureDetails?.isNotEmpty == true)
              Padding(
                padding: BusyApiInsets.listTile,
                child: SelectableText(run.failureDetails!),
              ),
            if (run.failure == 'bundle.server.template-context')
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(l.outputServerTemplateContext),
              ),
            if (run.failure == 'bundle.dialect.boundary')
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(l.bundleDialectBoundary),
              ),
            if (run.failure == 'bundle.package.assets')
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(
                  l.bundlePackageAssetsMissing(
                    run.failureAssetComponent ?? 'runtime.json',
                  ),
                ),
              ),
            if (run.failureAssetComponent != null &&
                run.failure != 'bundle.package.assets')
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(
                  l.documentationAssetsMissing(run.failureAssetComponent!),
                ),
              ),
            if (output == null && run.failedRoot != null)
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(
                  l.outputRoot(
                    run.owner?.roots
                            .where((root) => root.id == run.failedRoot)
                            .firstOrNull
                            ?.name ??
                        run.failedRoot!,
                  ),
                ),
              ),
            if (output == null &&
                run.failureAnalysis?['sourceSnapshot'] is String)
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(
                  l.outputSnapshot(
                    run.failureAnalysis!['sourceSnapshot'] as String,
                    run.failureAnalysis!['unsaved'] == true
                        ? l.outputUnsavedCopy
                        : l.outputSavedSource,
                  ),
                ),
              ),
            if (output != null)
              Padding(
                padding: BusyApiInsets.listTile,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.outputRoot(
                        run.owner?.roots
                                .where(
                                  (root) => root.id == output.snapshot.root,
                                )
                                .firstOrNull
                                ?.name ??
                            output.metadata['root'] as String,
                      ),
                    ),
                    Text(
                      l.outputSnapshot(
                        output.snapshot.sourceIdentity,
                        output.unsaved
                            ? l.outputUnsavedCopy
                            : l.outputSavedSource,
                      ),
                    ),
                    Text(
                      output.destination,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      output is ClientOutput
                          ? l.generatedClientContents(
                              output.metadata['generator'] as String,
                              output.files.length,
                            )
                          : output is DocumentationOutput
                          ? output.metadata['preset'] == 'redoc'
                                ? l.outputRedocContents
                                : output.metadata['preset'] == 'swagger'
                                ? l.outputSwaggerContents
                                : l.outputDocumentationContents
                          : output is ResourcePackageOutput
                          ? l.outputResourcePackageContents
                          : l.outputBundleContents,
                    ),
                  ],
                ),
              ),
            if (output != null)
              BusyApiActionRow(
                title: l.outputInputs(
                  (output.metadata['sources'] as List).length,
                ),
                onTap: () => unawaited(inputs(context, output)),
              ),
            if (output is ClientOutput) ...[
              BusyApiActionRow(
                title: l.generatedFiles,
                onTap: () => unawaited(generatedFiles(context, output)),
              ),
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(l.generatedLimitations),
              ),
              if (output.messages.isNotEmpty)
                Padding(
                  padding: BusyApiInsets.listTile,
                  child: SelectableText(output.messages),
                ),
            ],
            if (run.previous != null)
              Padding(
                padding: BusyApiInsets.listTile,
                child: Text(l.outputPreviousPreserved(run.previous!)),
              ),
            Wrap(
              children: [
                if (run.phase == 'ready')
                  BusyApiDialogButton(
                    label: publishLabel,
                    suggested: true,
                    onPressed: () => unawaited(publish(context)),
                  ),
                if (run.busy)
                  BusyApiDialogButton(label: l.cancel, onPressed: run.cancel),
                if (run.phase == 'published' && output != null)
                  BusyApiDialogButton(
                    label: l.openResult,
                    onPressed: () =>
                        unawaited(openPublishedResult(context, output)),
                  ),
                if (!run.busy)
                  BusyApiDialogButton(
                    label: run.phase == 'published' ? l.close : l.discard,
                    destructive: run.phase != 'published',
                    onPressed: run.clear,
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
