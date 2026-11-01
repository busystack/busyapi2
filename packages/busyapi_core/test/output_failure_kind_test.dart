import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _ClosingBundleEngine extends EngineProcess {
  _ClosingBundleEngine()
    : super(executable: runtimeNode, helper: runtimeHelper);

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'deriveBundle') await close();
    return super.request(method, params, requestId: requestId);
  }
}

String _source(String version, String format, {bool relative = true}) =>
    '${format == 'yaml' ? '# Preserve the original flow document\r\n' : ''}${const JsonEncoder.withIndent('  ').convert({
      'openapi': version,
      'info': {
        'title': 'Original output ownership 雪',
        'version': '1',
        'contact': {'url': relative ? 'contact' : 'https://example.invalid/contact'},
      },
      'paths': <String, Object?>{},
      'components': {
        'schemas': {
          'Use': {r'$ref': '#/info/contact'},
        },
      },
    })}\r\n';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format unsupported output retains typed kind, unsaved location and compiled CLI incomplete status',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-output-kind-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final file = File('${temp.path}/api.$format');
          final original = _source(version, format),
              originalBytes = [0xef, 0xbb, 0xbf, ...utf8.encode(original)];
          await file.writeAsBytes(originalBytes);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final root = project.roots.single.id,
              buffer = await project.buffer(root);
          project.store.replace(
            root,
            buffer.text.replaceFirst('Original', 'Captured unsaved'),
          );
          final captured = buffer.text;
          OutputAnalysisFailure? refusal;
          try {
            final output = await project.prepareBundle(
              root,
              '${temp.path}/native-output',
            );
            output.close();
          } on OutputAnalysisFailure catch (error) {
            refusal = error;
          }
          expect(refusal, isNotNull);
          expect(refusal!.code, 'schema.role.annotation');
          expect(refusal.kind, CoreFailureKind.unsupported);
          expect(outputFailureExitCode(refusal), 2);
          expect(refusal.analysis['complete'], true);
          expect(refusal.source!.resource, root);
          expect(refusal.source!.pointer, '/info/contact/url');
          expect(
            captured.substring(
              refusal.source!.range.start,
              refusal.source!.range.end,
            ),
            '"contact"',
          );
          expect(buffer.text, captured);
          expect(file.readAsBytesSync(), originalBytes);
          expect(Directory('${temp.path}/native-output').existsSync(), false);
          final output = '${temp.path}/cli-output';
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['bundle', file.path, '--output', output, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 2, reason: '${cli.stdout}\n${cli.stderr}');
          final report = jsonDecode(cli.stdout as String) as Map;
          expect(report['status'], 'incomplete');
          expect(report['complete'], false);
          expect(report['error']['code'], 'schema.role.annotation');
          expect(report['error']['source']['resource'], root);
          expect(report['error']['source']['pointer'], '/info/contact/url');
          final range = report['error']['source']['range'] as List;
          expect(
            original.substring(range[0] as int, range[1] as int),
            '"contact"',
          );
          expect(Directory(output).existsSync(), false);
          expect(file.readAsBytesSync(), originalBytes);
          expect(buffer.text, captured);
        },
      );
    }
  }
  test('a real helper closed during bundle preparation remains operational and publishes no output', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-output-engine-close-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/api.json')
      ..writeAsStringSync(_source('3.2.1', 'json', relative: false));
    final original = file.readAsBytesSync();
    final engine = _ClosingBundleEngine();
    addTearDown(engine.close);
    final project = await BusyProject.open(file.path, engine);
    addTearDown(project.close);
    OutputAnalysisFailure? failure;
    try {
      final output = await project.prepareBundle(
        project.roots.single.id,
        '${temp.path}/output',
      );
      output.close();
    } on OutputAnalysisFailure catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure!.code, 'engine.closed');
    expect(failure.kind, CoreFailureKind.operational);
    expect(outputFailureExitCode(failure), 3);
    expect(Directory('${temp.path}/output').existsSync(), false);
    expect(file.readAsBytesSync(), original);
  });
}
