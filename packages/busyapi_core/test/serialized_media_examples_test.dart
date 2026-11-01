import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _wire =
    '{"id":9007199254740993.00,"flag":false,"empty":"","\$ref":"literal"}';

List<dynamic> _examples(Map<String, dynamic> result) =>
    result['categories']['openapi']['schema']['serializedExamples'] as List;

String _root(String version, String format, {bool versionedExample = false}) {
  final content = {
    'application/json': {
      'schema': {
        'type': 'object',
        'required': ['id', 'flag', 'empty', r'$ref'],
        'properties': {
          'id': {
            'type': 'integer',
            'enum': ['EXACT'],
          },
          'flag': {'const': false},
          'empty': {'type': 'string', 'maxLength': 0},
          r'$ref': {'const': 'literal'},
        },
        'additionalProperties': false,
      },
      'examples': {
        'Check': {
          r'$ref':
              './examples.$format#/${versionedExample ? 'components/examples/' : ''}Value',
        },
      },
    },
  };
  return (format == 'json'
          ? '${jsonEncode({
              'openapi': version,
              'info': {'title': 'Keep 雪', 'version': 'api-version'},
              'paths': {
                '/parts': {
                  'post': {
                    'requestBody': {'content': content},
                    'responses': {
                      '204': {'description': 'Empty'},
                    },
                  },
                },
              },
            })}\r\n'
          : '''# Keep original YAML and 雪\r
openapi: $version\r
info: {title: Keep 雪, version: api-version}\r
paths:\r
  /parts:\r
    post:\r
      requestBody: {content: ${jsonEncode(content)}}\r
      responses: {'204': {description: Empty}}\r
''')
      .replaceAll('"EXACT"', '9007199254740993.00');
}

String _shared(String format, {bool versioned = false}) {
  final value = {'serializedValue': _wire};
  if (versioned) {
    return format == 'json'
        ? '${jsonEncode({
            'openapi': '3.2.1',
            'info': {'title': 'Shared', 'version': 'unchanged'},
            'paths': <String, dynamic>{},
            'components': {
              'examples': {'Value': value},
            },
          })}\r\n'
        : 'openapi: 3.2.1\r\ninfo: {title: Shared, version: unchanged}\r\npaths: {}\r\ncomponents: {examples: {Value: ${jsonEncode(value)}}}\r\n';
  }
  return format == 'json'
      ? '${jsonEncode({'Value': value})}\r\n'
      : '# Preserve shared aliases\r\nx-source: &example ${jsonEncode(value)}\r\nValue: *example\r\n';
}

void main() {
  for (final version in ['3.2.0', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format serialized media captures unsaved source and CLI reports',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-serialized-example-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/api.$format'),
              shared = File('${directory.path}/examples.$format');
          final source = _root(version, format), original = _shared(format);
          await file.writeAsString(source);
          await shared.writeAsString(original);
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final buffer = await project.buffer(shared.uri.toString());
          final initial = await project.check(file.uri.toString());
          expect(initial['complete'], isTrue, reason: '${initial['findings']}');
          expect(_examples(initial), hasLength(1));
          expect(_examples(initial).single['valid'], isTrue);
          expect(_examples(initial).single['resource'], shared.uri.toString());
          expect(
            _examples(initial).single['pointer'],
            format == 'json'
                ? '/Value/serializedValue'
                : '/x-source/serializedValue',
          );
          final rounded = original.replaceFirst(
            '9007199254740993.00',
            '9007199254740992',
          );
          project.store.replace(buffer.id, rounded);
          final edited = await project.check(file.uri.toString());
          expect(edited['complete'], isTrue, reason: '${edited['findings']}');
          expect(edited['unsaved'], isTrue);
          expect(_examples(edited).single['valid'], isFalse);
          final finding = (edited['findings'] as List).singleWhere(
            (value) => value['code'] == 'example.serialization.incompatible',
          );
          expect(finding['resource'], shared.uri.toString());
          expect(finding['pointer'], _examples(initial).single['pointer']);
          expect(
            buffer.text.substring(
              finding['range'][0] as int,
              finding['range'][1] as int,
            ),
            contains('9007199254740992'),
          );
          final saved = await project.check(file.uri.toString(), saved: true);
          expect(_examples(saved).single['valid'], isTrue);
          final cli = await Process.run(
            '$testBundle/busyapi',
            ['check', file.path, '--json'],
            environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
          final output = jsonDecode(cli.stdout as String) as Map;
          final results = output['categories'].single['results'];
          expect(
            results['openapi']['schema']['serializedExamples'],
            _examples(saved),
          );
          expect(buffer.text, rounded);
          project.store.undo();
          expect(
            _examples(await project.check(file.uri.toString())).single['valid'],
            isTrue,
          );
          project.store.redo();
          expect(
            _examples(await project.check(file.uri.toString())).single['valid'],
            isFalse,
          );
          project.store.replace(
            buffer.id,
            original.replaceFirst('9007199254740993.00', ''),
          );
          final malformed = await project.check(file.uri.toString());
          expect(malformed['complete'], isTrue);
          expect(_examples(malformed).single['valid'], isFalse);
          project.store.replace(buffer.id, original);
          final root = await project.buffer(file.uri.toString());
          project.store.replace(
            root.id,
            source.replaceFirst('application/json', 'application/xml'),
          );
          final unsupported = await project.check(root.id);
          expect(unsupported['complete'], isFalse);
          expect(unsupported['status'], 'incomplete');
          expect(_examples(unsupported).single['complete'], isFalse);
          expect(_examples(unsupported).single['valid'], isFalse);
          expect(await file.readAsString(), source);
          expect(await shared.readAsString(), original);
        },
      );
    }
  }
  for (final format in ['yaml', 'json']) {
    test('3.1 $format media retains a referenced 3.2 Example family', () async {
      final directory = await Directory.systemTemp.createTemp(
        'busyapi-example-family-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/api.$format'),
          shared = File('${directory.path}/examples.$format');
      final source = _root('3.1.2', format, versionedExample: true),
          original = _shared(format, versioned: true);
      await file.writeAsString(source);
      await shared.writeAsString(original);
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final checked = await project.check(file.uri.toString());
      expect(checked['complete'], isTrue, reason: '${checked['findings']}');
      expect(_examples(checked).single['valid'], isTrue);
      expect(_examples(checked).single['resource'], shared.uri.toString());
      expect(
        _examples(checked).single['media']['resource'],
        file.uri.toString(),
      );
      expect(await file.readAsString(), source);
      expect(await shared.readAsString(), original);
    });
  }
}
