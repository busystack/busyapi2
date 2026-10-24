import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:busyapi_core/busyapi_core.dart';

const usage = '''BusyAPI 0.1.0
Usage:
  busyapi init DESTINATION --title TITLE --api-version VERSION [--openapi 3.1.2|3.2.1] [--format yaml|json]
  busyapi check FILE_OR_PROJECT [--root NAME_OR_PATH] [--allow-directory PATH] [--map-resource URI FILE] [--json]
  busyapi lint FILE_OR_PROJECT [--root NAME_OR_PATH] [--ruleset URI_OR_PATH] [--fail-severity error|warning|information|hint] [--review-code | --approve-code TRUST_SHA256] [--map-resource URI FILE] [--json]
  busyapi bundle FILE_OR_PROJECT --output DIRECTORY [--format single-file|resource-package] [--root NAME_OR_PATH] [--map-resource URI FILE] [--replace-output RECEIPT_SHA256] [--json]
  busyapi build-docs FILE_OR_PROJECT --output DIRECTORY [--preset native-reference|redoc|swagger] [--root NAME_OR_PATH] [--map-resource URI FILE] [--replace-output RECEIPT_SHA256] [--json]
  busyapi diff FILE_OR_PROJECT (--base REVISION | --merge-base REVISION) [--root NAME_OR_PATH] [--fail-on breaking|potentially-breaking|any] [--json]
  busyapi mock FILE_OR_PROJECT [--root NAME_OR_PATH] [--port PORT] [--proxy HTTP_BASE_URL] [--json]
  busyapi test FILE_OR_PROJECT --case NAME [--case NAME...] [--root NAME_OR_PATH] [--environment NAME] [--allow-tls-file PATH...] [--secrets-stdin] [--json]
  busyapi import SOURCE --kind file|directory|url|git --output NEW_DIRECTORY [--root NAME_OR_PATH] [--allow-resource-url URL...] [--json]
  busyapi generate --list-generators [--json]
  busyapi generate --generator NAME --generator-options [--json]
  busyapi generate FILE_OR_PROJECT --generator NAME --output DIRECTORY [--root NAME_OR_PATH] [--option NAME=JSON_OR_TEXT ...] [--template-directory DIRECTORY] [--replace-output RECEIPT_SHA256] [--json]
  busyapi --help | --version
Reports: check/lint --sarif FILE; test --junit FILE (no-clobber exports; command exit status is unchanged).
Exit codes: 0 complete clean; 1 contract failure; 2 incomplete/unsupported; 3 operational/configuration failure.
''';
Future<void> main(List<String> args) => runBusyApi(args);

