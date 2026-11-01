import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

String _document(String version, String format, Map<String, Object?> schemas) {
  final value = <String, Object?>{
    if (version == '2.0') 'swagger': version else 'openapi': version,
    'info': {'title': 'Original 雪', 'version': 'business'},
    'paths': <String, Object?>{},
    if (version == '2.0') 'definitions': schemas
        else 'components': {'schemas': schemas},
  };
  return '\ufeff${format == 'yaml' ? '# Keep source\r\n' : ''}${jsonEncode(value).replaceAll('"EXACT"', '9007199254740993.00')}\r\n';
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      test('$version $format inline Markdown mapping keeps originals, stale review and one-step history', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-inline-markdown-');
        addTearDown(() => directory.delete(recursive: true));
        await Directory('${directory.path}/source').create();
        await Directory('${directory.path}/target').create();
        final source = File('${directory.path}/source/api.$format');
        final destination = File('${directory.path}/target/api.$format');
        final group = version == '2.0' ? '/definitions' : '/components/schemas';
        const description = '[Guide](./guide.md?q=0&empty=#part) ![図](./image.svg)\n\n`[code](./literal.md)`';
        await source.writeAsString(_document(version, format, {
          'Model': {'type': 'object', 'description': description, 'required': ['n'],
            'properties': {'n': {r'$ref': '#$group/Number'}}, 'x-exact': 'EXACT'},
          'Number': {'type': 'integer', 'minimum': 'EXACT'},
        }));
        await destination.writeAsString(_document(version, format, {
          'Use': {r'$ref': '../source/api.$format#$group/Model'},
        }));
        await File('${directory.path}/busyapi.yaml').writeAsString(
            'version: 1\nroots:\n  - {name: Source, path: source/api.$format}\n  - {name: Target, path: target/api.$format}\n');
        final original = source.readAsBytesSync(), originalTarget = destination.readAsBytesSync();
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(directory.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(destination.uri.toString());
        Future<RefactoringPlan> prepare() => project.planReferenceInlining({
          'root': buffer.id, 'resource': buffer.id,
          'generation': buffer.generation, 'pointer': '$group/Use',
        });
        final stale = await prepare();
        project.store.replace(buffer.id, buffer.text.replaceFirst('Original', 'Unsaved'));
        final working = buffer.bytes();
        await expectLater(project.applyRefactoring(stale), throwsA(isA<CoreFailure>()
            .having((e) => e.code, 'code', 'refactor.stale')));
        expect(buffer.bytes(), working);
        final plan = await prepare();
        await expectLater(project.applyRefactoring(plan, current: () => false), throwsA(isA<CoreFailure>()
            .having((e) => e.code, 'code', 'refactor.stale')));
        expect(buffer.bytes(), working);
        await project.applyRefactoring(plan);
        final accepted = buffer.bytes();
        final inspected = await project.inspectObject(buffer.id, buffer.id, '$group/Use');
        final text = inspected['value']['description'] as String;
        expect(text, contains(source.uri.resolve('./guide.md?q=0&empty=#part').toString().replaceAll('&', '&amp;')));
        expect(text, contains(source.uri.resolve('./image.svg').toString()));
        expect(text, contains('`[code](./literal.md)`'));
        expect(buffer.text, contains('9007199254740993.00'));
        expect(source.readAsBytesSync(), original);
        expect(destination.readAsBytesSync(), originalTarget);
        project.store.undo();
        expect(buffer.bytes(), working);
        project.store.redo();
        expect(buffer.bytes(), accepted);
        expect((await project.check(buffer.id))['complete'], true);
        await project.save(buffer);
        expect(destination.readAsBytesSync(), accepted);
        expect(source.readAsBytesSync(), original);
        final reopened = await BusyProject.open(directory.path, engine);
        addTearDown(reopened.close);
        expect((await reopened.check(destination.uri.toString()))['complete'], true);
        final fresh = await reopened.inspectObject(destination.uri.toString(), destination.uri.toString(), '$group/Use');
        expect(fresh['value']['description'], text);
      });

      test('$version $format file Markdown mapping is virtual, reversible and safely reopened', () async {
        final directory = await Directory.systemTemp.createTemp('busyapi-move-markdown-');
        addTearDown(() => directory.delete(recursive: true));
        await Directory('${directory.path}/source').create();
        await Directory('${directory.path}/target').create();
        final source = File('${directory.path}/source/api.$format');
        final destination = File('${directory.path}/target/api.$format');
        final group = version == '2.0' ? '/definitions' : '/components/schemas';
        await source.writeAsString(_document(version, format, {
          'Model': {'type': 'string', 'description': '[Guide](./guide.md) [local](#section)',
            'x-data': {'description': '[literal](./payload.md)'}, 'x-exact': 'EXACT'},
        }));
        final original = source.readAsBytesSync();
        await File('${directory.path}/busyapi.yaml').writeAsString(
            'version: 1\nroots:\n  - {name: API, path: source/api.$format}\n');
        final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
        addTearDown(engine.close);
        final project = await BusyProject.open(directory.path, engine);
        addTearDown(project.close);
        final buffer = await project.buffer(source.uri.toString());
        final stale = await project.planFileMove(buffer.id, destination.path);
        project.store.replace(buffer.id, buffer.text.replaceFirst('Original', 'Unsaved'));
        final working = buffer.bytes();
        await expectLater(project.applyRefactoring(stale), throwsA(isA<CoreFailure>()
            .having((e) => e.code, 'code', 'refactor.stale')));
        expect(buffer.id, source.uri.toString());
        expect(buffer.bytes(), working);
        final plan = await project.planFileMove(buffer.id, destination.path);
        expect(destination.existsSync(), false);
        await project.applyRefactoring(plan);
        expect(buffer.id, destination.uri.toString());
        final accepted = buffer.bytes();
        final expected = '[Guide](<${source.uri.resolve('./guide.md')}>) [local](#section)';
        final view = await project.inspectObject(buffer.id, buffer.id, '$group/Model');
        expect(view['value']['description'], expected);
        expect(view['value']['x-data']['description'], '[literal](./payload.md)');
        expect(source.readAsBytesSync(), original);
        expect(destination.existsSync(), false);
        project.store.undo();
        expect(buffer.id, source.uri.toString());
        expect(buffer.bytes(), working);
        project.store.redo();
        expect(buffer.id, destination.uri.toString());
        expect(buffer.bytes(), accepted);
        final publication = PublicationStore('${directory.path}/state');
        expect((await publication.save(project, [buffer])).complete, true);
        expect(destination.readAsBytesSync(), accepted);
        expect(source.existsSync(), false);
        final reopened = await BusyProject.open(directory.path, engine);
        addTearDown(reopened.close);
        final root = reopened.roots.single.id;
        expect(root, destination.uri.toString());
        expect((await reopened.check(root))['complete'], true);
        final fresh = await reopened.inspectObject(root, root, '$group/Model');
        expect(fresh['value']['description'], expected);
      });
    }
  }
}
