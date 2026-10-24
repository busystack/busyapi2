part of 'project.dart';

/// An explicit format choice. A package is never a fallback single-file bundle.
enum BundleFormat { singleFile, resourcePackage }

const _packageManifest = 'resource-package.json';
const _packageProducer = 'busyapi-resource-package';
const _packageLocations = {
  'offsetUnit': 'utf16',
  'range': 'half-open',
  'bom': 'excluded',
  'lineEndings': 'raw',
};

class ResourcePackageAssetsFailure extends CoreFailure {
  ResourcePackageAssetsFailure(this.component)
    : super(
        'bundle.package.assets',
        'The installed resource-package component "$component" is missing or mismatched. Rebuild the complete Linux installation; no runtime is downloaded.',
      );
  final String component;
}

void _verifyPackageDescription(
  Map<String, dynamic> description,
  AnalysisSnapshot snapshot,
) {
  final sources = {for (final r in snapshot.resources) r['id']: r};
  final entries = description['identities'];
  final Set<Object?> boundSources = entries is List && entries.length <= 20000
      ? {
          for (final entry in entries)
            if (entry is Map &&
                entry['kind'] == 'resource' &&
                entry['uri'] == entry['resource'] &&
                entry['pointer'] == '')
              entry['resource'],
        }
      : const {};
  if (description['version'] != 1 ||
      description['root'] != snapshot.root ||
      description['snapshot'] != snapshot.identity ||
      entries is! List ||
      entries.isEmpty ||
      entries.length > 20000 ||
      sources.keys.any((id) => !boundSources.contains(id)) ||
      entries.any((entry) {
        if (entry is! Map ||
            entry['uri'] is! String ||
            !['resource', 'anchor'].contains(entry['kind']) ||
            !sources.containsKey(entry['resource']) ||
            entry['pointer'] is! String ||
            (entry['pointer'] as String).length > 16384)
          return true;
        if (entry['physicalPointer'] != null) {
          final occurrence = entry['occurrenceRange'];
          if (entry['physicalPointer'] is! String ||
              (entry['physicalPointer'] as String).length > 16384 ||
              occurrence is! List ||
              occurrence.length != 2 ||
              occurrence[0] is! int ||
              occurrence[1] is! int ||
              (occurrence[0] as int) < 0 ||
              (occurrence[1] as int) < (occurrence[0] as int) ||
              (occurrence[1] as int) >
                  (sources[entry['resource']]!['text'] as String).length)
            return true;
        }
        final range = entry['range'];
        return range is! List ||
            range.length != 2 ||
            range[0] is! int ||
            range[1] is! int ||
            (range[0] as int) < 0 ||
            (range[1] as int) < (range[0] as int) ||
            (range[1] as int) >
                (sources[entry['resource']]!['text'] as String).length;
      })) {
    throw CoreFailure(
      'bundle.package.protocol',
      'The package graph did not describe valid original-source URI bindings',
    );
  }
}

/// Read-only approved resources, not another project/model/resolver. Original
/// URI identities are data, never permission to read that URI from disk/network.
class ResourcePackage {
  ResourcePackage._(this.snapshot, this.manifest);
  final AnalysisSnapshot snapshot;
  final Map<String, dynamic> manifest;

