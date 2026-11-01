import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

Future<SecurityContext> certificates(Directory directory) async {
  final target = Directory('${directory.path}/certs')..createSync();
  Future<void> openssl(List<String> arguments) async {
    final result = await Process.run(
      '/usr/bin/openssl',
      arguments,
      workingDirectory: target.path,
      environment: const {'PATH': '', 'LC_ALL': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(
      result.exitCode,
      0,
      reason: 'openssl ${arguments.first}: ${result.stderr}',
    );
  }

  await openssl([
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-days',
    '1',
    '-subj',
    '/CN=BusyAPI custom-method test CA',
    '-keyout',
    'ca.key',
    '-out',
    'ca.crt',
  ]);
  for (final role in ['server', 'client']) {
    await openssl([
      'req',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=BusyAPI fixture $role',
      '-keyout',
      '$role.key',
      '-out',
      '$role.csr',
    ]);
    File('${target.path}/$role.ext').writeAsStringSync(
      role == 'server'
          ? 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n'
          : 'extendedKeyUsage=clientAuth\n',
    );
    await openssl([
      'x509',
      '-req',
      '-in',
      '$role.csr',
      '-CA',
      'ca.crt',
      '-CAkey',
      'ca.key',
      '-set_serial',
      role == 'server' ? '1' : '2',
      '-days',
      '1',
      '-extfile',
      '$role.ext',
      '-out',
      '$role.crt',
    ]);
  }
  return SecurityContext(withTrustedRoots: false)
    ..useCertificateChain('${target.path}/server.crt')
    ..usePrivateKey('${target.path}/server.key')
    ..setTrustedCertificates('${target.path}/ca.crt');
}

Future<({BusyProject project, String root, String original})> openProject(
  Directory directory,
  Uri server, {
  Map<String, Object?> environments = const {},
  List<Map<String, Object?>> cases = const [],
  bool includeTrace = false,
}) async {
  final original = jsonEncode({
    'openapi': '3.2.1',
    'info': {'title': 'Custom-method TLS', 'version': '1'},
    'servers': [
      {'url': server.toString()},
    ],
    if (includeTrace)
      'components': {
        'securitySchemes': {
          'Client': {'type': 'mutualTLS'},
        },
      },
    'paths': {
      '/tls': {
        if (includeTrace)
          'trace': {
            'security': [
              {'Client': <String>[]},
            ],
            'responses': {
              '200': {
                'description': 'Verified',
                'content': {
                  'application/json': {
                    'schema': {
                      'type': 'object',
                      'required': ['verified'],
                    },
                  },
                },
              },
            },
          },
        'additionalOperations': {
          for (final method in ['purge', 'head'])
            method: {
              'requestBody': {
                'required': true,
                'content': {
                  'text/plain': {
                    'schema': {'type': 'string'},
                  },
                },
              },
              'responses': {
                '200': {
                  'description': 'Verified',
                  'content': {
                    'application/json': {
                      'schema': {
                        'type': 'object',
                        'required': ['verified'],
                      },
                    },
                  },
                },
              },
            },
        },
      },
    },
  });
  final file = File('${directory.path}/api.json')..writeAsStringSync(original);
  if (environments.isNotEmpty || cases.isNotEmpty)
    File('${directory.path}/busyapi.yaml').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'roots': [
          {'name': 'api', 'path': 'api.json'},
        ],
        'environments': environments,
        if (cases.isNotEmpty) 'tests': cases,
      }),
    );
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  addTearDown(engine.close);
  final project = await BusyProject.open(file.path, engine);
  addTearDown(project.close);
  return (project: project, root: file.uri.toString(), original: original);
}

Future<OperationRequestPlan> methodPlan(
  BusyProject project,
  String root,
  String method,
) async {
  final checked = await project.check(root);
  expect(checked['complete'], true, reason: '$checked');
  final operation = (checked['projection']['operations'] as List)
      .whereType<Map>()
      .singleWhere((value) => httpOperationMethod(value) == method);
  final plan = await project.prepareRequest(
    root,
    resource: operation['resource'] as String,
    pointer: operation['pointer'] as String,
    occurrence: operation['occurrence'] as String,
  );
  addTearDown(plan.close);
  return plan;
}

