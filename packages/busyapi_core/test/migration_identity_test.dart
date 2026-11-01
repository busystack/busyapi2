import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final target in ['3.1.2', '3.0.4', '2.0']) {
    for (final format in ['yaml', 'json']) {
      test('$format document identity lowers to $target with safe publication', () async {
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-migration-identity-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/api.$format');
        final source = <String, Object?>{
          'openapi': '3.2.1',
          r'$self': 'https://contracts.invalid/api',
          'info': {
            'title': 'Original',
            'version': 'business',
            'description': '[Guide](guide.md) `literal.md`',
            'contact': {'url': './contact'},
          },
          'servers': [
            {'url': 'https://api.invalid'},
          ],
          'paths': {
            '/value': {
              'get': {
                'responses': {
                  '200': {
                    'description': 'Value',
                    'content': {
                      'application/json': {
                        'schema': {r'$ref': 'model'},
                      },
                    },
                  },
                },
              },
            },
          },
          'components': {
            'schemas': {
              'Model': {
                r'$id': 'model',
                'type': 'string',
                'enum': ['café'],
              },
            },
          },
        };
        final original = format == 'json'
            ? '${jsonEncode(source)}\r\n'
            : '# Keep document comments 雪\r\n${source.entries.map((entry) => '${jsonEncode(entry.key)}: ${jsonEncode(entry.value)}').join('\r\n')}\r\n';
        await file.writeAsString(original);
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(file.uri.toString());
        project.store.replace(buffer.id, original.replaceFirst('Original', 'Unsaved 雪'));
        final destination = '${directory.path}/converted';
        final review = await project.prepareMigration(
          buffer.id,
          destination,
          targetVersion: target,
        );
        addTearDown(review.close);
        expect(review.publishable, true, reason: '${review.result}');
        expect(review.unsaved, true);
        expect(review.result['producerVersion'], '34');
        await expectLater(
          review.publish(cancelled: () => true),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled')),
        );
        expect(await Directory(destination).exists(), false);
        project.store.replace(buffer.id, buffer.text.replaceFirst('Unsaved 雪', 'Changed 雪'));
        await expectLater(
          review.publish(),
          throwsA(isA<CoreFailure>().having((error) => error.code, 'code', 'migration.stale')),
        );
        expect(await Directory(destination).exists(), false);
        final fresh = await project.prepareMigration(buffer.id, destination, targetVersion: target);
        addTearDown(fresh.close);
        expect(fresh.publishable, true, reason: '${fresh.result}');
        await fresh.publish();
        final output = await BusyProject.open(destination, engine);
        addTearDown(output.close);
        final checked = await output.check(output.roots.single.id);
        expect(checked['complete'], true, reason: '$checked');
        expect(checked['projection']['specification']['declaredVersion'], target);
        final text = (await output.buffer(output.roots.single.id)).text;
        expect(text, contains('Changed 雪'));
        expect(text, contains('https://contracts.invalid/guide.md'));
        expect(text, contains('`literal.md`'));
        expect(text, contains('https://contracts.invalid/contact'));
        expect(text, isNot(contains(r'$self')));
        final standalone = File('${directory.path}/standalone/api.$format');
        await standalone.parent.create();
        await standalone.writeAsString(text);
        final reopened = await BusyProject.open(standalone.path, engine);
        addTearDown(reopened.close);
        final cold = await reopened.check(reopened.roots.single.id);
        expect(cold['complete'], true, reason: '$cold');
        expect(cold['projection']['specification']['declaredVersion'], target);
        expect(await file.readAsString(), original);
        expect(buffer.text, contains('Changed 雪'));
        expect(buffer.dirty, true);
      });
    }
  }
}
