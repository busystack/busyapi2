import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

import 'model.dart';
import 'storage.dart';

const generatorVersion = '7.26.0';
const generatorJarIdentity =
    '5ccb60c4678901715376c6114afba60c28d0844fe506bd1e02891cbc363ab9ff';
const generatorRuntimeArchive =
    'ef491a51a46ef90cc47fbc4abb219fde32483ff91be5ec66ddc896df43524b27';

const _generatorLogging = '''<configuration>
<statusListener class="ch.qos.logback.core.status.NopStatusListener"/>
<appender name="LOG" class="ch.qos.logback.core.ConsoleAppender"><encoder><pattern>%level %logger - %msg%n</pattern></encoder></appender>
<appender name="COVERAGE" class="ch.qos.logback.core.ConsoleAppender"><encoder><pattern>BUSYAPI_OPERATION_JSON_START%n%msg%n{}BUSYAPI_OPERATION_JSON_END%n</pattern></encoder></appender>
<logger name="io.swagger.v3.core.util.Json" level="DEBUG" additivity="false"><appender-ref ref="COVERAGE"/></logger>
<logger name="org.openapitools.codegen.DefaultGenerator" level="WARN"/>
<logger name="org.openapitools.codegen.TemplateManager" level="WARN"/>
<root level="INFO"><appender-ref ref="LOG"/></root>
</configuration>''';

class ClientGenerator {
  const ClientGenerator(this.name, this.stability);
  final String name, stability;
  Map<String, Object?> toJson() => {'name': name, 'stability': stability};
}

class GeneratorOption {
  const GeneratorOption(this.name, this.documentation, this.example);
  final String name, documentation;
  final Object? example;
  Map<String, Object?> toJson() => {
    'name': name,
    'documentation': documentation,
    'example': example,
  };
}

class GeneratorFailure extends CoreFailure {
  GeneratorFailure(super.code, super.message, {this.detail = ''});
  final String detail;
}

class GeneratorProcessResult {
  const GeneratorProcessResult(this.exitCode, this.output, this.errors);
  final int exitCode;
  final String output, errors;
}

/// Only the executable-relative official JAR/runtime are used by GUI/CLI.
/// A directory override is a core embedding/test boundary, not a project option.
class GeneratorRuntime {
  GeneratorRuntime({String? directory})
    : directory =
          directory ??
          p.join(
            p.dirname(Platform.resolvedExecutable),
            'libexec/busyapi/generator',
          );
  final String directory;
  static int _active = 0;
  Map<String, dynamic>? _verified;
  List<ClientGenerator>? _catalog;
  final _documented = <String, List<GeneratorOption>>{};