  static Future<ResourcePackage> open(
    String directory,
    EngineProcess engine,
  ) async {
    final access = await ProjectAccess.open(p.absolute(directory));
    try {
      final bytes = await access.read(
        p.join(access.boundary, _packageManifest),
      );
      if (bytes.length > 4 * 1024 * 1024) throw const FormatException();
      final text = utf8.decode(bytes), value = jsonDecode(text);
      // This machine-owned manifest has one canonical spelling. Reject duplicate
      // keys/hand-edited ambiguous declarations; user resources are NOT rewritten.
      if (value is! Map<String, dynamic> ||
          text != '${jsonEncode(value)}\n' ||
          value['version'] != 1 ||
          value['format'] != _packageProducer ||
          value['producer'] != _packageProducer ||
          value['producerVersion'] != '1' ||
          value['root'] is! String ||
          jsonEncode(value['locations']) != jsonEncode(_packageLocations) ||
          !['working-copy', 'saved-source'].contains(value['input']) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch('${value['snapshot']}') ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch('${value['loader']}') ||
          value['resources'] is! List ||
          (value['resources'] as List).isEmpty ||
          (value['resources'] as List).length > 2048 ||
          value['identity'] !=
              textIdentity(jsonEncode({...value}..remove('identity'))))
        throw const FormatException();
      final resources = <Map<String, Object?>>[],
          paths = <String>{},
          ids = <String>{};
      var cost = 0;
      for (final record in value['resources'] as List) {
        if (record is! Map ||
            record['resource'] is! String ||
            record['path'] is! String ||
            record['hasBom'] is! bool ||
            record['aliases'] is! List ||
            (record['aliases'] as List).any((id) => id is! String) ||
            (record['aliases'] as List).length > 256 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch('${record['identity']}'))
          throw const FormatException();
        final id = record['resource'] as String,
            path = record['path'] as String;
        final uri = Uri.parse(id);
        if (!uri.isAbsolute ||
            uri.hasFragment ||
            !ids.add(id) ||
            !paths.add(path) ||
            path !=
                'resources/${textIdentity(id)}${p.url.extension(uri.path).toLowerCase() == '.json' ? '.json' : '.yaml'}')
          throw const FormatException();
        for (final alias in record['aliases'] as List) {
          final uri = Uri.parse(alias as String);
          if (!uri.isAbsolute || uri.hasFragment) throw const FormatException();
        }
        final source = await access.read(p.join(access.boundary, path));
        if (source.length > 16 * 1024 * 1024 ||
            await contentIdentityAsync(source) != record['identity'])
          throw CoreFailure(
            'bundle.package.changed',
            'A packaged resource is missing or changed; no alternate URI is retrieved',
          );
        final buffer = DocumentBuffer.decode(path, source);
        if (buffer.hasBom != record['hasBom']) throw const FormatException();
        cost += buffer.text.length * 6;
        if (cost > 48 * 1024 * 1024) throw const FormatException();
        resources.add({
          'id': id,
          'text': buffer.text,
          'identity': record['identity'],
          'generation': 0,
          'hasBom': buffer.hasBom,
          if ((record['aliases'] as List).isNotEmpty)
            'aliases': List<String>.from(record['aliases'] as List),
        });
      }
      if (!ids.contains(value['root'])) throw const FormatException();
      await engine.start();
      if (engine.assetIdentity != value['engine'])
        throw CoreFailure(
          'bundle.package.engine',
          'Use the matching included loader and contract engine',
        );
      final snapshot = AnalysisSnapshot(
        root: value['root'] as String,
        resources: resources,
        engineIdentity: engine.assetIdentity,
      );
      final description = await engine.request(
        'describeResourcePackage',
        snapshot.toJson(),
      );
      _verifyPackageDescription(description, snapshot);
      if (description['snapshot'] != snapshot.identity ||
          jsonEncode(description['identities']) !=
              jsonEncode(value['identities']))
        throw CoreFailure(
          'bundle.package.identity',
          'The packaged URI/source bindings do not match the canonical graph',
        );
      return ResourcePackage._(snapshot, _freezeResult(value));
    } on CoreFailure {
      rethrow;
    } on Object {
      throw CoreFailure(
        'bundle.package.invalid',
        'Invalid or unavailable resource package; only its declared local files may be read',
      );
    } finally {
      access.close();
    }
  }

