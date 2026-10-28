import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.0.4', '3.1.2', '3.2.1']) {
    for (final kind in ['array', 'server', 'variables', 'variable']) {
      test('$version $kind aliases retain captured HTTP and saved CLI ownership', () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-server-alias-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => endpoint.close(force: true));
        final received = <String>[];
        endpoint.listen((request) async {
          expect(request.method, 'GET');
          expect(
            request.headers.value(HttpHeaders.hostHeader),
            '127.0.0.1:${endpoint.port}',
          );
          expect(
            await request.fold<List<int>>([], (a, b) => a..addAll(b)),
            isEmpty,
          );
          received.add(request.uri.toString());
          request.response.statusCode = 204;
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${endpoint.port}';
        final declaration = switch (kind) {
          'array' => 'x-held: &held [{url: "$base/v1"}]\r\nservers: *held',
          'server' => 'x-held: &held {url: "$base/v1"}\r\nservers: [*held]',
          'variables' =>
            'x-held: &held {suffix: {default: v1}}\r\nservers: [{url: "$base/{suffix}", variables: *held}]',
          'variable' =>
            'x-held: &held {default: v1}\r\nservers: [{url: "$base/{suffix}", variables: {suffix: *held}}]',
          _ => throw StateError('Unexpected alias fixture $kind'),
        };
        final source =
            '# Keep Server aliases 雪\r\nopenapi: "$version"\r\n'
            'info: {title: "Aliased server", version: "API-1"}\r\n'
            '$declaration\r\nx-copy: *held\r\n'
            'paths: {/items: {get: {responses: {"204": {description: "No body"}}}}}\r\n'
            'x-exact: 9007199254740993.00\r\n';
        final original = [0xef, 0xbb, 0xbf, ...utf8.encode(source)];
        final file = File('${temp.path}/api.yaml')..writeAsBytesSync(original);
        final manifest = File('${temp.path}/busyapi.yaml')
          ..writeAsStringSync(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.yaml'},
              ],
              'tests': [
                {
                  'name': 'alias',
                  'operation': {'method': 'get', 'path': '/items'},
                  'expect': {'status': 204},
                },
              ],
            }),
          );
        final manifestBytes = manifest.readAsBytesSync();
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: runtimeHelper,
        );
        addTearDown(engine.close);
        final project = await BusyProject.open(temp.path, engine);
        addTearDown(project.close);
        final root = project.roots.single.id,
            buffer = await project.buffer(project.roots.single.id);
        project.store.replace(root, buffer.text.replaceFirst('v1', 'v雪'));
        final working = buffer.text;
        expect((await project.check(root))['status'], 'complete');
        expect(
          (await project.referencePage(
            root,
            root,
            '/paths/~1items/get',
          ))['complete'],
          true,
        );
        final plan = await project.prepareRequest(
          root,
          resource: root,
          pointer: '/paths/~1items/get',
        );
        try {
          final servers = plan.result['servers'] as List;
          expect(servers, hasLength(1));
          expect(servers[0]['source']['resource'], root);
          expect(servers[0]['source']['pointer'], '/servers/0');
          expect(servers[0]['urlSource']['resource'], root);
          expect(servers[0]['urlSource']['pointer'], '/servers/0/url');
          final result = await const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(planIdentity: plan.identity),
            resolveSecret: (_) async => throw StateError('No credentials'),
          );
          try {
            expect(result.conforming, true);
            expect(result.response.status, 204);
          } finally {
            await result.close();
          }
        } finally {
          plan.close();
        }
        expect(received, ['/v%E9%9B%AA/items']);
        expect(buffer.text, working);
        expect(file.readAsBytesSync(), original);
        final cli = await Process.run(
          '$testBundle/busyapi',
          ['test', temp.path, '--case', 'alias', '--json'],
          environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
          includeParentEnvironment: false,
        );
        expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
        final report = jsonDecode(cli.stdout as String) as Map;
        expect(report['complete'], true);
        expect(report['passed'], true);
        expect(report['cases'][0]['dispatched'], true);
        expect(report['cases'][0]['operationalFailure'], false);
        expect(received, ['/v%E9%9B%AA/items', '/v1/items']);
        project.store.replace(root, source);
        await project.save(buffer);
        expect(file.readAsBytesSync(), original);
        expect(manifest.readAsBytesSync(), manifestBytes);
      });
    }
  }
}
