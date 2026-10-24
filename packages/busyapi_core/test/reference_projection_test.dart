import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _HeldReference extends EngineProcess {
  _HeldReference() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  bool malformed = false;
  Map<String, dynamic> Function(Map<String, dynamic>)? mutate;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'referencePage' && release != null) {
      entered!.complete();
      await release!.future;
    }
    final result = await super.request(method, params, requestId: requestId);
    if (method != 'referencePage') return result;
    if (malformed) return {...result, 'resource': 'file:///wrong.json'};
    return mutate?.call(result) ?? result;
  }
}

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    test(
      'shared Operation $version keeps paged occurrence owners in native pages and portable native HTML',
      () async {
        final temp = await Directory.systemTemp.createTemp(
              'busyapi-context-core-',
            ),
            engine = _HeldReference();
        BusyProject? project;
        try {
          final modern = version.startsWith('3.2'),
              method = modern ? '/additionalOperations/COPY' : '/get';
          final source = File('${temp.path}/root.json'),
              part = File('${temp.path}/part.json');
          final operation = {
            'operationId': 'Shared',
            'responses': {
              '204': {'description': 'No body'},
            },
          };
          final definition = jsonEncode({
            'Shared': modern
                ? {
                    'additionalOperations': {'COPY': operation},
                  }
                : {'get': operation},
          });
          final text = jsonEncode({
            'openapi': version,
            'info': {'title': 'Context owners', 'version': '1'},
            'paths': {
              for (var n = 0; n < 53; n++)
                '/path-$n': {
                  r'$ref': 'part.json#/Shared',
                  'servers': [
                    {'url': 'https://owner-$n.invalid'},
                  ],
                  'parameters': [
                    {
                      'in': 'query',
                      'name': 'p$n',
                      'description': 'Owner $n',
                      'schema': {'type': 'integer', 'minimum': 111},
                    },
                  ],
                },
            },
          }).replaceAll('111', '9007199254740993.00');
          await source.writeAsString(text);
          await part.writeAsString(definition);
          project = await BusyProject.open(source.path, engine);
          final root = project.roots.single.id,
              resource = part.uri.toString(),
              pointer = '/Shared$method',
              selected = '$root#/paths/~1path-52$method';
          await project.check(root);
          final neutral = await project.referencePage(root, resource, pointer);
          expect(neutral['contextCount'], 53);
          expect(neutral['contexts'], hasLength(50));
          expect(neutral['effective'], isEmpty);
          final page = await project.referencePage(
            root,
            resource,
            pointer,
            occurrence: selected,
          );
          expect(page['occurrence'], selected);
          expect(page['selectedContext']['path'], '/path-52');
          expect(
            (page['contexts'] as List).any(
              (context) => context['occurrence'] == selected,
            ),
            false,
          );
          final parameters = (page['effective'] as List).firstWhere(
            (field) => field['name'] == 'parameters',
          );
          expect(parameters['entries'][0]['name'], 'p52');
          expect(parameters['entries'][0]['source']['resource'], root);
          expect(() => parameters['entries'].clear(), throwsUnsupportedError);
          final last = await project.referencePage(
            root,
            resource,
            pointer,
            contextOffset: 50,
            occurrence: selected,
          );
          expect(last['contexts'], hasLength(3));
          expect(last['contexts'].last['occurrence'], selected);
          final definitionPage = await project.referencePage(
            root,
            resource,
            pointer,
            definitionOnly: true,
          );
          expect(definitionPage['occurrence'], null);
          expect(definitionPage['effective'], isEmpty);
          for (final mutation
              in <Map<String, dynamic> Function(Map<String, dynamic>)>[
                (page) => {...page, 'contextCount': 1},
                (page) => {...page, 'contextOffset': 1},
                (page) => {
                  ...page,
                  'selectedContext': {
                    ...page['selectedContext'] as Map,
                    'occurrence': '$root#/paths/~1wrong/get',
                  },
                },
                (page) => {
                  ...page,
                  'contexts': [
                    page['contexts'][0],
                    page['contexts'][0],
                    ...(page['contexts'] as List).skip(2),
                  ],
                },
              ]) {
            engine.mutate = mutation;
            await expectLater(
              project.referencePage(
                root,
                resource,
                pointer,
                occurrence: selected,
              ),
              throwsA(
                isA<CoreFailure>().having(
                  (e) => e.code,
                  'code',
                  'reference.response',
                ),
              ),
            );
          }
          engine.mutate = null;
          final plan = await project.prepareDocumentation(
            root,
            '${temp.path}/output 雪',
          );
          try {
            await plan.publish();
            final html = await File('${plan.destination}/index.html')
                    .readAsString(),
                metadata = await File('${plan.destination}/provenance.json')
                    .readAsString();
            expect(
              RegExp('data-busyapi-operation-context=').allMatches(html),
              hasLength(53),
            );
            expect(
              html,
              contains(
                'COPY /path-52'.replaceFirst('COPY', modern ? 'COPY' : 'GET'),
              ),
            );
            expect(html, contains('9007199254740993.00'));
            expect(html, contains('p52 (query)'));
            expect(html, contains('owner-52.invalid'));
            expect(html, isNot(contains(temp.path)));
            expect(metadata, isNot(contains(temp.path)));
            final provenance = jsonDecode(metadata)['provenance'] as List,
                shared = provenance.firstWhere(
                  (section) => section['source']['pointer'] == pointer,
                );
            expect(shared['contexts'], hasLength(53));
            expect(
              shared['contexts'].last['pathItem']['resource'],
              './root.json',
            );
            expect(
              shared['contexts'].last['effective'].firstWhere(
                (field) => field['name'] == 'servers',
              )['source']['pointer'],
              '/paths/~1path-52/servers',
            );
            expect(await source.readAsString(), text);
            expect(await part.readAsString(), definition);
          } finally {
            plan.close();
          }
        } finally {
          project?.close();
          await engine.close();
          await temp.delete(recursive: true);
        }
      },
    );
    test(
      'Reference $version shares unsaved physical snapshots and rejects stale or malformed pages',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-reference-core-',
        );
        final engine = _HeldReference();
        BusyProject? project;
        try {
          await File('${temp.path}/root.yaml').writeAsString(
            'openapi: $version\ninfo: {title: Read, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model: {\$ref: "model.json#/Model"}\n',
          );
          final file = File('${temp.path}/model.json');
          const original =
              '{"Model":{"type":"object","description":"Disk","const":{"n":9007199254740993,"f":false,"z":0,"v":null,"\$ref":"payload"}}}';
          await file.writeAsString(original);
          project = await BusyProject.open(temp.path, engine);
          final root = project.roots.single.id;
          await project.check(root);
          final occurrence = await project.referencePage(
            root,
            root,
            '/components/schemas/Model',
          );
          final target = occurrence['references'][0]['target'];
          expect(target['resource'], Uri.file(file.path).toString());
          final buffer = await project.buffer(target['resource'] as String);
          project.store.replace(
            buffer.id,
            original.replaceFirst('Disk', 'Unsaved'),
          );
          final page = await project.referencePage(root, buffer.id, '/Model');
          expect(
            (page['entries'] as List).firstWhere(
              (f) => f['name'] == 'description',
            )['text'],
            'Unsaved',
          );
          final data = await project.referencePage(
            root,
            buffer.id,
            '/Model/const',
          );
          expect(data['references'], isEmpty);
          expect(
            (data['entries'] as List).firstWhere(
              (f) => f['name'] == 'n',
            )['text'],
            '9007199254740993',
          );
          expect(await file.readAsString(), original);
          engine.entered = Completer();
          engine.release = Completer();
          final pending = project.referencePage(root, buffer.id, '/Model');
          await engine.entered!.future;
          project.store.replace(
            buffer.id,
            buffer.text.replaceFirst('Unsaved', 'Newer'),
          );
          engine.release!.complete();
          await expectLater(
            pending,
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'reference.stale',
              ),
            ),
          );
          engine.release = null;
          engine.malformed = true;
          await expectLater(
            project.referencePage(root, buffer.id, '/Model'),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'reference.response',
              ),
            ),
          );
          engine.malformed = false;
          await expectLater(
            project.referencePage(
              root,
              Uri.file('${temp.path}/unapproved.json').toString(),
              '',
            ),
            throwsA(
              isA<CoreFailure>().having(
                (e) => e.code,
                'code',
                'inspect.resource',
              ),
            ),
          );
          expect(await file.readAsString(), original);
        } finally {
          if (engine.release != null && !engine.release!.isCompleted)
            engine.release!.complete();
          project?.close();
          await engine.close();
          await temp.delete(recursive: true);
        }
      },
    );
  }
}
