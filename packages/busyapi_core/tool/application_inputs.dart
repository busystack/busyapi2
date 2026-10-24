import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The selected Flutter build's own input manifest, tied to the actual kernel
/// or ELF copied by CMake. This is build provenance, not another package/API
/// resolver and not a claim that AOT retains every imported symbol.
class ApplicationInputs {
  ApplicationInputs({
    required this.artifactIdentity,
    required this.mode,
    required this.entry,
    required Map<String, List<String>> packages,
    required Set<String> nativePlugins,
  }) : packages = Map.unmodifiable({
         for (final item in packages.entries)
           item.key: List<String>.unmodifiable(item.value),
       }),
       nativePlugins = Set.unmodifiable(nativePlugins);
  final String artifactIdentity, mode, entry;
  final Map<String, List<String>> packages;
  final Set<String> nativePlugins;
  bool get productionEntry => entry == 'lib/main.dart';
}

Future<ApplicationInputs> applicationInputs({
  required Directory repository,
  required Map<String, Directory> packages,
  required String artifact,
  required String mode,
  required String entry,
}) async {
  repository = Directory(p.normalize(p.absolute(repository.path)));
  if (!{'Debug', 'Profile', 'Release'}.contains(mode)) {
    throw ArgumentError('Choose the actual Linux build mode');
  }
  final entryPath = p.normalize(
    p.isAbsolute(entry) ? entry : p.join(repository.path, entry),
  );
  if (!p.isWithin(repository.path, entryPath))
    throw ArgumentError('The Flutter entry must belong to this source project');
  final capturedMetadata = <String, String>{};
  Future<List<int>> metadata(String path) async {
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Missing/non-ordinary Flutter build metadata');
    }
    final length = await file.length();
    if (length > 4 * 1024 * 1024) {
      throw StateError(
        'Missing/non-ordinary or oversized Flutter build metadata',
      );
    }
    final bytes = await file
        .openRead(0, length)
        .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    if (await file.length() != length)
      throw StateError('Flutter build metadata changed during collection');
    final digest = sha256.convert(bytes).toString();
    final previous = capturedMetadata[path];
    if (previous != null && previous != digest)
      throw StateError('Flutter build metadata changed during collection');
    capturedMetadata[path] = digest;
    return bytes;
  }

  Future<String> identity(String path) async {
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Missing/non-ordinary application build output');
    }
    final length = await file.length();
    if (length == 0 || length > 256 * 1024 * 1024) {
      throw StateError(
        'Missing/non-ordinary or oversized application build output',
      );
    }
    final result = (await sha256.bind(file.openRead(0, length)).first)
        .toString();
    if (await file.length() != length)
      throw StateError('The application output changed during collection');
    return result;
  }

  final captured = await identity(artifact), kernel = mode == 'Debug';
  final builds = Directory(p.join(repository.path, '.dart_tool/flutter_build'));
  final candidates = <List<String>>[];
  var count = 0;
  await for (final directory in builds.list(followLinks: false)) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(p.basename(directory.path)))
      continue;
    if (++count > 128)
      throw StateError(
        'The Flutter build-input inspection exceeds its bounded directory limit',
      );
    if (directory is! Directory ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory)
      continue;
    final compiled = p.join(directory.path, kernel ? 'app.dill' : 'app.so');
    if (!await File(compiled).exists() || await identity(compiled) != captured)
      continue;
    final stamp = jsonDecode(
      utf8.decode(
        await metadata(p.join(directory.path, 'kernel_snapshot_program.stamp')),
      ),
    ) as Map;
    List<String> paths(Object? raw) {
      if (raw is! List ||
          raw.length > 20000 ||
          raw.any((value) => value is! String || !p.isAbsolute(value))) {
        throw StateError('Unrecognized Flutter compiler input/output manifest');
      }
      return raw.cast<String>().map(p.normalize).toSet().toList()..sort();
    }

    final inputs = paths(stamp['inputs']);
    final dill = p.join(directory.path, 'app.dill');
    if (!paths(stamp['outputs']).contains(dill) || !inputs.contains(entryPath))
      continue;
    if (!kernel) {
      final aot = jsonDecode(
        utf8.decode(
          await metadata(
            p.join(directory.path, 'aot_elf_${mode.toLowerCase()}.stamp'),
          ),
        ),
      ) as Map;
      if (!paths(aot['outputs']).contains(compiled) ||
          !paths(aot['inputs']).contains(dill))
        continue;
    }
    if (!candidates.any(
      (previous) => jsonEncode(previous) == jsonEncode(inputs),
    ))
      candidates.add(inputs);
  }
  if (candidates.length != 1)
    throw StateError(
      'The application output has no unique matching Flutter compiler-input receipt; build the selected entry/mode before staging notices',
    );
  final sdk = packages['flutter']?.parent.parent;
  if (sdk == null)
    throw StateError('Prepare the selected Flutter package configuration');
  final roots = [
    for (final item in packages.entries)
      (name: item.key, path: p.normalize(p.absolute(item.value.path))),
  ]..sort((a, b) => b.path.length.compareTo(a.path.length));
  final selected = <String, List<String>>{};
  for (final file in candidates.single) {
    final owners = roots.where((root) => p.isWithin(root.path, file)).toList();
    final owner = owners.firstOrNull;
    if (owner != null) {
      if (owners
              .where((value) => value.path.length == owner.path.length)
              .length !=
          1)
        throw StateError('A compiler input has ambiguous package ownership');
      if (owner.name == 'busyapi' || owner.name == 'busyapi_core') continue;
      (selected[owner.name] ??= []).add(
        p.posix.joinAll(p.split(p.relative(file, from: owner.path))),
      );
    } else if (!p.isWithin(sdk.path, file) &&
        !p.isWithin(repository.path, file)) {
      throw StateError(
        'A compiler input belongs to no configured package or selected SDK',
      );
    }
  }
  final plugins = jsonDecode(
    utf8.decode(
      await metadata(p.join(repository.path, '.flutter-plugins-dependencies')),
    ),
  ) as Map;
  final linux = plugins['plugins']?['linux'];
  if (linux is! List || linux.length > 128)
    throw StateError('Prepare the selected Linux Flutter plugin manifest');
  final native = <String>{};
  for (final raw in linux) {
    final name = raw['name'] as String, root = packages[name];
    if (raw['native_build'] != true) continue;
    if (root == null ||
        raw['path'] is! String ||
        p.normalize(p.absolute(raw['path'] as String)) !=
            p.normalize(p.absolute(root.path)) ||
        !native.add(name)) {
      throw StateError(
        'A Linux plugin differs from the selected package configuration',
      );
    }
    selected.putIfAbsent(name, () => []);
  }
  if (await identity(artifact) != captured)
    throw StateError(
      'The application output changed during build-input collection',
    );
  for (final path in capturedMetadata.keys.toList()) {
    await metadata(path);
  }
  return ApplicationInputs(
    artifactIdentity: captured,
    mode: mode,
    entry: p.posix.joinAll(
      p.split(p.relative(entryPath, from: repository.path)),
    ),
    packages: selected,
    nativePlugins: native,
  );
}
