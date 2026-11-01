import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _EvaluationEngine extends EngineProcess {
  _EvaluationEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  String? fault;
  int badCatalogues = 0;
  int evaluations = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'standardResource' &&
        params['list'] == true &&
        badCatalogues > 0) {
      badCatalogues--;
      return {'version': 1, 'identities': 'malformed'};
    }
    if (method == 'evaluateSchemas') {
      evaluations++;
      final gate = release;
      if (gate != null) {
        release = null;
        entered?.complete();
        await gate.future;
      }
      if (fault == 'crash')
        throw CoreFailure('engine.exit', 'Synthetic adapter exit');
      if (fault == 'malformed')
        return {
          'version': 1,
          'snapshot': params['snapshot'],
          'complete': true,
          'findings': [],
        };
    }
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'evaluateSchemas' && fault?.startsWith('example-') == true) {
      final location = {'resource': params['root'], 'pointer': ''};
      final proof = <String, Object?>{
        ...location,
        'complete': true,
        'valid': true,
      };
      switch (fault) {
        case 'example-mixed-owners':
          proof.addAll({'parameter': location, 'header': location});
        case 'example-missing-owner':
          break;
        case 'example-unknown-owner':
          proof['header'] = {
            'resource': 'file:///uncaptured.json',
            'pointer': '',
          };
        case 'example-forged-media':
          proof.addAll({
            'parameter': location,
            'mediaType': 'application/json',
          });
        case 'example-invalid-status':
          proof.addAll({'header': location, 'complete': false});
        case 'example-null-owner':
          proof.addAll({'parameter': location, 'media': null});
        case 'example-bad-media-field':
          proof.addAll({
            'media': location,
            'mediaType': 'application/json',
            'field': 'dataValue',
          });
        case 'example-nonmedia-field':
          proof.addAll({'header': location, 'field': 'value'});
      }
      result['serializedEvaluations'] = [proof];
    }
    return result;
  }
}

