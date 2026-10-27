import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _tail = '''x-literal: &payload
  number: 9007199254740993.00 # exact
  text: "café 東京"
  ref: {\$ref: literal-only}
x-copy: *payload
x-false: &flag false
x-flag: *flag
x-empty: &empty ""
x-empty-copy: *empty
''';

String _root(String version, int port) {
  final swagger = version == '2.0';
  return '''# Keep source ownership
${swagger ? 'swagger' : 'openapi'}: "$version"
info: &metadata {title: Original, version: "1"}
${swagger ? 'host: 127.0.0.1:$port\nschemes: [http]\nproduces: [application/json]' : 'servers: [{url: "http://127.0.0.1:$port"}]'}
paths:
  /items:
    get:
      responses:
        '200':
          description: Captured
${swagger ? '          schema: {\$ref: "./models.yaml#/Item"}' : '          content:\n            application/json:\n              schema: {\$ref: "./models.yaml#/Item"}'}
x-metadata: *metadata
$_tail'''
      .replaceAll('\n', '\r\n');
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final target in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
      test(
        'YAML ownership $version → $target retains captured source and HTTP meaning',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-migration-ownership-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final seen = <(String, String, List<int>)>[];
          var response = '{"id":9007199254740993.00}';
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final bytes = await request.fold<List<int>>(
              [],
              (all, part) => all..addAll(part),
            );
            seen.add((request.method, request.uri.toString(), bytes));
            request.response.headers.contentType = ContentType.json;
            request.response.write(response);
            await request.response.close();
          });
          final file = File('${directory.path}/api.yaml');
          final model = File('${directory.path}/models.yaml');
          await file.writeAsString('\ufeff${_root(version, server.port)}');
          await model.writeAsString(
            '\ufeff${('''# Shared model
Item: {type: object, required: [id], properties: {id: {type: integer, enum: [9007199254740993.00]}}, additionalProperties: false}
$_tail''').replaceAll('\n', '\r\n')}',
          );
          final originals = {
            file.path: await file.readAsBytes(),
            model.path: await model.readAsBytes(),
          };
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = file.uri.toString();
          final source = await project.buffer(root);
          final shared = await project.buffer(model.uri.toString());
          project.store.replace(
            root,
            source.text.replaceFirst('Original', 'Unsaved'),
          );
          project.store.replace(
            model.uri.toString(),
            shared.text.replaceFirst(
              '# Shared model',
              '# Unsaved shared model',
            ),
          );
          final capturedShared = shared.text;

          Future<void> send(
            BusyProject owner,
            String selectedRoot, {
            bool valid = true,
          }) async {
            final analysis = await owner.check(selectedRoot);
            expect(analysis['complete'], isTrue, reason: '$analysis');
            final operation =
                (analysis['projection']['operations'] as List).single as Map;
            final plan = await owner.prepareRequest(
              selectedRoot,
              resource: operation['resource'] as String,
              pointer: operation['pointer'] as String,
              occurrence: operation['occurrence'] as String,
            );
            try {
              final result = await const ContractRequestExecutor().execute(
                plan,
                OperationRequestDraft(planIdentity: plan.identity),
                resolveSecret: (_) async =>
                    throw StateError('This fixture has no credentials'),
              );
              try {
                expect(result.outgoing.complete, isTrue);
                expect(result.outgoing.valid, isTrue);
                expect(
                  result.received.complete,
                  isTrue,
                  reason: '${result.received.findings}',
                );
                expect(
                  result.received.valid,
                  valid,
                  reason: '${result.received.findings}',
                );
                expect(result.conforming, valid);
                expect(
                  await File(result.response.bodyFile).readAsBytes(),
                  utf8.encode(response),
                );
              } finally {
                await result.close();
              }
            } finally {
              plan.close();
            }
          }

          await send(project, root);
          final review = await project.prepareMigration(
            root,
            '${directory.path}/migrated',
            targetVersion: target,
          );
          addTearDown(review.close);
          expect(
            review.status,
            MigrationStatus.faithfullyConvertible,
            reason: '${review.result}',
          );
          expect(review.result['producerVersion'], '13');
          expect(review.unsaved, isTrue);
          expect(review.outdated, isFalse);
          expect(await Directory(review.destination).exists(), isFalse);
          await expectLater(
            review.publish(cancelled: () => true),
            throwsA(
              isA<CoreFailure>().having(
                (error) => error.code,
                'code',
                'cancelled',
              ),
            ),
          );
          expect(await Directory(review.destination).exists(), isFalse);
          await review.publish();
          final outputs = (review.result['outputs'] as List).cast<Map>();
          final sharedOutput = outputs.singleWhere(
            (value) => value['path'] != 'openapi.yaml',
          );
          expect(sharedOutput['text'], capturedShared);
          expect(
            await File('${review.destination}/${sharedOutput['path']}')
                .readAsBytes(),
            utf8.encode('\ufeff$capturedShared'),
          );
          final copy = await BusyProject.open(review.destination, engine);
          addTearDown(copy.close);
          await send(copy, copy.roots.single.id);
          response = '{"id":9007199254740992.00}';
          await send(copy, copy.roots.single.id, valid: false);
          expect(seen, hasLength(3));
          for (final request in seen) {
            expect(request.$1, 'GET');
            expect(request.$2, '/items');
            expect(request.$3, isEmpty);
          }
          expect(
            await File('${review.destination}/openapi.yaml').readAsString(),
            contains('title: Unsaved'),
          );
          expect(source.dirty, isTrue);
          expect(shared.dirty, isTrue);

          final cliDestination = '${directory.path}/cli-copy';
          Future<ProcessResult> cli(List<String> extra) => Process.run(
            '$testBundle/busyapi',
            [
              'migrate',
              file.path,
              '--target',
              target,
              '--output',
              cliDestination,
              '--json',
              ...extra,
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final prepared = await cli([]);
          expect(
            prepared.exitCode,
            0,
            reason: '${prepared.stdout}\n${prepared.stderr}',
          );
          final report = jsonDecode(prepared.stdout as String) as Map;
          expect(report['producerVersion'], '13');
          expect(report['published'], false);
          expect(await Directory(cliDestination).exists(), isFalse);
          final published = await cli([
            '--apply',
            report['reviewIdentity'] as String,
          ]);
          expect(
            published.exitCode,
            0,
            reason: '${published.stdout}\n${published.stderr}',
          );
          expect(
            (jsonDecode(published.stdout as String) as Map)['published'],
            true,
          );
          expect(
            await File('$cliDestination/openapi.yaml').readAsString(),
            contains('title: Original'),
          );
          for (final entry in originals.entries) {
            expect(await File(entry.key).readAsBytes(), entry.value);
          }
        },
      );
    }
  }

  test('a shared declaration blocker remains source-located and cannot publish', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-migration-shared-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final file = File('${directory.path}/api.yaml');
    const text =
        'openapi: &version "3.1.0"\ninfo: {title: Shared, version: "1"}\npaths: {}\nx-version: *version\n';
    await file.writeAsString(text);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final review = await project.prepareMigration(
      file.uri.toString(),
      '${directory.path}/copy',
      targetVersion: '3.1.2',
    );
    addTearDown(review.close);
    expect(review.status, MigrationStatus.blocked);
    expect(review.publishable, isFalse);
    final problem = review.problems.single;
    expect(problem.code, 'edit.shared');
    expect(problem.resource, file.uri.toString());
    expect(problem.pointer, '/openapi');
    expect(text.substring(problem.range.start, problem.range.end), '"3.1.0"');
    await expectLater(
      review.publish(),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'migration.blocked',
        ),
      ),
    );
    expect(await Directory(review.destination).exists(), isFalse);
    expect(await file.readAsString(), text);
  });

  test(
    'a changed shared buffer retires its migration review without publication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-migration-stale-alias-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final file = File('${directory.path}/api.yaml')
        ..writeAsStringSync(_root('3.0.4', 1));
      final model = File('${directory.path}/models.yaml')
        ..writeAsStringSync('Item: {type: integer}\n$_tail');
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final shared = await project.buffer(model.uri.toString());
      final original = await model.readAsBytes();
      final review = await project.prepareMigration(
        file.uri.toString(),
        '${directory.path}/copy',
        targetVersion: '3.2.1',
      );
      addTearDown(review.close);
      expect(review.publishable, isTrue, reason: '${review.result}');
      project.store.replace(
        shared.id,
        '${shared.text}# Later unsaved change\n',
      );
      expect(review.outdated, isTrue);
      await expectLater(
        review.publish(),
        throwsA(
          isA<CoreFailure>().having(
            (error) => error.code,
            'code',
            'migration.stale',
          ),
        ),
      );
      expect(await Directory(review.destination).exists(), isFalse);
      expect(await model.readAsBytes(), original);
      expect(shared.text, endsWith('# Later unsaved change\n'));
      expect(shared.dirty, isTrue);
    },
  );

  test('a previous migration producer cannot authorize publication', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-migration-previous-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final proxy = File('${directory.path}/previous.cjs');
    await proxy.writeAsString(
      'const helper = ${jsonEncode(runtimeHelper)};\n' +
          r'''
const child = require('node:child_process').spawn(process.execPath, [helper], {stdio: ['pipe', 'pipe', 'pipe']});
process.stdin.pipe(child.stdin);
child.stderr.pipe(process.stderr);
let pending = Buffer.alloc(0);
child.stdout.on('data', chunk => {
 pending = Buffer.concat([pending, chunk]);
 while (pending.length >= 4) {
  const length = pending.readUInt32BE(0);
  if (!length || length > 64 * 1024 * 1024) throw Error('Invalid fixture frame');
  if (pending.length < length + 4) break;
  const value = JSON.parse(pending.subarray(4, length + 4).toString('utf8'));
  pending = pending.subarray(length + 4);
  if (value.result?.producer === 'busyapi-native-migration') value.result.producerVersion = '2';
  const payload = Buffer.from(JSON.stringify(value)), header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length);
  process.stdout.write(header);
  process.stdout.write(payload);
 }
});
process.once('SIGTERM', () => child.kill('SIGTERM'));
child.once('exit', code => { process.exitCode = code ?? 1; });
''',
    );
    final engine = EngineProcess(executable: runtimeNode, helper: proxy.path);
    addTearDown(engine.close);
    final file = File('${directory.path}/api.yaml');
    const text =
        'openapi: 3.0.4\ninfo: {title: Previous, version: "1"}\npaths: {}\n';
    await file.writeAsString(text);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final destination = '${directory.path}/copy';
    await expectLater(
      project.prepareMigration(
        file.uri.toString(),
        destination,
        targetVersion: '3.2.1',
      ),
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'migration.protocol',
        ),
      ),
    );
    expect(await Directory(destination).exists(), isFalse);
    expect(await file.readAsString(), text);
  });
}
