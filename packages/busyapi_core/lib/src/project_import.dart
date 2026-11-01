import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'atomic_directory_writer.dart';
import 'engine_process.dart';
import 'git.dart';
import 'model.dart';
import 'project.dart';
import 'request.dart';
import 'storage.dart';

enum ProjectImportKind { file, directory, url, git }

/// Acquisition preserves the selected project boundary independently of its
/// contract root. Opening the root as a standalone file would lose that scope.
class ProjectImportResult {
  const ProjectImportResult({required this.destination, required this.root});
  final String destination, root;
}

class ImportRootSelectionRequired extends CoreFailure {
  ImportRootSelectionRequired(this.roots)
    : super('import.root', 'Select one of the acquired OpenAPI roots');
  final List<ProjectRoot> roots;
}

class ImportUrlApprovalRequired extends CoreFailure {
  ImportUrlApprovalRequired(this.urls)
    : super(
        'import.approval',
        'Additional exact resource or redirect URLs need explicit approval',
      );
  final List<String> urls;
}

/// Frozen acquisition and a separately held output-parent capability. Opening
/// is intentionally not part of publication: an Open retry never clones/fetches.
class ProjectImportPlan {
  ProjectImportPlan._(
    this._access,
    this.destination,
    this.rootPath,
    this._files,
    this.metadata,
    this.unavailable,
    this._executables,
    this._emptyDirectories,
  );
  final ProjectAccess _access;
  final String destination, rootPath;
  final Map<String, List<int>> _files;
  final Map<String, Object?> metadata;
  final List<String> unavailable;
  final Set<String> _executables;
  final Set<String> _emptyDirectories;
  bool _closed = false, _published = false;
  bool get complete => unavailable.isEmpty;
  bool get published => _published;
  late final List<String> files = List.unmodifiable(
    [..._files.keys, ..._emptyDirectories.map((name) => '$name/')]..sort(),
  );
  Future<ProjectImportResult> publish({
    RunCancellation? cancellation,
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
  }) async {
    if (_closed || _published)
      throw CoreFailure(
        'import.closed',
        'The import is closed or already acquired',
      );
    cancellation?.throwIfCancelled();
    try {
      await _access.publishOutput(
        destination,
        _files,
        metadata,
        beforePublish: beforePublish,
        afterPublish: afterPublish,
        cancelled: () => cancellation?.cancelled == true,
        executableFiles: _executables,
        emptyDirectories: _emptyDirectories,
      );
    } on OutputDirectoryChanged catch (error) {
      // Publication may have succeeded before a later verification failed.
      // Preserve that fact: neither retry nor revision may acquire a second copy.
      _published = error.published;
      rethrow;
    }
    _published = true;
    return ProjectImportResult(
      destination: destination,
      root: p.join(destination, rootPath),
    );
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _access.close();
    }
  }
}

class ProjectImporter {
  const ProjectImporter(
    this.engine, {
    this.transport = const ContractHttpTransport(),
  });
  final EngineProcess engine;
  final ContractHttpTransport transport;