String contract(String version) =>
    '''{"openapi":"$version","info":{"title":"Schema checks","version":"1"},"paths":{},"components":{"schemas":{"Count":{"type":"integer","minimum":9007199254740993,"examples":[9007199254740993,9007199254740992]}}}}''';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'schema identity/dialect checks retain current source and headless exit categories $version $json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-schema-identity-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}');
          final illegal = json
              ? '"\$schema":"https://json-schema.org/draft/2020-12/schema",'
              : '\$schema: "https://json-schema.org/draft/2020-12/schema", ';
          final text = json
              ? '{"openapi":"$version","info":{"title":"Identity 🐾","version":"1"},"paths":{},"components":{"schemas":{"Good":{"\$id":"https://schemas.invalid/good#","\$dynamicAnchor":"node","type":"object","properties":{"child":{"\$dynamicRef":"#node"}},"examples":[{"child":{}}]},"Bad":{"type":"object","properties":{"value":{$illegal"type":"integer"}}}}}}'
              : 'openapi: $version\r\ninfo: {title: "Identity 🐾", version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Good:\n      \$id: https://schemas.invalid/good#\n      \$dynamicAnchor: node\n      type: object\n      properties: {child: {\$dynamicRef: "#node"}}\n      examples: [{child: {}}]\n    Bad:\n      type: object\n      properties: {value: {$illegal type: integer}} # preserve';
          await file.writeAsBytes([239, 187, 191, ...utf8.encode(text)]);
          final original = await file.readAsBytes();
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final b = await project.buffer(file.uri.toString());
          final invalid = await project.check(b.id);
          expect(invalid['complete'], true, reason: jsonEncode(invalid));
          expect(invalid['status'], 'invalid');
          final finding = (invalid['findings'] as List).cast<Map>().firstWhere(
            (f) => f['code'] == 'schema.dialect.location',
          );
          expect(finding['resource'], b.id);
          expect(
            finding['pointer'],
            '/components/schemas/Bad/properties/value/\$schema',
          );
          expect(
            b.text.substring(
              finding['range'][0] as int,
              finding['range'][1] as int,
            ),
            contains('json-schema.org'),
          );
          final cliInvalid = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(cliInvalid.exitCode, 1, reason: cliInvalid.stderr as String);
          project.store.replace(b.id, b.text.replaceFirst(illegal, ''));
          final repaired = await project.check(b.id);
          expect(repaired['complete'], true, reason: jsonEncode(repaired));
          expect(repaired['status'], 'complete');
          expect(await file.readAsBytes(), original);
          project.store.undo();
          expect(b.bytes(), original);
          project.store.redo();
          await project.save(b);
          final cliValid = await Process.run('$testBundle/busyapi', [
            'check',
            file.path,
            '--json',
          ]);
          expect(cliValid.exitCode, 0, reason: cliValid.stderr as String);
          expect(await file.readAsBytes(), b.bytes());
        },
      );
    }
  }
  test('a malformed standard catalogue cannot return clean checks or poison a later retry', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-standard-retry-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(
        contract('3.2.1').replaceFirst(
          '"type":"integer"',
          '"type":"integer","\$ref":"https://json-schema.org/draft/2020-12/meta/validation"',
        ),
      );
    final engine = _EvaluationEngine()..badCatalogues = 1;
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final failed = await project.check(file.uri.toString());
    expect(failed['complete'], false);
    expect(failed['status'], 'incomplete');
    final retried = await project.check(file.uri.toString());
    expect(retried['complete'], true, reason: jsonEncode(retried['findings']));
  });
  test('bundled 2020-12 standards join the canonical graph without remote permission or editable buffers', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-bundled-schema-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(
        jsonEncode({
          'openapi': '3.2.1',
          'info': {'title': 'Meta', 'version': '1'},
          'paths': {},
          'components': {
            'schemas': {
              'Meta': {
                r'$ref': 'https://json-schema.org/draft/2020-12/schema',
                'examples': [
                  {'minLength': 1},
                  {'minLength': -1},
                ],
              },
            },
          },
        }),
      );
    final before = file.readAsBytesSync(), engine = _EvaluationEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final result = await project.check(file.uri.toString());
    expect(result['complete'], true, reason: jsonEncode(result['findings']));
    expect(
      (result['findings'] as List).where(
        (f) => f['code'] == 'example.schema.incompatible',
      ),
      hasLength(1),
    );
    expect(
      (result['references'] as List).every(
        (ref) => ref['resolution'] == 'resolved',
      ),
      true,
    );
    expect((result['resources'] as List).length, greaterThan(1));
    expect(project.approvedResources, isEmpty);
    expect(project.store.buffers, isEmpty);
    expect((await project.refreshResources()).resources, isEmpty);
    await expectLater(
      project.buffer('https://json-schema.org/draft/2020-12/schema'),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'resource.readonly'),
      ),
    );
    final second = await project.check(file.uri.toString(), saved: true);
    expect(second['snapshot'], result['snapshot']);
    expect(second['findings'], result['findings']);
    expect(file.readAsBytesSync(), before);
  });
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'schema checks are exact, source-located and CLI-identical $version',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-schema-parity-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/root.json')
          ..writeAsStringSync(contract(version));
        final original = file.readAsBytesSync();
        final engine = _EvaluationEngine();
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(file.uri.toString());
        Map<String, dynamic>? progress;
        final checked = await project.check(
          buffer.id,
          onProgress: (value) => progress = value,
        );
        expect(progress!['status'], 'checking');
        expect(progress!['complete'], false);
        expect(progress!['categories']['openapi']['complete'], false);
        expect(checked['complete'], true);
        expect(
          checked['status'],
          'complete',
          reason: 'Example compatibility is advice, not normative runtime conformance',
        );
        final finding = (checked['findings'] as List).singleWhere(
          (f) => f['code'] == 'example.schema.incompatible',
        );
        expect(finding['resource'], buffer.id);
        expect(finding['pointer'], '/components/schemas/Count/examples/1');
        expect(finding['snapshot'], checked['snapshot']);
        expect(
          buffer.text.substring(
            finding['range'][0] as int,
            finding['range'][1] as int,
          ),
          '9007199254740992',
        );
        expect(checked['categories']['openapi']['schema']['instances'], 2);
        final cli = await Process.run(
          '$testBundle/busyapi',
          ['check', file.path, '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
        expect(cli.stderr, isEmpty);
        final output = jsonDecode(cli.stdout as String);
        final saved = await project.check(buffer.id, saved: true);
        expect(output['findings'], saved['findings']);
        expect(output['categories'].single['results'], saved['categories']);
        expect(output['snapshots'].single, saved['snapshot']);
        expect(file.readAsBytesSync(), original);
      },
    );
  }
  test('structural progress remains usable while evaluation owns a frozen snapshot; later buffer edits reject its result', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-schema-stale-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(contract('3.2.1'));
    final engine = _EvaluationEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    final buffer = await project.buffer(file.uri.toString());
    engine.entered = Completer<void>();
    final gate = Completer<void>();
    engine.release = gate;
    final progress = <Map<String, dynamic>>[];
    final pending = project.check(buffer.id, onProgress: progress.add);
    await engine.entered!.future;
    expect(progress, hasLength(1));
    final inspected = await project.inspectObject(
      buffer.id,
      buffer.id,
      '/components/schemas/Count',
    );
    expect(inspected['kind'], 'schema');
    expect(engine.evaluations, 1);
    project.store.replace(
      buffer.id,
      buffer.text.replaceAll('9007199254740992', '9007199254740994'),
    );
    gate.complete();
    final checked = await pending;
    expect(engine.evaluations, 2);
    expect(progress, hasLength(2));
    expect(checked['findings'], isEmpty);
    expect(checked['unsaved'], true);
    expect(file.readAsStringSync(), contract('3.2.1'));
  });
  test('saved-input external changes and cancellation cannot publish a stale completed evaluation', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-schema-disk-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/root.json')
      ..writeAsStringSync(contract('3.2.1'));
    final engine = _EvaluationEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    engine.entered = Completer<void>();
    final gate = Completer<void>();
    engine.release = gate;
    final pending = project.check(file.uri.toString(), saved: true);
    await engine.entered!.future;
    file.writeAsStringSync(
      contract('3.2.1').replaceAll('9007199254740992', '9007199254740994'),
    );
    gate.complete();
    expect((await pending)['findings'], isEmpty);
    expect(engine.evaluations, 2);
    engine.entered = Completer<void>();
    final cancelGate = Completer<void>();
    engine.release = cancelGate;
    var cancelled = false;
    final cancelledRun = project.check(
      file.uri.toString(),
      saved: true,
      cancelled: () => cancelled,
    );
    final expected = expectLater(
      cancelledRun,
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    await engine.entered!.future;
    cancelled = true;
    cancelGate.complete();
    await expected;
  });
  for (final fault in [
    'crash',
    'malformed',
    'example-mixed-owners',
    'example-missing-owner',
    'example-unknown-owner',
    'example-forged-media',
    'example-invalid-status',
    'example-null-owner',
    'example-bad-media-field',
    'example-nonmedia-field',
  ]) {
    test(
      'failed or malformed schema adapter is incomplete, never empty success: $fault',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-schema-failure-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/root.json')
          ..writeAsStringSync(contract('3.2.1'));
        final engine = _EvaluationEngine()..fault = fault;
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final checked = await project.check(file.uri.toString());
        expect(checked['complete'], false);
        expect(checked['status'], 'incomplete');
        expect(checked['categories']['openapi']['schema']['complete'], false);
        expect(
          (checked['findings'] as List).any(
            (f) => f['code'] == 'schema.execution.incomplete',
          ),
          true,
        );
        expect(
          checked['projection']['info']['value']['title'],
          'Schema checks',
        );
        expect(file.readAsStringSync(), contract('3.2.1'));
      },
    );
  }
}