void main() {
  test('case-sensitive native requests retain selected trust, hostname verification and mutual TLS', () async {
    final directory = await Directory.systemTemp.createTemp(
      'busyapi-custom-tls-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final context = await certificates(directory);
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requireClientCertificate: true,
    );
    final sockets = <Socket>{}, handshakeErrors = <Object>[];
    addTearDown(() async {
      for (final socket in sockets.toList()) {
        socket.destroy();
      }
      await server.close();
    });
    final seen = <({String line, String body, String? client})>[];
    var echo = false;
    server.listen((socket) async {
      sockets.add(socket);
      try {
        final bytes = <int>[];
        await for (final chunk in socket) {
          bytes.addAll(chunk);
          expect(bytes.length, lessThan(2 * 1024 * 1024));
          final text = latin1.decode(bytes), end = text.indexOf('\r\n\r\n');
          if (end < 0) continue;
          final length = int.parse(
            RegExp(
                  r'^content-length:\s*(\d+)',
                  caseSensitive: false,
                  multiLine: true,
                ).firstMatch(text.substring(0, end))?.group(1) ??
                '0',
          );
          if (bytes.length < end + 4 + length) continue;
          seen.add((
            line: text.split('\r\n').first,
            body: utf8.decode(bytes.sublist(end + 4, end + 4 + length)),
            client: socket.peerCertificate?.subject,
          ));
          final response = utf8.encode(
            jsonEncode({'verified': true, if (echo) 'echo': seen.last.body}),
          );
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${response.length}\r\nConnection: close\r\n\r\n',
            ),
          );
          socket.add(response);
          await socket.flush();
          await socket.close();
          break;
        }
      } finally {
        sockets.remove(socket);
        socket.destroy();
      }
    }, onError: (Object error) => handshakeErrors.add(error));
    final tls = {
      'caFile': 'certs/ca.crt',
      'clientCertificateFile': 'certs/client.crt',
      'clientKeyFile': 'certs/client.key',
    };
    final fixture = await openProject(
      directory,
      Uri.parse('https://127.0.0.1:${server.port}'),
      includeTrace: true,
      environments: {
        'secure': {
          'tls': tls,
          'authentication': {
            'schemes': {'Client': <String, Object?>{}},
          },
        },
        'untrusted': {
          'tls': {
            'clientCertificateFile': 'certs/client.crt',
            'clientKeyFile': 'certs/client.key',
          },
        },
        'wrongName': {
          'baseUrl': 'https://localhost:${server.port}',
          'tls': tls,
        },
      },
      cases: [
        {
          'name': 'aot',
          'operation': {'method': 'purge', 'path': '/tls'},
          'body': {'mediaType': 'text/plain', 'value': 'AOT TLS body'},
          'expect': {'status': 200},
        },
      ],
    );
    for (final method in ['purge', 'head']) {
      final plan = await methodPlan(fixture.project, fixture.root, method);
      final result = await const ContractRequestExecutor().execute(
        plan,
        OperationRequestDraft(
          planIdentity: plan.identity,
          environment: 'secure',
          body: const RequestBodyDraft.raw(
            mediaType: 'text/plain',
            text: '雪😀 BUSYAPI body',
          ),
        ),
        resolveSecret: (_) async => null,
      );
      addTearDown(result.close);
      expect(result.conforming, true, reason: '${result.received.findings}');
      expect(seen.last.line, '$method /tls HTTP/1.1');
      expect(seen.last.body, '雪😀 BUSYAPI body');
      expect(seen.last.client, contains('BusyAPI fixture client'));
      expect(
        await result.response.decodedBytes(),
        utf8.encode('{"verified":true}'),
      );
      for (final environment in ['untrusted', 'wrongName']) {
        final call = const ContractRequestExecutor().execute(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            environment: environment,
            body: const RequestBodyDraft.raw(
              mediaType: 'text/plain',
              text: 'untrusted must not arrive',
            ),
          ),
          resolveSecret: (_) async => null,
        );
        await expectLater(
          call,
          throwsA(
            isA<CoreFailure>().having(
              (failure) => failure.code,
              'TLS failure',
              'request.tls',
            ),
          ),
        );
      }
    }
    final tracePlan = await methodPlan(fixture.project, fixture.root, 'TRACE');
    final traceResult = await const ContractRequestExecutor().execute(
      tracePlan,
      OperationRequestDraft(
        planIdentity: tracePlan.identity,
        environment: 'secure',
        securityAlternative: 0,
      ),
      resolveSecret: (_) async =>
          throw StateError('TLS credentials must not become HTTP secrets'),
    );
    addTearDown(traceResult.close);
    expect(traceResult.conforming, true);
    expect(seen.last.line, 'TRACE /tls HTTP/1.1');
    expect(seen.last.body, isEmpty);
    expect(seen.last.client, contains('BusyAPI fixture client'));
    final cli = await Process.run(
      '$testBundle/busyapi',
      [
        'test',
        directory.path,
        '--case',
        'aot',
        '--environment',
        'secure',
        '--json',
      ],
      environment: const {'PATH': '', 'LANG': 'C.UTF-8'},
      includeParentEnvironment: false,
    );
    expect(cli.exitCode, 0, reason: '${cli.stdout}\n${cli.stderr}');
    final cliReport = jsonDecode(cli.stdout as String) as Map;
    expect(cliReport['complete'], true);
    expect((cliReport['cases'] as List).single['passed'], true);
    expect(seen.last.line, 'purge /tls HTTP/1.1');
    expect(seen.last.body, 'AOT TLS body');
    expect(seen.last.client, contains('BusyAPI fixture client'));
    echo = true;
    final large = List.filled(50000, '雪😀\u0000BUSYAPI ').join();
    final largePlan = await methodPlan(fixture.project, fixture.root, 'purge');
    final largeResult = await const ContractRequestExecutor().execute(
      largePlan,
      OperationRequestDraft(
        planIdentity: largePlan.identity,
        environment: 'secure',
        body: RequestBodyDraft.raw(mediaType: 'text/plain', text: large),
      ),
      resolveSecret: (_) async => null,
    );
    addTearDown(largeResult.close);
    expect(
      largeResult.conforming,
      true,
      reason: '${largeResult.received.findings}',
    );
    expect(seen.last.body, large);
    final expected = utf8.encode(jsonEncode({'verified': true, 'echo': large}));
    expect(File(largeResult.response.bodyFile).readAsBytesSync(), expected);
    expect(await largeResult.response.decodedBytes(), expected);
    expect(seen, hasLength(5));
    expect(
      File.fromUri(Uri.parse(fixture.root)).readAsStringSync(),
      fixture.original,
    );
    expect(handshakeErrors.every((error) => error is HandshakeException), true);
  });

  for (final secure in [false, true])
    for (final timeout in [false, true])
      test(
        'custom ${secure ? 'TLS handshake' : 'HTTP response'} ${timeout ? 'timeout' : 'cancellation'} closes the owned connection',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'busyapi-custom-cancel-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final server = await ServerSocket.bind(
                InternetAddress.loopbackIPv4,
                0,
              ),
              arrived = Completer<void>(),
              closed = Completer<void>();
          final sockets = <Socket>{};
          addTearDown(() async {
            for (final socket in sockets.toList()) {
              socket.destroy();
            }
            await server.close();
          });
          server.listen((socket) {
            sockets.add(socket);
            socket.listen(
              (bytes) {
                if (!arrived.isCompleted) arrived.complete();
              },
              onDone: () {
                sockets.remove(socket);
                socket.destroy();
                if (!closed.isCompleted) closed.complete();
              },
              onError: (Object error) {
                if (!closed.isCompleted) closed.complete();
              },
            );
          });
          final fixture = await openProject(
            directory,
            Uri.parse(
              '${secure ? 'https' : 'http'}://127.0.0.1:${server.port}',
            ),
          );
          final plan = await methodPlan(fixture.project, fixture.root, 'purge'),
              cancel = RunCancellation();
          final call = const ContractRequestExecutor().execute(
            plan,
            OperationRequestDraft(
              planIdentity: plan.identity,
              overallTimeout: timeout
                  ? const Duration(milliseconds: 500)
                  : const Duration(seconds: 15),
              body: const RequestBodyDraft.raw(
                mediaType: 'text/plain',
                text: 'cancelled body',
              ),
            ),
            resolveSecret: (_) async => null,
            cancellation: cancel,
          );
          final check = expectLater(
            call,
            throwsA(
              isA<CoreFailure>().having(
                (failure) => failure.code,
                'failure reason',
                timeout ? 'request.timeout' : 'cancelled',
              ),
            ),
          );
          await arrived.future.timeout(const Duration(seconds: 5));
          if (!timeout) cancel.cancel();
          await check.timeout(const Duration(seconds: 5));
          await closed.future.timeout(const Duration(seconds: 5));
          expect(
            File.fromUri(Uri.parse(fixture.root)).readAsStringSync(),
            fixture.original,
          );
        },
      );
}
