import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'swagger_server_support.dart';
import 'test_support.dart';

void main() {
  for (final format in ['yaml', 'json']) {
    test(
      'Swagger $format invalid effective servers stay inspectable across unsaved corrections',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-swagger-server-reference-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final source = swaggerServerSource(format, '[::1]:8080');
        final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
        final file = File('${temp.path}/api.$format')
          ..writeAsBytesSync(original);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(file.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id,
            buffer = await project.buffer(project.roots.single.id);
        Future<Map> servers() async {
          final page = await project.referencePage(
            root,
            root,
            '/paths/~1items/get',
          );
          expect(page['kind'], 'operation');
          expect(page['previews'], isNotEmpty);
          return (page['effective'] as List).singleWhere(
            (dynamic field) => field['name'] == 'servers',
          ) as Map;
        }

        final valid = await servers();
        expect(valid['complete'], true);
        expect(valid['default'], [
          {'url': 'http://[::1]:8080/v1'},
        ]);
        for (final (before, after, pointer, code) in [
          ('[::1]:8080', 'user@[::1]:8080', '/host', 'swagger.host.syntax'),
          ('/v1', '/v1?q=1', '/basePath', 'swagger.basePath.syntax'),
          (
            format == 'yaml'
                ? 'schemes: [http]'
                : '"schemes": [\n          "http"\n        ]',
            format == 'yaml' ? 'schemes: http' : '"schemes": "http"',
            '/paths/~1items/get/schemes',
            'swagger.schemes.invalid',
          ),
        ]) {
          expect(source, contains(before));
          final changed = source.replaceFirst(before, after);
          project.store.replace(root, changed);
          expect((await project.check(root))['status'], 'invalid');
          final invalid = await servers();
          expect(invalid['complete'], false);
          expect(invalid['invalid'], true);
          expect(invalid['default'], isNull);
          expect(invalid['source']['pointer'], pointer);
          expect(invalid['source']['resource'], root);
          expect(invalid['source']['generation'], buffer.generation);
          expect(invalid['issues'][0]['code'], code);
          expect(invalid['issues'][0]['source']['pointer'], pointer);
          expect(file.readAsBytesSync(), original);
          project.store.undo();
          expect(buffer.text, source);
          expect((await project.check(root))['status'], 'complete');
          expect((await servers())['complete'], true);
          project.store.redo();
          expect((await servers())['complete'], false);
          project.store.undo();
        }
        await project.save(buffer);
        expect(file.readAsBytesSync(), original);
      },
    );
  }
}
