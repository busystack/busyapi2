import 'dart:async';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late EngineProcess engine;
  BusyProject? project;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'busyapi-corrective-lifecycle-',
    );
    engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  });
  tearDown(() async {
    project?.close();
    project = null;
    await engine.close();
    await temp.delete(recursive: true);
  });

  Future<OperationRequestPlan> prepare(String text) async {
    final file = File('${temp.path}/openapi.yaml')..writeAsStringSync(text);
    project = await BusyProject.open(temp.path, engine);
    final checked = await project!.check(file.uri.toString());
    final operation = (checked['projection']['operations'] as List).single;
    return project!.prepareRequest(
      file.uri.toString(),
      resource: operation['resource'] as String,
      pointer: operation['pointer'] as String,
      occurrence: operation['occurrence'] as String,
    );
  }

  for (final scopes in [
    "'read write'",
    "[write, '']",
    '[write, 17]',
    "[write, 'two words']",
  ]) {
    test('F07 malformed scopes $scopes acquire no callback receiver', () async {
      File('${temp.path}/busyapi.yaml').writeAsStringSync('''version: 1
roots: [{name: api, path: openapi.yaml}]
environments: {local: {authentication: {alternative: 0, schemes: {oauth: {clientId: desktop, scopes: $scopes}}}}}
''');
      final plan = await prepare('''openapi: 3.2.1
info: {title: Malformed scopes, version: '1'}
components: {securitySchemes: {oauth: {type: oauth2, flows: {authorizationCode: {authorizationUrl: http://127.0.0.1:1/authorize, tokenUrl: http://127.0.0.1:1/token, scopes: {write: Write}}}}}}
paths: {/private: {get: {security: [{oauth: [write]}], responses: {'204': {description: ok}}}}}
''');
      addTearDown(plan.close);
      var binds = 0, launches = 0;
      await expectLater(
        OAuthClient(
          bindCallbackReceiver: () async {
            binds++;
            throw StateError('A malformed scope must fail before binding');
          },
        ).authorizationCode(
          plan,
          environment: 'local',
          scheme: 'oauth',
          cancellation: RunCancellation(),
          launchBrowser: (_) async {
            launches++;
          },
        ),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'oauth.scopes'),
        ),
      );
      expect(binds, 0);
      expect(launches, 0);
    });
  }

  for (final closeOwner in [false, true]) {
    test(
      'F12 ${closeOwner ? 'closed owner' : 'cancellation'} cleans a directory acquired after a gated create',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          request.response.write('body');
          await request.response.close();
        });
        final plan = await prepare('''openapi: 3.2.1
info: {title: Directory ownership, version: '1'}
servers: [{url: 'http://127.0.0.1:${server.port}'}]
paths: {/data: {get: {responses: {'200': {description: ok}}}}}
''');
        addTearDown(plan.close);
        final token = RunCancellation();
        final entered = Completer<void>(), release = Completer<Directory>();
        final directory = Directory('${temp.path}/owned-response');
        var storageOpened = false;
        final input = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(planIdentity: plan.identity),
          resolveSecret: (_) async => null,
        );
        final pending = ContractHttpTransport(
          createResponseDirectory: () {
            entered.complete();
            return release.future;
          },
          openResponseStorage: (_) async {
            storageOpened = true;
            throw StateError('Retired ownership must prevent storage opening');
          },
        ).send(input, cancellation: token);
        final checked = expectLater(
          pending,
          throwsA(
            isA<CoreFailure>().having(
              (e) => e.code,
              'code',
              closeOwner ? 'request.closed' : 'cancelled',
            ),
          ),
        );
        await entered.future;
        if (closeOwner) {
          plan.close();
        } else {
          token.cancel();
        }
        release.complete(await directory.create());
        await checked;
        expect(storageOpened, isFalse);
        expect(await directory.exists(), isFalse);
      },
    );
  }
}
