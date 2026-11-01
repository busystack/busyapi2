// Shared VM/AOT regression oracle; not part of the distributed application.
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';

import 'test_support.dart';

Future<void> verifyLongRedirects(
  String location, {
  String version = '3.2.1',
}) async {
  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  final dir = await Directory.systemTemp.createTemp('busyapi-long-redirect-');
  final engine = EngineProcess(executable: runtimeNode, helper: runtimeHelper);
  HttpServer? origin, destination;
  BusyProject? project;
  OperationRequestPlan? plan;
  var destinationRequests = 0, requests = 0;
  var selected = '', scenario = '', target = '';
  final wireFailures = <String>[];
  try {
    destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    destination.listen((request) async {
      destinationRequests++;
      request.response.statusCode = 204;
      await request.response.close();
    });
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      requests++;
      final credential = location == 'header'
          ? request.headers.value('api_key')
          : Uri.decodeQueryComponent(
              request.uri.query
                  .split('&')
                  .singleWhere((part) => part.startsWith('api_key='))
                  .substring('api_key='.length),
            );
      if (credential != selected ||
          !request.uri.query.startsWith('opaque=%E9&tag=one%2Ftwo')) {
        wireFailures.add('$location ${selected.length} $scenario');
      }
      request.response.statusCode = scenario == 'ok' ? 200 : 302;
      if (scenario != 'ok') request.response.headers.set('location', target);
      request.response.write('{}');
      await request.response.close();
    });
    final base =
        'http://127.0.0.1:${origin.port}/base?opaque=%E9&tag=one%2Ftwo';
    await File('${dir.path}/openapi.yaml').writeAsString('''openapi: $version
info: {title: Long credential, version: "1"}
servers: [{url: '${version == '3.0.4' ? base : base.split('?').first}'}]
security: [{key: []}]
components: {securitySchemes: {key: {type: apiKey, in: $location, name: api_key}}}
paths: {/pets: {get: {responses: {'200': {description: ok}, '302': {description: redirect}}}}}
''');
    await File('${dir.path}/busyapi.yaml').writeAsString(
      'version: 1\nroots: [{name: api, path: openapi.yaml}]\nenvironments: {local: {${version == '3.0.4' ? '' : "baseUrl: '$base', "}authentication: {alternative: 0, schemes: {key: {secretRef: 123e4567-e89b-42d3-a456-426614174000}}}}}\n',
    );
    project = await BusyProject.open(dir.path, engine);
    final root = project.roots.single.id;
    final analysis = await project.check(root, schemaEvaluation: false);
    final operation =
        ((analysis['projection'] as Map? ?? analysis)['operations'] as List)
                .single
            as Map;
    plan = await project.prepareRequest(
      root,
      resource: operation['resource'] as String,
      pointer: operation['pointer'] as String,
      occurrence: operation['occurrence'] as String,
    );
    for (final length in [100, 5000, 65536]) {
      const suffix = '/plus+equals=end';
      selected = '${'A' * (length - suffix.length)}$suffix';
      for (final mode in ['ok', 'ordinary', 'literal', 'mixed']) {
        scenario = mode;
        final base = 'http://127.0.0.1:${destination.port}/target';
        final spelling = mode == 'mixed'
            ? selected.replaceAll('+', '%2B').replaceAll('=', '%3D')
            : selected;
        target = mode == 'ordinary'
            ? '$base?ordinary=retained&opaque=%E9&tag=one%2Ftwo'
            : '$base?reflected=$spelling&opaque=%E9&tag=one%2Ftwo';
        final request = await const ContractRequestBuilder().build(
          plan,
          OperationRequestDraft(
            planIdentity: plan.identity,
            environment: 'local',
            securityAlternative: 0,
          ),
          resolveSecret: (_) async => selected,
        );
        final response = await const ContractHttpTransport().send(request);
        try {
          final label = '$location $length $mode';
          check(response.status == (mode == 'ok' ? 200 : 302), '$label status');
          check(response.receiptComplete, '$label receipt');
          if (mode == 'ok') {
            check(response.redirects.isEmpty, '$label unexpected redirect');
          } else {
            check(
              response.incompleteReason == 'cross-origin-redirect-not-followed',
              '$label origin guard',
            );
            check(
              response.redirects.single ==
                  (mode == 'ordinary'
                      ? target
                      : '$base?reflected=[REDACTED]&opaque=%E9&tag=one%2Ftwo'),
              '$label summary',
            );
            check(
              response.headers.contains(('location', target)),
              '$label original header',
            );
          }
        } finally {
          await response.close();
        }
      }
    }
    check(requests == 12 && wireFailures.isEmpty, '$location outgoing wire');
    check(destinationRequests == 0, '$location destination received a request');
  } finally {
    plan?.close();
    project?.close();
    await engine.close();
    await origin?.close(force: true);
    await destination?.close(force: true);
    await dir.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  final version = args.length > 1 ? args[1] : '3.2.1';
  if (args.length > 2 || !['3.0.4', '3.1.2', '3.2.1'].contains(version)) {
    throw ArgumentError('Expected optional LOCATION VERSION fixture arguments');
  }
  for (final location in args.isEmpty ? ['header', 'query'] : [args[0]]) {
    await verifyLongRedirects(location, version: version);
    stdout.writeln('R14-E $location long redirect controls passed');
  }
}