  Future<ProjectImportPlan> prepare({
    required ProjectImportKind kind,
    required String source,
    required String destination,
    String? root,
    Set<String> approvedUrls = const {},
    RunCancellation? cancellation,
    Future<String?> Function(List<ProjectRoot>)? selectRoot,
    Future<void> Function(AnalysisSnapshot)? onSnapshotCaptured,
  }) async {
    cancellation?.throwIfCancelled();
    approvedUrls = Set.unmodifiable(approvedUrls);
    final inputDirectory = p.current;
    bool invalidApproval(String url) {
      final uri = Uri.tryParse(url);
      return url.length > 8192 ||
          uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment;
    }

    if (kind != ProjectImportKind.url && approvedUrls.isNotEmpty ||
        kind == ProjectImportKind.url && root != null ||
        source.isEmpty ||
        source.length > 8192 ||
        destination.isEmpty ||
        destination.length > 4096 ||
        approvedUrls.length > 256 ||
        approvedUrls.any(invalidApproval)) {
      throw CoreFailure(
        'import.input',
        'Import requires bounded paths and explicit credential-free resource URLs',
      );
    }
    final target = p.normalize(p.absolute(destination));
    if (kind == ProjectImportKind.file || kind == ProjectImportKind.directory)
      source = p.normalize(p.join(inputDirectory, source));
    final output = await ProjectAccess.open(p.dirname(target));
    Directory? cloneStage;
    BusyProject? project;
    ProjectAccess? input;
    final clock = Stopwatch()..start();
    final requestPrefix =
        'import-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(output)}:';
    var finished = false;
    Future<void> cancelOwned() async {
      try {
        await engine.cancelPrefix(requestPrefix);
      } on Object {
        // A closed engine has already retired these owned jobs.
      }
    }

    cancellation?.whenCancelled.then((_) async {
      if (!finished) await cancelOwned();
    });
    void active() {
      cancellation?.throwIfCancelled();
      if (clock.elapsed > const Duration(minutes: 2))
        throw CoreFailure(
          'import.timeout',
          'Import exceeded its acquisition time budget',
        );
    }

    try {
      if (!await output.missing(target))
        throw CoreFailure(
          'import.collision',
          'Import needs a new destination; existing files are preserved',
        );
      final files = <String, List<int>>{}, unavailable = <String>{};
      final identities = <Map<String, Object?>>[];
      final executables = <String>{};
      final emptyDirectories = <String>{};
      final captureMetadata = <String, Object?>{};
      var total = 0;
      Future<void> add(
        String name,
        List<int> bytes,
        String identity, {
        bool executable = false,
      }) async {
        active();
        if (!AtomicDirectoryWriter.safeName(name) ||
            name == AtomicDirectoryWriter.receiptName ||
            files.containsKey(name))
          throw CoreFailure(
            'import.path',
            'Import contains a reserved, colliding or escaping output path',
          );
        total += bytes.length;
        if (files.length + emptyDirectories.length >=
                AtomicDirectoryWriter.maxFiles ||
            bytes.length > 16 * 1024 * 1024 ||
            kind == ProjectImportKind.url &&
                identity != 'busyapi:import-configuration' &&
                total > 48 * 1024 * 1024 ||
            total > AtomicDirectoryWriter.maxBytes)
          throw CoreFailure(
            'limit.import',
            'Acquired files exceed the import budget',
          );
        Uint8List freeze() => Uint8List.fromList(bytes).asUnmodifiableView();
        files[name] = bytes.length < 262144
            ? freeze()
            : await Isolate.run(freeze);
        if (executable) executables.add(name);
        identities.add({
          'path': name,
          'resource': identity,
          'identity': await contentIdentityAsync(bytes),
        });
      }

      late String rootPath;
      if (kind == ProjectImportKind.url) {
        final initial = Uri.tryParse(source);
        if (initial == null ||
            !['http', 'https'].contains(initial.scheme) ||
            initial.host.isEmpty ||
            initial.userInfo.isNotEmpty ||
            initial.hasFragment ||
            initial.hasQuery) {
          throw CoreFailure(
            'import.url',
            'Choose a credential-free HTTP(S) root URL without query or fragment',
          );
        }
        final approvals = {initial.toString(), ...approvedUrls};
        final resources = <String, Map<String, Object?>>{};
        final names = <String, String>{};
        Future<String?> acquire(Uri uri, {bool entry = false}) async {
          active();
          if (!approvals.contains(uri.toString())) {
            unavailable.add(uri.toString());
            return null;
          }
          try {
            final result = await transport.acquireResource(
              uri,
              approved: (target) {
                final allowed =
                    approvals.contains(target.toString()) && !target.hasQuery;
                if (!allowed) unavailable.add(target.toString());
                return allowed;
              },
              cancellation: cancellation,
            );
            final id = result.$1.toString();
            final bytes = result.$2;
            if (!entry && id != uri.toString()) unavailable.add(uri.toString());
            if (resources.containsKey(id)) return id;
            String decode() => DocumentBuffer.decode('resource', bytes).text;
            final text = bytes.length < 262144
                ? decode()
                : await Isolate.run(decode);
            final name = entry
                ? (uri.path.toLowerCase().endsWith('.json')
                      ? 'openapi.json'
                      : 'openapi.yaml')
                : 'resources/${textIdentity(id)}.${uri.path.toLowerCase().endsWith('.json') ? 'json' : 'yaml'}';
            await add(name, bytes, id);
            names[id] = name;
            resources[id] = {
              'id': id,
              'text': text,
              'generation': 0,
              'identity': await contentIdentityAsync(bytes),
            };
            return id;
          } on CoreFailure catch (failure) {
            if (failure.code != 'import.approval') rethrow;
            unavailable.add(uri.toString());
            return null;
          }
        }

        final rootId = await acquire(initial, entry: true);
        if (rootId == null) {
          throw ImportUrlApprovalRequired(
            List.unmodifiable(
              unavailable.where((value) {
                final uri = Uri.tryParse(value);
                return uri != null && uri.userInfo.isEmpty && !uri.hasQuery;
              }),
            ),
          );
        }
        rootPath = names[rootId]!;
        await engine.start();
        final attempted = <String>{rootId};
        for (var depth = 0; ; depth++) {
          active();
          final snapshot = AnalysisSnapshot(
            root: rootId,
            resources: resources.values.toList(),
            engineIdentity: engine.assetIdentity,
          );
          captureMetadata.addAll({
            'snapshot': snapshot.sourceIdentity,
            'engine': engine.assetIdentity,
            'root': snapshot.root,
          });
          final analysis = await engine.request(
            'analyse',
            snapshot.toJson(),
            requestId: '${requestPrefix}graph-$depth',
          );
          if (analysis['snapshot'] != snapshot.identity)
            throw CoreFailure(
              'import.snapshot',
              'Import analysis returned an unrelated snapshot',
            );
          final missing = <String>{
            for (final ref in analysis['references'] as List? ?? [])
              if (ref['targetResource'] is String &&
                  !resources.containsKey(ref['targetResource']) &&
                  !attempted.contains(ref['targetResource']))
                ref['targetResource'] as String,
          };
          if (missing.isEmpty) break;
          if (depth >= 128 ||
              resources.length + missing.length > 2048 ||
              total > 48 * 1024 * 1024)
            throw CoreFailure(
              'limit.import',
              'Reachable import graph exceeds its resource budget',
            );
          for (final id in missing) {
            attempted.add(id);
            final uri = Uri.tryParse(id);
            if (uri == null ||
                !['http', 'https'].contains(uri.scheme) ||
                uri.userInfo.isNotEmpty ||
                uri.hasQuery ||
                !approvals.contains(id)) {
              unavailable.add(id);
              continue;
            }
            await acquire(uri);
          }
        }
        // Source bytes are untouched. Explicit mappings retain retrieval bases
        // after offline relocation; they grant no further network permission.
        final manifest =
            'version: 1\nroots:\n  - name: imported\n    path: $rootPath\nresourceMappings:\n${names.entries.map((e) => '  ${jsonEncode(e.key)}: ${jsonEncode(e.value)}').join('\n')}\n';
        await BusyProject.validateGeneratedConfiguration(
          output,
          engine,
          text: manifest,
          id: Uri.file(p.join(target, 'busyapi.yaml')).toString(),
        );
        active();
        await add(
          'busyapi.yaml',
          utf8.encode(manifest),
          'busyapi:import-configuration',
        );
      } else {
        var location = p.normalize(p.absolute(source));
        if (kind == ProjectImportKind.git) {
          cloneStage = await Directory.systemTemp.createTemp(
            'busyapi-import-clone-',
          );
          privatePermissions(cloneStage.path, 448);
          location = p.join(cloneStage.path, 'repository');
          final identity = await GitRepository.cloneIntoStage(
            source,
            location,
            cancellation: cancellation,
            sourceDirectory: inputDirectory,
          );
          captureMetadata['git'] = Map<String, Object?>.unmodifiable({
            'version': identity.version,
            'commit': identity.commit,
          });
        }
        final directory = kind != ProjectImportKind.file;
        final boundary = directory ? location : p.dirname(location);
        if (target == boundary || p.isWithin(boundary, target))
          throw CoreFailure(
            'import.destination',
            'Import destination must be outside the selected source directory',
          );
        project = await BusyProject.open(location, engine);
        final roots = project.roots;
        if (roots.isEmpty && project.discoveryFailure != null) {
          throw CoreFailure(
            'engine.discovery',
            'Contract discovery did not complete; source and destination were preserved',
          );
        }
        var selected = root == null
            ? (roots.length == 1 ? roots.single : null)
            : roots
                  .where(
                    (r) =>
                        r.name == root ||
                        r.id == root ||
                        p.relative(
                              Uri.parse(r.id).toFilePath(),
                              from: boundary,
                            ) ==
                            root,
                  )
                  .singleOrNull;
        if (selected == null && roots.length > 1 && selectRoot != null) {
          final choice = await selectRoot(List.unmodifiable(roots));
          active();
          if (choice == null)
            throw CoreFailure('cancelled', 'Root selection was cancelled');
          selected = roots.where((r) => r.id == choice).singleOrNull;
        }
        if (selected == null)
          throw ImportRootSelectionRequired(List.unmodifiable(roots));
        rootPath = p.relative(
          Uri.parse(selected.id).toFilePath(),
          from: boundary,
        );
        input = await ProjectAccess.open(boundary);
        AnalysisSnapshot? captured;
        final checked = await project.check(
          selected.id,
          schemaEvaluation: false,
          requestId: '${requestPrefix}local',
          cancelled: () => cancellation?.cancelled == true,
          onSnapshot: (s) => captured = s,
        );
        if (captured == null)
          throw CoreFailure(
            'import.snapshot',
            'Acquisition has no coherent captured source',
          );
        await onSnapshotCaptured?.call(captured!);
        captureMetadata.addAll({
          'snapshot': captured!.sourceIdentity,
          'engine': engine.assetIdentity,
          'root': './$rootPath',
        });
        active();
        final frozen = <String, Map<String, Object?>>{
          for (final source in [
            ...captured!.resources,
            ...captured!.configuration,
          ])
            if (Uri.parse(source['id'] as String).scheme == 'file')
              Uri.parse(source['id'] as String).toFilePath(): source,
        };
        Future<List<int>> sourceBytes(Map<String, Object?> source) async {
          List<int> encode() => utf8.encode(
            '${source['hasBom'] == true ? '\uFEFF' : ''}${source['text']}',
          );
          return (source['text'] as String).length < 262144
              ? encode()
              : await Isolate.run(encode);
        }

        for (final ref in checked['references'] as List? ?? []) {
          if (ref['targetResource'] is String &&
              !captured!.resources.any(
                (r) =>
                    r['id'] == ref['targetResource'] ||
                    (r['aliases'] as List? ?? []).contains(
                      ref['targetResource'],
                    ),
              ))
            unavailable.add(ref['targetResource'] as String);
        }
        if (directory) {
          Future<void> copy(String path, [int depth = 0]) async {
            active();
            if (depth > 128)
              throw CoreFailure(
                'limit.import',
                'Import directory nesting exceeds its budget',
              );
            final entries = await input!.importEntries(path);
            if (entries.isEmpty && path != boundary) {
              if (files.length + emptyDirectories.length >=
                  AtomicDirectoryWriter.maxFiles)
                throw CoreFailure(
                  'limit.import',
                  'Import directory count exceeds its budget',
                );
              emptyDirectories.add(p.relative(path, from: boundary));
            }
            for (final entry in entries) {
              final child = p.join(path, entry.$1);
              if (entry.$2 == FileSystemEntityType.directory) {
                await copy(child, depth + 1);
              } else if (entry.$2 == FileSystemEntityType.file) {
                await add(
                  p.relative(child, from: boundary),
                  frozen.containsKey(child)
                      ? await sourceBytes(frozen[child]!)
                      : await input!.read(child),
                  kind == ProjectImportKind.git
                      ? 'git:${(captureMetadata['git'] as Map)['commit']}:${p.relative(child, from: boundary)}'
                      : Uri.file(child).toString(),
                  executable: (await input!.mode(child)) & 0x49 != 0,
                );
              } else {
                throw CoreFailure(
                  'import.link',
                  'Import refuses symbolic links and special files',
                );
              }
            }
          }

          await copy(boundary);
          for (final source in frozen.entries) {
            final name = p.relative(source.key, from: boundary);
            if (!files.containsKey(name))
              await add(
                name,
                await sourceBytes(source.value),
                source.value['id'] as String,
              );
          }
        } else {
          for (final source in frozen.entries) {
            await add(
              p.relative(source.key, from: boundary),
              await sourceBytes(source.value),
              source.value['id'] as String,
            );
          }
        }
      }
      active();
      String visible(String value) {
        final uri = Uri.tryParse(value);
        return uri != null && (uri.userInfo.isNotEmpty || uri.hasQuery)
            ? '[credential-bearing resource URI withheld]'
            : value;
      }

      final missing = unavailable.map(visible).toSet().toList()..sort();
      return ProjectImportPlan._(
        output,
        target,
        rootPath,
        Map.unmodifiable(files),
        Map.unmodifiable({
          'version': 1,
          'operation': 'import',
          ...captureMetadata,
          'kind': kind.name,
          'entry': rootPath,
          'complete': unavailable.isEmpty,
          'sources': List.unmodifiable(
            identities.map(
              (identity) => Map<String, Object?>.unmodifiable(identity),
            ),
          ),
          'unavailable': List.unmodifiable(missing),
        }),
        List.unmodifiable(missing),
        Set.unmodifiable(executables),
        Set.unmodifiable(emptyDirectories),
      );
    } on Object {
      output.close();
      rethrow;
    } finally {
      finished = true;
      if (cancellation?.cancelled == true) await cancelOwned();
      input?.close();
      project?.close();
      if (cloneStage != null) await cloneStage.delete(recursive: true);
    }
  }
}