Future<void> runBusyApi(
  List<String> args, {
  PublicationBoundary? beforePublish,
}) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stdout.write(usage);
    return;
  }
  if (args.first == '--version') {
    stdout.writeln('BusyAPI 0.1.0');
    return;
  }
  final options = <String, String>{};
  final positionals = <String>[];
  final resourceMappings = <(String, String)>[];
  final rulesets = <String>[];
  final cases = <String>[];
  final executionFiles = <String>[];
  final importUrls = <String>{};
  final generationOptions = <String>[];
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--option' &&
        i + 1 < args.length &&
        !args[i + 1].startsWith('--')) {
      generationOptions.add(args[++i]);
    } else if (args[i] == '--allow-resource-url' &&
        i + 1 < args.length &&
        !args[i + 1].startsWith('--')) {
      importUrls.add(args[++i]);
    } else if (args[i] == '--allow-tls-file' &&
        i + 1 < args.length &&
        !args[i + 1].startsWith('--')) {
      executionFiles.add(args[++i]);
    } else if (args[i] == '--case' &&
        i + 1 < args.length &&
        !args[i + 1].startsWith('--')) {
      cases.add(args[++i]);
    } else if (args[i] == '--ruleset' &&
        i + 1 < args.length &&
        !args[i + 1].startsWith('--')) {
      rulesets.add(args[++i]);
    } else if (args[i] == '--map-resource' &&
        i + 2 < args.length &&
        !args[i + 1].startsWith('--') &&
        !args[i + 2].startsWith('--')) {
      resourceMappings.add((args[i + 1], args[i + 2]));
      i += 2;
    } else if ([
      '--json',
      '--review-code',
      '--secrets-stdin',
      '--list-generators',
      '--generator-options',
    ].contains(args[i])) {
      options[args[i].substring(2)] = 'true';
    } else if (args[i].startsWith('--')) {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        if (args.contains('--json')) {
          stdout.writeln(
            jsonEncode({
              'version': 1,
              'status': 'operational-failure',
              'complete': false,
              'checkedRoots': [],
              'findings': [],
              'error': {
                'code': 'cli.option',
                'message': 'Missing option value',
              },
            }),
          );
        } else {
          stderr.writeln('Missing value for ${args[i]}');
        }
        exitCode = 3;
        return;
      }
      options[args[i].substring(2)] = args[++i];
    } else {
      positionals.add(args[i]);
    }
  }
  EngineProcess? engine;
  BusyProject? project;
  List<ProjectRoot> selectedRoots = const [];
  try {
    if (resourceMappings.isNotEmpty &&
        ![
          'check',
          'lint',
          'bundle',
          'build-docs',
          'generate',
        ].contains(args.first)) {
      throw CoreFailure(
        'cli.option',
        'Resource mappings apply to check, lint, bundle and build-docs',
      );
    }
    final allowed = args.first == 'init'
        ? {'title', 'api-version', 'openapi', 'format'}
        : args.first == 'import'
        ? {'kind', 'output', 'root', 'json'}
        : {
            'root',
            'allow-directory',
            'json',
            if (['check', 'lint'].contains(args.first)) 'sarif',
            if (args.first == 'test') 'junit',
            if (['bundle', 'build-docs'].contains(args.first)) ...[
              'output',
              'replace-output',
            ],
            if (args.first == 'build-docs') 'preset',
            if (args.first == 'bundle') 'format',
            if (args.first == 'generate') ...[
              'generator',
              'output',
              'replace-output',
              'template-directory',
              'list-generators',
              'generator-options',
            ],
            if (args.first == 'diff') ...['base', 'merge-base', 'fail-on'],
            if (args.first == 'mock') ...['port', 'proxy'],
            if (args.first == 'test') ...['environment', 'secrets-stdin'],
            if (args.first == 'lint') ...[
              'fail-severity',
              'review-code',
              'approve-code',
            ],
          };
    if (options.keys.any((key) => !allowed.contains(key))) {
      throw CoreFailure('cli.option', 'Unknown option for this command');
    }
    if (rulesets.isNotEmpty && args.first != 'lint') {
      throw CoreFailure('cli.option', 'Ruleset selection applies to lint');
    }
    if (generationOptions.isNotEmpty && args.first != 'generate')
      throw CoreFailure(
        'cli.option',
        'Generator options apply only to generate',
      );
    if (args.first == 'generate' &&
        (options['list-generators'] == 'true' ||
            options['generator-options'] == 'true')) {
      if (positionals.isNotEmpty ||
          resourceMappings.isNotEmpty ||
          options.containsKey('list-generators') &&
              options.containsKey('generator') ||
          generationOptions.isNotEmpty ||
          options.keys.any(
            (key) => ![
              'generator',
              'json',
              'list-generators',
              'generator-options',
            ].contains(key),
          ) ||
          options.containsKey('list-generators') &&
              options.containsKey('generator-options'))
        throw CoreFailure(
          'cli.option',
          'Choose a generator metadata query without a project or output',
        );
      final runtime = GeneratorRuntime();
      final cancellation = RunCancellation();
      final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
          .map((signal) => signal.watch().listen((_) => cancellation.cancel()))
          .toList();
      try {
        if (options['list-generators'] == 'true') {
          final generators = await runtime.clients(
            cancelled: () => cancellation.cancelled,
          );
          if (options['json'] == 'true') {
            stdout.writeln(
              jsonEncode({
                'version': 1,
                'complete': true,
                'producer': 'openapi-generator',
                'producerVersion': generatorVersion,
                'generators': generators.map((g) => g.toJson()).toList(),
              }),
            );
          } else {
            for (final generator in generators)
              stdout.writeln('${generator.name} (${generator.stability})');
          }
        } else {
          final generator = options['generator'];
          if (generator == null)
            throw CoreFailure('cli.option', '--generator NAME is required');
          final documented = await runtime.options(
            generator,
            cancelled: () => cancellation.cancelled,
          );
          if (options['json'] == 'true') {
            stdout.writeln(
              jsonEncode({
                'version': 1,
                'complete': true,
                'producer': 'openapi-generator',
                'producerVersion': generatorVersion,
                'generator': generator,
                'options': documented.map((o) => o.toJson()).toList(),
              }),
            );
          } else {
            for (final option in documented)
              stdout.writeln(
                '${option.name}\n${option.documentation}\nExample/default: ${option.example}\n',
              );
          }
        }
      } finally {
        for (final signal in signals) {
          await signal.cancel();
        }
      }
      exitCode = 0;
      return;
    }
    if (cases.isNotEmpty && args.first != 'test') {
      throw CoreFailure('cli.option', 'Case selection applies to test');
    }
    if (importUrls.isNotEmpty && args.first != 'import')
      throw CoreFailure(
        'cli.option',
        'Resource URL approvals apply only to explicit import',
      );
    if (executionFiles.isNotEmpty && args.first != 'test')
      throw CoreFailure(
        'cli.option',
        'Individual TLS file approval applies to test',
      );
    if (options.containsKey('review-code') &&
        options.containsKey('approve-code'))
      throw CoreFailure(
        'cli.option',
        'Review code without executing it, or explicitly approve the reviewed identity',
      );
    if (positionals.length != 1) {
      throw CoreFailure(
        'cli.input',
        'Provide exactly one file or project path',
      );
    }
    if (args.first == 'init') {
      if (!options.containsKey('title') ||
          !options.containsKey('api-version')) {
        throw CoreFailure(
          'init.input',
          '--title and --api-version are required in non-interactive use',
        );
      }
      final file = await Initializer.create(
        destination: positionals.single,
        title: options['title']!,
        apiVersion: options['api-version']!,
        openapi: options['openapi'] ?? '3.1.2',
        format: options['format'] ?? 'yaml',
        beforePublish: beforePublish,
      );
      stdout.writeln(file);
      return;
    }
    if (args.first == 'import') {
      final kind = ProjectImportKind.values
          .where((value) => value.name == options['kind'])
          .singleOrNull;
      final destination = options['output'];
      if (kind == null || destination == null)
        throw CoreFailure(
          'cli.import',
          'Import requires --kind file|directory|url|git and --output NEW_DIRECTORY',
        );
      engine = EngineProcess.bundled();
      final cancellation = RunCancellation();
      final interrupt = ProcessSignal.sigint.watch().listen(
        (_) => cancellation.cancel(),
      );
      final terminate = ProcessSignal.sigterm.watch().listen(
        (_) => cancellation.cancel(),
      );
      ProjectImportPlan? plan;
      try {
        plan = await ProjectImporter(engine).prepare(
          kind: kind,
          source: positionals.single,
          destination: destination,
          root: options['root'],
          approvedUrls: importUrls,
          cancellation: cancellation,
        );
        final acquired = await plan.publish(
          cancellation: cancellation,
          beforePublish: beforePublish == null
              ? null
              : () => beforePublish(plan!.destination),
        );
        if (options['json'] == 'true') {
          stdout.writeln(
            jsonEncode({
              'version': 1,
              'status': plan.complete ? 'acquired' : 'incomplete',
              'complete': plan.complete,
              'opened': false,
              'root': acquired.root,
              'output': acquired.destination,
              'unavailable': plan.unavailable,
              'files': plan.files,
              'provenance': plan.metadata,
            }),
          );
        } else {
          stdout.writeln('Acquired contract: ${acquired.root}');
          if (!plan.complete)
            stderr.writeln(
              'Import is not self-contained: ${plan.unavailable.length} unavailable or unapproved resource(s).',
            );
        }
        exitCode = plan.complete ? 0 : 2;
      } finally {
        plan?.close();
        await interrupt.cancel();
        await terminate.cancel();
      }
      return;
    }
    if (![
      'check',
      'lint',
      'bundle',
      'build-docs',
      'diff',
      'mock',
      'test',
      'generate',
    ].contains(args.first)) {
      throw CoreFailure('cli.command', 'Unknown command');
    }
    engine = EngineProcess.bundled();
    project = await BusyProject.open(positionals.single, engine);
    for (final file in executionFiles) {
      await project.approveExecutionFile(file);
    }
    if (options['allow-directory'] != null) {
      await project.approveContext(options['allow-directory']!);
    }
    for (final mapping in resourceMappings) {
      await project.approveResource(
        mapping.$1,
        Uri.file(p.absolute(mapping.$2)).toString(),
      );
    }
    final selected = options['root'];
    var roots = project.roots;
    if (selected != null) {
      roots = roots
          .where(
            (r) =>
                r.name == selected ||
                Uri.parse(r.id).toFilePath() == p.absolute(selected) ||
                p.relative(
                      Uri.parse(r.id).toFilePath(),
                      from: project!.access.boundary,
                    ) ==
                    selected,
          )
          .toList();
      if (roots.isEmpty) {
        throw CoreFailure('cli.root', 'Requested root was not found');
      }
    }
    if (roots.isEmpty && File(positionals.single).existsSync()) {
      roots = [
        ProjectRoot(
          p.basename(positionals.single),
          Uri.file(p.absolute(positionals.single)).toString(),
        ),
      ];
    }
    if (roots.isEmpty) {
      if (project.discoveryFailure != null) {
        throw CoreFailure('engine.discovery', project.discoveryFailure!);
      }
      throw CoreFailure('cli.fragment', 'Input has no OpenAPI root');
    }
    if (selected == null &&
        roots.length > 1 &&
        ([
              'bundle',
              'build-docs',
              'diff',
              'mock',
              'test',
              'generate',
            ].contains(args.first) ||
            !File(p.join(project.access.boundary, 'busyapi.yaml'))
                .existsSync())) {
      throw CoreFailure(
        'cli.ambiguous',
        'Multiple unconfigured roots; select one with --root',
      );
    }
    if (args.first == 'generate') {
      selectedRoots = List.unmodifiable(roots);
      final generator = options['generator'], destination = options['output'];
      if (generator == null || destination == null || roots.length != 1)
        throw CoreFailure(
          'cli.generate',
          'Generate requires one root, --generator NAME and --output DIRECTORY',
        );
      final values = <String, Object?>{};
      for (final argument in generationOptions) {
        final at = argument.indexOf('=');
        if (at <= 0 || values.containsKey(argument.substring(0, at)))
          throw CoreFailure(
            'cli.option',
            'Use distinct --option NAME=JSON_OR_TEXT values',
          );
        final text = argument.substring(at + 1);
        Object? value;
        try {
          value = jsonDecode(text);
        } on FormatException {
          value = text;
        }
        values[argument.substring(0, at)] = value;
      }
      final token = RunCancellation();
      final signals = [
        ProcessSignal.sigint,
        ProcessSignal.sigterm,
      ].map((signal) => signal.watch().listen((_) => token.cancel())).toList();
      ClientOutput? output;
      try {
        output = await project.prepareClient(
          roots.single.id,
          destination,
          generator: generator,
          options: values,
          templateDirectory: options['template-directory'],
          saved: true,
          cancelled: () => token.cancelled,
        );
        final previous = await output.existing();
        if (previous != null && previous.identity != options['replace-output'])
          throw CoreFailure(
            'generate.ownership',
            'Replacement requires the reviewed unchanged output receipt identity',
          );
        if (previous == null && options.containsKey('replace-output'))
          throw CoreFailure(
            'generate.ownership',
            'No existing output matches the replacement authorization',
          );
        final changes = await output.changes(previous);
        final published = await output.publish(
          replaceIdentity: options['replace-output'],
          cancelled: () => token.cancelled,
          beforePublish: beforePublish == null
              ? null
              : () => beforePublish(output!.destination),
        );
        final receipt = await output.existing();
        if (options['json'] == 'true') {
          stdout.writeln(
            jsonEncode({
              'version': 1,
              'status': 'complete',
              'complete': true,
              'snapshot': output.snapshot.sourceIdentity,
              'input': 'saved-source',
              'producer': 'openapi-generator',
              'producerVersion': generatorVersion,
              'generator': generator,
              'output': {
                'directory': output.destination,
                'identity': output.identity,
                'receiptIdentity': receipt!.identity,
                if (published.previous != null) 'previous': published.previous,
              },
              'changes': changes.map((change) => change.toJson()).toList(),
              'coverage': output.metadata['coverage'],
              'messages': output.messages,
            }),
          );
        } else {
          stdout.writeln(
            'Generated $generator client: ${output.destination}\nSnapshot: ${output.snapshot.sourceIdentity}',
          );
          if (output.messages.isNotEmpty) stderr.writeln(output.messages);
        }
        exitCode = 0;
        return;
      } finally {
        output?.close();
        for (final signal in signals) await signal.cancel();
      }
    }
    if (['diff', 'mock', 'test'].contains(args.first)) {
      selectedRoots = List.unmodifiable(roots);
      if (roots.length != 1) {
        throw CoreFailure(
          'cli.ambiguous',
          '${args.first} requires exactly one selected API root',
        );
      }
      final root = roots.single;
      if (args.first == 'diff') {
        final base = options['base'], mergeBase = options['merge-base'];
        if ((base == null) == (mergeBase == null)) {
          throw CoreFailure(
            'diff.baseline',
            'Choose exactly one --base REVISION or --merge-base REVISION',
          );
        }
        final repository = await GitRepository.discover(
          project.access.boundary,
        );
        if (repository == null) {
          throw CoreFailure(
            'git.repository',
            'The project is not inside a Git repository',
          );
        }
        final revision = mergeBase == null
            ? base!
            : await repository.mergeBase('HEAD', mergeBase);
        final rootPath = p.relative(
          Uri.parse(root.id).toFilePath(),
          from: project.access.boundary,
        );
        final baseline = await repository.historicalSnapshot(
          revision: revision,
          projectBoundary: project.access.boundary,
          rootPath: rootPath,
          engine: engine,
        );
        final current = await project.captureContractSnapshot(
          root.id,
          saved: true,
          requestId: 'cli-diff-current',
        );
        final review = await OasdiffAdapter().compare(
          baseline.snapshot,
          current.snapshot,
          engine,
          baselineAnalysis: baseline.analysis,
          currentAnalysis: current.analysis,
        );
        if (options['json'] == 'true') {
          stdout.writeln(jsonEncode(review.toJson()));
        } else {
          stdout.write(review.summary());
          if (review.rawDiff.isNotEmpty) {
            stdout.writeln('\nRaw source diff:');
            stdout.write(review.rawDiff);
          }
        }
        final threshold = options['fail-on'] ?? 'breaking';
        if (!const {
          'breaking',
          'potentially-breaking',
          'any',
        }.contains(threshold)) {
          throw CoreFailure(
            'diff.threshold',
            'Choose --fail-on breaking, potentially-breaking or any',
          );
        }
        final failed =
            review.breaking ||
            threshold != 'breaking' && review.potentiallyBreaking ||
            threshold == 'any' && review.changes.isNotEmpty;
        exitCode = !review.complete
            ? 2
            : failed
            ? 1
            : 0;
        return;
      }
      if (args.first == 'mock') {
        final requestedPort = int.tryParse(options['port'] ?? '0');
        if (requestedPort == null ||
            requestedPort < 0 ||
            requestedPort > 65535) {
          throw CoreFailure('mock.port', '--port must be between 0 and 65535');
        }
        final plan = await project.prepareMock(
          root.id,
          saved: true,
          requestId: 'cli-mock',
        );
        MockRun? run;
        StreamSubscription<ProcessSignal>? interrupt, terminate;
        var signalled = false;
        try {
          final proxy = options['proxy'] == null
              ? null
              : Uri.tryParse(options['proxy']!);
          if (options['proxy'] != null && proxy == null) {
            throw CoreFailure(
              'mock.proxy.target',
              '--proxy must be an HTTP(S) base URL',
            );
          }
          run = await plan.start(port: requestedPort, proxyTarget: proxy);
          final ready = {
            'version': 1,
            'status': 'ready',
            'complete': true,
            'snapshot': plan.snapshot.identity,
            'input': 'saved-source',
            'tool': 'Prism',
            'toolVersion': run.toolVersion,
            'adapter': 'in-memory-http-spec-7.1.0',
            'host': run.host,
            'port': run.port,
            'operations': run.operations,
            'upstreamForwarding': run.upstreamForwarding,
          };
          if (options['json'] == 'true') {
            stdout.writeln(jsonEncode(ready));
          } else {
            stdout.writeln(
              'Prism ${run.toolVersion} ready at ${run.baseUri} for ${run.operations} operation(s)${run.upstreamForwarding ? ' as an explicit validation proxy' : ''}',
            );
            stdout.writeln(
              'Snapshot: ${plan.snapshot.sourceIdentity} (saved source)',
            );
          }
          Future<void> stop(ProcessSignal _) async {
            if (signalled) return;
            signalled = true;
            await run!.stop();
          }

          interrupt = ProcessSignal.sigint.watch().listen(
            (signal) => stop(signal),
          );
          terminate = ProcessSignal.sigterm.watch().listen(
            (signal) => stop(signal),
          );
          final code = await run.exitCode;
          if (run.errors.isNotEmpty) stderr.writeln(run.errors);
          exitCode = signalled && code == 0
              ? 0
              : code == 0
              ? 0
              : 3;
          return;
        } finally {
          await interrupt?.cancel();
          await terminate?.cancel();
          if (run != null) await run.stop();
          plan.close();
        }
      }
      if (args.first == 'test') {
        if (cases.isEmpty) {
          throw CoreFailure(
            'test.selection',
            'Select at least one configured --case NAME',
          );
        }
        final secrets = <String, String>{};
        if (options['secrets-stdin'] == 'true') {
          Object? value;
          try {
            var bytes = 0;
            final raw = await stdin
                .map((chunk) {
                  bytes += chunk.length;
                  if (bytes > 1024 * 1024) {
                    throw CoreFailure(
                      'secret.input.limit',
                      '--secrets-stdin is limited to 1 MiB',
                    );
                  }
                  return chunk;
                })
                .transform(utf8.decoder)
                .join();
            value = jsonDecode(raw);
          } on FormatException {
            // FormatException.toString contains the original input. Secret
            // input must never reach the general CLI error reporter as text.
            throw CoreFailure(
              'secret.input',
              '--secrets-stdin expects valid UTF-8 JSON with reference-to-value string pairs',
            );
          }
          if (value is! Map ||
              value.entries.any(
                (entry) => entry.key is! String || entry.value is! String,
              )) {
            throw CoreFailure(
              'secret.input',
              '--secrets-stdin expects one JSON object of reference-to-value pairs',
            );
          }
          for (final entry in value.entries) {
            secrets[entry.key as String] = entry.value as String;
          }
        }
        final report = await const ContractTestRunner().run(
          project,
          root.id,
          selectedCases: cases,
          environment: options['environment'],
          resolveSecret: (reference) async => secrets[reference],
        );
        if (options['junit'] case final destination?) {
          await CiReports.publish(
            destination,
            CiReports.junit(report, secrets: secrets.values),
          );
        }
        if (options['json'] == 'true') {
          stdout.writeln(jsonEncode(report.toJson()));
        } else {
          for (final value in report.cases) {
            stdout.writeln(
              '${value.status}: ${value.name} · ${value.operation}',
            );
            for (final finding in value.findings) {
              stdout.writeln(
                '  ${finding['severity']} ${finding['code']}: ${finding['message']}',
              );
            }
          }
          stdout.writeln(
            'Executed ${report.executedOperations.length}; untested ${report.untestedOperations.length}; exhaustive: no',
          );
        }
        exitCode = !report.complete
            ? 2
            : report.passed
            ? 0
            : 1;
        return;
      }
    }
    if (['bundle', 'build-docs'].contains(args.first)) {
      selectedRoots = List.unmodifiable(roots);
      if (roots.length != 1)
        throw CoreFailure(
          'cli.ambiguous',
          'An export requires exactly one selected API root',
        );
      final destination = options['output'];
      if (destination == null)
        throw CoreFailure('cli.output', '--output DIRECTORY is required');
      final documentation = args.first == 'build-docs';
      final bundleFormat = options['format'] ?? 'single-file';
      if (!['single-file', 'resource-package'].contains(bundleFormat)) {
        throw CoreFailure(
          'cli.option',
          'Choose bundle --format single-file or resource-package',
        );
      }
      final plan = documentation
          ? await project.prepareDocumentation(
              roots.single.id,
              destination,
              preset: options['preset'] ?? 'native-reference',
              saved: true,
            )
          : await project.prepareBundle(
              roots.single.id,
              destination,
              saved: true,
              format: bundleFormat == 'resource-package'
                  ? BundleFormat.resourcePackage
                  : BundleFormat.singleFile,
            );
      try {
        final published = await plan.publish(
          replaceIdentity: options['replace-output'],
          beforePublish: beforePublish == null
              ? null
              : () => beforePublish(plan.destination),
        );
        final receipt = await plan.existing();
        if (options['json'] == 'true') {
          stdout.writeln(
            jsonEncode({
              'version': 1,
              'status': 'complete',
              'complete': true,
              'checkedRoots': [
                {'name': roots.single.name, 'resource': roots.single.id},
              ],
              'snapshot': plan.snapshot.sourceIdentity,
              'input': 'saved-source',
              'unsaved': false,
              'producer': plan.result['producer'],
              'producerVersion': plan.result['producerVersion'],
              if (documentation) 'preset': plan.metadata['preset'],
              if (!documentation) 'format': plan.metadata['format'],
              'output': {
                'directory': plan.destination,
                'entry': plan.metadata['entry'],
                'identity': plan.identity,
                'receiptIdentity': receipt?.identity,
                if (published.previous != null) 'previous': published.previous,
              },
            }),
          );
        } else {
          stdout.writeln(
            '${documentation ? 'Built documentation for' : 'Bundled'} ${roots.single.name}: ${p.join(plan.destination, plan.metadata['entry'] as String)}',
          );
          stdout.writeln(
            'Snapshot: ${plan.snapshot.sourceIdentity} (saved source)',
          );
          if (published.previous != null)
            stdout.writeln('Previous output preserved: ${published.previous}');
        }
        exitCode = 0;
        return;
      } finally {
        plan.close();
      }
    }
    PolicyCodeApproval? codeApproval;
    if (args.first == 'lint' &&
        (options.containsKey('review-code') ||
            options.containsKey('approve-code'))) {
      selectedRoots = List.unmodifiable(roots);
      if (roots.length != 1)
        throw CoreFailure(
          'cli.ambiguous',
          'Code approval requires exactly one selected API root',
        );
      final review = await project.reviewPolicyCode(
        roots.single.id,
        saved: true,
        rulesets: rulesets.isEmpty ? null : rulesets,
        failSeverity: options['fail-severity'],
      );
      if (options.containsKey('review-code')) {
        final trust = review.complete
            ? await project.policyCodeTrust(review)
            : null;
        if (options['json'] == 'true') {
          stdout.writeln(
            jsonEncode({
              'version': 1,
              'command': 'lint-code-review',
              'complete': review.complete,
              'status': review.complete ? 'complete' : 'incomplete',
              'checkedRoots': [
                {'name': roots.single.name, 'resource': roots.single.id},
              ],
              'saved': true,
              'executed': false,
              'codeReview': review.result,
              'trust': trust,
            }),
          );
        } else {
          stdout.writeln(
            'Source-only code review: ${review.complete ? 'complete' : 'incomplete'}; no code executed.',
          );
          for (final module in review.result['modules'] as List)
            stdout.writeln(
              '${module['resource']}: ${module['format']} ${module['identity']}',
            );
          for (final binding in review.result['bindings'] as List)
            stdout.writeln(
              '${binding['from']}: ${binding['specifier']} -> ${binding['target'] ?? 'unavailable'}',
            );
          for (final issue in review.result['issues'] as List)
            stdout.writeln(
              '${issue['resource'] ?? issue['from'] ?? roots.single.id}: ${issue['code']}',
            );
          if (trust != null)
            stdout.writeln('One-run trust identity: ${trust['identity']}');
        }
        exitCode = review.complete ? 0 : 2;
        return;
      }
      codeApproval = await project.approvePolicyCode(
        review,
        expectedIdentity: options['approve-code']!,
      );
    }
    final runs = <Map<String, dynamic>>[];
    final reportSnapshots = <AnalysisSnapshot>[];
    for (final root in roots) {
      runs.add(
        args.first == 'lint'
            ? await project.lint(
                root.id,
                saved: true,
                rulesets: rulesets.isEmpty ? null : rulesets,
                failSeverity: options['fail-severity'],
                codeApproval: codeApproval,
                onSnapshot: reportSnapshots.add,
              )
            : await project.check(
                root.id,
                saved: true,
                onSnapshot: reportSnapshots.add,
              ),
      );
    }
    final findings = runs.expand((r) => r['findings'] as List).toList();
    final status =
        runs.any((r) => ['incomplete', 'unsupported'].contains(r['status']))
        ? 'incomplete'
        : runs.any((r) => r['status'] == 'invalid')
        ? 'invalid'
        : 'complete';
    final output = {
      'version': 1,
      'status': status,
      'complete': runs.every((r) => r['complete'] == true),
      'checkedRoots': roots
          .map((r) => {'name': r.name, 'resource': r.id})
          .toList(),
      'findings': findings,
      'snapshots': runs.map((r) => r['snapshot']).toList(),
      if (args.first == 'lint') ...{
        'sourceSnapshots': runs.map((r) => r['sourceSnapshot']).toList(),
        'configurations': runs.map((r) => r['configuration']).toList(),
        'effectiveRules': [
          for (var i = 0; i < roots.length; i++)
            {'root': roots[i].id, 'rules': runs[i]['effectiveRules']},
        ],
      },
      'versions': runs.first['versions'],
      'coverage': runs.first['coverage'],
      'categories': [
        for (var i = 0; i < runs.length; i++)
          {'root': roots[i].id, 'results': runs[i]['categories'] ?? {}},
      ],
    };
    if (options['sarif'] case final destination?) {
      await CiReports.publish(
        destination,
        '${jsonEncode(CiReports.sarif(runs, snapshots: reportSnapshots))}\n',
      );
    }
    if (options['json'] == 'true') {
      stdout.writeln(jsonEncode(output));
    } else {
      for (final r in roots) {
        stdout.writeln('Checked ${r.name} (${r.id})');
      }
      for (final d in findings) {
        stdout.writeln(
          '${d['resource']}: ${d['severity']} ${d['code']}: ${d['message']}',
        );
      }
      stdout.writeln('Run: $status');
    }
    exitCode = status == 'complete'
        ? 0
        : status == 'invalid'
        ? 1
        : 2;
  } on Object catch (e) {
    final code = e is CoreFailure ? e.code : 'io.failure';
    final failureExit = args.first == 'generate' && code == 'cancelled'
            ? 2
            : outputFailureExitCode(e),
        incomplete =
            failureExit == 2 ||
            code.startsWith('policy.code.') ||
            code.startsWith('policy.assets') ||
            code.startsWith('policy.isolation.'),
        contract = failureExit == 1;
    final checked = e is OutputAnalysisFailure
        ? (e.analysis['checkedRoots'] as List? ?? const [])
        : const [];
    final failureRoots = <Map<String, Object?>>[
      for (final value in checked)
        if (value is String || value is Map && value['resource'] is String)
          {
            'name':
                selectedRoots
                    .where(
                      (root) =>
                          root.id ==
                          (value is String ? value : value['resource']),
                    )
                    .firstOrNull
                    ?.name ??
                project?.roots
                    .where(
                      (root) =>
                          root.id ==
                          (value is String ? value : value['resource']),
                    )
                    .singleOrNull
                    ?.name ??
                (value is Map && value['name'] is String
                    ? value['name']
                    : 'root'),
            'resource': value is String ? value : value['resource'],
          },
    ];
    if (options['sarif'] case final destination?) {
      try {
        await CiReports.publish(
          destination,
          '${jsonEncode(CiReports.sarif([
            {'complete': false, 'status': 'operational-failure', 'findings': e is OutputAnalysisFailure ? e.analysis['findings'] : []},
          ]))}\n',
        );
      } on Object {
        stderr.writeln(
          'SARIF report could not be published; existing files were preserved.',
        );
      }
    }
    if (options['junit'] case final destination?) {
      try {
        await CiReports.publish(
          destination,
          CiReports.junit(
            const ContractTestReport(
              snapshot: 'unavailable',
              complete: false,
              passed: false,
              cases: [],
              executedOperations: [],
              untestedOperations: [],
            ),
          ),
        );
      } on Object {
        stderr.writeln(
          'JUnit report could not be published; existing files were preserved.',
        );
      }
    }
    if (options['json'] == 'true') {
      stdout.writeln(
        jsonEncode({
          'version': 1,
          'status': incomplete
              ? 'incomplete'
              : contract
              ? 'invalid'
              : 'operational-failure',
          'complete': false,
          'checkedRoots': failureRoots,
          if (args.first == 'generate') ...{
            'generator': options['generator'],
            'tool': {
              'name': 'openapi-generator',
              'version': generatorVersion,
              'jarSha256': generatorJarIdentity,
            },
          },
          'findings': e is OutputAnalysisFailure ? e.analysis['findings'] : [],
          if (e is OutputAnalysisFailure) ...{
            'snapshot': e.analysis['snapshot'],
            'sourceSnapshot': e.analysis['sourceSnapshot'],
            'versions': e.analysis['versions'],
            'categories': [
              for (final root in failureRoots)
                {
                  'root': root['resource'],
                  'results': e.analysis['categories'] ?? const {},
                },
            ],
          },
          if (e is OutputDirectoryChanged) ...{
            'published': e.published,
            'recoveryPath': e.recoveryPath,
          },
          'error': {
            'code': code,
            'message': e.toString(),
            if (e is GeneratorFailure) 'detail': e.detail,
            if (e is OutputAnalysisFailure && e.cause is GeneratorFailure)
              'detail': (e.cause as GeneratorFailure).detail,
          },
        }),
      );
    } else {
      stderr.writeln(e);
      if (e is GeneratorFailure) stderr.writeln(e.detail);
      if (e is OutputAnalysisFailure && e.cause is GeneratorFailure)
        stderr.writeln((e.cause as GeneratorFailure).detail);
    }
    exitCode = incomplete
        ? 2
        : contract
        ? 1
        : 3;
  } finally {
    project?.close();
    await engine?.close();
  }
}