  Future<Map<String, dynamic>> check(EngineProcess engine) async {
    final structural = await engine.request('analyse', snapshot.toJson());
    if (structural['snapshot'] != snapshot.identity ||
        structural['findings'] is! List)
      throw CoreFailure(
        'bundle.package.protocol',
        'The worker did not return the captured package analysis',
      );
    for (final finding in structural['findings'] as List) {
      finding['snapshot'] = snapshot.sourceIdentity;
    }
    for (final category in (structural['categories'] as Map? ?? {}).values) {
      if (category is Map) category['snapshot'] = snapshot.sourceIdentity;
    }
    structural.addAll({
      'contextSnapshot': snapshot.identity,
      'snapshot': snapshot.sourceIdentity,
      'checkedRoots': [snapshot.root],
      'unsaved': manifest['input'] == 'working-copy',
      'input': manifest['input'],
    });
    Map<String, dynamic>? evaluated;
    String? failure;
    try {
      evaluated = await engine.request('evaluateSchemas', snapshot.toJson());
      BusyProject._verifySchemaEvaluation(evaluated, snapshot);
    } on Object catch (error) {
      failure = error is CoreFailure ? error.code : 'schema.execution';
      evaluated = null;
    }
    return {
      ..._mergeSchemaEvaluation(snapshot, structural, evaluated, failure),
      'resourcePackage': {
        'identity': manifest['identity'],
        'originalSnapshot': manifest['snapshot'],
        'input': manifest['input'],
        'engine': manifest['engine'],
      },
    };
  }
}

class ResourcePackageOutput extends BundleOutput {
  ResourcePackageOutput._(
    BusyProject owner,
    _OutputInput captured,
    Map<String, dynamic> result,
    Map<String, Object?> metadata,
    this._files,
  ) : super._(
        owner,
        captured.access,
        captured.target,
        captured.snapshot,
        captured.saved,
        captured.checked['unsaved'] == true,
        captured.revision,
        result,
        metadata,
      );
  final Map<String, List<int>> _files;
  @override
  Future<OutputDirectoryResult> publish({
    String? replaceIdentity,
    bool Function()? cancelled,
    FutureOr<void> Function()? beforePublish,
    FutureOr<void> Function()? afterPublish,
  }) {
    if (_closed)
      throw CoreFailure('output.closed', 'The frozen output owner is closed');
    return _access.publishOutput(
      destination,
      _files,
      metadata,
      replaceIdentity: replaceIdentity,
      cancelled: cancelled,
      beforePublish: beforePublish,
      afterPublish: afterPublish,
      executableFiles: const {'busyapi-resource', 'libexec/busyapi/node'},
    );
  }
}