  Future<Map<String, dynamic>> verify() async {
    final root = p.absolute(directory);
    final previous = _verified;
    final verified = await Isolate.run(() async {
      try {
        final states = await _generatorAssetStates(root);
        if (previous != null &&
            jsonEncode(states) == jsonEncode(previous['states']))
          return previous;
        if (await FileSystemEntity.type(root, followLinks: false) !=
            FileSystemEntityType.directory)
          throw const FormatException();
        final marker = File(p.join(root, 'assets.json'));
        if (await FileSystemEntity.type(marker.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await marker.length() > 1024 * 1024)
          throw const FormatException();
        final receipt =
            jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        final lock = receipt['lock'];
        final files = receipt['files'];
        if (receipt['version'] != 1 ||
            lock is! Map ||
            lock['generatorVersion'] != generatorVersion ||
            lock['jarSha256'] != generatorJarIdentity ||
            lock['runtimeArchiveSha256'] != generatorRuntimeArchive ||
            files is! Map ||
            files.length > 4096 ||
            files['openapi-generator.jar'] != generatorJarIdentity)
          throw const FormatException();
        for (final entry in files.entries) {
          // The archive's complete dereferenced JRE inventory is locked, not
          // merely asserted by a mutable installed receipt.
          final name = entry.key as String;
          if (p.isAbsolute(name) ||
              name.split('/').any((s) => s == '..' || s.isEmpty))
            throw const FormatException();
          final file = File(p.join(root, name));
          if (await FileSystemEntity.type(file.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              await file.length() > 128 * 1024 * 1024 ||
              (await sha256.bind(file.openRead()).first).toString() !=
                  entry.value)
            throw const FormatException();
        }
        final actual = <String>{};
        await for (final file in Directory(
          root,
        ).list(recursive: true, followLinks: false)) {
          if (file is Link || file is! File && file is! Directory)
            throw const FormatException();
          if (file is File && file.path != marker.path)
            actual.add(
              p.relative(file.path, from: root).replaceAll(p.separator, '/'),
            );
        }
        if (actual.length != files.length ||
            !actual.containsAll(files.keys.cast<String>()))
          throw const FormatException();
        for (final name in ['jre/bin/java', 'generator-launcher']) {
          if ((await File(p.join(root, name)).stat()).mode & 0x49 == 0)
            throw const FormatException();
        }
        final runtimeFiles = {
          for (final entry in files.entries)
            if ((entry.key as String).startsWith('jre/'))
              entry.key as String: entry.value,
        };
        if (textIdentity(jsonEncode(runtimeFiles)) !=
            '93e5b214c9638fdd0e00c0c5c3c7d36c5448ce81bc5a151a4d2f246e43e16f73')
          throw const FormatException();
        if (jsonEncode(states) != jsonEncode(await _generatorAssetStates(root)))
          throw const FormatException();
        return <String, dynamic>{'receipt': receipt, 'states': states};
      } on Object {
        throw GeneratorFailure(
          'generate.assets',
          'The packaged OpenAPI Generator or Java runtime is missing or altered. Prepare the locked build assets; editing needs neither Java nor generation assets.',
        );
      }
    });
    _verified = verified;
    // Metadata callers cannot mutate the internal verified cache.
    return Map<String, dynamic>.from(
      jsonDecode(jsonEncode(verified['receipt'])) as Map,
    );
  }

  Future<T> _temporary<T>(Future<T> Function(Directory) action) async {
    final stage = await Directory.systemTemp.createTemp('busyapi-generator-');
    privatePermissions(stage.path, 448);
    try {
      return await action(stage);
    } finally {
      await stage.delete(recursive: true);
    }
  }

  Future<List<ClientGenerator>> clients({bool Function()? cancelled}) =>
      _temporary((stage) async {
        if (_catalog != null) return _catalog!;
        final result = await run(stage.path, [
          'list',
          '--include',
          'all',
        ], cancelled: cancelled);
        if (result.exitCode != 0)
          throw GeneratorFailure(
            'generate.catalog',
            'The packaged generator catalog could not be read',
            detail: 'Exit ${result.exitCode}: ${result.errors}',
          );
        return _catalog = await _clientCatalogAsync(result.output);
      });

  static List<ClientGenerator> parseClients(String text) {
    final block = text.split('CLIENT generators:');
    if (block.length != 2)
      throw GeneratorFailure(
        'generate.catalog',
        'Unrecognized official generator catalog',
      );
    final result = <ClientGenerator>[];
    for (final line
        in block[1]
            .split(RegExp(r'\n\s*SERVER generators:'))
            .first
            .split('\n')) {
      final match = RegExp(r'^\s+- ([a-z0-9][a-z0-9-]*)(?: \(([^)]+)\))?\s*$')
          .firstMatch(line);
      if (match != null)
        result.add(ClientGenerator(match[1]!, match[2] ?? 'stable'));
    }
    if (result.isEmpty ||
        result.length > 512 ||
        result.map((g) => g.name).toSet().length != result.length)
      throw GeneratorFailure(
        'generate.catalog',
        'Incomplete official client catalog',
      );
    return List.unmodifiable(result);
  }

  Future<List<GeneratorOption>> options(
    String generator, {
    bool Function()? cancelled,
  }) => _temporary((stage) async {
    if (_documented.containsKey(generator)) return _documented[generator]!;
    final catalog = await clients(cancelled: cancelled);
    if (!catalog.any((item) => item.name == generator))
      throw GeneratorFailure(
        'generate.selection',
        'Select a client from the packaged generator catalog',
      );
    final result = await run(stage.path, [
      'config-help',
      '-g',
      generator,
      '--format',
      'yamlsample',
    ], cancelled: cancelled);
    if (result.exitCode != 0)
      throw GeneratorFailure(
        'generate.options',
        'Official generator options could not be read',
        detail: 'Exit ${result.exitCode}: ${result.errors}',
      );
    return _documented[generator] = await _generatorOptionsAsync(result.output);
  });

  static List<GeneratorOption> parseOptions(String text) {
    final result = <GeneratorOption>[], description = <String>[];
    for (final line in text.split('\n')) {
      final match = line.startsWith('# Description:')
          ? null
          : RegExp(r'^(?:# )?([A-Za-z][A-Za-z0-9_]*):\s?(.*)$')
                .firstMatch(line);
      if (match != null) {
        final value = match[2]!;
        Object? example;
        try {
          example = jsonDecode(value);
        } on FormatException {
          example = value;
        }
        result.add(GeneratorOption(match[1]!, description.join('\n'), example));
        description.clear();
      } else if (line.startsWith('#')) {
        description.add(line.replaceFirst(RegExp(r'^# ?'), ''));
      }
    }
    if (result.length > 1024)
      throw GeneratorFailure(
        'generate.options',
        'Generator options exceed the bounded metadata limit',
      );
    return List.unmodifiable(result);
  }

  Future<GeneratorProcessResult> run(
    String stage,
    List<String> arguments, {
    bool Function()? cancelled,
    Duration timeout = const Duration(minutes: 2),
    void Function(int pid)? onStarted,
  }) async {
    if (_active >= 2)
      throw GeneratorFailure(
        'generate.busy',
        'Two generator processes are already active',
      );
    _active++;
    Process? process;
    Timer? timer;
    Timer? budgetTimer;
    Future<void>? inspection;
    var inspecting = false;
    var finished = false;
    var collecting = false;
    String? failure;
    final clock = Stopwatch()..start();
    void stop(String reason) {
      failure ??= reason;
      if (!finished && process != null) {
        if (!Process.killPid(-process.pid, ProcessSignal.sigkill))
          process.kill(ProcessSignal.sigkill);
      }
    }

    try {
      await verify();
      if (cancelled?.call() == true)
        throw CoreFailure('cancelled', 'Client generation cancelled');
      if (clock.elapsed >= timeout)
        throw GeneratorFailure(
          'generate.timeout',
          'Generator deadline expired before launch',
        );
      await File(p.join(stage, '.busyapi-logback.xml'))
          .writeAsString(_generatorLogging);
      process = await Process.start(
        p.join(directory, 'generator-launcher'),
        [
          p.join(directory, 'jre'),
          p.join(directory, 'openapi-generator.jar'),
          p.absolute(stage),
          ...arguments,
        ],
        workingDirectory: stage,
        environment: {
          'LANG': 'C.UTF-8',
          'LD_LIBRARY_PATH': p.normalize(
            p.join(directory, '..', '..', '..', 'lib'),
          ),
        },
        includeParentEnvironment: false,
      );
      onStarted?.call(process.pid);
      if (cancelled?.call() == true) stop('cancelled');
      await process.stdin.close();
      timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
        if (cancelled?.call() == true) stop('cancelled');
        if (clock.elapsed >= timeout) stop('generate.timeout');
      });
      budgetTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (inspecting || finished) return;
        inspecting = true;
        inspection = _generatorStageFits(stage)
            .then(
              (fits) {
                if (!finished && !fits) stop('generate.limit');
              },
              onError: (Object _) {
                if (!finished) stop('generate.limit');
              },
            )
            .whenComplete(() => inspecting = false);
      });
      var size = 0;
      Future<Uint8List> collect(Stream<List<int>> stream) async {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in stream) {
          size += chunk.length;
          if (size > 16 * 1024 * 1024) {
            stop('generate.limit');
          } else {
            bytes.add(chunk);
          }
        }
        return bytes.takeBytes();
      }

      collecting = true;
      final out = collect(process.stdout), err = collect(process.stderr);
      final code = await process.exitCode;
      final output = await out, errors = await err;
      if (failure != null)
        throw GeneratorFailure(
          failure!,
          'Client generation did not complete; no output was published',
        );
      return GeneratorProcessResult(
        code,
        await _generatorText(output),
        await _generatorText(errors),
      );
    } on Object catch (error) {
      if (failure != null)
        throw GeneratorFailure(
          failure!,
          'Client generation did not complete; no output was published',
        );
      if (error is ProcessException || error is SocketException) {
        throw GeneratorFailure(
          'generate.process',
          'The packaged generator process could not start or complete',
        );
      }
      rethrow;
    } finally {
      timer?.cancel();
      budgetTimer?.cancel();
      if (process != null) {
        if (!Process.killPid(-process.pid, ProcessSignal.sigkill))
          process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        if (!collecting) {
          await Future.wait([
            process.stdout.drain<void>(),
            process.stderr.drain<void>(),
          ]);
        }
      }
      finished = true;
      await inspection;
      _active--;
    }
  }
}

