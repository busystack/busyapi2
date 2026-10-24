import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _BrokenPackageGraph extends EngineProcess {
  _BrokenPackageGraph(this.fault)
    : super(executable: runtimeNode, helper: runtimeHelper);
  final String fault;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method != 'describeResourcePackage')
      return super.request(method, params, requestId: requestId);
    return {
      'version': 1,
      'root': params['root'],
      'snapshot': params['snapshot'],
      'identities': fault == 'empty'
          ? []
          : [
              {
                'uri': params['root'],
                'kind': 'resource',
                'resource': params['root'],
                'pointer': '',
                'range': [0, fault == 'range' ? 1000000000 : 0],
                if (fault == 'alias') 'physicalPointer': false,
                if (fault == 'alias') 'occurrenceRange': [0, 0],
              },
            ],
    };
  }
}

void main() {
  for (final fault in ['empty', 'range', 'alias']) {
    test(
      'a malformed package graph cannot publish a successful empty or unrelated output $fault',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-package-protocol-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/root.json'),
            text =
                '{"openapi":"3.2.1","info":{"title":"Protocol","version":"1"},"paths":{}}';
        await file.writeAsString(text);
        final engine = _BrokenPackageGraph(fault);
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        await expectLater(
          project.prepareBundle(
            file.uri.toString(),
            '${temp.path}/output',
            format: BundleFormat.resourcePackage,
          ),
          throwsA(
            isA<OutputAnalysisFailure>().having(
              (e) => e.code,
              'code',
              'bundle.package.protocol',
            ),
          ),
        );
        expect(Directory('${temp.path}/output').existsSync(), false);
        expect(await file.readAsString(), text);
      },
    );
  }
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'explicit resource package preserves legal mixed dialects, URI bases, exact data and standalone loader $version $json',
        () async {
          final workflow = Stopwatch()..start();
          final stages = <String>[];
          void stage(String name) =>
              stages.add('$name@${workflow.elapsedMilliseconds}ms');
          addTearDown(() {
            // Fixed labels only: retain the last entered phase on a timeout
            // without logging contract data, private paths or changing limits.
            print(
              'Resource package $version $json: ${stages.join(', ')}; '
              'total ${workflow.elapsedMilliseconds} ms',
            );
          });
          stage('setup');
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-resource-package-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final source = await Directory('${temp.path}/source 雪').create();
          final suffix = json ? 'json' : 'yaml',
              root = File('${source.path}/root.$suffix'),
              models = File('${source.path}/mixed.$suffix'),
              leaf = File('${source.path}/leaf.$suffix');
          final modelUri = 'https://contracts.invalid/original/mixed.$suffix',
              leafUri = 'https://contracts.invalid/original/leaf.$suffix';
          final document = <String, Object?>{
            'openapi': version,
            'info': {'title': 'Package 雪😀', 'version': '1'},
            'paths': <String, Object?>{},
            if (version.startsWith('3.2'))
              r'$self': 'https://contracts.invalid/original/root.$suffix',
            'components': {
              'schemas': {
                'A': {r'$ref': '$modelUri#/components/schemas/A'},
                'B': {r'$ref': '$modelUri#/components/schemas/B'},
                'Tree': {r'$ref': '$modelUri#/components/schemas/Tree'},
                'Escaped': {
                  r'$ref': '$leafUri#/\$defs/Escaped~1~0name',
                  'examples': [111, 222],
                },
              },
            },
            'x-payload': {r'$ref': 'payload data', 'number': 111},
          };
          final model = <String, Object?>{
            'openapi': version,
            'info': {'title': 'Original model', 'version': '1'},
            'paths': <String, Object?>{},
            'components': {
              'schemas': {
                'A': {
                  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
                  r'$ref': 'leaf.$suffix#text',
                  'examples': ['good', 1],
                },
                'B': {
                  'type': 'integer',
                  'const': 111,
                  'examples': [111, 222],
                },
                'Tree': {
                  r'$id': 'tree',
                  r'$dynamicAnchor': 'node',
                  'type': 'object',
                  'properties': {
                    'value': {'const': 111},
                    'child': {r'$dynamicRef': '#node'},
                  },
                  'required': ['value'],
                  'unevaluatedProperties': false,
                  'examples': [
                    {
                      'value': 111,
                      'child': {'value': 111},
                    },
                    {
                      'value': 111,
                      'child': {'value': 222},
                    },
                  ],
                },
              },
              'examples': {
                'Data': {
                  'externalValue': 'payload data',
                  'x-preserved': {r'$ref': 'not a dependency', 'exact': 111},
                },
              },
            },
          };
          final leafData = {
            r'$schema': 'https://json-schema.org/draft/2020-12/schema',
            r'$id': leafUri,
            r'$defs': {
              'Text': {r'$anchor': 'text', 'type': 'string'},
              'Escaped/~name': {'const': 111},
            },
            'x-data': {r'$ref': 'not a reference', 'decimal': 333},
          };
          String render(Object data) =>
              (json
                      ? jsonEncode(data)
                      : '\ufeff# Preserve 雪😀\r\n${jsonEncode(data)}')
                  .replaceAll('111', '9007199254740993')
                  .replaceAll('222', '9007199254740992')
                  .replaceAll('333', '0.10000000000000000000001');
          await root.writeAsString(render(document));
          await models.writeAsString(render(model));
          await leaf.writeAsString(render(leafData));
          final originals = {
            for (final file in [root, models, leaf])
              file.path: await file.readAsBytes(),
          };
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          await project.approveResource(modelUri, models.uri.toString());
          await project.approveResource(leafUri, leaf.uri.toString());
          final buffer = await project.buffer(models.uri.toString());
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Original model', 'Unsaved model'),
          );
          stage('original-check');
          final original = await project.check(root.uri.toString());
          expect(original['complete'], true, reason: jsonEncode(original));
          expect(original['status'], 'complete');
          expect(
            (original['findings'] as List).where(
              (f) => f['code'] == 'schema.dialect.location',
            ),
            isEmpty,
          );
          stage('single-file-refusal');
          await expectLater(
            project.prepareBundle(root.uri.toString(), '${temp.path}/single'),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'bundle.dialect.boundary',
              ),
            ),
          );
          expect(Directory('${temp.path}/single').existsSync(), false);
          stage('working-package-capture');
          final plan = await project.prepareBundle(
            root.uri.toString(),
            '${temp.path}/package one 雪',
            format: BundleFormat.resourcePackage,
          );
          addTearDown(plan.close);
          expect(plan, isA<ResourcePackageOutput>());
          expect(plan.unsaved, true);
          expect(plan.metadata['format'], 'resource-package');
          stage('working-package-publish');
          await plan.publish();
          final receipt = (await plan.existing())!;
          stage('repeated-package-capture');
          final repeated = await project.prepareBundle(
            root.uri.toString(),
            '${temp.path}/package two 雪',
            format: BundleFormat.resourcePackage,
          );
          addTearDown(repeated.close);
          stage('repeated-package-publish');
          await repeated.publish();
          expect((await repeated.existing())!.files, receipt.files);
          if (version == '3.2.1' && json) {
            stage('owned-output-replacement');
            final replaced = await repeated.publish(
              replaceIdentity: (await repeated.existing())!.identity,
            );
            expect(replaced.previous, isNotNull);
            final outputAccess = await ProjectAccess.open(temp.path);
            try {
              expect(
                (await outputAccess.inspectOutput(replaced.previous!)).files,
                receipt.files,
              );
            } finally {
              outputAccess.close();
            }
            expect((await repeated.existing())!.files, receipt.files);
          }
          for (final entry in originals.entries)
            expect(await File(entry.key).readAsBytes(), entry.value);
          // The output is a frozen working copy even after the source changes.
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Unsaved model', 'Later model'),
          );
          expect(plan.outdated, true);
          stage('frozen-package-load');
          final frozen = await ResourcePackage.open(plan.destination, engine);
          expect(frozen.manifest['input'], 'working-copy');
          expect(
            frozen.snapshot.resources.singleWhere(
              (r) => r['id'] == models.uri.toString(),
            )['text'],
            contains('Unsaved model'),
          );
          expect(
            frozen.snapshot.resources.singleWhere(
              (r) => r['id'] == models.uri.toString(),
            )['aliases'],
            [modelUri],
          );
          stage('frozen-package-check');
          final checked = await frozen.check(engine);
          List<Object?> findings(Map data) => (data['findings'] as List)
              .map(
                (f) => [
                  f['code'],
                  f['resource'],
                  f['pointer'],
                  f['range'],
                  f['severity'],
                ],
              )
              .toList();
          expect(findings(checked), findings(original));
          stage('instance-equivalence');
          final evaluation = await engine.request(
            'evaluateSchemas',
            frozen.snapshot.toJson(),
          );
          expect(evaluation['complete'], true);
          expect((evaluation['evaluations'] as List).length, 8);
          expect((evaluation['evaluations'] as List).map((e) => e['valid']), [
            true,
            false,
            true,
            false,
            true,
            false,
            true,
            false,
          ]);
          final identities = frozen.manifest['identities'] as List;
          expect(
            identities.any(
              (i) =>
                  i['uri'] == 'https://contracts.invalid/original/tree#node' &&
                  i['pointer'] == '/components/schemas/Tree',
            ),
            true,
          );
          expect(
            identities.any(
              (i) =>
                  i['uri'] == '$leafUri#text' && i['pointer'] == r'/$defs/Text',
            ),
            true,
          );
          for (final resource in frozen.snapshot.resources) {
            final record = (frozen.manifest['resources'] as List).singleWhere(
              (r) => r['resource'] == resource['id'],
            );
            final bytes = await File('${plan.destination}/${record['path']}')
                .readAsBytes();
            expect(contentIdentity(bytes), record['identity']);
            expect(utf8.decode(bytes), contains('9007199254740993'));
          }
          expect(
            await File(
              '${plan.destination}/licenses/busyapi-engine/NODE-LICENSE',
            ).readAsString(),
            contains('Node.js'),
          );
          expect(
            await File('${plan.destination}/licenses/busyapi-dart/DART-LICENSE')
                .readAsString(),
            contains('Dart'),
          );
          final runtimeNotices = jsonDecode(
            await File(
              '${plan.destination}/licenses/busyapi-dart/runtime/dependencies.json',
            ).readAsString(),
          ) as Map;
          expect((runtimeNotices['components'] as List).length, 10);
          for (final component in runtimeNotices['components'] as List) {
            for (final notice in component['notices'] as List) {
              final relative = 'runtime/${notice['file']}';
              final exported = await File(
                '${plan.destination}/licenses/busyapi-dart/$relative',
              ).readAsBytes();
              expect(contentIdentity(exported), notice['sha256']);
              expect(
                exported,
                await File('$testBundle/share/licenses/busyapi-dart/$relative')
                    .readAsBytes(),
              );
            }
          }
          expect(
            Directory('${plan.destination}/node_modules').existsSync(),
            false,
          );
          expect(File('${plan.destination}/openapi.json').existsSync(), false);
          project.store.undo();
          expect(buffer.text, contains('Unsaved model'));
          expect(buffer.text, isNot(contains('Later model')));
          stage('source-save');
          await project.save(buffer);
          final cliPath = '${temp.path}/CLI package';
          stage('saved-package-capture');
          final savedPlan = await project.prepareBundle(
            root.uri.toString(),
            cliPath,
            saved: true,
            format: BundleFormat.resourcePackage,
          );
          addTearDown(savedPlan.close);
          stage('packaged-cli-export');
          final cli = await Process.run(
            '$testBundle/busyapi',
            [
              'bundle',
              root.path,
              '--output',
              cliPath,
              '--format',
              'resource-package',
              '--map-resource',
              modelUri,
              models.path,
              '--map-resource',
              leafUri,
              leaf.path,
              '--json',
            ],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          expect(cli.stderr, isEmpty);
          final cliResult = jsonDecode(cli.stdout as String) as Map;
          expect(cliResult['format'], 'resource-package');
          expect(cliResult['output']['identity'], savedPlan.identity);
          stage('saved-package-equivalence');
          final savedPackage = await ResourcePackage.open(cliPath, engine);
          expect(
            findings(await savedPackage.check(engine)),
            findings(original),
          );
          expect(savedPackage.manifest['input'], 'saved-source');
          // No source paths or original HTTP retrieval endpoints are available.
          await source.rename('${temp.path}/unavailable original source');
          final relocated = await Directory(plan.destination)
              .rename('${temp.path}/relocated package 雪 with spaces');
          stage('relocated-standalone-loader');
          final run = await Process.run(
            '${relocated.path}/busyapi-resource',
            ['--json'],
            workingDirectory: '/tmp',
            environment: const {
              'PATH': '',
              'LANG': 'C.UTF-8',
              'NODE_OPTIONS': '--require=/nonexistent',
            },
            includeParentEnvironment: false,
          );
          expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
          expect(run.stderr, isEmpty);
          final result = jsonDecode(run.stdout as String) as Map;
          expect(result['complete'], true);
          expect(findings(result), findings(original));
          expect(result['resourcePackage']['identity'], plan.identity);
          if (version == '3.2.1' && json) {
            stage('standalone-loader-network-trace');
            final trace = '${temp.path}/package-network.trace';
            final monitored = await Process.run(
              '/usr/bin/strace',
              [
                '-f',
                '-e',
                'trace=network',
                '-o',
                trace,
                '${relocated.path}/busyapi-resource',
                '--json',
              ],
              workingDirectory: '/tmp',
              environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
              includeParentEnvironment: false,
            );
            expect(
              monitored.exitCode,
              0,
              reason: '${monitored.stdout}\n${monitored.stderr}',
            );
            expect(
              (jsonDecode(monitored.stdout as String) as Map)['complete'],
              true,
            );
            final connections = await File(trace).readAsString();
            expect(
              connections,
              isNot(contains('AF_INET')),
              reason: 'An ordinary offline package load must not even attempt an IP socket',
            );
          }
          stage('tampered-manifest-refusal');
          final manifestFile = File('${relocated.path}/resource-package.json'),
              manifestBytes = await File(
                '${relocated.path}/resource-package.json',
              ).readAsBytes();
          final altered =
              jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
          (altered['resources'] as List).first['path'] =
              '../outside-source.json';
          altered.remove('identity');
          altered['identity'] = textIdentity(jsonEncode(altered));
          await manifestFile.writeAsString('${jsonEncode(altered)}\n');
          await expectLater(
            ResourcePackage.open(relocated.path, engine),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'bundle.package.invalid',
              ),
            ),
          );
          await manifestFile.writeAsBytes(manifestBytes);
          stage('escaping-symlink-refusal');
          final first = (frozen.manifest['resources'] as List).first;
          final packagedFile = File('${relocated.path}/${first['path']}'),
              packagedBytes = await File('${relocated.path}/${first['path']}')
                  .readAsBytes();
          await packagedFile.delete();
          final outside = File('${temp.path}/outside-source.json');
          await outside.writeAsBytes(packagedBytes);
          await Link(packagedFile.path).create(outside.path);
          await expectLater(
            ResourcePackage.open(relocated.path, engine),
            throwsA(isA<CoreFailure>()),
          );
          await Link(packagedFile.path).delete();
          await packagedFile.writeAsBytes(packagedBytes);
          final modelRecord = (frozen.manifest['resources'] as List)
              .singleWhere((r) => r['resource'] == models.uri.toString());
          await File('${relocated.path}/${modelRecord['path']}')
              .writeAsString('{}');
          stage('changed-resource-refusal');
          final denied = await Process.run(
            '${relocated.path}/busyapi-resource',
            ['--json'],
            environment: const {'PATH': ''},
            includeParentEnvironment: false,
          );
          expect(denied.exitCode, 3);
          expect(jsonDecode(denied.stdout as String)['complete'], false);
          expect(
            jsonDecode(denied.stdout as String)['error']['code'],
            'bundle.package.changed',
          );
          stage('complete');
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