extension _ResourcePackageCapture on BusyProject {
  Future<BundleOutput> _prepareResourcePackage(
    String root,
    String destination, {
    bool saved = false,
    String? requestId,
    bool Function()? cancelled,
    void Function(String resource)? onResourceRefreshed,
  }) async {
    final captured = await _captureOutputInput(
      root,
      destination,
      operation: 'bundle',
      saved: saved,
      requestId: requestId,
      cancelled: cancelled,
      onResourceRefreshed: onResourceRefreshed,
    );
    try {
      final snapshot = captured.snapshot;
      final description = await engine.request(
        'describeResourcePackage',
        snapshot.toJson(),
        requestId: requestId == null ? null : '$requestId-package',
      );
      _verifyPackageDescription(description, snapshot);
      // Installed executable-relative runtime only. No SDK/PATH/checkout search.
      final runtime = await _loadResourcePackageRuntime(
        p.dirname(p.dirname(p.dirname(engine.executable))),
      );
      if (runtime.identities['libexec/busyapi/engine.cjs'] !=
          engine.assetIdentity)
        throw CoreFailure(
          'bundle.package.assets',
          'The package loader runtime does not match the active contract engine',
        );
      final files = <String, List<int>>{...runtime.files},
          resources = <Map<String, Object?>>[];
      for (final resource
          in snapshot.resources.toList()..sort(
            (a, b) => (a['id'] as String).compareTo(b['id'] as String),
          )) {
        final id = resource['id'] as String, bom = resource['hasBom'] == true;
        final path =
            'resources/${textIdentity(id)}${p.url.extension(Uri.parse(id).path).toLowerCase() == '.json' ? '.json' : '.yaml'}';
        final bytes = utf8.encode('${bom ? '\ufeff' : ''}${resource['text']}');
        if (await contentIdentityAsync(bytes) != resource['identity'])
          throw CoreFailure(
            'bundle.snapshot',
            'A captured resource has no exact byte identity',
          );
        files[path] = bytes;
        resources.add({
          'resource': id,
          'path': path,
          'identity': resource['identity'],
          'hasBom': bom,
          'aliases': List<String>.from(resource['aliases'] as List? ?? const [])
            ..sort(),
        });
      }
      final manifest = <String, Object?>{
        'version': 1,
        'format': _packageProducer,
        'producer': _packageProducer,
        'producerVersion': '1',
        'root': root,
        'snapshot': snapshot.sourceIdentity,
        'input': captured.checked['unsaved'] == true
            ? 'working-copy'
            : 'saved-source',
        'engine': engine.assetIdentity,
        'locations': _packageLocations,
        'resources': resources,
        'identities': description['identities'],
        'loader': runtime.identity,
      };
      final identity = await textIdentityAsync(jsonEncode(manifest));
      manifest['identity'] = identity;
      final manifestBytes = utf8.encode('${jsonEncode(manifest)}\n');
      if (manifestBytes.length > 4 * 1024 * 1024) {
        throw CoreFailure(
          'limit.bundle.manifest',
          'The resource-package URI/source manifest exceeds 4 MiB; no output was published',
        );
      }
      files[_packageManifest] = manifestBytes;
      files['README.txt'] = utf8.encode(
        'BusyAPI resource package v1 (not a single-file OpenAPI bundle)\n\n'
        'Linux amd64: run ./busyapi-resource --json from any directory. The included headless Dart loader and pinned Node/contract engine require no BusyAPI installation, global Node, display, checkout, account, server or network service. Linux/glibc runtime requirements are recorded in loader-runtime.json.\n'
        'The loader reads only the declared packaged files through BusyAPI\'s anchored approved-resource boundary, verifies their digests and URI bindings, and uses the same canonical graph and dialect checks as BusyAPI. It never retrieves original file/HTTP URIs.\n'
        'resource-package.json maps original retrieval identities and aliases to exact UTF-8 source bytes (including BOM). Its graph identities include embedded schema-resource pointers; every original pointer/range is unchanged inside its packaged file. Source locations use UTF-16 half-open offsets, with BOM excluded and original line endings. YAML alias occurrences retain their separate physical-definition/occurrence ranges. Original URI identities may contain private paths because changing them changes base resolution. The manifest and ownership receipt identify the captured saved or unsaved input.\n'
        'Do not load the resource files independently with a tool that substitutes their packaged paths as retrieval URIs. Other consumers need this original-URI map. Renderer support is qualified separately; this package does not claim Swagger UI/Redoc compatibility.\n'
        'No canonical document was changed. No \$id, dialect or reference was synthesized. Resources and example data retain their original ownership/licensing. Bundled code notices are in licenses/. This loader performs no requests, authentication, project rule execution or runtime conformance.\n',
      );
      final metadata = <String, Object?>{
        'version': 1,
        'operation': 'bundle',
        'format': 'resource-package',
        'producer': _packageProducer,
        'producerVersion': '1',
        'root': root,
        'snapshot': snapshot.sourceIdentity,
        'input': manifest['input'],
        'unsaved': captured.checked['unsaved'] == true,
        'entry': _packageManifest,
        'outputIdentity': identity,
        'engine': engine.assetIdentity,
        'sources': resources,
        'loader': runtime.identity,
      };
      files['provenance.json'] = utf8.encode('${jsonEncode(metadata)}\n');
      if (_closed || cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Output generation was cancelled');
      return ResourcePackageOutput._(
        this,
        captured,
        {
          'output': {'identity': identity},
          'producer': _packageProducer,
          'producerVersion': '1',
        },
        metadata,
        Map.unmodifiable(files),
      );
    } on Object catch (error) {
      captured.access.close();
      if (error is OutputAnalysisFailure) rethrow;
      throw OutputAnalysisFailure(
        error is CoreFailure ? error.code : 'io.failure',
        error is CoreFailure
            ? error.message
            : 'Resource-package preparation did not complete',
        captured.checked,
        cause: error is CoreFailure ? error : null,
      );
    }
  }
}

class _ResourcePackageRuntime {
  _ResourcePackageRuntime(this.identity, this.files, this.identities);
  final String identity;
  final Map<String, List<int>> files;
  final Map<String, String> identities;
}

Future<_ResourcePackageRuntime> _loadResourcePackageRuntime(String directory) =>
    Isolate.run(() => _readResourcePackageRuntime(directory));

Future<_ResourcePackageRuntime> _readResourcePackageRuntime(
  String directory,
) async {
  final access = await ProjectAccess.open(directory);
  var component = 'share/busyapi/resource-package/runtime.json';
  try {
    final bytes = await access.read(
      p.join(access.boundary, 'share/busyapi/resource-package/runtime.json'),
    );
    if (bytes.length > 1024 * 1024) throw const FormatException();
    final descriptor = jsonDecode(utf8.decode(bytes));
    if (descriptor is! Map ||
        descriptor['version'] != 1 ||
        descriptor['producer'] != 'busyapi-resource-package-runtime' ||
        descriptor['files'] is! Map ||
        (descriptor['files'] as Map).length > 1024 ||
        descriptor['identity'] !=
            textIdentity(jsonEncode({...descriptor}..remove('identity'))))
      throw const FormatException();
    final files = <String, List<int>>{}, identities = <String, String>{};
    var size = 0;
    for (final entry in (descriptor['files'] as Map).entries) {
      final path = entry.key;
      if (path is! String ||
          !AtomicDirectoryWriter.safeName(path) ||
          entry.value is! String ||
          !(path == 'libexec/busyapi/resource-package-loader' ||
              path == 'libexec/busyapi/node' ||
              path == 'libexec/busyapi/engine.cjs' ||
              path.startsWith('share/licenses/busyapi-engine/') ||
              path.startsWith('share/licenses/busyapi-dart/')))
        throw const FormatException();
      component = path;
      final data = path == 'libexec/busyapi/node'
          ? await access.readVerifiedArtifact(
              p.join(access.boundary, path),
              entry.value as String,
            )
          : await access.read(p.join(access.boundary, path));
      size += data.length;
      if (size > 180 * 1024 * 1024 ||
          path != 'libexec/busyapi/node' &&
              await contentIdentityAsync(data) != entry.value)
        throw const FormatException();
      identities[path] = entry.value as String;
      files[path == 'libexec/busyapi/resource-package-loader'
              ? 'busyapi-resource'
              : path.startsWith('share/licenses/')
              ? path.replaceFirst('share/licenses/', 'licenses/')
              : path] =
          data;
    }
    final required = {
      'libexec/busyapi/resource-package-loader',
      'libexec/busyapi/node',
      'libexec/busyapi/engine.cjs',
      'share/licenses/busyapi-engine/NODE-LICENSE',
      'share/licenses/busyapi-dart/DART-LICENSE',
      'share/licenses/busyapi-engine/dependencies.json',
      'share/licenses/busyapi-dart/dependencies.json',
    };
    for (final path in required) {
      if (!identities.containsKey(path)) {
        component = path;
        throw const FormatException();
      }
    }
    files['loader-runtime.json'] = bytes;
    return _ResourcePackageRuntime(
      descriptor['identity'] as String,
      files,
      identities,
    );
  } on Object {
    throw ResourcePackageAssetsFailure(component);
  } finally {
    access.close();
  }
}
