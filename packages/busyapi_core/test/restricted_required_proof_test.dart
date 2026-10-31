import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

const _name = 'kind/~雪';

String _source(Map<String, Object?> value, String format) =>
    '${format == 'yaml' ? '# Keep required proof and CRLF\r\n' : ''}'
    '${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';

String _chain(String format, int length) => _source({
  for (var index = 0; index < length; index++)
    'Chain$index': index + 1 == length
        ? {
            'type': 'object',
            'required': [_name],
            'properties': {
              _name: {'type': 'string'},
            },
          }
        : {r'$ref': '#/Chain${index + 1}'},
}, format);

void main() {
  for (final version in ['3.0.0', '3.0.1', '3.0.2', '3.0.3', '3.0.4']) {
    for (final format in ['yaml', 'json']) {
      test(
        '$version $format inherited required limits retain source and incomplete CLI categories',
        () async {
          final directory = await Directory.systemTemp.createTemp('bpr-');
          addTearDown(() => directory.delete(recursive: true));
          final root = File('${directory.path}/api.$format');
          final shared = File('${directory.path}/shared.$format');
          final text = _source({
            'openapi': version,
            'info': {'title': 'Native required proof', 'version': 'business'},
            'paths': {},
            'components': {
              'schemas': {
                'Subject': {
                  'type': 'object',
                  'discriminator': {'propertyName': _name},
                  'allOf': [
                    {r'$ref': 'shared.$format#/Chain0'},
                  ],
                },
              },
            },
            'x-number': 'EXACT',
            'x-payload': {r'$ref': 'literal.json', 'empty': '', 'flag': false},
          }, format);
          await root.writeAsBytes([239, 187, 191, ...utf8.encode(text)]);
          await shared.writeAsBytes([
            239,
            187,
            191,
            ...utf8.encode(_chain(format, 8)),
          ]);
          final originalRoot = await root.readAsBytes();
          final originalShared = await shared.readAsBytes();
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final rootBuffer = await project.buffer(root.uri.toString());
          final sharedBuffer = await project.buffer(shared.uri.toString());
          Future<Map<String, dynamic>> cli(int exitCode) async {
            final result = await Process.run('$testBundle/busyapi', [
              'check',
              root.path,
              '--json',
            ]);
            expect(result.exitCode, exitCode, reason: result.stderr as String);
            return jsonDecode(result.stdout as String) as Map<String, dynamic>;
          }

          final initial = await project.check(rootBuffer.id);
          expect(initial['complete'], true, reason: jsonEncode(initial));
          expect(initial['status'], 'complete');
          expect((initial['versions'] as Map)['restrictedSchemaRules'], '2');
          expect((await cli(0))['complete'], true);
          project.store.replace(sharedBuffer.id, _chain(format, 130));
          final limited = await project.check(rootBuffer.id);
          expect(limited['complete'], false);
          expect(limited['status'], 'incomplete');
          expect(limited['unsaved'], true);
          final findings = (limited['findings'] as List).cast<Map>();
          expect(
            findings.where((note) => note['code'] == 'discriminator.required'),
            isEmpty,
          );
          final note = findings.singleWhere(
            (note) => note['code'] == 'discriminator.required.incomplete',
          );
          expect(note['resource'], rootBuffer.id);
          expect(
            note['pointer'],
            '/components/schemas/Subject/discriminator/propertyName',
          );
          expect(note['severity'], 'warning');
          expect(note['incomplete'], true);
          expect(
            rootBuffer.text.substring(
              note['range'][0] as int,
              note['range'][1] as int,
            ),
            contains(_name),
          );
          expect(await root.readAsBytes(), originalRoot);
          expect(await shared.readAsBytes(), originalShared);
          expect(
            (await project.check(rootBuffer.id, saved: true))['complete'],
            true,
          );
          project.store.undo();
          expect(sharedBuffer.bytes(), originalShared);
          expect((await project.check(rootBuffer.id))['complete'], true);
          project.store.redo();
          expect((await project.check(rootBuffer.id))['complete'], false);
          await project.save(sharedBuffer);
          expect((await cli(2))['complete'], false);
          expect(await root.readAsBytes(), originalRoot);
          final repaired = rootBuffer.text.replaceFirst(
            '"allOf":',
            '"required":["$_name"],"allOf":',
          );
          project.store.replace(rootBuffer.id, repaired);
          final checked = await project.check(rootBuffer.id);
          expect(checked['complete'], true, reason: jsonEncode(checked));
          expect(checked['status'], 'complete');
          expect((await cli(2))['complete'], false);
          await project.save(rootBuffer);
          expect((await cli(0))['complete'], true);
          expect(await root.readAsBytes(), rootBuffer.bytes());
          expect(await shared.readAsBytes(), sharedBuffer.bytes());
          expect(rootBuffer.text, contains('9007199254740993.00'));
          expect(rootBuffer.text, contains('literal.json'));
          final saved = await root.readAsBytes();
          await project.save(rootBuffer);
          expect(await root.readAsBytes(), saved);
        },
      );
    }
  }
}