Future<List<ClientGenerator>> _clientCatalogAsync(String text) =>
    Isolate.run(() => GeneratorRuntime.parseClients(text));
Future<List<GeneratorOption>> _generatorOptionsAsync(String text) =>
    Isolate.run(() => GeneratorRuntime.parseOptions(text));
Future<String> _generatorText(Uint8List bytes) => bytes.length < 65536
    ? Future.value(utf8.decode(bytes, allowMalformed: true))
    : Isolate.run(() => utf8.decode(bytes, allowMalformed: true));

Future<bool> _generatorStageFits(String path) => Isolate.run(() {
  var bytes = 0, count = 0;
  final pending = [Directory(path)];
  while (pending.isNotEmpty) {
    List<FileSystemEntity> entries;
    try {
      entries = pending.removeLast().listSync(followLinks: false);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) continue;
      rethrow;
    }
    for (final entry in entries) {
      if (++count > 8192 ||
          entry is Link ||
          entry is! File && entry is! Directory)
        return false;
      if (entry is Directory) {
        pending.add(entry);
      } else {
        final state = entry.statSync();
        if (state.type == FileSystemEntityType.notFound) continue;
        final size = state.size;
        bytes += size;
        if (size > 64 * 1024 * 1024 || bytes > 320 * 1024 * 1024) return false;
      }
    }
  }
  return true;
});

Future<Map<String, String>> _generatorAssetStates(String root) async {
  final states = <String, String>{};
  await for (final entry in Directory(
    root,
  ).list(recursive: true, followLinks: false)) {
    if (entry is Link ||
        entry is! File && entry is! Directory ||
        states.length >= 8192)
      throw const FormatException();
    final state = await entry.stat();
    states[p.relative(entry.path, from: root)] =
        '${state.type}:${state.mode}:${state.size}:${state.modified.microsecondsSinceEpoch}:${state.changed.microsecondsSinceEpoch}';
  }
  return {for (final name in states.keys.toList()..sort()) name: states[name]!};
}

Future<({Set<String> operations, String log})> generatorCoverageAsync(
  String output,
) => Isolate.run(() => generatorOperationCoverage(output));

/// Read only the official debugOperations packet, never round-trip the input.
/// Its paths/methods prove conversion coverage, not generated-code correctness.
({Set<String> operations, String log}) generatorOperationCoverage(
  String output,
) {
  final operations = <String>{};
  final packet = RegExp(
    r'^BUSYAPI_OPERATION_JSON_START\r?\n([\s\S]*?)\r?\nBUSYAPI_OPERATION_JSON_END\r?$',
    multiLine: true,
  );
  final matches = packet.allMatches(output).toList();
  if (matches.isEmpty)
    throw GeneratorFailure(
      'generate.coverage',
      'The generator did not report operation conversion coverage',
    );
  try {
    for (final match in matches) {
      final value = jsonDecode(match[1]!);
      for (final group in value as List) {
        for (final operation
            in group['operations']?['operation'] as List? ?? []) {
          if (operation['httpMethod'] is! String ||
              operation['path'] is! String)
            throw const FormatException();
          operations.add(
            '${operation['httpMethod']}'.toUpperCase() +
                ' ${operation['path']}',
          );
        }
      }
    }
  } on Object {
    throw GeneratorFailure(
      'generate.coverage',
      'Unrecognized official operation conversion metadata; output was withheld',
    );
  }
  return (operations: operations, log: output.replaceAll(packet, ''));
}
